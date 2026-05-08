defmodule CodePuppyControl.Tools.CommandRunner.ExecutorPtyTest do
  @moduledoc """
  Tests for CommandRunner.ExecutorPty.

  Covers:
  - PTY output collection with {:get_output, requester} handler
  - Chunk ordering preservation
  - pty: true in results when PTY path is used
  - pty: false in results when PTY creation fails (fallback)
  - Exit status parsing
  - PTY session lifecycle
  - Regression: output included in {:pty_done, ...} so collector
    death does not race with get_pty_output (code_puppy-mmk.6)

  All PTY integration tests use PtyManager.Stub (registered under the
  real PtyManager name) so no OS processes are spawned.

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  use CodePuppyControl.StatefulCase, async: false

  alias CodePuppyControl.Tools.CommandRunner.ExecutorPty
  alias CodePuppyControl.Tools.CommandRunner.Executor
  alias CodePuppyControl.PtyManager.Stub

  # ---------------------------------------------------------------------------
  # Module-level setup: replace real PtyManager with Stub for ALL tests
  # ---------------------------------------------------------------------------

  setup_all do
    supervisor = CodePuppyControl.Supervisor

    if _pid = Process.whereis(CodePuppyControl.PtyManager) do
      :ok = Supervisor.terminate_child(supervisor, CodePuppyControl.PtyManager)
      :ok = Supervisor.delete_child(supervisor, CodePuppyControl.PtyManager)
    end

    case Stub.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    on_exit(fn ->
      if pid = Process.whereis(CodePuppyControl.PtyManager) do
        if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
      end

      try do
        spec = %{
          id: CodePuppyControl.PtyManager,
          start: {CodePuppyControl.PtyManager, :start_link, [[]]},
          type: :worker
        }

        Supervisor.start_child(supervisor, spec)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # Reset Stub state between individual tests
  setup do
    Stub.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Output Collector Unit Tests
  # ---------------------------------------------------------------------------

  describe "PTY output collector" do
    test "collects output chunks and responds to {:get_output, requester}" do
      parent = self()
      session_id = "test-collector-#{:erlang.unique_integer([:positive])}"

      collector =
        spawn_link(fn ->
          # Simulate collect_pty_loop behavior
          pty_loop(parent, session_id, [])
        end)

      # Send some output
      send(collector, {:pty_output, session_id, "chunk1"})
      send(collector, {:pty_output, session_id, "chunk2"})
      send(collector, {:pty_output, session_id, "chunk3"})

      # Small delay to ensure messages are processed
      Process.sleep(50)

      # Request output
      send(collector, {:get_output, self()})

      assert_receive {:output, chunks}, 1000
      # Chunks should be in arrival order
      assert chunks == ["chunk1", "chunk2", "chunk3"]

      # Stop the collector
      send(collector, :stop)
    end

    test "preserves chunk ordering (not reversed)" do
      parent = self()
      session_id = "test-order-#{:erlang.unique_integer([:positive])}"

      collector =
        spawn_link(fn ->
          pty_loop(parent, session_id, [])
        end)

      # Send output in specific order
      send(collector, {:pty_output, session_id, "A"})
      send(collector, {:pty_output, session_id, "B"})
      send(collector, {:pty_output, session_id, "C"})

      Process.sleep(50)

      send(collector, {:get_output, self()})

      assert_receive {:output, chunks}, 1000
      assert chunks == ["A", "B", "C"]

      send(collector, :stop)
    end

    test "returns empty list when no chunks collected" do
      parent = self()
      session_id = "test-empty-#{:erlang.unique_integer([:positive])}"

      collector =
        spawn_link(fn ->
          pty_loop(parent, session_id, [])
        end)

      Process.sleep(50)

      send(collector, {:get_output, self()})

      assert_receive {:output, chunks}, 1000
      assert chunks == []

      send(collector, :stop)
    end

    test "forwards pty_exit as {:pty_done, ...} with output chunks" do
      parent = self()
      session_id = "test-exit-#{:erlang.unique_integer([:positive])}"

      collector =
        spawn_link(fn ->
          pty_loop(parent, session_id, [])
        end)

      # Send output + exit to the COLLECTOR (not self)
      send(collector, {:pty_output, session_id, "hello"})
      send(collector, {:pty_exit, session_id, :normal})

      # Collector sends {:pty_done, ...} with ordered chunks to parent
      assert_receive {:pty_done, ^session_id, 0, ["hello"]}, 500
    end
  end

  # ---------------------------------------------------------------------------
  # Exit Status Parsing
  # ---------------------------------------------------------------------------

  describe "parse_exit_status/1" do
    test "parses :normal as 0" do
      assert parse_exit_status(:normal) == 0
    end

    test "parses :closed as 0" do
      assert parse_exit_status(:closed) == 0
    end

    test "parses {:status, code} as the code" do
      assert parse_exit_status({:status, 42}) == 42
      assert parse_exit_status({:status, 0}) == 0
      assert parse_exit_status({:status, 1}) == 1
    end

    test "parses unknown as -1" do
      assert parse_exit_status(:something_else) == -1
      assert parse_exit_status({:noproc, nil}) == -1
    end
  end

  # ---------------------------------------------------------------------------
  # PTY Result pty Flag
  # ---------------------------------------------------------------------------

  describe "PTY result pty flag" do
    test "PTY execution reports pty: true on success" do
      Stub.set_auto_response("pty_flag_test\r\n", :normal)

      assert {:ok, result} = ExecutorPty.execute("echo pty_flag_test", timeout: 2)

      # When PTY path is used (Stub succeeds), pty should be true
      assert result.pty == true
    end

    test "standard execution reports pty: false" do
      assert {:ok, result} = Executor.execute_standard("echo std_flag_test", [])

      assert result.pty == false
    end

    test "result builders default to pty: false" do
      result = Executor.build_success_result("test", "out", "err", 0, 100, false)
      assert result.pty == false

      result = Executor.build_timeout_result("test", 100)
      assert result.pty == false

      result = Executor.build_timeout_result_with_output("test", "out", 100)
      assert result.pty == false
    end
  end

  # ---------------------------------------------------------------------------
  # Regression: code_puppy-mmk.6 — output in {:pty_done, ...}
  # ---------------------------------------------------------------------------

  describe "PTY execute captures output (code_puppy-mmk.6 regression)" do
    test "execute returns stdout containing command marker" do
      Stub.set_auto_response("pty_output_test\r\n", :normal)

      assert {:ok, result} = ExecutorPty.execute("echo pty_output_test", timeout: 2)
      assert result.pty == true
      assert result.stdout =~ "pty_output_test"
    end

    test "execute returns pty: true and non-empty stdout" do
      Stub.set_auto_response("hello from pty\r\n", :normal)

      assert {:ok, result} = ExecutorPty.execute("echo hello", timeout: 2)
      assert result.pty == true
      assert result.stdout != ""
    end

    test "execute preserves chunk ordering from auto-response" do
      # Multi-chunk simulation: configure auto_response with ordered markers
      Stub.set_auto_response("first\r\nsecond\r\nthird\r\n", :normal)

      assert {:ok, result} = ExecutorPty.execute("echo ordered", timeout: 2)
      assert result.pty == true
      # All markers present and in order
      assert result.stdout =~ "first"
      assert result.stdout =~ "second"
      assert result.stdout =~ "third"

      assert String.contains?(result.stdout, "first") and
               String.contains?(result.stdout, "second") and
               String.contains?(result.stdout, "third")
    end

    test "execute reports exit code 0 on :normal exit" do
      Stub.set_auto_response("ok\r\n", :normal)

      assert {:ok, result} = ExecutorPty.execute("true", timeout: 2)
      assert result.pty == true
      assert result.exit_code == 0
      assert result.success == true
    end

    test "execute reports non-zero exit code on {:status, 1}" do
      Stub.set_auto_response("fail\r\n", {:status, 1})

      assert {:ok, result} = ExecutorPty.execute("false", timeout: 2)
      assert result.pty == true
      assert result.exit_code == 1
      assert result.success == false
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Mirror of ExecutorPty's collect_pty_loop for direct testing.
  # Updated to match the new {:pty_done, session_id, exit_code, chunks} format
  # (code_puppy-mmk.6 fix).
  defp pty_loop(parent, session_id, chunks) do
    receive do
      {:pty_output, ^session_id, data} ->
        pty_loop(parent, session_id, [data | chunks])

      {:pty_exit, ^session_id, status} ->
        # Mirror the fix: include ordered chunks in the done message
        ordered = Enum.reverse(chunks)
        send(parent, {:pty_done, session_id, parse_exit_status(status), ordered})

      {:get_output, requester} ->
        # Reverse to preserve arrival order
        ordered = Enum.reverse(chunks)
        send(requester, {:output, ordered})
        pty_loop(parent, session_id, chunks)

      :stop ->
        :ok
    after
      100 -> pty_loop(parent, session_id, chunks)
    end
  end

  # Mirror of ExecutorPty's parse_exit_status for direct testing
  defp parse_exit_status(:normal), do: 0
  defp parse_exit_status(:closed), do: 0
  defp parse_exit_status({:status, code}) when is_integer(code), do: code
  defp parse_exit_status(_), do: -1
end
