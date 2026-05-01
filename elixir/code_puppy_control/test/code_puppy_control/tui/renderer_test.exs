defmodule CodePuppyControl.TUI.RendererTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

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

  # Runs a full renderer lifecycle inside CaptureIO and returns the
  # captured stdout.  Starting the GenServer *inside* capture_io
  # ensures its group leader is the captured device, so all
  # Owl.IO.puts output is captured.
  defp capture_renderer(opts \\ [], fun) do
    capture_io(fn ->
      {pid, name} = start_renderer(opts)
      fun.(name)
      # Small sleep ensures elapsed > 0 for the completion stats line
      # and lets Owl.Spinner teardown settle before we un-capture.
      Process.sleep(10)
      Renderer.finalize(name)
      Process.sleep(10)
      Renderer.stop(pid)
    end)
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
    test "TextStart prints AGENT RESPONSE banner" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "body\n"})
          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      assert output =~ "AGENT RESPONSE"
    end

    test "TextDelta renders text and finalizes with token stats" do
      long_text = String.duplicate("x", 25) <> "\n"

      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: long_text})
          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      assert output =~ "Completed:"
      assert output =~ "tokens"
    end

    test "TextEnd flushes remaining buffer" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          # "hello" is short (5 chars) — stays buffered until TextEnd flushes it
          Renderer.push(name, %Event.TextDelta{index: 0, text: "hello"})
          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      assert output =~ "hello"
    end
  end

  # ── Tool Call Flow ─────────────────────────────────────────────────────────

  describe "ToolCallStart / ToolCallEnd" do
    test "ToolCallStart prints tool banner" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.ToolCallStart{index: 1, name: "read_file"})

          Renderer.push(name, %Event.ToolCallEnd{
            index: 1,
            name: "read_file",
            id: "tc-1",
            arguments: "{}"
          })
        end)

      assert output =~ "READ FILE"
    end

    test "ToolCallEnd prints completion marker" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.ToolCallStart{index: 1, name: "read_file"})

          Renderer.push(name, %Event.ToolCallEnd{
            index: 1,
            name: "read_file",
            id: "tc-1",
            arguments: "{}"
          })
        end)

      assert output =~ "read_file"
    end

    test "unknown tool name prints default-style banner" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.ToolCallStart{index: 2, name: "custom_tool_xyz"})

          Renderer.push(name, %Event.ToolCallEnd{
            index: 2,
            name: "custom_tool_xyz",
            id: "tc-2",
            arguments: "{}"
          })
        end)

      # Banner contains the tool name (as its own label for unknown tools)
      assert output =~ "custom_tool_xyz"
    end
  end

  # ── Thinking Flow ──────────────────────────────────────────────────────────

  describe "ThinkingStart / ThinkingDelta / ThinkingEnd" do
    test "thinking flow renders thinking text" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.ThinkingStart{index: 3})
          Renderer.push(name, %Event.ThinkingDelta{index: 3, text: "hmm..."})
          Renderer.push(name, %Event.ThinkingEnd{index: 3})
        end)

      assert output =~ "THINKING"
      assert output =~ "hmm..."
    end
  end

  # ── Done Event ─────────────────────────────────────────────────────────────

  describe "Done event" do
    test "flushes partial text buffers" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          # "partial" is short — stays buffered until Done or finalize flushes
          Renderer.push(name, %Event.TextDelta{index: 0, text: "partial"})
          Renderer.push(name, %Event.ToolCallStart{index: 1, name: "grep"})
          Renderer.push(name, %Event.Done{})
        end)

      assert output =~ "partial"
    end
  end

  # ── EventBus Map Events ───────────────────────────────────────────────────

  describe "EventBus map events" do
    test "converts agent_llm_stream to rendered text" do
      # EventBus events use atom keys (legacy format)
      long_chunk = String.duplicate("x", 25) <> "\n"

      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          send(name, {:event, %{type: "agent_llm_stream", chunk: long_chunk}})
        end)

      # The text should appear in the output (flushed via finalize)
      assert output =~ String.duplicate("x", 25)
    end

    test "handles agent_run_failed event" do
      {pid, _name} = start_renderer()

      # Should not crash even for unrecognized events
      send(pid, {:event, %{"type" => "agent_run_failed", "error" => "timeout"}})

      Process.sleep(10)
      assert Process.alive?(pid)

      Renderer.stop(pid)
    end

    test "handles agent_run_completed as Done" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "some text\n"})
          send(name, {:event, %{type: "agent_run_completed"}})
        end)

      # Text should have been flushed
      assert output =~ "some text"
    end

    test "ignores unknown event types" do
      {pid, _name} = start_renderer()

      send(pid, {:event, %{"type" => "something_weird", "data" => "nope"}})

      Process.sleep(10)
      assert Process.alive?(pid)

      Renderer.stop(pid)
    end
  end

  # ── Finalize and Reset ────────────────────────────────────────────────────

  describe "finalize/1" do
    test "renders buffered text and prints completion stats" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "hello world\n"})
        end)

      assert output =~ "hello world"
      assert output =~ "Completed:"
    end
  end

  describe "reset/1" do
    # Reset tests the public API — state assertions are legitimate here
    # per issue guidance (reset is about internal state cleanup).
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

      assert spec.start ==
               {CodePuppyControl.TUI.Renderer, :start_link, [[session_id: "sess-1"]]}

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
    test "is silently ignored (no visible output)" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "baseline\n"})
          # Push a ToolCallArgsDelta — should produce no additional output
          Renderer.push(name, %Event.ToolCallArgsDelta{index: 0, arguments: "{}"})
          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      # The baseline text should appear; ArgsDelta produces nothing visible
      assert output =~ "baseline"
    end
  end

  # ── UsageUpdate ────────────────────────────────────────────────────────────

  describe "UsageUpdate" do
    test "is silently ignored (no visible output before finalization)" do
      output =
        capture_renderer(fn name ->
          Renderer.push(name, %Event.TextStart{index: 0})
          Renderer.push(name, %Event.TextDelta{index: 0, text: "baseline\n"})

          Renderer.push(name, %Event.UsageUpdate{
            prompt_tokens: 10,
            completion_tokens: 5,
            total_tokens: 15
          })

          Renderer.push(name, %Event.TextEnd{index: 0})
        end)

      # The baseline text should appear; UsageUpdate produces nothing visible
      assert output =~ "baseline"
    end
  end
end
