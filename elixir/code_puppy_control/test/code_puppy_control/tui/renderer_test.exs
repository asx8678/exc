defmodule CodePuppyControl.TUI.RendererTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Stream.Event
  alias CodePuppyControl.TUI.Renderer

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Starts a renderer without PubSub subscriptions (no session/run id).
  # We push events directly via Renderer.push/2.
  defp start_renderer(opts \\ []) do
    # Use a unique name so parallel tests don't clash
    name =
      Keyword.get_lazy(opts, :name, fn ->
        :"renderer_test_#{System.unique_integer([:positive])}"
      end)

    {:ok, pid} = Renderer.start_link(opts ++ [name: name])
    {pid, name}
  end

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts without session_id or run_id" do
      {pid, _name} = start_renderer()
      assert Process.alive?(pid)
      Renderer.stop(pid)
    end

    test "starts with a session_id" do
      {pid, _name} = start_renderer(session_id: "test-session-1")
      assert Process.alive?(pid)
      Renderer.stop(pid)
    end

    test "starts with a run_id" do
      {pid, _name} = start_renderer(run_id: "test-run-1")
      assert Process.alive?(pid)
      Renderer.stop(pid)
    end
  end

  # ── Text Streaming ─────────────────────────────────────────────────────────

  describe "TextStart / TextDelta / TextEnd" do
    test "TextStart adds part to streaming_parts and text_parts" do
      {pid, name} = start_renderer()
      Renderer.push(name, %Event.TextStart{index: 0})

      # Give the cast time to process
      Process.sleep(10)

      assert Renderer.streaming?(name, 0)
      assert Renderer.text_part?(name, 0)
      assert Renderer.banner_printed?(name, 0)

      Renderer.stop(pid)
    end

    test "TextDelta increments token_count" do
      {pid, name} = start_renderer()
      Renderer.push(name, %Event.TextStart{index: 0})

      # Send a delta that exceeds the flush threshold so it renders
      long_text = String.duplicate("x", 25)
      Renderer.push(name, %Event.TextDelta{index: 0, text: long_text})

      Process.sleep(10)

      assert Renderer.token_count(name) >= 1

      Renderer.stop(pid)
    end

    test "TextEnd flushes buffer and cleans up part" do
      {pid, name} = start_renderer()
      Renderer.push(name, %Event.TextStart{index: 0})
      Renderer.push(name, %Event.TextDelta{index: 0, text: "hello\n"})
      Renderer.push(name, %Event.TextEnd{index: 0})

      Process.sleep(10)

      refute Renderer.streaming?(name, 0)
      assert Renderer.buffer_empty?(name, 0)

      Renderer.stop(pid)
    end
  end

  # ── Tool Call Flow ─────────────────────────────────────────────────────────

  describe "ToolCallStart / ToolCallEnd" do
    test "ToolCallStart registers spinner and prints banner" do
      {pid, name} = start_renderer()
      Renderer.push(name, %Event.ToolCallStart{index: 1, name: "read_file"})

      Process.sleep(50)

      assert Renderer.tool_part?(name, 1)
      assert Renderer.spinner_active?(name, 1)

      Renderer.stop(pid)
    end

    test "ToolCallEnd stops spinner and cleans up" do
      {pid, name} = start_renderer()
      Renderer.push(name, %Event.ToolCallStart{index: 1, name: "read_file"})
      Process.sleep(50)

      Renderer.push(name, %Event.ToolCallEnd{
        index: 1,
        name: "read_file",
        id: "tc-1",
        arguments: "{}"
      })

      Process.sleep(50)

      refute Renderer.tool_part?(name, 1)
      refute Renderer.spinner_active?(name, 1)

      Renderer.stop(pid)
    end

    test "unknown tool name uses default banner style" do
      {pid, name} = start_renderer()
      # This should not crash even for unrecognised tool names
      Renderer.push(name, %Event.ToolCallStart{index: 2, name: "custom_tool_xyz"})

      Process.sleep(50)

      assert Renderer.tool_part?(name, 2)

      Renderer.stop(pid)
    end
  end

  # ── Thinking Flow ──────────────────────────────────────────────────────────

  describe "ThinkingStart / ThinkingDelta / ThinkingEnd" do
    test "thinking flow buffers and flushes" do
      {pid, name} = start_renderer()
      Renderer.push(name, %Event.ThinkingStart{index: 3})
      Renderer.push(name, %Event.ThinkingDelta{index: 3, text: "hmm..."})
      Renderer.push(name, %Event.ThinkingEnd{index: 3})

      Process.sleep(10)

      # After ThinkingEnd, the part should be cleaned up
      refute Renderer.thinking_part?(name, 3)
      # Thinking buffer should be cleared
      assert Renderer.thinking_buffer_empty?(name, 3)

      Renderer.stop(pid)
    end
  end

  # ── Done Event ─────────────────────────────────────────────────────────────

  describe "Done event" do
    test "flushes all buffers and stops all spinners" do
      {pid, name} = start_renderer()

      # Set up some state
      Renderer.push(name, %Event.TextStart{index: 0})
      Renderer.push(name, %Event.TextDelta{index: 0, text: "partial"})
      Renderer.push(name, %Event.ToolCallStart{index: 1, name: "grep"})

      Process.sleep(50)

      # Send Done — should flush everything
      Renderer.push(name, %Event.Done{})

      Process.sleep(50)

      assert Renderer.spinners_idle?(name)
      assert Renderer.all_buffers_flushed?(name)

      Renderer.stop(pid)
    end
  end

  # ── EventBus Map Events ───────────────────────────────────────────────────

  describe "EventBus map events" do
    test "converts agent_llm_stream to TextDelta" do
      {pid, name} = start_renderer()

      # TextStart is needed so the renderer tracks the part index
      Renderer.push(name, %Event.TextStart{index: 0})

      # Send a chunk long enough to flush (exceeds @flush_threshold of 20)
      # EventBus events use atom keys
      long_chunk = String.duplicate("x", 25) <> "\n"
      send(name, {:event, %{type: "agent_llm_stream", chunk: long_chunk}})

      Process.sleep(20)

      # token_count should have been incremented by the TextDelta handler
      assert Renderer.token_count(name) >= 1

      Renderer.stop(pid)
    end

    test "handles agent_run_failed event" do
      {pid, name} = start_renderer()

      # Should not crash
      send(name, {:event, %{"type" => "agent_run_failed", "error" => "timeout"}})

      Process.sleep(10)
      assert Process.alive?(pid)

      Renderer.stop(pid)
    end

    test "handles agent_run_completed as Done" do
      {pid, name} = start_renderer()

      Renderer.push(name, %Event.TextStart{index: 0})
      send(name, {:event, %{"type" => "agent_run_completed"}})

      Process.sleep(10)

      assert Renderer.spinners_idle?(name)

      Renderer.stop(pid)
    end

    test "ignores unknown event types" do
      {pid, name} = start_renderer()

      send(name, {:event, %{"type" => "something_weird", "data" => "nope"}})

      Process.sleep(10)
      assert Process.alive?(pid)

      Renderer.stop(pid)
    end
  end

  # ── Finalize and Reset ────────────────────────────────────────────────────

  describe "finalize/1" do
    test "flushes buffers and prints stats" do
      {pid, name} = start_renderer()

      Renderer.push(name, %Event.TextStart{index: 0})
      Renderer.push(name, %Event.TextDelta{index: 0, text: "hello world\n"})

      # Finalize is a call, so it blocks until done
      :ok = Renderer.finalize(name)

      assert Renderer.all_buffers_flushed?(name)

      Renderer.stop(pid)
    end
  end

  describe "reset/1" do
    test "clears state for a new session" do
      {pid, name} = start_renderer()

      Renderer.push(name, %Event.TextStart{index: 0})
      Renderer.push(name, %Event.TextDelta{index: 0, text: "some text\n"})
      Renderer.push(name, %Event.ToolCallStart{index: 1, name: "grep"})

      Process.sleep(50)

      :ok = Renderer.reset(name)

      # Verify all previously-active indices are cleared
      refute Renderer.streaming?(name, 0)
      refute Renderer.text_part?(name, 0)
      refute Renderer.tool_part?(name, 1)
      refute Renderer.banner_printed?(name, 0)

      # Verify spinners and buffers are clean
      assert Renderer.spinners_idle?(name)
      assert Renderer.all_buffers_flushed?(name)
      assert Renderer.token_count(name) == 0

      Renderer.stop(pid)
    end
  end

  # ── child_spec ─────────────────────────────────────────────────────────────

  describe "child_spec/1" do
    test "returns a valid child spec for a supervisor" do
      spec = Renderer.child_spec(session_id: "sess-1")

      assert spec.id == CodePuppyControl.TUI.Renderer
      assert spec.start == {CodePuppyControl.TUI.Renderer, :start_link, [[session_id: "sess-1"]]}

      # Should be restartable
      assert spec.restart == :transient
    end

    test "supports custom id via :id option" do
      spec = Renderer.child_spec(id: :my_renderer, session_id: "sess-2")
      assert spec.id == :my_renderer
    end
  end

  # ── ToolCallArgsDelta ──────────────────────────────────────────────────────

  describe "ToolCallArgsDelta" do
    test "is silently ignored (no state change)" do
      {pid, name} = start_renderer()

      count_before = Renderer.token_count(name)
      Renderer.push(name, %Event.ToolCallArgsDelta{index: 0, arguments: "{}"})
      Process.sleep(10)

      # token_count should be unchanged
      assert Renderer.token_count(name) == count_before

      Renderer.stop(pid)
    end
  end

  # ── UsageUpdate ────────────────────────────────────────────────────────────

  describe "UsageUpdate" do
    test "is silently ignored (displayed at finalization)" do
      {pid, name} = start_renderer()

      count_before = Renderer.token_count(name)

      Renderer.push(name, %Event.UsageUpdate{
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15
      })

      Process.sleep(10)

      assert Renderer.token_count(name) == count_before

      Renderer.stop(pid)
    end
  end
end
