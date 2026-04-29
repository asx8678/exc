defmodule CodePuppyControl.TUI.Renderer.EventMapper do
  @moduledoc """
  Event normalization for the TUI Renderer.

  Converts incoming EventBus map events into canonical Stream.Event
  structs. Tries `Event.from_wire/1` first for canonical string-keyed
  wire events, then falls back to legacy atom-keyed EventBus maps.
  """

  alias CodePuppyControl.Stream.Event

  @doc """
  Convert an EventBus map event to a canonical Stream.Event struct.

  Returns `{:ok, canonical}`, `:skip` (for unrecognized events that
  should be handled by the legacy EventBus handler), or nothing
  for non-map values.
  """
  @spec event_to_canonical(map()) :: {:ok, Event.canonical()} | :skip
  def event_to_canonical(%{"type" => _} = wire_event) do
    case Event.from_wire(wire_event) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, :unknown_type} -> legacy_event_to_canonical(wire_event)
    end
  end

  def event_to_canonical(%{type: _} = event) do
    # Legacy atom-keyed EventBus maps
    legacy_event_to_canonical(event)
  end

  def event_to_canonical(_), do: :skip

  # ── Legacy EventBus Conversions ──────────────────────────────────────────

  defp legacy_event_to_canonical(%{type: "agent_llm_stream", chunk: chunk}) do
    {:ok, %Event.TextDelta{index: 0, text: chunk}}
  end

  defp legacy_event_to_canonical(%{
         type: "agent_tool_call_start",
         tool_name: name,
         tool_call_id: id
       }) do
    {:ok, %Event.ToolCallStart{index: 0, id: id, name: name}}
  end

  defp legacy_event_to_canonical(%{
         type: "agent_tool_call_end",
         tool_name: name,
         tool_call_id: id
       }) do
    {:ok, %Event.ToolCallEnd{index: 0, id: id || "", name: name, arguments: ""}}
  end

  defp legacy_event_to_canonical(%{type: "agent_run_completed"}), do: {:ok, %Event.Done{}}

  defp legacy_event_to_canonical(_), do: :skip
end
