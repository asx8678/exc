defmodule CodePuppyControl.REPL.DispatchRollbackWithClauseTest do
  @moduledoc """
  Regression tests for: broadened rollback — with-clause raises.

  These tests verify that raises from ensure_renderer/1 or
  start_agent_loop/4 (i.e. the `with`-clause path in
  dispatch_after_append/4) correctly roll back the user message to
  messages_before.

  The broadened fix moves catch clauses to the outer try, so faults
  from the with-clause path also trigger rollback.

  Split from dispatch_rollback_test.exs to stay under the
  600-line cap.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.REPL.DispatchRollbackTestHelper
  alias CodePuppyControl.REPL.Loop

  import DispatchRollbackTestHelper

  setup :setup_mock_llm_and_session

  # ===========================================================================
  # with-clause fault injection: raise from ensure_renderer / start_agent_loop
  # ===========================================================================

  describe "dispatch_after_append — rollback on with-clause raises (dispatch rollback)" do
    test "raise from ensure_renderer rolls back user message", %{
      state: state,
      session_id: session_id
    } do
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "earlier message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      Application.put_env(
        :code_puppy_control,
        :test_ensure_renderer_raise,
        "renderer boom for dispatch rollback"
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("This should be rolled back", state)
        end)

      assert output =~ "⚠" or output =~ "\e[31m" or output =~ "Unexpected error"

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 1
      assert hd(messages)["parts"] |> hd() |> Map.get("text") == "earlier message"
    end

    test "raise from ensure_renderer preserves earlier messages (surgical rollback)", %{
      state: state,
      session_id: session_id
    } do
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "msg one"}]
      })

      State.append_message(session_id, "code_puppy", %{
        "role" => "assistant",
        "parts" => [%{"type" => "text", "text" => "msg two"}]
      })

      assert length(State.get_messages(session_id, "code_puppy")) == 2

      Application.put_env(
        :code_puppy_control,
        :test_ensure_renderer_raise,
        "renderer boom surgical"
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("should be rolled back", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2
      assert Enum.at(messages, 0)["parts"] |> hd() |> Map.get("text") == "msg one"
      assert Enum.at(messages, 1)["parts"] |> hd() |> Map.get("text") == "msg two"
    end

    test "raise from start_agent_loop rolls back user message", %{
      state: state,
      session_id: session_id
    } do
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "earlier message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      Application.put_env(
        :code_puppy_control,
        :test_start_agent_loop_raise,
        "agent loop boom for dispatch rollback"
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("This should be rolled back", state)
        end)

      assert output =~ "⚠" or output =~ "\e[31m" or output =~ "Unexpected error"

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 1
      assert hd(messages)["parts"] |> hd() |> Map.get("text") == "earlier message"
    end

    test "raise from start_agent_loop preserves earlier messages (surgical rollback)", %{
      state: state,
      session_id: session_id
    } do
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "msg one"}]
      })

      State.append_message(session_id, "code_puppy", %{
        "role" => "assistant",
        "parts" => [%{"type" => "text", "text" => "msg two"}]
      })

      assert length(State.get_messages(session_id, "code_puppy")) == 2

      Application.put_env(
        :code_puppy_control,
        :test_start_agent_loop_raise,
        "agent loop boom surgical"
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("should be rolled back", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2
      assert Enum.at(messages, 0)["parts"] |> hd() |> Map.get("text") == "msg one"
      assert Enum.at(messages, 1)["parts"] |> hd() |> Map.get("text") == "msg two"
    end

    test "REPL survives and subsequent call works after ensure_renderer raise", %{
      state: state,
      session_id: session_id
    } do
      Application.put_env(
        :code_puppy_control,
        :test_ensure_renderer_raise,
        "first renderer boom"
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("crash me", state)
      end)

      Application.delete_env(:code_puppy_control, :test_ensure_renderer_raise)

      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "recovered reply",
        tool_calls: []
      })

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("try again", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2

      assert [
               %{"role" => "user", "parts" => [%{"type" => "text", "text" => "try again"}]},
               %{
                 "role" => "assistant",
                 "parts" => [%{"type" => "text", "text" => "recovered reply"}]
               }
             ] = messages
    end
  end
end
