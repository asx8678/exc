defmodule CodePuppyControl.Stream.EventNormalizer do
  @moduledoc """
  Unified schema normalizer for streaming events.

  Converts different stream event formats into a unified schema so that
  downstream consumers (e.g., Agent Trace) can process streaming content
  consistently, regardless of whether events originated from the main
  agent stream or a sub-agent stream.

  ## Problem

  - Main agent stream sends `%{delta_type: ..., delta: ...}`
  - Sub-agent stream sends `%{content_delta, args_delta}`
  - Agent Trace plugin expects `%{content}` or `%{text}` — neither provides it

  ## Solution

  Unified schema with normalized fields:

      %{
        content_delta: String.t() | nil,
        args_delta: String.t() | nil,
        tool_name: String.t() | nil,
        tool_name_delta: String.t() | nil,
        part_kind: String.t(),
        index: integer(),
        raw: map()
      }

  Port of `code_puppy/agents/stream_event_normalizer.py`.
  """

  @type normalized :: %{
          content_delta: String.t() | nil,
          args_delta: String.t() | nil,
          tool_name: String.t() | nil,
          tool_name_delta: String.t() | nil,
          part_kind: String.t(),
          index: integer(),
          raw: map()
        }

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Normalizes a stream event to the unified schema.

  Accepts an `event_type` (`"part_start"`, `"part_delta"`, `"part_end"`)
  and a raw `event_data` map from any stream handler.

  Returns a map following the unified schema.

  ## Examples

      iex> EventNormalizer.normalize("part_start", %{"part_type" => "TextPart", "index" => 0, "content" => "hi"})
      %{content_delta: "hi", args_delta: nil, tool_name: nil, tool_name_delta: nil, part_kind: "text", index: 0, raw: %{"part_type" => "TextPart", "index" => 0, "content" => "hi"}}

      iex> EventNormalizer.normalize("part_delta", %{"delta_type" => "TextPartDelta", "content_delta" => "world", "index" => 1})
      %{content_delta: "world", args_delta: nil, tool_name: nil, tool_name_delta: nil, part_kind: "text", index: 1, raw: %{"delta_type" => "TextPartDelta", "content_delta" => "world", "index" => 1}}
  """
  @spec normalize(String.t(), map()) :: normalized()
  def normalize(event_type, event_data) when is_map(event_data) do
    %{
      content_delta: nil,
      args_delta: nil,
      tool_name: nil,
      tool_name_delta: nil,
      part_kind: "unknown",
      index: event_data["index"] || event_data[:index] || -1,
      raw: event_data
    }
    |> apply_event_type(event_type, event_data)
  end

  # Fallback for non-map data (shouldn't happen in practice)
  @spec normalize(String.t(), term()) :: normalized()
  def normalize(event_type, event_data) do
    %{
      content_delta: if(event_data, do: to_string(event_data), else: nil),
      args_delta: nil,
      tool_name: nil,
      tool_name_delta: nil,
      part_kind: "unknown",
      index: -1,
      raw: %{_original: event_data, _event_type: event_type}
    }
  end

  @doc """
  Extracts content suitable for token estimation from a normalized event.

  Concatenates `content_delta`, `args_delta`, and `tool_name_delta`
  into a single string suitable for token counting.

  ## Examples

      iex> EventNormalizer.content_for_token_estimation(%{content_delta: "hello", args_delta: nil, tool_name_delta: nil})
      "hello"

      iex> EventNormalizer.content_for_token_estimation(%{content_delta: "hi", args_delta: "{\\"a\\":1}", tool_name_delta: nil})
      "hi{\"a\":1}"

      iex> EventNormalizer.content_for_token_estimation(%{content_delta: nil, args_delta: nil, tool_name_delta: nil})
      ""
  """
  @spec content_for_token_estimation(normalized()) :: String.t()
  def content_for_token_estimation(event_data) when is_map(event_data) do
    parts =
      []
      |> maybe_append(event_data[:content_delta] || event_data["content_delta"])
      |> maybe_append(event_data[:args_delta] || event_data["args_delta"])
      |> maybe_append(event_data[:tool_name_delta] || event_data["tool_name_delta"])

    Enum.join(parts, "")
  end

  # ── Part Kind Extraction ────────────────────────────────────────────

  @part_kind_map %{
    "TextPart" => "text",
    "ThinkingPart" => "thinking",
    "ToolCallPart" => "tool_call"
  }

  @delta_kind_map %{
    "TextPartDelta" => "text",
    "ThinkingPartDelta" => "thinking",
    "ToolCallPartDelta" => "tool_call"
  }

  @doc """
  Maps a part type name (e.g., "TextPart") to a normalized kind string.
  """
  @spec part_kind_from_start(String.t()) :: String.t()
  def part_kind_from_start(part_type) do
    Map.get(@part_kind_map, part_type, "unknown")
  end

  @doc """
  Maps a delta type name (e.g., "TextPartDelta") to a normalized kind string.
  """
  @spec part_kind_from_delta(String.t()) :: String.t()
  def part_kind_from_delta(delta_type) do
    Map.get(@delta_kind_map, delta_type, "unknown")
  end

  @doc """
  Extracts part kind from a part_end event's `next_part_kind` field.
  """
  @spec part_kind_from_end(String.t() | nil) :: String.t()
  def part_kind_from_end(nil), do: "unknown"
  def part_kind_from_end(kind) when is_binary(kind), do: kind
  def part_kind_from_end(kind), do: to_string(kind)

  # ── Private ─────────────────────────────────────────────────────────

  defp apply_event_type(acc, "part_start", event_data) do
    part_type = event_data["part_type"] || event_data[:part_type] || ""
    kind = part_kind_from_start(part_type)
    tool_name = event_data["tool_name"] || event_data[:tool_name]
    content = event_data["content"] || event_data[:content]

    acc
    |> Map.put(:part_kind, kind)
    |> Map.put(:tool_name, tool_name)
    |> Map.put(:content_delta, content)
  end

  defp apply_event_type(acc, "part_delta", event_data) do
    delta_type = event_data["delta_type"] || event_data[:delta_type] || ""
    kind = part_kind_from_delta(delta_type)

    acc
    |> Map.put(:part_kind, kind)
    |> extract_delta_fields(event_data)
    |> Map.put(:tool_name, extract_tool_name(event_data))
  end

  defp apply_event_type(acc, "part_end", event_data) do
    next_kind = event_data["next_part_kind"] || event_data[:next_part_kind]
    tool_name = event_data["tool_name"] || event_data[:tool_name]

    acc
    |> Map.put(:part_kind, part_kind_from_end(next_kind))
    |> Map.put(:tool_name, tool_name)
  end

  defp apply_event_type(acc, _unknown_type, _event_data) do
    acc
  end

  # Handle different source formats for delta fields
  defp extract_delta_fields(acc, event_data) do
    # Sub-agent format: direct content_delta/args_delta fields
    content_delta = event_data["content_delta"] || event_data[:content_delta]
    args_delta = event_data["args_delta"] || event_data[:args_delta]
    tool_name_delta = event_data["tool_name_delta"] || event_data[:tool_name_delta]

    cond do
      content_delta != nil ->
        # Sub-agent format: direct content_delta field
        acc
        |> Map.put(:content_delta, content_delta)

      args_delta != nil ->
        # Sub-agent format: direct args_delta field
        acc
        |> Map.put(:args_delta, args_delta)
        |> Map.put(:tool_name_delta, tool_name_delta)

      # Main agent format: delta object with attributes
      delta = event_data["delta"] || event_data[:delta] ->
        delta_content = attr(delta, :content_delta)
        delta_args = attr(delta, :args_delta)
        delta_tool_name = attr(delta, :tool_name_delta)

        acc
        |> Map.put(:content_delta, delta_content)
        |> Map.put(:args_delta, delta_args)
        |> Map.put(:tool_name_delta, delta_tool_name)

      true ->
        acc
    end
  end

  defp extract_tool_name(event_data) do
    # Direct field
    case event_data["tool_name"] || event_data[:tool_name] do
      nil ->
        # From delta object
        delta = event_data["delta"] || event_data[:delta]

        if delta do
          attr(delta, :tool_name)
        else
          nil
        end

      name ->
        name
    end
  end

  # Safely extract an attribute from a struct or map
  defp attr(%{__struct__: _} = struct, key) do
    Map.get(struct, key)
  end

  defp attr(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp attr(_, _), do: nil

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, value), do: list ++ [to_string(value)]
end
