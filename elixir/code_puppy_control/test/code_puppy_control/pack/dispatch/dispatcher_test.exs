defmodule CodePuppyControl.Pack.Dispatch.DispatcherTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.Dispatch.Dispatcher

  # ── Backward Compat: Local Dispatch ──────────────────────────────────────

  describe "dispatch/3 backward compatibility" do
    test "defaults to local when no options provided" do
      assert {:local, :noop} = Dispatcher.dispatch(:terrier, %{worktree_path: "."})
    end

    test "defaults to local with empty options list" do
      assert {:local, :noop} = Dispatcher.dispatch(:terrier, %{worktree_path: "."}, [])
    end

    test "defaults to local when auto_dispatch is explicitly false" do
      assert {:local, :noop} =
               Dispatcher.dispatch(:terrier, %{worktree_path: "."}, auto_dispatch: false)
    end

    test "defaults to local when node is nil" do
      assert {:local, :noop} =
               Dispatcher.dispatch(:terrier, %{worktree_path: "."}, node: nil)
    end

    test "defaults to local with random irrelevant options" do
      assert {:local, :noop} =
               Dispatcher.dispatch(:terrier, %{worktree_path: "."},
                 model: "claude-sonnet-4-20250514",
                 session_id: "test-session-abc123"
               )
    end
  end

  # ── Remote Dispatch ──────────────────────────────────────────────────────

  describe "dispatch/3 with explicit node" do
    test "attempts remote dispatch when node option is set" do
      # Remote dispatch via RemoteNodeProxy will fail because the Registry
      # isn't running in test — but we verify the module attempts the remote path
      # by checking the result shape (error, not local).
      result =
        Dispatcher.dispatch(:terrier, %{worktree_path: "."},
          node: :nonexistent_worker@localhost
        )

      assert match?({:error, _}, result)
      refute match?({:local, _}, result)
    end

    test "returns error when remote dispatch crashes" do
      # When Registry/RemoteNodeProxy aren't running, the GenServer call
      # exits — this is caught by the catch clause and returned as an error.
      assert {:error, {:remote_dispatch_crashed, _reason}} =
               Dispatcher.dispatch(:terrier, %{}, node: :nonexistent_worker@localhost)
    end
  end

  # ── Auto Dispatch ────────────────────────────────────────────────────────

  describe "dispatch/3 with auto_dispatch" do
    test "falls back to local when auto_dispatch is true but no workers available" do
      # Capability-based worker selection is not yet implemented;
      # auto_dispatch falls back to local.
      assert {:local, :noop} =
               Dispatcher.dispatch(:terrier, %{worktree_path: "."}, auto_dispatch: true)
    end

    test "local fallback for auto_dispatch with empty params" do
      assert {:local, :noop} = Dispatcher.dispatch(:terrier, %{}, auto_dispatch: true)
    end
  end

  # ── remote_dispatch?/1 ───────────────────────────────────────────────────

  describe "remote_dispatch?/1" do
    test "returns false when no options given" do
      refute Dispatcher.remote_dispatch?([])
    end

    test "returns false when node is nil" do
      refute Dispatcher.remote_dispatch?(node: nil)
    end

    test "returns false when only auto_dispatch is set" do
      refute Dispatcher.remote_dispatch?(auto_dispatch: true)
    end

    test "returns true when node is specified" do
      assert Dispatcher.remote_dispatch?(node: :worker@host)
    end

    test "returns true when node is specified alongside other options" do
      assert Dispatcher.remote_dispatch?(node: :worker@host, auto_dispatch: true)
    end
  end

  # ── Telemetry ────────────────────────────────────────────────────────────

  describe "telemetry emission" do
    test "emits [:code_puppy, :pack, :dispatch, :decision] on local dispatch" do
      handler_id = make_ref()
      events = [:code_puppy, :pack, :dispatch, :decision]

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:dispatch_decision, measurements, metadata})
        end,
        self()
      )

      assert {:local, :noop} = Dispatcher.dispatch(:terrier, %{worktree_path: "."})

      assert_received {:dispatch_decision, %{system_time: _},
                       %{kind: :local, agent_name: :terrier}}

      :telemetry.detach(handler_id)
    end

    test "emits telemetry with node info on remote attempt" do
      handler_id = make_ref()
      events = [:code_puppy, :pack, :dispatch, :decision]

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:dispatch_decision, measurements, metadata})
        end,
        self()
      )

      _result =
        Dispatcher.dispatch(:watchdog, %{},
          node: :some_remote@host
        )

      assert_received {:dispatch_decision, %{system_time: _},
                       %{kind: :remote, agent_name: :watchdog, node: :some_remote@host}}

      :telemetry.detach(handler_id)
    end

    test "emits telemetry on auto_dispatch" do
      handler_id = make_ref()
      events = [:code_puppy, :pack, :dispatch, :decision]

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:dispatch_decision, measurements, metadata})
        end,
        self()
      )

      assert {:local, :noop} =
               Dispatcher.dispatch(:shepherd, %{task: "x"}, auto_dispatch: true)

      assert_received {:dispatch_decision, %{system_time: _},
                       %{kind: :auto, agent_name: :shepherd}}

      :telemetry.detach(handler_id)
    end
  end
end
