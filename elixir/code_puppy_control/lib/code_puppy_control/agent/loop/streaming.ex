defmodule CodePuppyControl.Agent.Loop.Streaming do
  @moduledoc """
  Streaming and response accumulation logic for Agent.Loop.

  Handles building the stream callback and accumulating streamed
  responses into a `Turn` struct.

  Tool lifecycle events (`tool_call_start` / `tool_call_end`) are owned
  by `ToolDispatch`, which publishes them at dispatch time. This module
  only publishes `llm_stream` (text delta) events from the provider.

  Extracted from `Agent.Loop` to keep it under the 600-line hard cap.
  """

  alias CodePuppyControl.Agent.{Events, Turn}
  alias CodePuppyControl.Stream.Event

  @doc """
  Build the callback function that receives streaming events from the LLM.

  The callback publishes `llm_stream` events via the EventBus as text
  deltas arrive. Tool lifecycle events (`tool_call_start` / `tool_call_end`)
  are emitted by `ToolDispatch` at dispatch time — not from the stream.
  """
  @spec build_stream_callback(map()) :: (term() -> term())
  def build_stream_callback(state) do
    fn
      {:stream, %Event.TextDelta{text: text}} when is_binary(text) ->
        Events.publish(Events.llm_stream(state.run_id, state.session_id, text))

      {:stream, %Event.ToolCallEnd{}} ->
        # Tool lifecycle events are owned by ToolDispatch, which publishes
        # tool_call_start before execution and tool_call_end after. The
        # stream callback must not publish tool_call_start here — doing so
        # produces a duplicate start event that overwrites the spinner ref
        # in the TUI renderer.
        :ok

      {:stream, %Event.Done{}} ->
        :ok

      {:stream, _other} ->
        :ok

      _other ->
        :ok
    end
  end

  @doc """
  Accumulate a streamed LLM response into the turn.

  Appends text and tool calls from the response to the turn's
  accumulated state.
  """
  @spec accumulate_response(Turn.t(), map()) :: Turn.t()
  def accumulate_response(turn, %{text: text, tool_calls: tool_calls} = response) do
    turn =
      if text && text != "" do
        case Turn.append_text(turn, text) do
          {:ok, t} -> t
          _ -> turn
        end
      else
        turn
      end

    turn =
      Enum.reduce(tool_calls || [], turn, fn tc, acc ->
        case Turn.add_tool_call(acc, tc) do
          {:ok, t} -> t
          _ -> acc
        end
      end)

    # Store usage data from provider response
    case response[:usage] || response["usage"] do
      nil -> turn
      usage -> %{turn | usage: usage}
    end
  end

  def accumulate_response(turn, _other), do: turn
end
