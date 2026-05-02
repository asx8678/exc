defmodule CodePuppyControl.Agent.LLMAdapter do
  @moduledoc """
  Adapter translating the old `CodePuppyControl.Agent.LLM` behaviour contract
  (used by `Agent.Loop`) into the provider-facing `CodePuppyControl.LLM`
  contract.

  ## Why

  `Agent.Loop` was built against the Agent.LLM behaviour (atom tool names,
  `{:ok, response}` return). `CodePuppyControl.LLM` was built against the
  Finch+provider contract (schema-map tools, `:ok` return with response
  delivered via `{:done, response}` callback event). This module is the single
  place where the two formats cross.

  ## Contracts

  Inbound (from Agent.Loop via `do_llm_stream/2`):
    * messages — list of maps, possibly mixed atom/string keys, possibly
      using `"parts"` format from Agent.State
    * tools — list of atoms from `agent_module.allowed_tools/0`
    * opts — keyword with `:model`, `:system_prompt`
    * callback_fn — Normalizer-wrapped function receiving raw provider events

  Outbound (to CodePuppyControl.LLM):
    * messages — list of `%{role: _, content: _}` (atom keys, flattened
      from "parts" format for v1)
    * tools — list of JSON-Schema function maps per Tool.Registry
    * opts — pass-through
    * callback_fn — wrapped to capture the terminal response for return value
  """

  @behaviour CodePuppyControl.Agent.LLM

  alias CodePuppyControl.LLM
  alias CodePuppyControl.Tool
  alias CodePuppyControl.Tool.Registry

  require Logger

  @impl true
  def stream_chat(messages, tool_names, opts, callback_fn) do
    provider_messages = Enum.flat_map(messages, &to_provider_message/1)
    provider_tools = resolve_tools(tool_names)

    llm_mod = Application.get_env(:code_puppy_control, :llm_adapter_provider, LLM)

    parent = self()
    ref = make_ref()

    # Wrap the callback to capture the final response from {:done, response}.
    #
    # The callback_fn we receive is already Normalizer-wrapped (by
    # do_llm_stream/2), so it accepts raw provider events. We intercept
    # the {:done, response} event before forwarding it, because the Normalizer
    # converts it to {:stream, %Done{}} which loses the response content.
    wrapped_callback = fn
      {:done, response} = event ->
        send(parent, {:llm_adapter_done, ref, response})
        callback_fn.(event)

      event ->
        callback_fn.(event)
    end

    case llm_mod.stream_chat(provider_messages, provider_tools, opts, wrapped_callback) do
      :ok ->
        # LLM.stream_chat returns :ok after all streaming is complete.
        # The {:done, response} callback has already fired, so the message
        # is in our mailbox.
        receive do
          {:llm_adapter_done, ^ref, response} ->
            {:ok, adapter_response(response)}
        after
          5_000 ->
            Logger.warning("LLMAdapter: timed out waiting for {:done, response}")
            {:error, :adapter_timeout}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Response conversion ──────────────────────────────────────────────────

  # Convert provider response to the Agent.LLM contract return format.
  # Provider uses :content and :tool_calls with %{id, name, arguments}.
  # Agent.LLM contract expects %{text: ..., tool_calls: [%{id, name, arguments}]}.
  defp adapter_response(response) when is_map(response) do
    %{
      text: response[:content] || response["content"] || "",
      tool_calls: normalize_tool_calls(response[:tool_calls] || response["tool_calls"] || []),
      usage: response[:usage] || response["usage"]
    }
  end

  defp adapter_response(_), do: %{text: "", tool_calls: []}

  defp normalize_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, &normalize_tool_call/1)
  end

  defp normalize_tool_call(%{id: id, name: name, arguments: args}) do
    %{id: id || "", name: safe_atomize(name), arguments: args}
  end

  defp normalize_tool_call(%{"id" => id, "name" => name, "arguments" => args}) do
    %{id: id || "", name: safe_atomize(name), arguments: args}
  end

  defp normalize_tool_call(other), do: other

  # Safely convert a string tool name to an atom ONLY if the atom already
  # exists in the BEAM atom table (i.e., it was created during tool module
  # compilation and registration). Uses String.to_existing_atom/1 to prevent
  # unbounded atom creation from provider-controlled strings.
  #
  # If the atom doesn't exist, the name is left as a string — downstream
  # code (Agent.Loop dispatch, Tool.Runner) treats it as unknown/not-allowed.
  defp safe_atomize(name) when is_atom(name), do: name

  defp safe_atomize(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end

  defp safe_atomize(name), do: name

  # ── Message conversion ───────────────────────────────────────────────────

  # Prompt Toolkit "parts" format (string-keyed) — flatten to text.
  # Supports part schemas:
  # Legacy: %{"type" => "text", "text" => "..."}
  # Canonical text: %{"part_kind" => "text", "content" => "..."}
  # Canonical tool-return: %{"part_kind" => "tool-return", "tool_call_id" => "...", "content" => "..."}
  # Both string-keyed and atom-keyed variants are handled.
  #
  # Returns a list of provider messages. Text parts are joined into a single
  # message; each tool-return part becomes its own message (providers require
  # one tool_call_id per tool-role message).
  defp to_provider_message(%{"role" => role, "parts" => parts} = msg) when is_list(parts) do
    msg_tool_call_id = msg["tool_call_id"] || msg[:tool_call_id]

    {text_parts, tool_return_parts} =
      Enum.split_with(parts, fn
        %{"part_kind" => "tool-return"} -> false
        %{part_kind: "tool-return"} -> false
        _ -> true
      end)

    # Flatten text-like parts into a single content string
    text_content =
      text_parts
      |> Enum.map(fn
        %{"part_kind" => "text", "content" => c} -> c || ""
        %{part_kind: "text", content: c} -> c || ""
        %{"type" => "text", "text" => t} -> t
        %{type: :text, text: t} -> t
        other when is_binary(other) -> other
        _ -> ""
      end)
      |> Enum.join("")

    text_msg =
      if text_content != "" or tool_return_parts == [] do
        base = %{role: role, content: text_content}
        [maybe_put(base, :tool_call_id, msg_tool_call_id)]
      else
        []
      end

    # Each tool-return part produces its own provider message with
    # part-level tool_call_id (falling back to message-root tool_call_id).
    tool_return_msgs =
      Enum.map(tool_return_parts, fn part ->
        content = part["content"] || part[:content] || ""
        part_tool_call_id = part["tool_call_id"] || part[:tool_call_id]
        base = %{role: role, content: content}
        maybe_put(base, :tool_call_id, part_tool_call_id || msg_tool_call_id)
      end)

    text_msg ++ tool_return_msgs
  end

  # ── Assistant messages with tool_calls ──────────────────────────────
  #
  # Agent.Loop.finalize_turn stores assistant messages with tool_calls
  # as `%{role: "assistant", content: text | nil, tool_calls: [...]}`.
  # The internal tool_call shape is `%{id, name, arguments}` where name
  # is an atom or string and arguments is a map.  The provider API
  # expects `%{id, type: "function", function: %{name, arguments: json_string}}`.
  # These clauses must appear BEFORE the generic content-only clauses so
  # they take priority when tool_calls are present.

  # String-keyed assistant message with tool_calls
  defp to_provider_message(%{"role" => role, "tool_calls" => tool_calls} = msg)
       when is_list(tool_calls) and tool_calls != [] do
    provider_tcs = Enum.map(tool_calls, &to_provider_tool_call/1)

    base = %{role: role, content: msg["content"]}

    [Map.put(base, :tool_calls, provider_tcs)]
  end

  # Atom-keyed assistant message with tool_calls
  defp to_provider_message(%{role: role, tool_calls: tool_calls} = msg)
       when is_list(tool_calls) and tool_calls != [] do
    provider_tcs = Enum.map(tool_calls, &to_provider_tool_call/1)

    base = %{role: to_string(role), content: msg[:content]}

    [Map.put(base, :tool_calls, provider_tcs)]
  end

  # String-keyed content (already in provider shape or close to it)
  defp to_provider_message(%{"role" => role, "content" => content} = msg) do
    base = %{role: role, content: content}
    [maybe_put(base, :tool_call_id, msg["tool_call_id"] || msg[:tool_call_id])]
  end

  # Atom-keyed content (from Agent.Loop internals)
  defp to_provider_message(%{role: role, content: content} = msg) do
    base = %{role: to_string(role), content: content}
    [maybe_put(base, :tool_call_id, msg[:tool_call_id] || msg["tool_call_id"])]
  end

  # Fallback: try to coerce
  defp to_provider_message(msg) do
    Logger.warning("LLMAdapter: unknown message shape, passing through: #{inspect(msg)}")
    [msg]
  end

  # ── Tool call shape conversion ────────────────────────────────────────
  #
  # Internal shape (from Turn/Loop): %{id, name, arguments}
  #   where name is atom | string, arguments is map | string
  # Provider shape (from LLM.Provider types): %{id, type: "function",
  #   function: %{name: string, arguments: json_string}}
  #
  # We convert name to string via to_string/1 (atoms → strings safely)
  # and arguments to JSON string.  We NEVER call String.to_atom/1 on
  # provider-controlled names here — that only happens in
  # safe_atomize/1 during inbound response normalization.

  defp to_provider_tool_call(%{id: id, name: name, arguments: args}) do
    %{
      id: id || "",
      type: "function",
      function: %{name: to_string(name), arguments: encode_arguments(args)}
    }
  end

  defp to_provider_tool_call(%{"id" => id, "name" => name, "arguments" => args}) do
    %{
      id: id || "",
      type: "function",
      function: %{name: to_string(name), arguments: encode_arguments(args)}
    }
  end

  # Catch-all for malformed tool calls — return a safe placeholder
  defp to_provider_tool_call(other) do
    Logger.warning("LLMAdapter: malformed tool_call in message history: #{inspect(other)}")

    %{id: "", type: "function", function: %{name: "unknown", arguments: "{}"}}
  end

  defp encode_arguments(args) when is_binary(args), do: args

  # Defensive: use Jason.encode/1 (returns {:ok, _} | {:error, _}) instead of
  # Jason.encode!/1 which raises on non-encodable values.  Fallback to "{}"
  # prevents a single bad map from crashing the entire stream.
  defp encode_arguments(args) when is_map(args) do
    case Jason.encode(args) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end

  defp encode_arguments(_), do: "{}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── Tool conversion ──────────────────────────────────────────────────────

  # Resolve atom tool names into JSON-Schema function maps.
  # Uses Tool.Registry.lookup/1 + Tool.to_llm_format/1.
  # If Registry is unavailable or lookup fails, return empty list
  # (agent runs without tools rather than crashing).
  defp resolve_tools(tool_names) when is_list(tool_names) do
    tool_names
    |> Enum.map(&resolve_single_tool/1)
    |> Enum.reject(&is_nil/1)
  rescue
    _ -> []
  end

  defp resolve_single_tool(name) when is_atom(name) do
    try do
      case Registry.lookup(name) do
        {:ok, module} ->
          Tool.to_llm_format(module)

        :error ->
          Logger.debug("LLMAdapter: tool #{inspect(name)} not found in Registry, skipping")
          nil
      end
    rescue
      _ -> nil
    end
  end

  defp resolve_single_tool(_), do: nil
end
