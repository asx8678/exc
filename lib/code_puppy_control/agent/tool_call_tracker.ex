defmodule CodePuppyControl.Agent.ToolCallTracker do
  @moduledoc """
  Tool call ID tracking and interrupted tool call pruning.

  Ports Python's BaseAgent methods for tool-call bookkeeping:
  - `_collect_tool_call_ids` / `_collect_tool_call_ids_uncached`
  - `_check_pending_tool_calls`
  - `has_pending_tool_calls` / `get_pending_tool_call_count`
  - `prune_interrupted_tool_calls`
  - `_is_tool_call_part` / `_is_tool_return_part`

  All functions are pure — no process state, no side effects. The agent
  loop or Agent.State holds the message list; this module analyses it.

  ## Message format

  Messages are maps following the Agent.State / provider convention:

      %{
        "role" => "assistant",
        "tool_calls" => [%{id: "tc_1", name: :cp_read_file, arguments: %{}}],
      }

      %{
        "role" => "tool",
        "tool_call_id" => "tc_1",
        "content" => "file contents..."
      }

  Parts-style messages (pydantic-ai legacy) use `"parts"` with
  `part_kind` of `"tool-call"` or `"tool-return"`.

  ## Design decisions

  - **Pure functions** — no caching, no GenServer. The loop calls these
    on the current message list. If caching is needed later, it belongs
    in the loop's server state, not here.
  - **String tool_call_ids** — IDs are always strings (provider contract).
    We never call `String.to_atom/1` on them.
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type tool_call_ids :: MapSet.t(String.t())
  @type tool_return_ids :: MapSet.t(String.t())

  @type id_pair :: %{
          call_ids: tool_call_ids(),
          return_ids: tool_return_ids()
        }

  # ---------------------------------------------------------------------------
  # ID Collection
  # ---------------------------------------------------------------------------

  @doc """
  Collect tool_call_ids and tool_return_ids from a message list.

  Returns a map with `:call_ids` and `:return_ids` MapSets.

  Handles both flat message format (`tool_calls` / `tool_call_id`)
  and parts-style messages (`parts[].part_kind`).

  ## Examples

      iex> messages = [
      ...>   %{"role" => "assistant", "tool_calls" => [%{id: "tc_1", name: "read", arguments: %{}}]},
      ...>   %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"}
      ...> ]
      iex> result = ToolCallTracker.collect_ids(messages)
      iex> MapSet.to_list(result.call_ids)
      ["tc_1"]
      iex> MapSet.to_list(result.return_ids)
      ["tc_1"]
  """
  @spec collect_ids([map()]) :: id_pair()
  def collect_ids(messages) when is_list(messages) do
    Enum.reduce(messages, %{call_ids: MapSet.new(), return_ids: MapSet.new()}, fn msg, acc ->
      collect_ids_from_message(msg, acc)
    end)
  end

  defp collect_ids_from_message(%{"tool_calls" => tool_calls} = _msg, acc)
       when is_list(tool_calls) and tool_calls != [] do
    # String-keyed assistant message with tool_calls
    collect_tool_call_ids(tool_calls, acc)
  end

  defp collect_ids_from_message(%{tool_calls: tool_calls} = _msg, acc)
       when is_list(tool_calls) and tool_calls != [] do
    # Atom-keyed assistant message with tool_calls
    # (produced by Agent.Loop.finalize_turn)
    collect_tool_call_ids(tool_calls, acc)
  end

  defp collect_ids_from_message(%{"role" => "tool", "tool_call_id" => id}, acc)
       when is_binary(id) and id != "" do
    %{acc | return_ids: MapSet.put(acc.return_ids, id)}
  end

  defp collect_ids_from_message(%{role: "tool", tool_call_id: id}, acc)
       when is_binary(id) and id != "" do
    %{acc | return_ids: MapSet.put(acc.return_ids, id)}
  end

  defp collect_ids_from_message(%{"parts" => parts}, acc) when is_list(parts) do
    Enum.reduce(parts, acc, &collect_ids_from_part/2)
  end

  defp collect_ids_from_message(%{parts: parts}, acc) when is_list(parts) do
    Enum.reduce(parts, acc, &collect_ids_from_part/2)
  end

  defp collect_ids_from_message(_msg, acc), do: acc

  # Shared helper: collect tool call IDs from a tool_calls list,
  # handling both atom-keyed (%{id: ...}) and string-keyed (%{"id" => ...}) shapes.
  defp collect_tool_call_ids(tool_calls, acc) do
    ids =
      Enum.map(tool_calls, fn
        %{id: id} when is_binary(id) -> id
        %{"id" => id} when is_binary(id) -> id
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    %{acc | call_ids: Enum.reduce(ids, acc.call_ids, &MapSet.put(&2, &1))}
  end

  defp collect_ids_from_part(part, acc) do
    kind = part_kind(part)

    case kind do
      :tool_call ->
        case part_id(part) do
          nil -> acc
          id -> %{acc | call_ids: MapSet.put(acc.call_ids, id)}
        end

      :tool_return ->
        case part_id(part) do
          nil -> acc
          id -> %{acc | return_ids: MapSet.put(acc.return_ids, id)}
        end

      _ ->
        acc
    end
  end

  # ---------------------------------------------------------------------------
  # Pending Tool Calls
  # ---------------------------------------------------------------------------

  @doc """
  Check for pending tool calls and return both existence flag and count.

  A pending tool call is one that has a call ID without a matching return ID.

  Returns `{has_pending, pending_count}`.

  ## Examples

      iex> messages = [
      ...>   %{"role" => "assistant", "tool_calls" => [
      ...>     %{id: "tc_1", name: "read", arguments: %{}},
      ...>     %{id: "tc_2", name: "write", arguments: %{}}
      ...>   ]},
      ...>   %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"}
      ...> ]
      iex> ToolCallTracker.check_pending(messages)
      {true, 1}
  """
  @spec check_pending([map()]) :: {boolean(), non_neg_integer()}
  def check_pending(messages) when is_list(messages) do
    %{call_ids: call_ids, return_ids: return_ids} = collect_ids(messages)
    pending = MapSet.difference(call_ids, return_ids)
    {MapSet.size(pending) > 0, MapSet.size(pending)}
  end

  @doc """
  Returns `true` if there are any pending tool calls.

  ## Examples

      iex> ToolCallTracker.has_pending_tool_calls?([
      ...>   %{"role" => "assistant", "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]}
      ...> ])
      true

      iex> ToolCallTracker.has_pending_tool_calls?([])
      false
  """
  @spec has_pending_tool_calls?([map()]) :: boolean()
  def has_pending_tool_calls?(messages) do
    check_pending(messages) |> elem(0)
  end

  @doc """
  Returns the count of pending tool calls.

  ## Examples

      iex> ToolCallTracker.pending_tool_call_count([
      ...>   %{"role" => "assistant", "tool_calls" => [
      ...>     %{id: "tc_1", name: "r", arguments: %{}},
      ...>     %{id: "tc_2", name: "w", arguments: %{}}
      ...>   ]},
      ...>   %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"}
      ...> ])
      1
  """
  @spec pending_tool_call_count([map()]) :: non_neg_integer()
  def pending_tool_call_count(messages) do
    check_pending(messages) |> elem(1)
  end

  # ---------------------------------------------------------------------------
  # Pruning
  # ---------------------------------------------------------------------------

  @doc """
  Remove messages that participate in mismatched tool call sequences.

  A mismatched tool_call_id is one that appears in a ToolCall without a
  corresponding ToolReturn, or vice versa. Preserves original order and
  only drops messages that contain parts referencing mismatched IDs.

  This is the Elixir port of Python's `prune_interrupted_tool_calls`.

  ## Examples

      iex> messages = [
      ...>   %{"role" => "assistant", "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]},
      ...>   %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"},
      ...>   %{"role" => "assistant", "tool_calls" => [%{id: "tc_2", name: "w", arguments: %{}}]}
      ...> ]
      iex> ToolCallTracker.prune_interrupted(messages) |> length()
      2
  """
  @spec prune_interrupted([map()]) :: [map()]
  def prune_interrupted(messages) when is_list(messages) do
    if messages == [] do
      messages
    else
      %{call_ids: call_ids, return_ids: return_ids} = collect_ids(messages)
      mismatched = MapSet.symmetric_difference(call_ids, return_ids)

      if MapSet.size(mismatched) == 0 do
        messages
      else
        Enum.reject(messages, fn msg -> message_has_mismatched_id?(msg, mismatched) end)
      end
    end
  end

  defp message_has_mismatched_id?(%{"tool_calls" => tool_calls}, mismatched)
       when is_list(tool_calls) do
    Enum.any?(tool_calls, fn
      %{id: id} -> MapSet.member?(mismatched, id)
      %{"id" => id} -> MapSet.member?(mismatched, id)
      _ -> false
    end)
  end

  defp message_has_mismatched_id?(%{tool_calls: tool_calls}, mismatched)
       when is_list(tool_calls) do
    Enum.any?(tool_calls, fn
      %{id: id} -> MapSet.member?(mismatched, id)
      _ -> false
    end)
  end

  defp message_has_mismatched_id?(%{"role" => "tool", "tool_call_id" => id}, mismatched) do
    MapSet.member?(mismatched, id)
  end

  defp message_has_mismatched_id?(%{role: "tool", tool_call_id: id}, mismatched) do
    MapSet.member?(mismatched, id)
  end

  defp message_has_mismatched_id?(%{"parts" => parts}, mismatched) when is_list(parts) do
    Enum.any?(parts, fn part ->
      case part_id(part) do
        nil -> false
        id -> MapSet.member?(mismatched, id)
      end
    end)
  end

  defp message_has_mismatched_id?(%{parts: parts}, mismatched) when is_list(parts) do
    Enum.any?(parts, fn part ->
      case part_id(part) do
        nil -> false
        id -> MapSet.member?(mismatched, id)
      end
    end)
  end

  defp message_has_mismatched_id?(_msg, _mismatched), do: false

  # ---------------------------------------------------------------------------
  # Part Classification
  # ---------------------------------------------------------------------------

  @doc """
  Returns `true` if a message part represents a tool call request.

  Handles both struct-style and map-style parts.

  ## Examples

      iex> ToolCallTracker.tool_call_part?(%{"part_kind" => "tool-call", "tool_call_id" => "tc_1"})
      true

      iex> ToolCallTracker.tool_call_part?(%{part_kind: "text", content: "hello"})
      false
  """
  @spec tool_call_part?(map()) :: boolean()
  def tool_call_part?(part) when is_map(part) do
    case part_kind(part) do
      :tool_call -> true
      _ -> false
    end
  end

  @doc """
  Returns `true` if a message part represents a tool return/result.

  ## Examples

      iex> ToolCallTracker.tool_return_part?(%{"part_kind" => "tool-return", "tool_call_id" => "tc_1"})
      true

      iex> ToolCallTracker.tool_return_part?(%{part_kind: "text", content: "hello"})
      false
  """
  @spec tool_return_part?(map()) :: boolean()
  def tool_return_part?(part) when is_map(part) do
    case part_kind(part) do
      :tool_return -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Safe Split Index
  # ---------------------------------------------------------------------------

  @doc """
  Adjust a split index to avoid breaking tool_use/tool_result pairs.

  Ensures that if a tool_result is in the protected zone (after the split),
  its corresponding tool_use is also included in the protected zone.

  Returns an adjusted index that may be lower than `initial_split_idx`.

  ## Examples

      iex> messages = [
      ...>   %{"role" => "system", "content" => "You are helpful"},
      ...>   %{"role" => "assistant", "tool_calls" => [%{id: "tc_1", name: "r", arguments: %{}}]},
      ...>   %{"role" => "tool", "tool_call_id" => "tc_1", "content" => "ok"},
      ...>   %{"role" => "user", "content" => "continue"}
      ...> ]
      iex> ToolCallTracker.find_safe_split_index(messages, 2)
      1
  """
  @spec find_safe_split_index([map()], non_neg_integer()) :: non_neg_integer()
  def find_safe_split_index(_messages, initial_split_idx) when initial_split_idx <= 1 do
    initial_split_idx
  end

  def find_safe_split_index(messages, initial_split_idx) do
    # Collect tool_call_ids from messages AFTER the split (protected zone)
    protected_return_ids =
      messages
      |> Enum.slice(initial_split_idx..-1//1)
      |> Enum.reduce(MapSet.new(), fn msg, acc ->
        case msg do
          %{"role" => "tool", "tool_call_id" => id} when is_binary(id) ->
            MapSet.put(acc, id)

          %{role: "tool", tool_call_id: id} when is_binary(id) ->
            MapSet.put(acc, id)

          _ ->
            acc
        end
      end)

    if MapSet.size(protected_return_ids) == 0 do
      initial_split_idx
    else
      # Scan backwards from split point to find any tool_uses matching protected returns
      do_find_safe_split(messages, initial_split_idx, protected_return_ids)
    end
  end

  defp do_find_safe_split(messages, initial_idx, protected_return_ids) do
    # Walk backwards, checking if messages before the split reference
    # tool_call_ids that have their returns in the protected zone
    Enum.reduce(initial_idx..1//-1, initial_idx, fn i, adjusted_idx ->
      msg = Enum.at(messages, i)

      case msg do
        %{"tool_calls" => tool_calls} when is_list(tool_calls) ->
          has_match =
            Enum.any?(tool_calls, fn
              %{id: id} -> MapSet.member?(protected_return_ids, id)
              %{"id" => id} -> MapSet.member?(protected_return_ids, id)
              _ -> false
            end)

          if has_match, do: i, else: adjusted_idx

        _ ->
          adjusted_idx
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  # Normalize part_kind to atom, handling both string and atom keys,
  # and the hyphen/underscore convention difference.
  defp part_kind(part) do
    kind =
      Map.get(part, "part_kind") ||
        Map.get(part, :part_kind) ||
        ""

    kind = if is_atom(kind), do: Atom.to_string(kind), else: kind
    # Normalize hyphens to underscores for pattern matching
    kind = String.replace(kind, "-", "_")

    case kind do
      "tool_call" -> :tool_call
      "tool_return" -> :tool_return
      "tool_result" -> :tool_return
      "text" -> :text
      _ -> :unknown
    end
  end

  # Extract tool_call_id from a part (string or atom keys)
  defp part_id(part) do
    Map.get(part, "tool_call_id") || Map.get(part, :tool_call_id)
  end
end
