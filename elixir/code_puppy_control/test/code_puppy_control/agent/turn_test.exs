defmodule CodePuppyControl.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.Turn

  describe "new/2" do
    test "creates an idle turn with correct defaults" do
      turn = Turn.new(1)

      assert turn.state == :idle
      assert turn.turn_number == 1
      assert turn.messages == []
      assert turn.accumulated_text == ""
      assert turn.pending_tool_calls == []
      assert turn.completed_tool_calls == []
      assert turn.tool_results == []
      assert turn.error == nil
      assert turn.started_at == nil
      assert turn.finished_at == nil
    end

    test "accepts initial messages" do
      messages = [%{role: "user", content: "hello"}]
      turn = Turn.new(5, messages)

      assert turn.turn_number == 5
      assert turn.messages == messages
    end
  end

  describe "state transitions" do
    test "idle → calling_llm" do
      turn = Turn.new(1)
      assert {:ok, turn} = Turn.start_llm_call(turn)
      assert turn.state == :calling_llm
      assert turn.started_at != nil
    end

    test "calling_llm → streaming" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      assert {:ok, turn} = Turn.start_streaming(turn)
      assert turn.state == :streaming
    end

    test "streaming accumulates text" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)

      {:ok, turn} = Turn.append_text(turn, "Hello ")
      {:ok, turn} = Turn.append_text(turn, "world!")

      assert turn.accumulated_text == "Hello world!"
    end

    test "streaming records tool calls" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)

      tc = %{id: "tc-1", name: :file_read, arguments: %{"path" => "/tmp/test"}}
      {:ok, turn} = Turn.add_tool_call(turn, tc)

      assert length(turn.pending_tool_calls) == 1
      assert hd(turn.pending_tool_calls).id == "tc-1"
    end

    test "streaming → done when no tool calls" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)
      assert {:ok, turn} = Turn.start_tool_calls(turn)
      assert turn.state == :done
      assert turn.finished_at != nil
    end

    test "streaming → tool_calling when tool calls exist" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)
      tc = %{id: "tc-1", name: :shell, arguments: %{}}
      {:ok, turn} = Turn.add_tool_call(turn, tc)
      assert {:ok, turn} = Turn.start_tool_calls(turn)
      assert turn.state == :tool_calling
    end

    test "tool_calling → tool_awaiting" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)
      tc = %{id: "tc-1", name: :shell, arguments: %{}}
      {:ok, turn} = Turn.add_tool_call(turn, tc)
      {:ok, turn} = Turn.start_tool_calls(turn)
      assert {:ok, turn} = Turn.await_tools(turn)
      assert turn.state == :tool_awaiting
    end

    test "complete_tool resolves and transitions to done" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)
      tc = %{id: "tc-1", name: :shell, arguments: %{}}
      {:ok, turn} = Turn.add_tool_call(turn, tc)
      {:ok, turn} = Turn.start_tool_calls(turn)
      {:ok, turn} = Turn.await_tools(turn)

      assert {:ok, turn} = Turn.complete_tool(turn, "tc-1", {:ok, "output"})
      assert turn.state == :done
      assert turn.finished_at != nil
      assert length(turn.completed_tool_calls) == 1
      assert length(turn.tool_results) == 1
    end

    test "complete_tool with multiple tools stays in tool_awaiting until all done" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)

      {:ok, turn} = Turn.add_tool_call(turn, %{id: "tc-1", name: :a, arguments: %{}})
      {:ok, turn} = Turn.add_tool_call(turn, %{id: "tc-2", name: :b, arguments: %{}})

      {:ok, turn} = Turn.start_tool_calls(turn)
      {:ok, turn} = Turn.await_tools(turn)

      # First tool done — still waiting
      {:ok, turn} = Turn.complete_tool(turn, "tc-1", {:ok, "a-result"})
      assert turn.state == :tool_awaiting
      assert length(turn.pending_tool_calls) == 1

      # Second tool done — now done
      {:ok, turn} = Turn.complete_tool(turn, "tc-2", {:ok, "b-result"})
      assert turn.state == :done
      assert turn.pending_tool_calls == []
      assert length(turn.completed_tool_calls) == 2
    end

    test "finish/1 forces early termination" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)

      assert {:ok, turn} = Turn.finish(turn)
      assert turn.state == :done
    end

    test "fail/1 transitions to error state" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.fail(turn, :timeout)

      assert turn.state == :error
      assert turn.error == :timeout
      assert turn.finished_at != nil
    end
  end

  describe "invalid transitions" do
    test "start_llm_call from non-idle returns error" do
      turn = Turn.new(1)
      {:ok, turn} = Turn.start_llm_call(turn)
      assert {:error, :invalid_transition} = Turn.start_llm_call(turn)
    end

    test "start_streaming from non-calling_llm returns error" do
      turn = Turn.new(1)
      assert {:error, :invalid_transition} = Turn.start_streaming(turn)
    end

    test "append_text from non-streaming returns error" do
      turn = Turn.new(1)
      assert {:error, :invalid_transition} = Turn.append_text(turn, "text")
    end

    test "add_tool_call from non-streaming returns error" do
      turn = Turn.new(1)
      tc = %{id: "tc-1", name: :x, arguments: %{}}
      assert {:error, :invalid_transition} = Turn.add_tool_call(turn, tc)
    end

    test "start_tool_calls from non-streaming returns error" do
      turn = Turn.new(1)
      assert {:error, :invalid_transition} = Turn.start_tool_calls(turn)
    end

    test "await_tools from non-tool_calling returns error" do
      turn = Turn.new(1)
      assert {:error, :invalid_transition} = Turn.await_tools(turn)
    end

    test "complete_tool from non-tool_awaiting returns error" do
      turn = Turn.new(1)
      assert {:error, :invalid_transition} = Turn.complete_tool(turn, "tc-1", :ok)
    end

    test "finish from idle returns error" do
      turn = Turn.new(1)
      assert {:error, :invalid_transition} = Turn.finish(turn)
    end
  end

  describe "queries" do
    test "terminal?/1" do
      assert Turn.terminal?(Turn.new(1)) == false

      {:ok, done_turn} =
        Turn.new(1)
        |> Turn.start_llm_call()
        |> then(fn {:ok, t} -> Turn.start_streaming(t) end)
        |> then(fn {:ok, t} -> Turn.start_tool_calls(t) end)

      assert Turn.terminal?(done_turn) == true

      {:ok, error_turn} = Turn.new(1) |> Turn.fail(:err)
      assert Turn.terminal?(error_turn) == true
    end

    test "has_pending_tools?/1" do
      turn = Turn.new(1)
      assert Turn.has_pending_tools?(turn) == false

      {:ok, turn} = Turn.start_llm_call(turn)
      {:ok, turn} = Turn.start_streaming(turn)
      {:ok, turn} = Turn.add_tool_call(turn, %{id: "tc-1", name: :x, arguments: %{}})
      assert Turn.has_pending_tools?(turn) == true
    end

    test "elapsed_ms/1 returns nil when not started" do
      assert Turn.elapsed_ms(Turn.new(1)) == nil
    end

    test "elapsed_ms/1 returns integer after start" do
      {:ok, turn} = Turn.new(1) |> Turn.start_llm_call()
      assert is_integer(Turn.elapsed_ms(turn))
      assert Turn.elapsed_ms(turn) >= 0
    end

    test "elapsed_ms/1 is fixed after finish" do
      {:ok, turn} =
        Turn.new(1)
        |> Turn.start_llm_call()
        |> then(fn {:ok, t} -> Turn.start_streaming(t) end)
        |> then(fn {:ok, t} -> Turn.start_tool_calls(t) end)

      assert is_integer(Turn.elapsed_ms(turn))
      assert turn.finished_at != nil
    end

    test "summary/1 returns correct map" do
      {:ok, turn} =
        Turn.new(3)
        |> Turn.start_llm_call()
        |> then(fn {:ok, t} -> Turn.start_streaming(t) end)
        |> then(fn {:ok, t} -> Turn.append_text(t, "hello") end)
        |> then(fn {:ok, t} ->
          Turn.add_tool_call(t, %{id: "tc-1", name: :x, arguments: %{}})
        end)
        |> then(fn {:ok, t} -> Turn.start_tool_calls(t) end)

      summary = Turn.summary(turn)

      assert summary.turn_number == 3
      assert summary.state == :tool_calling
      assert summary.text_length == 5
      assert summary.tool_calls_requested == 1
      assert summary.tool_calls_completed == 0
      assert summary.error == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Property-based tests
  # ---------------------------------------------------------------------------

  describe "property: valid state machine paths" do
    test "text-only path: idle → calling_llm → streaming → done" do
      result =
        Turn.new(1)
        |> Turn.start_llm_call()
        |> then(fn {:ok, t} -> Turn.start_streaming(t) end)
        |> then(fn {:ok, t} -> Turn.append_text(t, "response") end)
        |> then(fn {:ok, t} -> Turn.start_tool_calls(t) end)

      assert {:ok, turn} = result
      assert turn.state == :done
      assert turn.accumulated_text == "response"
    end

    test "tool-only path: idle → calling_llm → streaming → tool_calling → tool_awaiting → done" do
      result =
        Turn.new(1)
        |> Turn.start_llm_call()
        |> then(fn {:ok, t} -> Turn.start_streaming(t) end)
        |> then(fn {:ok, t} ->
          Turn.add_tool_call(t, %{id: "tc-1", name: :x, arguments: %{}})
        end)
        |> then(fn {:ok, t} -> Turn.start_tool_calls(t) end)
        |> then(fn {:ok, t} -> Turn.await_tools(t) end)
        |> then(fn {:ok, t} -> Turn.complete_tool(t, "tc-1", {:ok, "result"}) end)

      assert {:ok, turn} = result
      assert turn.state == :done
      assert length(turn.completed_tool_calls) == 1
    end

    test "error at any point is handled" do
      for fail_at <- [:idle, :calling_llm, :streaming] do
        turn = Turn.new(1)

        turn =
          case fail_at do
            :idle ->
              turn

            :calling_llm ->
              elem(Turn.start_llm_call(turn), 1)

            :streaming ->
              turn
              |> Turn.start_llm_call()
              |> then(fn {:ok, t} -> Turn.start_streaming(t) end)
              |> elem(1)
          end

        assert {:ok, error_turn} = Turn.fail(turn, :test_error)
        assert error_turn.state == :error
        assert error_turn.error == :test_error
      end
    end

    test "arbitrary number of text chunks produces concatenated result" do
      chunks = ["a", "b", "c", "d", "e"]

      {:ok, turn} =
        Turn.new(1)
        |> Turn.start_llm_call()
        |> then(fn {:ok, t} -> Turn.start_streaming(t) end)

      {:ok, turn} =
        Enum.reduce(chunks, {:ok, turn}, fn chunk, {:ok, acc} ->
          Turn.append_text(acc, chunk)
        end)

      assert turn.accumulated_text == "abcde"
    end

    test "multiple tool calls are tracked independently" do
      tools = [
        %{id: "tc-1", name: :a, arguments: %{}},
        %{id: "tc-2", name: :b, arguments: %{}},
        %{id: "tc-3", name: :c, arguments: %{}}
      ]

      {:ok, turn} =
        Turn.new(1)
        |> Turn.start_llm_call()
        |> then(fn {:ok, t} -> Turn.start_streaming(t) end)

      {:ok, turn} =
        Enum.reduce(tools, {:ok, turn}, fn tc, {:ok, acc} ->
          Turn.add_tool_call(acc, tc)
        end)

      assert length(turn.pending_tool_calls) == 3

      {:ok, turn} = Turn.start_tool_calls(turn)
      {:ok, turn} = Turn.await_tools(turn)

      # Complete in reverse order
      {:ok, turn} = Turn.complete_tool(turn, "tc-3", {:ok, "c-result"})
      assert turn.state == :tool_awaiting

      {:ok, turn} = Turn.complete_tool(turn, "tc-1", {:ok, "a-result"})
      assert turn.state == :tool_awaiting

      {:ok, turn} = Turn.complete_tool(turn, "tc-2", {:ok, "b-result"})
      assert turn.state == :done
      assert length(turn.completed_tool_calls) == 3
    end
  end
end
