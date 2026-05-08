defmodule CodePuppyControl.Agent.Loop.Streaming do
  @moduledoc """
  Streaming and response accumulation logic for Agent.Loop.

  Handles building the stream callback, parsing tool arguments from
  JSON, and accumulating streamed responses into a `Turn` struct.

  Extracted from `Agent.Loop` to keep it under the 600-line hard cap.
  """

  alias CodePuppyControl.Agent.{Events, Turn}
  alias CodePuppyControl.Stream.Event

  @doc """
  Build the callback function that receives streaming events from the LLM.

  The callback publishes `llm_stream` and `tool_call_start` events via
  the EventBus as they arrive.
  """
  @spec build_stream_callback(map()) :: (term() -> term())
  def build_stream_callback(state) do
    fn
      {:stream, %Event.TextDelta{text: text}} when is_binary(text) ->
        Events.publish(Events.llm_stream(state.run_id, state.session_id, text))

      {:stream, %Event.ToolCallEnd{name: name, arguments: args_json, id: id}} ->
        arguments = parse_tool_arguments(args_json)

        Events.publish(
          Events.tool_call_start(state.run_id, state.session_id, name, arguments, id)
        )

      {:stream, %Event.Done{}} ->
        :ok

      {:stream, _other} ->
        :ok

      _other ->
        :ok
    end
  end

  @doc """
  Parse tool arguments from a JSON string.

  Returns the decoded map on success, or the raw string on failure.
  Non-binary arguments pass through unchanged.
  """
  @spec parse_tool_arguments(term()) :: map() | String.t() | term()
  def parse_tool_arguments(args_json) when is_binary(args_json) do
    case Jason.decode(args_json) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> args_json
    end
  end

  def parse_tool_arguments(args), do: args

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
