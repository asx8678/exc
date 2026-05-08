defmodule CodePuppyControl.LLM.Providers.Google do
  @moduledoc """
  Google Gemini provider.

  Implements `CodePuppyControl.LLM.Provider` for Google's native Gemini
  `generateContent` API at `generativelanguage.googleapis.com/v1beta`.

  ## Features

  - Non-streaming chat completions
  - SSE streaming via `streamGenerateContent`
  - Function calling support (Gemini format)
  - Vision support (image inputs)

  ## Gemini API Differences from OpenAI

  - Messages use `contents` array with `parts` instead of flat `content`
  - System instructions are a top-level `systemInstruction` object
  - Tool definitions use `functionDeclarations` instead of `tools`
  - API key is passed as query parameter `?key=...`
  - Response has `candidates[].content.parts[]` structure
  - Usage metadata uses `promptTokenCount` / `candidatesTokenCount`

  ## Configuration

  Accepts these options:
  - `:api_key` — Google API key (required, or `GOOGLE_API_KEY` / `GEMINI_API_KEY` env var)
  - `:base_url` — API base URL (default: `"https://generativelanguage.googleapis.com"`)
  - `:model` — Model name (default: `"gemini-1.5-flash"`)
  - `:temperature` — Sampling temperature
  - `:max_tokens` — Maximum output tokens (`maxOutputTokens` in Gemini)
  - `:http_client` — HTTP client module (default: `CodePuppyControl.HttpClient`)
  """

  @behaviour CodePuppyControl.LLM.Provider

  alias CodePuppyControl.LLM.Provider
  alias CodePuppyControl.LLM.SystemPrompt

  @default_base_url "https://generativelanguage.googleapis.com"
  @default_model "gemini-1.5-flash"

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
  def supports_vision?, do: true

  # ── Private: Request Building ─────────────────────────────────────────────

  defp build_request(messages, tools, opts) do
    base_url = Keyword.get(opts, :base_url, @default_base_url)
    model = Keyword.get(opts, :model, @default_model)
    api_key = Keyword.get(opts, :api_key) || resolve_api_key()
    stream = Keyword.get(opts, :stream, false)

    url = build_url(base_url, model, api_key, stream)

    headers =
      [
        {"content-type", "application/json"}
      ]
      |> merge_extra_headers(opts)

    # Normalize system prompt: extract from messages + merge with opts
    {system_instruction, chat_messages} =
      SystemPrompt.normalize(:gemini, messages, Keyword.get(opts, :system_prompt))

    body =
      %{
        "contents" => Enum.map(chat_messages, &format_content/1)
      }
      |> maybe_put("systemInstruction", system_instruction)
      |> maybe_put("generationConfig", build_generation_config(opts))
      |> maybe_put_tool_declarations(tools)

    {url, headers, body}
  end

  defp build_url(base_url, model, api_key, true = _stream) do
    normalized = String.replace_trailing(base_url, "/", "")
    "#{normalized}/v1beta/models/#{model}:streamGenerateContent?alt=sse&key=#{api_key}"
  end

  defp build_url(base_url, model, api_key, _stream) do
    normalized = String.replace_trailing(base_url, "/", "")
    "#{normalized}/v1beta/models/#{model}:generateContent?key=#{api_key}"
  end

  # System prompt extraction and formatting is now handled by SystemPrompt.normalize/3

  # Convert OpenAI-style messages to Gemini `contents` format.
  # Gemini uses "user" and "model" roles (not "assistant").
  defp format_content(%{role: role, content: content} = msg) do
    gemini_role = to_gemini_role(role)

    parts = build_parts(content, msg)
    %{"role" => gemini_role, "parts" => parts}
  end

  defp format_content(%{"role" => role, "content" => content} = msg) do
    gemini_role = to_gemini_role(role)

    parts = build_parts(content, msg)
    %{"role" => gemini_role, "parts" => parts}
  end

  defp build_parts(content, msg) do
    text_parts = if content && content != "", do: [%{"text" => content}], else: []

    tool_call_parts =
      build_tool_call_parts(Map.get(msg, :tool_calls) || Map.get(msg, "tool_calls"))

    tool_result_parts =
      build_tool_result_parts(
        Map.get(msg, :tool_call_id) || Map.get(msg, "tool_call_id"),
        content
      )

    tool_call_parts ++ tool_result_parts ++ text_parts
  end

  defp build_tool_call_parts(nil), do: []

  defp build_tool_call_parts(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn
      %{id: id, function: %{name: name, arguments: args}} ->
        args_json = if is_binary(args), do: args, else: Jason.encode!(args)

        %{
          "functionCall" => %{
            "name" => name,
            "args" => parse_json_args(args_json)
          },
          "functionCallId" => id
        }

      %{"id" => id, "function" => %{"name" => name, "arguments" => args}} ->
        args_json = if is_binary(args), do: args, else: Jason.encode!(args)

        %{
          "functionCall" => %{
            "name" => name,
            "args" => parse_json_args(args_json)
          },
          "functionCallId" => id
        }

      _ ->
        %{}
    end)
  end

  defp build_tool_result_parts(nil, _content), do: []
  defp build_tool_result_parts(_tool_call_id, nil), do: []

  defp build_tool_result_parts(tool_call_id, content) do
    [
      %{
        "functionResponse" => %{
          "name" => tool_call_id,
          "response" => %{"result" => content}
        },
        "functionCallId" => tool_call_id
      }
    ]
  end

  defp parse_json_args(args_json) when is_binary(args_json) do
    case Jason.decode(args_json) do
      {:ok, parsed} -> parsed
      _ -> %{}
    end
  end

  defp parse_json_args(args), do: args

  defp to_gemini_role("assistant"), do: "model"
  defp to_gemini_role("tool"), do: "user"
  defp to_gemini_role(role), do: role

  defp build_generation_config(opts) do
    config = %{}

    config =
      case Keyword.get(opts, :temperature) do
        nil -> config
        temp -> Map.put(config, "temperature", temp)
      end

    config =
      case Keyword.get(opts, :max_tokens) do
        nil -> config
        max -> Map.put(config, "maxOutputTokens", max)
      end

    if map_size(config) == 0, do: nil, else: config
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp maybe_put_tool_declarations(body, []), do: body
  defp maybe_put_tool_declarations(body, nil), do: body

  defp maybe_put_tool_declarations(body, tools) when is_list(tools) do
    declarations =
      Enum.map(tools, fn
        %{type: _type, function: func} ->
          %{
            "name" => func.name,
            "description" => func.description,
            "parameters" => func.parameters
          }

        %{"type" => _type, "function" => func} ->
          %{
            "name" => func["name"],
            "description" => func["description"],
            "parameters" => func["parameters"]
          }
      end)

    Map.put(body, "tools", [%{"functionDeclarations" => declarations}])
  end

  # ── Private: Response Parsing ─────────────────────────────────────────────

  defp parse_chat_response(body) do
    case Jason.decode(body) do
      {:ok, %{"candidates" => [candidate | _]} = resp} ->
        content_parts = get_in(candidate, ["content", "parts"]) || []
        {text_content, tool_calls} = extract_parts(content_parts)

        finish_reason = candidate["finishReason"]

        {:ok,
         %{
           id: resp["responseId"] || "",
           model: resp["modelVersion"] || "",
           content: text_content,
           tool_calls: tool_calls,
           finish_reason: finish_reason,
           usage: parse_usage(resp["usageMetadata"])
         }}

      {:ok, %{"error" => error}} ->
        {:error, %{body: error}}

      {:error, reason} ->
        {:error, {:json_decode_error, reason}}
    end
  end

  defp extract_parts(parts) do
    {texts, tools} =
      Enum.split_with(parts, fn
        %{"text" => _} -> true
        _ -> false
      end)

    text =
      texts
      |> Enum.map_join(fn part -> part["text"] || "" end)
      |> then(fn t -> if t == "", do: nil, else: t end)

    tool_calls =
      Enum.map(tools, fn
        %{"functionCall" => fc, "functionCallId" => id} ->
          %{
            id: id || "",
            name: fc["name"] || "",
            arguments: fc["args"] || %{}
          }

        %{"functionCall" => fc} ->
          %{
            id: "",
            name: fc["name"] || "",
            arguments: fc["args"] || %{}
          }

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    {text, tool_calls}
  end

  defp parse_usage(nil), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp parse_usage(usage) do
    prompt = usage["promptTokenCount"] || 0
    completion = usage["candidatesTokenCount"] || 0
    total = usage["totalTokenCount"] || prompt + completion

    %{
      prompt_tokens: prompt,
      completion_tokens: completion,
      total_tokens: total
    }
  end

  defp parse_error_body(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} -> error
      _ -> body
    end
  end

  # ── Private: SSE Streaming ────────────────────────────────────────────────
  # Gemini SSE format uses `data: {...}\n\n` like OpenAI but no [DONE] marker.
  # The stream ends when the HTTP stream closes.

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

  defp handle_sse_event(data, acc, callback_fn) do
    case Jason.decode(data) do
      {:ok, %{"candidates" => [candidate | _]} = resp} ->
        acc = maybe_set_meta(acc, resp)
        parts = get_in(candidate, ["content", "parts"]) || []
        acc = process_parts(parts, acc, callback_fn)

        finish_reason = candidate["finishReason"]

        acc =
          case finish_reason do
            nil -> acc
            reason -> %{acc | finish_reason: reason}
          end

        {:ok, acc}

      {:ok, %{"error" => error}} ->
        {:error, %{status: 200, body: error}}

      {:error, _reason} ->
        # Skip malformed chunks
        {:ok, acc}
    end
  end

  defp maybe_set_meta(acc, resp) do
    acc
    |> Map.put(:id, resp["responseId"] || acc.id)
    |> Map.put(:model, resp["modelVersion"] || acc.model)
    |> then(fn acc ->
      case resp["usageMetadata"] do
        nil -> acc
        usage -> %{acc | usage: parse_usage(usage)}
      end
    end)
  end

  defp process_parts(parts, acc, callback_fn) do
    Enum.reduce(parts, acc, fn part, acc ->
      case part do
        %{"text" => text} when is_binary(text) and text != "" ->
          process_text_delta(text, acc, callback_fn)

        %{"functionCall" => fc} ->
          process_function_call(fc, part["functionCallId"], acc, callback_fn)

        _ ->
          acc
      end
    end)
  end

  defp process_text_delta(text, acc, callback_fn) do
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

  defp process_function_call(fc, call_id, acc, callback_fn) do
    index = map_size(acc.tool_calls)
    name = fc["name"] || ""

    part = %{
      type: :tool_call,
      index: index,
      id: call_id,
      name: name,
      arg_chunks: [Jason.encode!(fc["args"] || %{})]
    }

    tc_parts = Map.put(acc.tool_calls, index, part)
    acc = %{acc | tool_calls: tc_parts}

    callback_fn.({:part_start, %{type: :tool_call, index: index, id: call_id}})

    callback_fn.(
      {:part_delta, %{type: :tool_call, index: index, text: nil, name: name, arguments: nil}}
    )

    callback_fn.(
      {:part_delta,
       %{
         type: :tool_call,
         index: index,
         text: nil,
         name: nil,
         arguments: Jason.encode!(fc["args"] || %{})
       }}
    )

    acc
  end

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
          arguments: parse_json_args(args)
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

  defp merge_extra_headers(headers, opts) do
    case Keyword.get(opts, :extra_headers) do
      nil -> headers
      extra when is_list(extra) -> headers ++ extra
      _ -> headers
    end
  end

  # ── Private: Config ───────────────────────────────────────────────────────

  defp resolve_api_key do
    CodePuppyControl.ModelFactory.Credentials.env_or_store("GOOGLE_API_KEY") ||
      CodePuppyControl.ModelFactory.Credentials.env_or_store("GEMINI_API_KEY") || ""
  end
end
