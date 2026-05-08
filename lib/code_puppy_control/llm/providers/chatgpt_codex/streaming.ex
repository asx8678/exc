defmodule CodePuppyControl.LLM.Providers.ChatGPTCodex.Streaming do
  @moduledoc false
  # SSE streaming internals for ChatGPTCodex provider.
  # Extracted to keep the main provider module under 600 lines.

  # ── SSE Chunk Parsing ──────────────────────────────────────────────────

  # Line-based SSE parser (reuses OpenAI provider pattern).
  def parse_sse_chunk(chunk, acc) do
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

          "event: " <> _event_type ->
            {events, data_buf}

          _ ->
            {events, data_buf}
        end
      end)

    {Enum.reverse(events), %{acc | line_buf: remaining, current_data: data_buf}}
  end

  # ── SSE Event Handling ───────────────────────────────────────────────

  def handle_sse_event("[DONE]", acc, _callback_fn) do
    {:ok, acc}
  end

  def handle_sse_event(data, acc, callback_fn) do
    case Jason.decode(data) do
      {:ok, %{"type" => "response.output_text.delta"} = event} ->
        handle_text_delta(event, acc, callback_fn)

      {:ok, %{"type" => "response.function_call_arguments.delta"} = event} ->
        handle_function_call_args_delta(event, acc, callback_fn)

      {:ok, %{"type" => "response.function_call_arguments.done"} = event} ->
        handle_function_call_args_done(event, acc)

      {:ok, %{"type" => "response.output_item.added"} = event} ->
        handle_output_item_added(event, acc, callback_fn)

      {:ok, %{"type" => "response.completed"} = event} ->
        handle_response_completed(event, acc)

      {:ok, %{"type" => "response.failed"}} ->
        {:error, %{status: 200, body: "Response failed"}}

      {:ok, %{"type" => "response.incomplete"}} ->
        {:error, %{status: 200, body: "Response incomplete"}}

      {:ok, %{"type" => "error", "error" => error}} ->
        {:error, %{status: 200, body: error}}

      {:ok, %{"error" => error}} ->
        {:error, %{status: 200, body: error}}

      {:ok, _other} ->
        {:ok, acc}

      {:error, _reason} ->
        {:ok, acc}
    end
  end

  # ── Event Handlers ───────────────────────────────────────────────────

  defp handle_text_delta(event, acc, callback_fn) do
    text = event["delta"] || ""
    index = Map.get(event, "output_index", 0)

    if text != "" do
      parts = acc.content_parts
      part = Map.get(parts, index, %{type: :text, index: index, text_chunks: []})
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

      {:ok, acc}
    else
      {:ok, acc}
    end
  end

  defp handle_function_call_args_delta(event, acc, callback_fn) do
    call_id = event["call_id"] || ""
    name = event["name"] || ""
    args_delta = event["delta"] || ""
    index = Map.get(event, "output_index", call_id_index(call_id))

    tc_parts = acc.tool_calls
    is_new = not Map.has_key?(tc_parts, index)

    part =
      Map.get(tc_parts, index, %{
        type: :tool_call,
        index: index,
        id: call_id,
        name: name,
        arg_chunks: []
      })

    part = %{part | arg_chunks: [args_delta | part.arg_chunks]}

    part =
      if part.name == nil or part.name == "" do
        %{part | name: name}
      else
        part
      end

    # (code_puppy-be7) Never overwrite a non-empty id with an empty one.
    # Argument delta events sometimes omit call_id after the initial
    # output_item.added event already set it.
    part = merge_id(part, call_id)
    tc_parts = Map.put(tc_parts, index, part)
    acc = %{acc | tool_calls: tc_parts}

    if is_new do
      callback_fn.({:part_start, %{type: :tool_call, index: index, id: part.id}})
    end

    if args_delta != "" do
      callback_fn.(
        {:part_delta,
         %{type: :tool_call, index: index, text: nil, name: nil, arguments: args_delta}}
      )
    end

    {:ok, acc}
  end

  defp handle_function_call_args_done(event, acc) do
    done_call_id = event["call_id"] || ""
    done_name = event["name"] || ""
    done_index = Map.get(event, "output_index", call_id_index(done_call_id))

    tc_parts = acc.tool_calls

    part =
      Map.get(tc_parts, done_index, %{
        type: :tool_call,
        index: done_index,
        id: done_call_id,
        name: done_name,
        arg_chunks: []
      })

    # (code_puppy-be7) Never overwrite a non-empty id with an empty one.
    part = %{
      part
      | id: merge_id_value(part.id, done_call_id),
        name: if(part.name == nil or part.name == "", do: done_name, else: part.name)
    }

    tc_parts = Map.put(tc_parts, done_index, part)
    {:ok, %{acc | tool_calls: tc_parts}}
  end

  defp handle_output_item_added(event, acc, callback_fn) do
    item = event["item"] || %{}
    index = Map.get(event, "output_index", 0)

    case item["type"] do
      "function_call" ->
        # (code_puppy-be7) Prefer call_id, then item["id"], then event["item_id"].
        # The Responses API may populate "id" but not "call_id" on some events.
        call_id =
          item["call_id"] || item["id"] || event["item_id"] || ""

        name = item["name"] || ""

        tc_parts = acc.tool_calls
        is_new = not Map.has_key?(tc_parts, index)

        part = %{type: :tool_call, index: index, id: call_id, name: name, arg_chunks: []}
        tc_parts = Map.put(tc_parts, index, part)
        acc = %{acc | tool_calls: tc_parts}

        if is_new do
          callback_fn.({:part_start, %{type: :tool_call, index: index, id: call_id}})
        end

        {:ok, acc}

      _ ->
        {:ok, acc}
    end
  end

  defp handle_response_completed(event, acc) do
    response = event["response"] || %{}
    acc = maybe_set_meta_from_response(acc, response)
    acc = parse_response_output(acc, response)
    acc = %{acc | finish_reason: parse_finish_reason(response)}
    {:ok, acc}
  end

  # ── Response Parsing ─────────────────────────────────────────────────

  # Parse output items from the completed response to fill in tool calls
  # that may have been missed during streaming. Does NOT re-add text content
  # that was already collected from response.output_text.delta events —
  # that would double the content.
  defp parse_response_output(acc, response) do
    output = response["output"] || []

    Enum.reduce(output, acc, fn item, acc ->
      case item["type"] do
        "function_call" ->
          call_id = item["call_id"] || item["id"] || ""
          name = item["name"] || ""
          arguments = item["arguments"] || ""
          index = find_tool_call_index(acc.tool_calls, call_id) || call_id_index(call_id)

          tc_parts = acc.tool_calls

          part =
            Map.get(tc_parts, index, %{
              type: :tool_call,
              index: index,
              id: call_id,
              name: name,
              arg_chunks: []
            })

          # (code_puppy-be7) Never overwrite a non-empty id with an empty one.
          part =
            if part.arg_chunks == [] and arguments != "" do
              %{part | id: merge_id_value(part.id, call_id), name: name, arg_chunks: [arguments]}
            else
              %{part | id: merge_id_value(part.id, call_id), name: name}
            end

          tc_parts = Map.put(tc_parts, index, part)
          %{acc | tool_calls: tc_parts}

        # Do NOT re-add text from message output items — it was already
        # collected from response.output_text.delta events.
        "message" ->
          acc

        _ ->
          acc
      end
    end)
  end

  defp maybe_set_meta_from_response(acc, response) do
    acc
    |> Map.put(:id, response["id"] || acc.id)
    |> Map.put(:model, response["model"] || acc.model)
    |> then(fn acc ->
      case response["usage"] do
        nil -> acc
        usage -> %{acc | usage: parse_usage(usage)}
      end
    end)
  end

  defp parse_finish_reason(response) do
    case response["status"] || "" do
      "completed" -> "stop"
      "failed" -> "failed"
      "incomplete" -> "incomplete"
      _ -> nil
    end
  end

  defp parse_usage(nil), do: %{prompt_tokens: 0, completion_tokens: 0, total_tokens: 0}

  defp parse_usage(usage) do
    input = usage["input_tokens"] || usage["prompt_tokens"] || 0
    output = usage["output_tokens"] || usage["completion_tokens"] || 0

    %{
      prompt_tokens: input,
      completion_tokens: output,
      total_tokens: input + output
    }
  end

  # Find the index key in tool_calls map that matches the given call_id.
  defp find_tool_call_index(tool_calls, call_id) when is_binary(call_id) and call_id != "" do
    Enum.find_value(tool_calls, fn {idx, part} ->
      if part.id == call_id, do: idx, else: nil
    end)
  end

  defp find_tool_call_index(_tool_calls, _call_id), do: nil

  # Derive a stable integer index from a call_id for use as tool_calls map key
  # when output_index is absent.
  def call_id_index(""), do: 0
  def call_id_index(call_id), do: :erlang.phash2(call_id)

  # ── Emit Done ────────────────────────────────────────────────────────

  def emit_done(acc, callback_fn) do
    # Emit part_end for all content parts
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

    # Emit part_end for tool calls
    Enum.each(acc.tool_calls, fn {_index, part} ->
      args = part.arg_chunks |> Enum.reverse() |> Enum.join()

      # (code_puppy-be7) Ensure tool_call id is never empty —
      # generate a deterministic safe ID if the provider didn't supply one.
      safe_id = ensure_safe_call_id(part.id, part.name, part.index)

      callback_fn.(
        {:part_end,
         %{
           type: :tool_call,
           index: part.index,
           id: safe_id,
           name: part.name,
           arguments: args
         }}
      )
    end)

    # Build final tool_calls list
    tool_calls =
      acc.tool_calls
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_index, part} ->
        args = part.arg_chunks |> Enum.reverse() |> Enum.join()

        # (code_puppy-be7) Ensure tool_call id is never empty in output.
        safe_id = ensure_safe_call_id(part.id, part.name, part.index)

        %{
          id: safe_id,
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

  defp parse_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, parsed} -> parsed
      _ -> args
    end
  end

  defp parse_arguments(args), do: args

  # ── ID Sanitization Helpers ─────────────────────────────────────────────

  # (code_puppy-be7) Merge an incoming id with an existing one:
  # never overwrite a non-empty id with an empty one.
  @spec merge_id_value(String.t() | nil, String.t() | nil) :: String.t()
  defp merge_id_value(existing, _incoming) when is_binary(existing) and existing != "" do
    existing
  end

  defp merge_id_value(_existing, incoming) when is_binary(incoming), do: incoming
  defp merge_id_value(_, _), do: ""

  # Merge a call_id into a tool-call part map, preserving a non-empty id.
  defp merge_id(part, call_id) do
    %{part | id: merge_id_value(part.id, call_id)}
  end

  # (code_puppy-be7) Generate a deterministic safe ID for tool calls when
  # the provider did not supply one. The Responses API requires IDs that
  # contain only letters, numbers, underscores, and dashes.
  # (code_puppy-be7.2) Also validate character set for non-empty IDs:
  # IDs with characters outside [A-Za-z0-9_-] are sanitized too.
  @spec ensure_safe_call_id(String.t() | nil, String.t() | nil, non_neg_integer()) :: String.t()
  defp ensure_safe_call_id(id, name, index) when is_binary(id) and id != "" do
    # Validate character set: Responses API only allows [A-Za-z0-9_-]
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, id), do: id, else: safe_call_id(name, index)
  end

  defp ensure_safe_call_id(_id, name, index) do
    safe_call_id(name, index)
  end

  defp safe_call_id(name, index) do
    safe_base = String.replace(name || "call", ~r/[^A-Za-z0-9_-]/, "_")
    "call_#{safe_base}_#{index}"
  end
end
