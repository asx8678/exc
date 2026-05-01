defmodule CodePuppyControl.Pack.RemoteNodeProxyTelemetryTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.RemoteNodeProxy

  @test_node :pup_test_worker@localhost

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_proxy(opts \\ []) do
    base = [
      node_name: @test_node,
      name: nil,
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end
    ]

    RemoteNodeProxy.start_link(Keyword.merge(base, opts))
  end

  defp mock_caps do
    %{
      node_name: @test_node,
      sub_agents: [:terrier, :watchdog],
      host_os: "linux",
      available_models: ["claude-sonnet-4-20250514"],
      max_concurrent_runs: 4,
      features: %{file_ops: true, shell_access: true, git_access: true}
    }
  end

  # ── Telemetry ────────────────────────────────────────────────────────────

  describe "telemetry events" do
    test "emits node connected event on successful handshake" do
      events = [:code_puppy, :distributed_pack, :node, :connected]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_node_connected, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert_received {:telemetry_node_connected, %{node: @test_node}, %{capabilities: caps}}
      assert caps == mock_caps()

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits node disconnected event on nodedown" do
      events = [:code_puppy, :distributed_pack, :node, :disconnected]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_node_disconnected, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      send(pid, {:nodedown, @test_node})
      # Synchronous flush: status/1 call is processed AFTER the nodedown info
      RemoteNodeProxy.status(pid)

      assert_received {:telemetry_node_disconnected, %{node: @test_node}, %{active_runs: []}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits dispatch start on successful dispatch" do
      events = [:code_puppy, :distributed_pack, :dispatch, :start]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_dispatch_start, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      assert_received {:telemetry_dispatch_start, %{run_id: ^run_id},
                       %{node: @test_node, sub_agent: :terrier}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits dispatch stop on worker result" do
      events = [:code_puppy, :distributed_pack, :dispatch, :stop]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_dispatch_stop, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      GenServer.cast(pid, {:result, run_id, %{status: :success, output: "done"}})
      # Flush the cast
      RemoteNodeProxy.status(pid)

      assert_received {:telemetry_dispatch_stop,
                       %{run_id: ^run_id, duration_ms: dur, status: :success},
                       %{node: @test_node, sub_agent: :terrier}}

      assert is_integer(dur)

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits dispatch exception on nodedown with active runs" do
      events = [:code_puppy, :distributed_pack, :dispatch, :exception]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_dispatch_exception, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      assert {:ok, run_id} = RemoteNodeProxy.dispatch(pid, :terrier, %{worktree_path: "."})

      send(pid, {:nodedown, @test_node})
      # Synchronous flush
      RemoteNodeProxy.status(pid)

      assert_received {:telemetry_dispatch_exception,
                       %{run_id: ^run_id, error: "node_disconnected"}, %{node: @test_node}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end

    test "emits capabilities updated on capabilities cast" do
      events = [:code_puppy, :distributed_pack, :capabilities, :updated]
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_caps_updated, measurements, metadata})
        end,
        self()
      )

      {:ok, pid} = start_proxy()

      new_caps = mock_caps()
      GenServer.cast(pid, {:capabilities, new_caps})
      # Flush the cast
      RemoteNodeProxy.status(pid)

      assert_received {:telemetry_caps_updated, %{node: @test_node}, %{capabilities: ^new_caps}}

      :telemetry.detach(handler_id)
      GenServer.stop(pid, :normal)
    end
  end
end
