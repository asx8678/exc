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
  alias CodePuppyControl.LLM.SystemPrompt

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

    # Normalize system prompt: extract from messages + merge with opts
    {instructions, chat_messages} =
      SystemPrompt.normalize(:chatgpt_codex, messages, system_prompt)

    # Convert non-system messages to Responses-style input
    input = messages_to_input(chat_messages)

    body =
      %{
        "model" => model,
        "input" => input,
        "stream" => true,
        "store" => false
      }
      |> maybe_put_instructions(instructions)
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
  #
  # (code_puppy-be7.2) Threads an ID tracker through message processing so
  # that synthetic IDs generated for empty tool_call ids are consistent
  # between the assistant function_call and the corresponding tool-result
  # function_call_output. Without this, the Responses API would reject the
  # request with "invalid input[*].id" when tool-result call_ids don't match
  # any function_call id.
  # (code_puppy-be7.4) The tracker now maps original id → call_id (the
  # correlation id), while function_call.id is a separate fc-prefixed
  # response-item id. Tool outputs match on call_id, not on the item id.
  defp messages_to_input(messages) do
    tracker = %{by_id: %{}, empty_queue: :queue.new()}

    {items, _tracker} =
      messages
      |> Enum.reject(fn
        %{role: "system"} -> true
        %{"role" => "system"} -> true
        _ -> false
      end)
      |> Enum.map_reduce(tracker, &input_items_from_message/2)

    Enum.concat(items)
  end

  # Assistant messages with tool_calls produce the message item AND separate
  # function_call items in the flat input array.  This matches the Responses API
  # wire format where tool calls are siblings of messages, not nested inside them.
  defp input_items_from_message(%{role: role, content: content} = msg, tracker)
       when role in ["user", "assistant"] do
    item = %{"role" => role, "content" => content || ""}

    case Map.get(msg, :tool_calls) do
      nil ->
        {[item], tracker}

      tool_calls ->
        {fcs, tracker} = Enum.map_reduce(tool_calls, tracker, &format_tool_call_for_input/2)
        {[item | fcs], tracker}
    end
  end

  defp input_items_from_message(%{"role" => role, "content" => content} = msg, tracker)
       when role in ["user", "assistant"] do
    item = %{"role" => role, "content" => content || ""}

    case Map.get(msg, "tool_calls") do
      nil ->
        {[item], tracker}

      tool_calls ->
        {fcs, tracker} = Enum.map_reduce(tool_calls, tracker, &format_tool_call_for_input/2)
        {[item | fcs], tracker}
    end
  end

  defp input_items_from_message(%{role: "tool", content: content, tool_call_id: call_id}, tracker) do
    # (code_puppy-be7) Never emit empty call_id — generate a safe one
    # so the Responses API doesn't reject the request.
    # (code_puppy-be7.2) Look up the tracker for previously generated IDs
    # (from format_tool_call_for_input) to ensure matching call_ids.
    # (code_puppy-be7.3) resolve returns {safe_id, updated_tracker} so the
    # empty_queue is properly consumed.
    {safe_id, tracker} = resolve_tool_result_call_id(call_id, tracker)

    {[%{"type" => "function_call_output", "call_id" => safe_id, "output" => content || ""}],
     tracker}
  end

  defp input_items_from_message(
         %{
           "role" => "tool",
           "content" => content,
           "tool_call_id" => call_id
         },
         tracker
       ) do
    {safe_id, tracker} = resolve_tool_result_call_id(call_id, tracker)

    {[%{"type" => "function_call_output", "call_id" => safe_id, "output" => content || ""}],
     tracker}
  end

  defp input_items_from_message(%{role: role, content: content}, tracker) do
    {[%{"role" => role, "content" => content || ""}], tracker}
  end

  defp input_items_from_message(%{"role" => role, "content" => content}, tracker) do
    {[%{"role" => role, "content" => content || ""}], tracker}
  end

  defp format_tool_call_for_input(%{id: id, type: _type, function: func}, tracker) do
    # (code_puppy-be7.4) The Responses API requires two separate IDs on
    # function_call input items:
    #   - "id"      — the response-item id, must start with "fc" (e.g. "fc_abc123")
    #   - "call_id"  — the tool-call correlation id (e.g. "call_mS6k...")
    # Previously both were set to the same sanitized tool-call id, which
    # failed when that id started with "call_" instead of "fc".
    call_id = sanitize_tool_call_id(id, func.name)

    # Generate a valid fc-prefixed response-item id.
    # If the original id already starts with "fc_" and is valid, reuse it
    # as the item id (it satisfies both requirements). Otherwise, generate
    # a fresh fc-prefixed id.
    item_id = fc_item_id_for(id, call_id)

    # Track by call_id for tool-result matching.
    # When the original ID was empty, the tool-result tool_call_id will
    # also be empty — use this tracker to retrieve the same call_id.
    tracker = track_id(tracker, id, func.name, call_id)

    {%{
       "type" => "function_call",
       "id" => item_id,
       "call_id" => call_id,
       "name" => func.name,
       "arguments" => func.arguments
     }, tracker}
  end

  defp format_tool_call_for_input(%{"id" => id, "type" => _type, "function" => func}, tracker) do
    call_id = sanitize_tool_call_id(id, func["name"])
    item_id = fc_item_id_for(id, call_id)
    tracker = track_id(tracker, id, func["name"], call_id)

    {%{
       "type" => "function_call",
       "id" => item_id,
       "call_id" => call_id,
       "name" => func["name"],
       "arguments" => func["arguments"]
     }, tracker}
  end

  # Track synthetic IDs so tool-result call_ids can look up the matching
  # function_call id.  The tracker is a map with two keys:
  #   :by_id       — map of original_id => safe_id for non-empty original IDs
  #   :empty_queue — :queue of safe_ids for empty/nil original IDs (FIFO)
  #
  # (code_puppy-be7.3) Using a queue for empty IDs prevents the bug where
  # multiple empty-id tool calls overwrite tracker[""], causing all
  # function_call_output items to reference the last synthetic ID.
  defp track_id(tracker, id, _name, safe_id) when is_binary(id) and id != "" do
    # Original ID was non-empty. Track it by original id so tool results
    # with the same original call_id find the matching synthetic ID.
    put_in(tracker, [:by_id, id], safe_id)
  end

  defp track_id(tracker, _id, _name, safe_id) do
    # Original ID was empty/nil — enqueue the synthetic ID so tool results
    # with empty call_id consume them in order.
    update_in(tracker, [:empty_queue], &:queue.in(safe_id, &1))
  end

  # Resolve tool-result call_id by looking up the tracker, returning
  # {safe_id, updated_tracker} so the FIFO queue is properly consumed.
  #
  # (code_puppy-be7.3) Empty/nil call_ids consume from the FIFO queue so
  # multiple empty-id tool calls pair correctly in order.
  # Invalid non-empty call_ids look up in :by_id first; if absent,
  # sanitize/generate a safe ID.
  defp resolve_tool_result_call_id(call_id, tracker) when is_binary(call_id) and call_id != "" do
    # Try tracker first (in case the original ID was sanitized to a different
    # value in format_tool_call_for_input, e.g., invalid characters stripped)
    case tracker.by_id[call_id] do
      nil ->
        # Not tracked; sanitize invalid characters to prevent 400 errors
        {sanitize_tool_call_id(call_id, nil), tracker}

      safe_id ->
        {safe_id, tracker}
    end
  end

  defp resolve_tool_result_call_id(_call_id, tracker) do
    # Empty/nil call_id: consume the next synthetic ID from the FIFO queue.
    case :queue.out(tracker.empty_queue) do
      {{:value, safe_id}, rest} ->
        {safe_id, %{tracker | empty_queue: rest}}

      {:empty, _rest} ->
        # No queued IDs (shouldn't happen in normal flows); generate fallback
        {sanitize_tool_call_id(nil, nil), tracker}
    end
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

  # (code_puppy-be7) Sanitize tool-call IDs for the Responses API.
  # The API requires IDs that contain only letters, numbers, underscores,
  # and dashes. Empty IDs cause 400 errors. When no valid ID is available,
  # generate a deterministic safe ID.
  #
  # (code_puppy-be7.2) Also validate the character set for non-empty IDs:
  # existing IDs with characters outside [A-Za-z0-9_-] are sanitized too.
  @spec sanitize_tool_call_id(String.t() | nil, String.t() | nil) :: String.t()
  defp sanitize_tool_call_id(id, name) when is_binary(id) and id != "" do
    # Validate character set: Responses API only allows [A-Za-z0-9_-]
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, id), do: id, else: generate_safe_call_id(name)
  end

  defp sanitize_tool_call_id(_id, name) do
    generate_safe_call_id(name)
  end

  defp generate_safe_call_id(name) do
    base = name || "call"
    safe_base = String.replace(base, ~r/[^A-Za-z0-9_-]/, "_")
    "call_#{safe_base}_#{safe_id_suffix()}"
  end

  # (code_puppy-be7.4) Generate a valid fc-prefixed response-item id for
  # function_call input items. The Responses API requires input[*].id to
  # start with "fc" (e.g. "fc_abc123").
  #
  # Backward-compat: old history may only have one %{id: ...} field.
  # We treat that field as the call_id UNLESS it already looks like an
  # fc-prefixed response item id (starts with "fc_" and is valid). In that
  # case we reuse it as the item id since it satisfies the fc-prefix
  # requirement. In all other cases we generate a fresh fc-prefixed id,
  # keeping the original sanitized value as the call_id for correlation.
  @spec fc_item_id_for(String.t() | nil, String.t()) :: String.t()
  defp fc_item_id_for(original_id, _call_id)
       when is_binary(original_id) and original_id != "" do
    if String.starts_with?(original_id, "fc_") and
         Regex.match?(~r/^[A-Za-z0-9_-]+$/, original_id) do
      # Original id already looks like an fc response-item id — reuse as-is.
      original_id
    else
      # Original id is a call correlation id (e.g. "call_mS6k...") —
      # generate a separate fc-prefixed response-item id.
      generate_fc_item_id()
    end
  end

  defp fc_item_id_for(_original_id, _call_id) do
    generate_fc_item_id()
  end

  defp generate_fc_item_id do
    "fc_#{safe_id_suffix()}"
  end

  # Generate a short, deterministic-safe suffix for synthetic call IDs.
  defp safe_id_suffix do
    System.unique_integer([:positive])
    |> Integer.to_string()
  end
end
