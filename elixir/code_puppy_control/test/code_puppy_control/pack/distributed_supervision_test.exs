defmodule CodePuppyControl.Pack.DistributedSupervisionTest do
  @moduledoc """
  Integration tests for the distributed pack supervision tree startup.

  Tests that Registries, DistributedSupervisor, and NodeMonitor start
  successfully and coexist without crashes.

  These tests use the app-started Registries (already running in the
  supervision tree) and only start test-specific DistributedSupervisor
  and NodeMonitor instances.

  ## Tagging

  Tagged with `@moduletag :integration` and `@moduletag :distributed`.
  Run via:

      mix test --only integration --only distributed
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :distributed

  alias CodePuppyControl.Pack.DistributedSupervisor
  alias CodePuppyControl.Pack.NodeMonitor

  @ds_name :test_int_distributed_supervisor
  @nm_name :test_int_node_monitor

  # ── Mock helpers ─────────────────────────────────────────────────────────

  defp mock_proxy_opts do
    [
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end,
      name: nil,
      grace_period_timeout: 0
    ]
  end

  defp monitor_opts(extra) do
    Keyword.merge(
      [
        name: @nm_name,
        supervisor_name: @ds_name,
        proxy_opts: mock_proxy_opts(),
        connect_fn: fn _node -> false end,
        monitor_fn: fn _node, _flag -> true end
      ],
      extra
    )
  end

  defp nm_status, do: GenServer.call(@nm_name, :status)

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    cleanup_ets()

    on_exit(fn ->
      cleanup_ets()
    end)

    :ok
  end

  defp cleanup_ets do
    try do
      :ets.delete(:pack_node_monitor_state)
    rescue
      _ -> :ok
    end

    try do
      :ets.delete(:pack_distributed_supervisor_nodes)
    rescue
      _ -> :ok
    end
  end

  # ── Supervision tree startup ─────────────────────────────────────────────

  describe "supervision tree startup" do
    test "Registries supervisor is already running from app tree" do
      assert is_pid(Process.whereis(CodePuppyControl.Pack.Registries)),
             "Registries should be started by the application tree"

      assert is_pid(Process.whereis(CodePuppyControl.Pack.RemoteNodeSupervisor.Registry)),
             "RemoteNodeSupervisor.Registry should be started"

      assert is_pid(Process.whereis(CodePuppyControl.Pack.RemoteNodeProxy.Registry)),
             "RemoteNodeProxy.Registry should be started"
    end

    test "DistributedSupervisor starts successfully" do
      assert {:ok, _pid} = start_supervised({DistributedSupervisor, name: @ds_name})

      assert DistributedSupervisor.list_nodes(@ds_name) == []

      on_exit(fn ->
        kill_registered(@ds_name)
      end)
    end

    test "NodeMonitor starts successfully in disabled mode" do
      start_supervised!({DistributedSupervisor, name: @ds_name})

      assert {:ok, _pid} =
               start_supervised(
                 {NodeMonitor,
                  monitor_opts(
                    enabled: false,
                    workers: [],
                    heartbeat_interval: 60_000
                  )}
               )

      status = nm_status()
      assert status.configured_workers == []
      assert status.connected_nodes == []

      on_exit(fn ->
        kill_registered(@nm_name)
        kill_registered(@ds_name)
      end)
    end

    test "all three processes coexist without crashes" do
      start_supervised!({DistributedSupervisor, name: @ds_name})

      assert {:ok, pid} =
               start_supervised(
                 {NodeMonitor,
                  monitor_opts(
                    enabled: false,
                    workers: [],
                    heartbeat_interval: 60_000
                  )}
               )

      assert Process.alive?(pid)
      assert Process.whereis(@ds_name) |> is_pid()
      assert is_pid(Process.whereis(CodePuppyControl.Pack.Registries))

      on_exit(fn ->
        kill_registered(@nm_name)
        kill_registered(@ds_name)
      end)
    end

    test "NodeMonitor starts with test-specific unique names" do
      ds_name = :"test_su_ds_#{:erlang.unique_integer([:positive])}"
      nm_name = :"test_su_nm_#{:erlang.unique_integer([:positive])}"

      start_supervised!({DistributedSupervisor, name: ds_name})

      {:ok, pid} =
        start_supervised(
          {NodeMonitor,
           Keyword.merge(
             monitor_opts(
               enabled: false,
               workers: [],
               heartbeat_interval: 60_000
             ),
             name: nm_name,
             supervisor_name: ds_name
           )}
        )

      assert Process.alive?(pid)
      assert length(DistributedSupervisor.list_nodes(ds_name)) == 0

      on_exit(fn ->
        kill_registered(nm_name)
        kill_registered(ds_name)
      end)
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp kill_registered(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        Process.exit(pid, :kill)

        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          2000 -> :ok
        end
    end
  end
end
