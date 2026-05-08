defmodule CodePuppyControl.Agent.Loop.StreamingTest do
  @moduledoc """
  Tests for Agent.Loop.Streaming — the stream callback builder.

  Verifies that the streaming layer does NOT publish tool lifecycle
  events (tool_call_start / tool_call_end). Those events are owned
  by ToolDispatch, which publishes them at dispatch time.

  This regression test guards against the bug where receiving a
  provider `%Event.ToolCallEnd{}` in the stream callback caused a
  duplicate `tool_call_start` event to be published — leading to
  spinner ref overwrites in the TUI renderer.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop.Streaming
  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Stream.Event

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  @run_id "streaming-test-run-#{System.unique_integer([:positive])}"
  @session_id "streaming-test-session"

  defp build_state do
    %{
      run_id: @run_id,
      session_id: @session_id
    }
  end

  defp subscribe_and_collect(run_id, fun) do
    :ok = EventBus.subscribe_run(run_id)

    fun.()

    # Phoenix.PubSub.broadcast is synchronous on the local node,
    # so messages arrive in the subscriber's mailbox before broadcast returns.
    # A small sleep guards against scheduler jitter.
    Process.sleep(10)
    events = collect_events([])
    :ok = EventBus.unsubscribe_run(run_id)
    events
  end

  defp collect_events(acc) do
    receive do
      {:event, event} when is_map(event) ->
        collect_events([event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "build_stream_callback/1" do
    test "text delta publishes agent_llm_stream event" do
      state = build_state()
      callback = Streaming.build_stream_callback(state)

      events =
        subscribe_and_collect(state.run_id, fn ->
          callback.({:stream, %Event.TextDelta{text: "Hello world"}})
        end)

      llm_events = Enum.filter(events, &(&1.type == "agent_llm_stream"))
      assert length(llm_events) >= 1
      assert Enum.any?(llm_events, &(&1.chunk == "Hello world"))
    end

    test "provider ToolCallEnd does NOT publish agent_tool_call_start" do
      state = build_state()
      callback = Streaming.build_stream_callback(state)

      events =
        subscribe_and_collect(state.run_id, fn ->
          callback.(
            {:stream,
             %Event.ToolCallEnd{
               name: "read_file",
               arguments: ~s({"path": "/tmp"}),
               id: "tc-1"
             }}
          )
        end)

      tool_start_events = Enum.filter(events, &(&1.type == "agent_tool_call_start"))

      assert tool_start_events == [],
             "streaming layer must not publish tool_call_start for provider ToolCallEnd"
    end

    test "provider ToolCallEnd does NOT publish agent_tool_call_end" do
      state = build_state()
      callback = Streaming.build_stream_callback(state)

      events =
        subscribe_and_collect(state.run_id, fn ->
          callback.(
            {:stream,
             %Event.ToolCallEnd{
               name: "grep",
               arguments: "{}",
               id: "tc-2"
             }}
          )
        end)

      tool_end_events = Enum.filter(events, &(&1.type == "agent_tool_call_end"))

      assert tool_end_events == [],
             "streaming layer must not publish tool_call_end for provider ToolCallEnd"
    end

    test "Done event produces no events" do
      state = build_state()
      callback = Streaming.build_stream_callback(state)

      events =
        subscribe_and_collect(state.run_id, fn ->
          callback.({:stream, %Event.Done{}})
        end)

      assert events == []
    end

    test "unknown stream event produces no events" do
      state = build_state()
      callback = Streaming.build_stream_callback(state)

      events =
        subscribe_and_collect(state.run_id, fn ->
          callback.({:stream, :something_else})
        end)

      assert events == []
    end

    test "non-stream message produces no events" do
      state = build_state()
      callback = Streaming.build_stream_callback(state)

      events =
        subscribe_and_collect(state.run_id, fn ->
          callback.(:not_a_stream_tuple)
        end)

      assert events == []
    end
  end
end
