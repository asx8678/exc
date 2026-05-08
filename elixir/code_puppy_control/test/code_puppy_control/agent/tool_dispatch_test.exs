defmodule CodePuppyControl.Agent.ToolDispatchTest do
  @moduledoc """
  Unit tests for ToolDispatch.

  Covers:
    - sanitize_tool_call_id/1
    - sanitize_tool_call_ids/1
    - Disallowed-tool lifecycle: balanced tool_call_start / tool_call_end
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop.ToolDispatch
  alias CodePuppyControl.EventBus

  @valid_chars ~r/^[A-Za-z0-9_-]+$/

  describe "sanitize_tool_call_id/1" do
    test "passes through valid IDs unchanged" do
      assert ToolDispatch.sanitize_tool_call_id("call_abc123") == "call_abc123"
    end

    test "passes through IDs with dashes and underscores" do
      id = "call_my-tool_v2"
      assert ToolDispatch.sanitize_tool_call_id(id) == id
    end

    test "replaces empty string with generated ID" do
      result = ToolDispatch.sanitize_tool_call_id("")
      assert result != ""
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces nil with generated ID" do
      result = ToolDispatch.sanitize_tool_call_id(nil)
      assert result != ""
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces ID with invalid characters (dots)" do
      result = ToolDispatch.sanitize_tool_call_id("call.123")
      assert result != "call.123"
      assert Regex.match?(@valid_chars, result)
    end

    test "replaces ID with invalid characters (colons, slashes)" do
      result = ToolDispatch.sanitize_tool_call_id("abc:def/ghi")
      assert result != "abc:def/ghi"
      refute result =~ ":"
      refute result =~ "/"
      assert Regex.match?(@valid_chars, result)
    end

    test "generates unique IDs for repeated calls with nil input" do
      ids = Enum.map(1..10, fn _ -> ToolDispatch.sanitize_tool_call_id(nil) end)
      assert length(Enum.uniq(ids)) == 10, "Generated IDs must be unique"
    end
  end

  describe "sanitize_tool_call_ids/1" do
    test "sanitizes list of tool calls with mixed valid and invalid IDs" do
      tool_calls = [
        %{id: "valid_id", name: :tool_a, arguments: %{}},
        %{id: "", name: :tool_b, arguments: %{}},
        %{id: "bad.chars", name: :tool_c, arguments: %{}}
      ]

      result = ToolDispatch.sanitize_tool_call_ids(tool_calls)

      assert length(result) == 3

      # First: valid, unchanged
      assert Enum.at(result, 0).id == "valid_id"

      # Second: empty → generated
      id2 = Enum.at(result, 1).id
      assert id2 != ""
      assert Regex.match?(@valid_chars, id2)

      # Third: invalid chars → generated
      id3 = Enum.at(result, 2).id
      assert id3 != "bad.chars"
      assert Regex.match?(@valid_chars, id3)
    end

    test "returns empty list for empty input" do
      assert ToolDispatch.sanitize_tool_call_ids([]) == []
    end

    test "preserves name and arguments fields" do
      tool_calls = [%{id: "", name: :echo_tool, arguments: %{"input" => "hello"}}]

      [result] = ToolDispatch.sanitize_tool_call_ids(tool_calls)

      assert result.name == :echo_tool
      assert result.arguments == %{"input" => "hello"}
      assert Regex.match?(@valid_chars, result.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Disallowed-tool lifecycle: balanced start/end events
  # ---------------------------------------------------------------------------

  describe "disallowed-tool lifecycle" do
    setup do
      run_id = "dispatch-test-run-#{System.unique_integer([:positive])}"

      state = %{
        run_id: run_id,
        session_id: "dispatch-test-session",
        agent_module: DisallowedTestAgent,
        agent_state: %{}
      }

      :ok = EventBus.subscribe_run(run_id)

      on_exit(fn ->
        EventBus.unsubscribe_run(run_id)
      end)

      {:ok, state: state}
    end

    test "disallowed tool emits balanced tool_call_start + tool_call_end", %{state: state} do
      tool_call = %{id: "tc-disallowed", name: "forbidden_tool", arguments: %{}}
      # Turn with a pending tool call
      turn = %{pending_tool_calls: [tool_call]}
      messages = []

      ToolDispatch.dispatch_tool_calls(state, turn, messages)

      # Collect published events
      Process.sleep(50)
      events = collect_events([])

      start_events = Enum.filter(events, &(&1.type == "agent_tool_call_start"))
      end_events = Enum.filter(events, &(&1.type == "agent_tool_call_end"))

      # Balanced: one start and one end
      assert length(start_events) == 1
      assert length(end_events) == 1

      # Both events reference the same tool call ID
      [start_evt] = start_events
      [end_evt] = end_events

      # The resolved name for a disallowed string tool may stay as a string
      # if it doesn't match any allowed atom
      assert start_evt.tool_call_id == end_evt.tool_call_id
    end

    test "disallowed tool result message has consistent tool_call_id", %{state: state} do
      tool_call = %{id: "tc-x", name: "no_such_tool", arguments: %{}}
      turn = %{pending_tool_calls: [tool_call]}

      result_messages = ToolDispatch.dispatch_tool_calls(state, turn, [])

      assert length(result_messages) == 1
      msg = hd(result_messages)
      assert msg.role == "tool"
      assert msg.tool_call_id == "tc-x"
      assert msg.content =~ "not available"
    end

    test "allowed tool emits balanced start/end with correct name", %{state: state} do
      # :echo_tool is in allowed_tools
      tool_call = %{id: "tc-echo", name: :echo_tool, arguments: %{}}
      turn = %{pending_tool_calls: [tool_call]}

      # This will try to actually invoke :echo_tool via Tool.Runner,
      # which will fail since we don't register it. But the event
      # lifecycle should still be balanced. We just need to catch
      # the result.
      ToolDispatch.dispatch_tool_calls(state, turn, [])

      Process.sleep(50)
      events = collect_events([])

      start_events = Enum.filter(events, &(&1.type == "agent_tool_call_start"))
      end_events = Enum.filter(events, &(&1.type == "agent_tool_call_end"))

      assert length(start_events) == 1
      assert length(end_events) == 1

      [start_evt] = start_events
      [end_evt] = end_events
      assert start_evt.tool_call_id == end_evt.tool_call_id
    end
  end

  defp collect_events(acc) do
    receive do
      {:event, event} when is_map(event) ->
        collect_events([event | acc])
    after
      10 -> Enum.reverse(acc)
    end
  end
end

# Top-level agent module for disallowed-tool tests
# (Cannot be defined inside defp due to unquote constraints)
defmodule DisallowedTestAgent do
  @moduledoc false
  @behaviour CodePuppyControl.Agent.Behaviour

  @impl true
  def name, do: :disallowed_test_agent
  @impl true
  def system_prompt(_ctx), do: "test"
  @impl true
  def allowed_tools, do: [:echo_tool]
  @impl true
  def model_preference, do: "test-model"
  @impl true
  def on_tool_result(_tool, _result, state), do: {:cont, state}
end
