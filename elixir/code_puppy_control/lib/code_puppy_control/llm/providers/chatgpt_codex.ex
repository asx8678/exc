defmodule CodePuppyControl.LLM.Providers.ChatGPTCodex do
  @moduledoc """
  ChatGPT Codex (Responses-style) provider for OAuth-backed ChatGPT models.

  Implements `CodePuppyControl.LLM.Provider` for the ChatGPT Codex backend
  at `https://chatgpt.com/backend-api/codex`, which uses the Responses API
  wire format (`/responses`) rather than OpenAI Chat Completions.

  ## Key Differences from OpenAI Chat Completions

  - Endpoint: `<base_url>/responses` (not `/v1/chat/completions`)
  - Body uses `input` instead of `messages`
  - `instructions` field for system prompt (not a system message)
  - `store: false` and `stream: true` are mandatory
  - `reasoning` defaults injected for gpt-5 and o-series models
  - Unsupported params: `max_tokens`, `max_output_tokens`, `verbosity`
  - Tools use Responses-style format: `%{"type" => "function", "name" => ..., "parameters" => ...}`
  - SSE events use `response.output_text.delta`, `response.function_call_arguments.delta`,
    `response.completed`, etc.

  ## Configuration

  Accepts these options:
  - `:api_key` — OAuth access token (required, injected by RuntimeConnection)
  - `:base_url` — API base URL (default: `"https://chatgpt.com/backend-api/codex"`)
  - `:model` — Model name (default: `"gpt-5.4"`)
  - `:temperature` — Sampling temperature
  - `:system_prompt` — System prompt mapped to `instructions`
  - `:reasoning` — Reasoning config override (e.g. `%{"effort" => "high", "summary" => "auto"}`)
  - `:http_client` — HTTP client module (default: `CodePuppyControl.HttpClient`)
  - `:extra_headers` — Additional headers from RuntimeConnection
  """

  @behaviour CodePuppyControl.LLM.Provider

  alias CodePuppyControl.LLM.Provider
  alias CodePuppyControl.LLM.Providers.ChatGPTCodex.Streaming

  @default_base_url "https://chatgpt.com/backend-api/codex"
  @default_model "gpt-5.4"

  # Reasoning model prefixes that get default reasoning config
  @reasoning_prefixes ~w(gpt-5 o1 o3 o4)

  # ── Provider Callbacks ────────────────────────────────────────────────────

  @impl Provider
  def chat(messages, tools, opts \\ []) do
    # The Codex backend requires stream=true, so we stream internally
    # and collect into a single response.
    collected = collect_stream(messages, tools, opts)

    case collected do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Provider
  def stream_chat(messages, tools, opts \\ [], callback_fn) do
    http_client = Keyword.get(opts, :http_client, CodePuppyControl.HttpClient)
    {url, headers, body} = build_request(messages, tools, opts)

    stream =
      http_client.stream(:post, url,
        headers: headers,
        body: Jason.encode!(body)
      )

    initial_acc = %{
      line_buf: "",
      current_data: "",
      id: nil,
      model: nil,
      content_parts: %{},
      tool_calls: %{},
      usage: nil,
      finish_reason: nil
    }

    case Enum.reduce(stream, {:ok, initial_acc}, fn
           {:data, chunk}, {:ok, acc} ->
             {events, acc} = Streaming.parse_sse_chunk(chunk, acc)

             Enum.reduce_while(events, {:ok, acc}, fn event, {:ok, acc} ->
               case Streaming.handle_sse_event(event, acc, callback_fn) do
                 {:ok, acc} -> {:cont, {:ok, acc}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end)

           {:done, _metadata}, {:ok, acc} ->
             Streaming.emit_done(acc, callback_fn)
             {:ok, acc}

           {:error, details}, {:ok, _acc} ->
             {:error, details}

           _event, {:error, reason} ->
             {:error, reason}
         end) do
      {:ok, _acc} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Provider
  def supports_tools?, do: true

  @impl Provider
  def supports_vision?, do: false

  # ── Private: chat/3 collection ───────────────────────────────────────────

  defp collect_stream(messages, tools, opts) do
    ref = make_ref()
    test_pid = self()

    result =
      stream_chat(messages, tools, opts, fn
        {:done, response} ->
          send(test_pid, {ref, {:response, response}})
          :ok

        _ ->
          :ok
      end)

    case result do
      :ok ->
        receive do
          {^ref, {:response, response}} -> {:ok, response}
        after
          5_000 -> {:error, :no_response_collected}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private: Request Building ─────────────────────────────────────────────

  defp build_request(messages, tools, opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = Keyword.get(opts, :model, @default_model)
    api_key = Keyword.get(opts, :api_key) || ""
    system_prompt = Keyword.get(opts, :system_prompt)

    url = build_url(base_url)

    headers =
      [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]
      |> merge_extra_headers(opts)

    # Convert OpenAI-style messages to Responses-style input
    input = messages_to_input(messages)

    body =
      %{
        "model" => model,
        "input" => input,
        "stream" => true,
        "store" => false
      }
      |> maybe_put_instructions(system_prompt)
      |> maybe_put_tools(tools)
      |> maybe_put_reasoning(model, opts)
      |> maybe_put("temperature", Keyword.get(opts, :temperature))

    {url, headers, body}
  end

  # Build URL: append /responses to base_url, avoiding duplication.
  defp build_url(base_url) do
    normalized = String.trim_trailing(base_url, "/")

    if String.ends_with?(normalized, "/responses") do
      normalized
    else
      "#{normalized}/responses"
    end
  end

  # Convert OpenAI-style messages to Responses-style input items.
  # System messages are extracted as `instructions` (handled separately),
  # not included in input. User/assistant/tool messages become input items.
  defp messages_to_input(messages) do
    messages
    |> Enum.reject(fn
      %{role: "system"} -> true
      %{"role" => "system"} -> true
      _ -> false
    end)
    |> Enum.flat_map(&input_items_from_message/1)
  end

  # Assistant messages with tool_calls produce the message item AND separate
  # function_call items in the flat input array.  This matches the Responses API
  # wire format where tool calls are siblings of messages, not nested inside them.
  defp input_items_from_message(%{role: role, content: content} = msg)
       when role in ["user", "assistant"] do
    item = %{"role" => role, "content" => content || ""}

    case Map.get(msg, :tool_calls) do
      nil ->
        [item]

      tool_calls ->
        function_calls = Enum.map(tool_calls, &format_tool_call_for_input/1)
        [item | function_calls]
    end
  end

  defp input_items_from_message(%{"role" => role, "content" => content} = msg)
       when role in ["user", "assistant"] do
    item = %{"role" => role, "content" => content || ""}

    case Map.get(msg, "tool_calls") do
      nil ->
        [item]

      tool_calls ->
        function_calls = Enum.map(tool_calls, &format_tool_call_for_input/1)
        [item | function_calls]
    end
  end

  defp input_items_from_message(%{role: "tool", content: content, tool_call_id: call_id}) do
    [%{"type" => "function_call_output", "call_id" => call_id || "", "output" => content || ""}]
  end

  defp input_items_from_message(%{
         "role" => "tool",
         "content" => content,
         "tool_call_id" => call_id
       }) do
    [%{"type" => "function_call_output", "call_id" => call_id || "", "output" => content || ""}]
  end

  defp input_items_from_message(%{role: role, content: content}) do
    [%{"role" => role, "content" => content || ""}]
  end

  defp input_items_from_message(%{"role" => role, "content" => content}) do
    [%{"role" => role, "content" => content || ""}]
  end

  defp format_tool_call_for_input(%{id: id, type: _type, function: func}) do
    %{
      "type" => "function_call",
      "id" => id || "",
      "call_id" => id || "",
      "name" => func.name,
      "arguments" => func.arguments
    }
  end

  defp format_tool_call_for_input(%{"id" => id, "type" => _type, "function" => func}) do
    %{
      "type" => "function_call",
      "id" => id || "",
      "call_id" => id || "",
      "name" => func["name"],
      "arguments" => func["arguments"]
    }
  end

  # If system_prompt is provided via opts, put it as `instructions`.
  defp maybe_put_instructions(body, nil), do: body
  defp maybe_put_instructions(body, ""), do: body

  defp maybe_put_instructions(body, system_prompt) when is_binary(system_prompt) do
    Map.put(body, "instructions", system_prompt)
  end

  defp maybe_put_instructions(body, _), do: body

  # Convert OpenAI-style tools to Responses-style tools.
  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, nil), do: body

  defp maybe_put_tools(body, tools) when is_list(tools) do
    responses_tools = Enum.map(tools, &format_responses_tool/1)
    Map.put(body, "tools", responses_tools)
  end

  defp format_responses_tool(%{type: _type, function: func}) do
    %{
      "type" => "function",
      "name" => func.name,
      "description" => func.description,
      "parameters" => func.parameters
    }
  end

  defp format_responses_tool(%{"type" => _type, "function" => func}) do
    %{
      "type" => "function",
      "name" => func["name"],
      "description" => func["description"],
      "parameters" => func["parameters"]
    }
  end

  # Add reasoning defaults for gpt-5 and o-series models, unless already set.
  defp maybe_put_reasoning(body, model, opts) do
    cond do
      # Explicit override from opts
      reasoning = Keyword.get(opts, :reasoning) ->
        Map.put(body, "reasoning", reasoning)

      # Already in body
      Map.has_key?(body, "reasoning") ->
        body

      # Auto-inject for reasoning models
      reasoning_model?(model) ->
        Map.put(body, "reasoning", %{"effort" => "medium", "summary" => "auto"})

      true ->
        body
    end
  end

  defp reasoning_model?(model) when is_binary(model) do
    model_lower = String.downcase(model)
    Enum.any?(@reasoning_prefixes, &String.starts_with?(model_lower, &1))
  end

  defp reasoning_model?(_), do: false

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  # Merge extra_headers from opts into the header list.
  defp merge_extra_headers(headers, opts) do
    case Keyword.get(opts, :extra_headers) do
      nil -> headers
      extra when is_list(extra) -> headers ++ extra
      _ -> headers
    end
  end
end
