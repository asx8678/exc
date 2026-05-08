defmodule CodePuppyControl.REPL.DispatchRollbackSuccessTest do
  @moduledoc """
  Regression tests for: broadened rollback — success-path faults.

  These tests verify that raises / throws / exits that occur AFTER
  run_until_done returns :ok (i.e. in the "success path" of
  dispatch_after_append/4) correctly roll back the user message to
  messages_before.

  The broadened fix moves catch clauses to the outer try, so faults
  from the success path (not just the inner try) trigger rollback.

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
  # Success-path fault injection: raise / throw / exit
  # ===========================================================================

  describe "dispatch_after_append — rollback on success-path faults (dispatch rollback)" do
    test "raise after run_until_done ok rolls back user message", %{
      state: state,
      session_id: session_id
    } do
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "earlier message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        "injected failure for dispatch rollback test"
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

    test "raise with RuntimeError rolls back user message", %{
      state: state,
      session_id: session_id
    } do
      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        RuntimeError.exception("boom from dispatch rollback test")
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("This should be rolled back", state)
        end)

      assert output =~ "⚠" or output =~ "\e[31m" or output =~ "Unexpected error"

      messages = State.get_messages(session_id, "code_puppy")
      assert messages == []
    end

    test "REPL survives and subsequent call works after post-append raise", %{
      state: state,
      session_id: session_id
    } do
      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        "first boom"
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("crash me", state)
      end)

      Application.delete_env(:code_puppy_control, :test_dispatch_success_fault)

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

    test "raise preserves earlier messages (rollback is surgical)", %{
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

      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        "surgical test"
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("should be rolled back", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2
      assert Enum.at(messages, 0)["parts"] |> hd() |> Map.get("text") == "msg one"
      assert Enum.at(messages, 1)["parts"] |> hd() |> Map.get("text") == "msg two"
    end

    test "throw in success path rolls back user message", %{
      state: state,
      session_id: session_id
    } do
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "earlier message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        {:throw, :dispatch_throw_test}
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("This should be rolled back", state)
        end)

      assert output =~ "⚠" or output =~ "\e[31m" or output =~ "throw"

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 1
      assert hd(messages)["parts"] |> hd() |> Map.get("text") == "earlier message"
    end

    test "throw preserves earlier messages (rollback is surgical)", %{
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

      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        {:throw, :dispatch_surgical_throw}
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("should be rolled back", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2
      assert Enum.at(messages, 0)["parts"] |> hd() |> Map.get("text") == "msg one"
      assert Enum.at(messages, 1)["parts"] |> hd() |> Map.get("text") == "msg two"
    end

    test "exit in success path rolls back user message", %{
      state: state,
      session_id: session_id
    } do
      State.append_message(session_id, "code_puppy", %{
        "role" => "user",
        "parts" => [%{"type" => "text", "text" => "earlier message"}]
      })

      assert [%{"role" => "user"}] = State.get_messages(session_id, "code_puppy")

      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        {:exit, :dispatch_exit_test}
      )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Loop.handle_input("This should be rolled back", state)
        end)

      assert output =~ "⚠" or output =~ "\e[31m" or output =~ "crashed"

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 1
      assert hd(messages)["parts"] |> hd() |> Map.get("text") == "earlier message"
    end

    test "exit preserves earlier messages (rollback is surgical)", %{
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

      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        {:exit, :dispatch_surgical_exit}
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("should be rolled back", state)
      end)

      messages = State.get_messages(session_id, "code_puppy")
      assert length(messages) == 2
      assert Enum.at(messages, 0)["parts"] |> hd() |> Map.get("text") == "msg one"
      assert Enum.at(messages, 1)["parts"] |> hd() |> Map.get("text") == "msg two"
    end

    test "REPL survives and subsequent call works after post-append throw", %{
      state: state,
      session_id: session_id
    } do
      DispatchRollbackTestHelper.DispatchRollbackMockLLM.set_response(%{
        text: "mock reply",
        tool_calls: []
      })

      Application.put_env(
        :code_puppy_control,
        :test_dispatch_success_fault,
        {:throw, :first_throw}
      )

      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Loop.handle_input("crash me", state)
      end)

      Application.delete_env(:code_puppy_control, :test_dispatch_success_fault)

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
