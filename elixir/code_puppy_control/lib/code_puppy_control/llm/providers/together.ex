defmodule CodePuppyControl.LLM.Providers.Together do
  @moduledoc """
  Together AI inference provider.

  Implements `CodePuppyControl.LLM.Provider` for Together AI's OpenAI-compatible
  `/v1/chat/completions` API.

  ## Features

  - Non-streaming chat completions
  - SSE streaming with `data: {...}\\n\\n` format and `data: [DONE]` terminator
  - Tool calling support (OpenAI-compatible format)
  - Usage tracking (prompt/completion tokens)

  ## Configuration

  Accepts these options:
  - `:api_key` — Together API key (required, or `TOGETHER_API_KEY` env var)
  - `:base_url` — API base URL (default: `"https://api.together.xyz"`)
  - `:model` — Model name (default: `"meta-llama/Llama-3-70b-chat-hf"`)
  - `:temperature` — Sampling temperature
  - `:max_tokens` — Maximum tokens to generate
  - `:http_client` — HTTP client module (default: `CodePuppyControl.HttpClient`)
  """

  @behaviour CodePuppyControl.LLM.Provider

  alias CodePuppyControl.LLM.Provider
  alias CodePuppyControl.LLM.SystemPrompt

  @default_base_url "https://api.together.xyz"
  @default_model "meta-llama/Llama-3-70b-chat-hf"

  # ── Provider Callbacks ────────────────────────────────────────────────────

  @impl Provider
  def chat(messages, tools, opts \\ []) do
    http_client = Keyword.get(opts, :http_client, CodePuppyControl.HttpClient)
    {url, headers, body} = build_request(messages, tools, opts)

    case http_client.request(:post, url, headers: headers, body: Jason.encode!(body)) do
      {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
        parse_chat_response(resp_body)

      {:ok, %{status: status, body: resp_body}} ->
        {:error, %{status: status, body: parse_error_body(resp_body)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Provider
  def stream_chat(messages, tools, opts \\ [], callback_fn) do
    http_client = Keyword.get(opts, :http_client, CodePuppyControl.HttpClient)
    {url, headers, body} = build_request(messages, tools, Keyword.put(opts, :stream, true))

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
             {events, acc} = parse_sse_chunk(chunk, acc)

             Enum.reduce_while(events, {:ok, acc}, fn event, {:ok, acc} ->
               case handle_sse_event(event, acc, callback_fn) do
                 {:ok, acc} -> {:cont, {:ok, acc}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end)

           {:done, _metadata}, {:ok, acc} ->
             emit_done(acc, callback_fn)
             {:ok, acc}

           {:error, msg}, {:ok, _acc} ->
             {:error, msg}

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

  # ── Private: Request Building ─────────────────────────────────────────────

  defp build_request(messages, tools, opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = Keyword.get(opts, :model, @default_model)
    api_key = Keyword.get(opts, :api_key) || resolve_api_key()
    stream = Keyword.get(opts, :stream, false)

    url = build_url(base_url)

    headers =
      [
        {"authorization", "Bearer #{api_key}"},
        {"content-type", "application/json"}
      ]
      |> merge_extra_headers(opts)

    # Normalize system prompt: ensure system prompt opt is in messages
    normalized_messages =
      SystemPrompt.ensure_in_messages(messages, Keyword.get(opts, :system_prompt))

    body =
      %{
        "model" => model,
        "messages" => Enum.map(normalized_messages, &format_message/1),
        "stream" => stream
      }
      |> maybe_put("temperature", Keyword.get(opts, :temperature))
      |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
      |> maybe_put_tools(tools)

    {url, headers, body}
  end

  defp format_message(%{role: role, content: content} = msg) do
    %{"role" => role, "content" => content}
    |> maybe_put_tool_calls(Map.get(msg, :tool_calls))
    |> maybe_put("tool_call_id", Map.get(msg, :tool_call_id))
  end

  defp format_message(%{"role" => role, "content" => content} = msg) do
    %{"role" => role, "content" => content}
    |> maybe_put_tool_calls(Map.get(msg, "tool_calls"))
    |> maybe_put("tool_call_id", Map.get(msg, "tool_call_id"))
  end

  defp maybe_put_tool_calls(body, nil), do: body

  defp maybe_put_tool_calls(body, tool_calls) when is_list(tool_calls) do
    Map.put(body, "tool_calls", Enum.map(tool_calls, &format_tool_call/1))
  end

  defp format_tool_call(%{id: id, type: type, function: func}) do
    %{
      "id" => id,
      "type" => type,
      "function" => %{"name" => func.name, "arguments" => func.arguments}
    }
  end

  defp format_tool_call(%{"id" => id, "type" => type, "function" => func}) do
    %{
      "id" => id,
      "type" => type,
      "function" => %{"name" => func["name"], "arguments" => func["arguments"]}
    }
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, nil), do: body

  defp maybe_put_tools(body, tools) when is_list(tools) do
    Map.put(body, "tools", Enum.map(tools, &format_tool/1))
  end

  defp format_tool(%{type: type, function: func}) do
    %{
      "type" => type,
      "function" => %{
        "name" => func.name,
        "description" => func.description,
        "parameters" => func.parameters
      }
    }
  end

  defp format_tool(%{"type" => type, "function" => func}) do
    %{
      "type" => type,
      "function" => %{
        "name" => func["name"],
        "description" => func["description"],
        "parameters" => func["parameters"]
      }
    }
  end

  # ── Private: Response Parsing ─────────────────────────────────────────────

  defp parse_chat_response(body) do
    case Jason.decode(body) do
      {:ok, %{"choices" => [choice | _]} = resp} ->
        message = choice["message"] || %{}
        tool_calls = parse_tool_calls(message["tool_calls"] || [])

        {:ok,
         %{
           id: resp["id"] || "",
           model: resp["model"] || "",
           content: message["content"],
           tool_calls: tool_calls,
           finish_reason: choice["finish_reason"],
           usage: parse_usage(resp["usage"])
         }}

      {:ok, %{"error" => error}} ->
        {:error, %{body: error}}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp parse_tool_calls(nil), do: []

  defp parse_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      %{
        id: tc["id"] || "",
        name: get_in(tc, ["function", "name"]) || "",
        arguments: parse_arguments(get_in(tc, ["function", "arguments"]) || "{}")
      }
    end)
  end

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> args
    end
  end

  defp parse_arguments(args), do: args

  defp parse_usage(nil), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp parse_usage(usage) do
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
      total_tokens: usage["total_tokens"] || 0
    }
  end

  defp parse_error_body(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> error
      _ -> body
    end
  end

  # ── Private: SSE Streaming ────────────────────────────────────────────────

  defp parse_sse_chunk(chunk, acc) do
    combined = acc.line_buf <> chunk
    lines = :binary.split(combined, "\n", [:global])
    ends_with_newline = byte_size(combined) > 0 and :binary.last(combined) == ?\n

    {complete, remaining} =
      if ends_with_newline do
        {Enum.drop(lines, -1), ""}
      else
        {Enum.drop(lines, -1), List.last(lines)}
      end

    {events, data_buf} =
      Enum.reduce(complete, {[], acc.current_data}, fn line, {events, data_buf} ->
        case line do
          "" ->
            if data_buf != "" do
              {[data_buf | events], ""}
            else
              {events, ""}
            end

          "data: " <> data ->
            new_buf = if data_buf == "", do: data, else: data_buf <> "\n" <> data
            {events, new_buf}

          _ ->
            {events, data_buf}
        end
      end)

    {Enum.reverse(events), %{acc | line_buf: remaining, current_data: data_buf}}
  end

  defp handle_sse_event("DONE", acc, _callback_fn) do
    {:ok, acc}
  end

  defp handle_sse_event(data, acc, callback_fn) do
    case Jason.decode(data) do
      {:ok, %{"choices" => [choice | _]} = resp} ->
        acc = maybe_set_meta(acc, resp)
        delta = choice["delta"] || %{}
        acc = process_delta(delta, acc, callback_fn)

        case choice["finish_reason"] do
          nil -> {:ok, acc}
          reason -> {:ok, %{acc | finish_reason: reason}}
        end

      {:ok, %{"error" => error}} ->
        {:error, %{status: 200, body: error}}

      {:error, _reason} ->
        {:ok, acc}
    end
  end

  defp maybe_set_meta(acc, resp) do
    acc
    |> Map.put(:id, resp["id"] || acc.id)
    |> Map.put(:model, resp["model"] || acc.model)
    |> then(fn acc ->
      case resp["usage"] do
        nil -> acc
        usage -> %{acc | usage: parse_usage(usage)}
      end
    end)
  end

  defp process_delta(%{"content" => text}, acc, callback_fn)
       when is_binary(text) and text != "" do
    index = 0
    parts = acc.content_parts

    part =
      Map.get(parts, index, %{type: :text, index: index, text_chunks: []})

    is_new = part.text_chunks == []
    part = %{part | text_chunks: [text | part.text_chunks]}
    parts = Map.put(parts, index, part)
    acc = %{acc | content_parts: parts}

    if is_new do
      callback_fn.({:part_start, %{type: :text, index: index, id: nil}})
    end

    callback_fn.(
      {:part_delta, %{type: :text, index: index, text: text, name: nil, arguments: nil}}
    )

    acc
  end

  defp process_delta(%{"tool_calls" => tool_calls}, acc, callback_fn)
       when is_list(tool_calls) do
    Enum.reduce(tool_calls, acc, fn tc, acc ->
      index = tc["index"] || 0
      tc_id = tc["id"]
      func = tc["function"] || %{}
      tc_parts = acc.tool_calls

      part =
        Map.get(tc_parts, index, %{
          type: :tool_call,
          index: index,
          id: nil,
          name: nil,
          arg_chunks: []
        })

      is_new = part.id == nil and tc_id != nil

      part =
        part
        |> maybe_update(:id, tc_id)
        |> maybe_update(:name, func["name"])
        |> then(fn part ->
          case func["arguments"] do
            nil -> part
            "" -> part
            args -> %{part | arg_chunks: [args | part.arg_chunks]}
          end
        end)

      tc_parts = Map.put(tc_parts, index, part)
      acc = %{acc | tool_calls: tc_parts}

      if is_new do
        callback_fn.({:part_start, %{type: :tool_call, index: index, id: tc_id}})
      end

      if func["name"] do
        callback_fn.(
          {:part_delta,
           %{type: :tool_call, index: index, text: nil, name: func["name"], arguments: nil}}
        )
      end

      if func["arguments"] && func["arguments"] != "" do
        callback_fn.(
          {:part_delta,
           %{type: :tool_call, index: index, text: nil, name: nil, arguments: func["arguments"]}}
        )
      end

      acc
    end)
  end

  defp process_delta(_delta, acc, _callback_fn), do: acc

  defp maybe_update(map, _key, nil), do: map
  defp maybe_update(map, key, value), do: Map.put(map, key, value)

  defp emit_done(acc, callback_fn) do
    Enum.each(acc.content_parts, fn {_index, part} ->
      callback_fn.(
        {:part_end,
         %{
           type: :text,
           index: part.index,
           id: nil,
           name: nil,
           arguments: nil
         }}
      )
    end)

    Enum.each(acc.tool_calls, fn {_index, part} ->
      args = part.arg_chunks |> Enum.reverse() |> Enum.join()

      callback_fn.(
        {:part_end,
         %{
           type: :tool_call,
           index: part.index,
           id: part.id,
           name: part.name,
           arguments: args
         }}
      )
    end)

    tool_calls =
      acc.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_index, part} ->
        args = part.arg_chunks |> Enum.reverse() |> Enum.join()

        %{
          id: part.id || "",
          name: part.name || "",
          arguments: parse_arguments(args)
        }
      end)

    content =
      acc.content_parts
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map_join(fn {_index, part} ->
        part.text_chunks |> Enum.reverse() |> Enum.join()
      end)

    response = %{
      id: acc.id || "",
      model: acc.model || "",
      content: if(content == "", do: nil, else: content),
      tool_calls: tool_calls,
      finish_reason: acc.finish_reason,
      usage: acc.usage || %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}
    }

    callback_fn.({:done, response})
  end

  # ── Private: URL Building ─────────────────────────────────────────────────

  defp build_url(base_url) do
    normalized = String.replace_trailing(base_url, "/v1/", "")
    normalized = String.replace_trailing(normalized, "/v1", "")
    normalized = String.replace_trailing(normalized, "/", "")
    "#{normalized}/v1/chat/completions"
  end

  defp merge_extra_headers(headers, opts) do
    case Keyword.get(opts, :extra_headers) do
      nil -> headers
      extra when is_list(extra) -> headers ++ extra
      _ -> headers
    end
  end

  # ── Private: Config ───────────────────────────────────────────────────────

  defp resolve_api_key do
    CodePuppyControl.ModelFactory.Credentials.env_or_store("TOGETHER_API_KEY") || ""
  end
end
