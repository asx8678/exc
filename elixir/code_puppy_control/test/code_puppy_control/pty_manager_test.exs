defmodule CodePuppyControl.PtyManagerTest do
  @moduledoc """
  Tests for PtyManager GenServer.

  PTY tests spawn real OS processes via erlexec, so they require:
  - A Unix OS (macOS or Linux)
  - The erlexec port program (exec-port) compiled and available

  Unit tests (session tracking, list, count) are fast and always run.
  Integration tests that spawn real shells are tagged @tag :integration.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.PtyManager
  alias CodePuppyControl.PtyManager.Session

  setup do
    # Start PtyManager for each test (isolated, not the app's global one)
    {:ok, pid} = GenServer.start_link(PtyManager, [])

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :shutdown)
      end
    end)

    %{manager: pid}
  end

  # ===========================================================================
  # Unit tests (no OS process spawning)
  # ===========================================================================

  describe "initial state" do
    test "starts with no sessions", %{manager: manager} do
      assert GenServer.call(manager, :list_sessions) == []
      assert GenServer.call(manager, :count) == 0
    end

    test "starts with erlexec_started: false (lazy startup)", %{manager: manager} do
      # PtyManager no longer calls Application.ensure_all_started(:erlexec)
      # at init time. It starts with erlexec_started: false and lazily
      # attempts erlexec startup on first create_session call.
      state = :sys.get_state(manager)
      assert state.erlexec_started == false
    end

    test "get_session returns nil for unknown session", %{manager: manager} do
      assert GenServer.call(manager, {:get_session, "nonexistent"}) == nil
    end

    test "write to unknown session returns error", %{manager: manager} do
      assert {:error, :not_found} = GenServer.call(manager, {:write, "ghost", "data"})
    end

    test "resize unknown session returns error", %{manager: manager} do
      assert {:error, :not_found} = GenServer.call(manager, {:resize, "ghost", 80, 24})
    end

    test "close unknown session returns error", %{manager: manager} do
      assert {:error, :not_found} = GenServer.call(manager, {:close_session, "ghost"})
    end

    test "subscribe to unknown session returns error", %{manager: manager} do
      assert {:error, :not_found} =
               GenServer.call(manager, {:subscribe, "ghost", self()})
    end

    test "unsubscribe unknown session returns ok", %{manager: manager} do
      assert :ok = GenServer.call(manager, {:unsubscribe, "ghost", self()})
    end
  end

  # ===========================================================================
  # Integration tests (spawn real PTY processes)
  # ===========================================================================

  describe "PTY session lifecycle" do
    @tag :integration
    test "create_session spawns a shell process", %{manager: manager} do
      assert {:ok, session} =
               GenServer.call(manager, {:create_session, "test-1", [subscriber: self()]})

      assert %Session{} = session
      assert session.session_id == "test-1"
      assert session.os_pid > 0
      assert session.cols == 80
      assert session.rows == 24
      assert is_pid(session.pid)

      # Session should appear in listing
      assert GenServer.call(manager, :list_sessions) == ["test-1"]
      assert GenServer.call(manager, :count) == 1

      # Cleanup — pty_exit sent synchronously from close_session
      drain_pty_output("test-1")
      assert :ok = GenServer.call(manager, {:close_session, "test-1"})
      assert_receive {:pty_exit, "test-1", :closed}
    end

    @tag :integration
    test "create_session with custom cols/rows", %{manager: manager} do
      assert {:ok, session} =
               GenServer.call(
                 manager,
                 {:create_session, "test-size", [cols: 120, rows: 40, subscriber: self()]}
               )

      assert session.cols == 120
      assert session.rows == 40

      # Cleanup
      drain_pty_output("test-size")
      assert :ok = GenServer.call(manager, {:close_session, "test-size"})
      assert_receive {:pty_exit, "test-size", :closed}
    end

    @tag :integration
    test "create_session with custom shell", %{manager: manager} do
      assert {:ok, session} =
               GenServer.call(
                 manager,
                 {:create_session, "test-shell", [shell: "/bin/sh", subscriber: self()]}
               )

      assert session.shell == "/bin/sh"

      # Cleanup
      drain_pty_output("test-shell")
      assert :ok = GenServer.call(manager, {:close_session, "test-shell"})
      assert_receive {:pty_exit, "test-shell", :closed}
    end

    @tag :integration
    test "create_session replaces existing session with same id", %{manager: manager} do
      assert {:ok, session1} =
               GenServer.call(manager, {:create_session, "dup", [subscriber: self()]})

      os_pid_1 = session1.os_pid

      assert {:ok, session2} =
               GenServer.call(manager, {:create_session, "dup", [subscriber: self()]})

      # Should be a new process (old one was killed)
      assert session2.os_pid != os_pid_1

      # Wait for old session's pty_exit (from close_session_internal)
      assert_receive {:pty_exit, "dup", :closed}

      # Only one session in the map
      assert GenServer.call(manager, :count) == 1

      # Cleanup
      drain_pty_output("dup")
      assert :ok = GenServer.call(manager, {:close_session, "dup"})
      assert_receive {:pty_exit, "dup", :closed}, 5_000
    end

    @tag :integration
    test "write sends data to the shell and produces output", %{manager: manager} do
      assert {:ok, _session} =
               GenServer.call(
                 manager,
                 {:create_session, "write-test", [subscriber: self()]}
               )

      # Drain initial prompt output
      drain_pty_output("write-test")

      assert :ok =
               GenServer.call(manager, {:write, "write-test", "echo hello\n"})

      # Wait for actual output instead of sleeping
      assert_receive {:pty_output, "write-test", data}, 3_000
      assert is_binary(data)

      # Cleanup
      drain_pty_output("write-test")
      assert :ok = GenServer.call(manager, {:close_session, "write-test"})
      assert_receive {:pty_exit, "write-test", :closed}
    end

    @tag :integration
    test "resize changes terminal dimensions", %{manager: manager} do
      assert {:ok, _session} =
               GenServer.call(
                 manager,
                 {:create_session, "resize-test", [subscriber: self()]}
               )

      assert :ok =
               GenServer.call(manager, {:resize, "resize-test", 200, 50})

      session = GenServer.call(manager, {:get_session, "resize-test"})
      assert session.cols == 200
      assert session.rows == 50

      # Cleanup
      drain_pty_output("resize-test")
      assert :ok = GenServer.call(manager, {:close_session, "resize-test"})
      assert_receive {:pty_exit, "resize-test", :closed}
    end

    @tag :integration
    test "subscribe receives output messages", %{manager: manager} do
      assert {:ok, _session} =
               GenServer.call(
                 manager,
                 {:create_session, "sub-test", [subscriber: self()]}
               )

      # Write something that produces output
      assert :ok =
               GenServer.call(manager, {:write, "sub-test", "echo pty_test_output\n"})

      # Collect output messages — the shell prompt may come first,
      # then the echo output in subsequent messages
      all_output = collect_pty_output("sub-test", 3_000)
      combined = Enum.join(all_output)
      assert combined =~ "pty_test_output"

      # Cleanup
      drain_pty_output("sub-test")
      assert :ok = GenServer.call(manager, {:close_session, "sub-test"})
      assert_receive {:pty_exit, "sub-test", :closed}
    end

    @tag :integration
    test "subscribe after creation also receives output", %{manager: manager} do
      assert {:ok, _session} =
               GenServer.call(manager, {:create_session, "late-sub", []})

      # Subscribe after creation
      assert :ok = GenServer.call(manager, {:subscribe, "late-sub", self()})

      assert :ok =
               GenServer.call(manager, {:write, "late-sub", "echo late_output\n"})

      all_output = collect_pty_output("late-sub", 3_000)
      combined = Enum.join(all_output)
      assert combined =~ "late_output"

      # Cleanup
      drain_pty_output("late-sub")
      assert :ok = GenServer.call(manager, {:close_session, "late-sub"})
      assert_receive {:pty_exit, "late-sub", :closed}
    end

    @tag :integration
    test "unsubscribe stops receiving output", %{manager: manager} do
      assert {:ok, _session} =
               GenServer.call(
                 manager,
                 {:create_session, "unsub-test", [subscriber: self()]}
               )

      # Drain any initial output (prompt etc.)
      collect_pty_output("unsub-test", 500)

      assert :ok =
               GenServer.call(manager, {:unsubscribe, "unsub-test", self()})

      # Write something
      assert :ok =
               GenServer.call(manager, {:write, "unsub-test", "echo unsub_output\n"})

      # Should NOT receive output anymore
      refute_receive {:pty_output, "unsub-test", _}, 500

      # Cleanup
      assert :ok = GenServer.call(manager, {:close_session, "unsub-test"})
      # We unsubscribed, so we won't get pty_exit either
    end

    @tag :integration
    test "close_all terminates all sessions", %{manager: manager} do
      assert {:ok, _} =
               GenServer.call(
                 manager,
                 {:create_session, "a", [subscriber: self()]}
               )

      assert {:ok, _} =
               GenServer.call(
                 manager,
                 {:create_session, "b", [subscriber: self()]}
               )

      assert GenServer.call(manager, :count) == 2

      # Drain output before close to avoid mailbox noise
      drain_pty_output("a")
      drain_pty_output("b")

      assert :ok = GenServer.call(manager, :close_all)

      # Both pty_exit messages sent synchronously from close_all
      assert_receive {:pty_exit, "a", :closed}
      assert_receive {:pty_exit, "b", :closed}
    end

    @tag :integration
    test "exiting shell sends DOWN message and cleans up session", %{manager: manager} do
      assert {:ok, _session} =
               GenServer.call(
                 manager,
                 {:create_session, "exit-test", [subscriber: self()]}
               )

      # Tell the shell to exit
      assert :ok =
               GenServer.call(manager, {:write, "exit-test", "exit\n"})

      # Should receive exit notification from DOWN handler (not close_session)
      assert_receive {:pty_exit, "exit-test", _reason}, 5_000
    end

    @tag :integration
    test "close_session sends pty_exit to subscriber", %{manager: manager} do
      assert {:ok, _session} =
               GenServer.call(
                 manager,
                 {:create_session, "close-notify", [subscriber: self()]}
               )

      # Drain output first
      drain_pty_output("close-notify")

      # Close the session explicitly
      assert :ok = GenServer.call(manager, {:close_session, "close-notify"})

      # Subscriber receives pty_exit synchronously from close_session
      assert_receive {:pty_exit, "close-notify", :closed}
    end
  end

  # ===========================================================================
  # Error handling
  # ===========================================================================

  describe "error handling" do
    @tag :integration
    test "create_session with nonexistent shell exits quickly", %{manager: manager} do
      # erlexec doesn't fail immediately for a bad executable — it starts a process
      # that then exits. With :monitor, we get a DOWN message.
      assert {:ok, _session} =
               GenServer.call(
                 manager,
                 {:create_session, "bad-shell", [shell: "/nonexistent/shell", subscriber: self()]}
               )

      # The process should exit with an error (from DOWN handler)
      assert_receive {:pty_exit, "bad-shell", _reason}, 5_000
    end
  end

  # ===========================================================================
  # Test helpers
  # ===========================================================================

  # Drain all pending {:pty_output, ...} messages for a session from the mailbox.
  # Used before close_session to avoid stale output interfering with assert_receive.
  defp drain_pty_output(session_id) do
    receive do
      {:pty_output, ^session_id, _data} -> drain_pty_output(session_id)
    after
      0 -> :ok
    end
  end

  defp collect_pty_output(session_id, timeout) do
    collect_pty_output(session_id, timeout, [])
  end

  defp collect_pty_output(session_id, timeout, acc) do
    receive do
      {:pty_output, ^session_id, data} ->
        collect_pty_output(session_id, 100, [data | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end
end
