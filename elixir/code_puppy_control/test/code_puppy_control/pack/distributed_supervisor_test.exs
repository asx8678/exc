defmodule CodePuppyControl.Pack.DistributedSupervisorTest do
  @moduledoc """
  Tests for DistributedSupervisor — DynamicSupervisor managing per-node
  RemoteNodeSupervisor children.

  Uses mock proxy opts (monitor_fn, handshake_fn, name) so tests run
  without a real remote Erlang node or distribution layer. All tests
  use async: false because they share the Registry processes started
  by the application tree.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.DistributedSupervisor
  alias CodePuppyControl.Pack.RemoteNodeProxy

  @test_node :pup_ds_test_worker@localhost
  @ds_name :test_distributed_supervisor

  # Mock proxy opts — avoid Node.monitor/2 (crashes without distribution)
  # and GenServer.call to a non-existent remote node during handshake.
  # Cannot be a module attribute because anonymous functions are not escapable.
  defp mock_proxy_opts do
    [
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end,
      name: nil
    ]
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # Registries are already started by the application supervision tree.
    # Only start the DistributedSupervisor under a custom name for isolation.
    start_supervised!({DistributedSupervisor, name: @ds_name})

    %{ds_name: @ds_name}
  end

  # ── start_link ────────────────────────────────────────────────────────────

  describe "start_link/1" do
    test "returns {:ok, pid}" do
      {:ok, pid} = DistributedSupervisor.start_link(name: :ds_start_test)
      assert Process.alive?(pid)
      Supervisor.stop(pid)
    end
  end

  # ── add_node ──────────────────────────────────────────────────────────────

  describe "add_node/1" do
    test "starts a RemoteNodeSupervisor child under the DynamicSupervisor" do
      assert {:ok, sup_pid} =
               DistributedSupervisor.add_node(@test_node,
                 supervisor_name: @ds_name,
                 proxy_opts: mock_proxy_opts()
               )

      assert Process.alive?(sup_pid)

      # Verify via DynamicSupervisor.count_children
      counts = DynamicSupervisor.count_children(@ds_name)
      assert counts.active == 1

      # Verify via list_nodes
      assert DistributedSupervisor.list_nodes(@ds_name) == [@test_node]
    end

    test "add_node on duplicate returns {:error, {:already_present, pid}}" do
      {:ok, pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      assert {:error, {:already_present, ^pid}} =
               DistributedSupervisor.add_node(@test_node,
                 supervisor_name: @ds_name,
                 proxy_opts: mock_proxy_opts()
               )
    end

    test "add_node with keyword-form opts works" do
      assert {:ok, _pid} =
               DistributedSupervisor.add_node(:pup_compat_test@localhost,
                 supervisor_name: @ds_name,
                 proxy_opts: mock_proxy_opts()
               )
    end
  end

  # ── remove_node ───────────────────────────────────────────────────────────

  describe "remove_node/1" do
    test "removes a previously added node" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      assert DistributedSupervisor.list_nodes(@ds_name) == [@test_node]

      assert :ok = DistributedSupervisor.remove_node(@test_node, @ds_name)
      assert DistributedSupervisor.list_nodes(@ds_name) == []
    end

    test "returns {:error, :not_found} for unknown node" do
      assert {:error, :not_found} =
               DistributedSupervisor.remove_node(:unknown_node@host, @ds_name)
    end
  end

  # ── dispatch ──────────────────────────────────────────────────────────────

  describe "dispatch/3" do
    test "returns {:error, {:node_not_connected, name}} for unknown node" do
      assert {:error, {:node_not_connected, :unknown_node@host}} =
               DistributedSupervisor.dispatch(:unknown_node@host, :terrier, %{}, @ds_name)
    end

    test "delegates to RemoteNodeProxy on a connected node" do
      {:ok, sup_pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      assert Process.alive?(sup_pid)

      # The proxy starts in :connecting state (handshake hasn't succeeded).
      # Find it and push a capabilities cast to make it connected.
      proxy_pid = find_proxy_pid(sup_pid)

      GenServer.cast(proxy_pid, {:capabilities, %{sub_agents: [:terrier]}})
      Process.sleep(10)

      # Verify the proxy transitioned to connected
      assert %{status: :connected} = RemoteNodeProxy.status(proxy_pid)

      # Dispatch should delegate through to the proxy
      assert {:ok, run_id} =
               DistributedSupervisor.dispatch(
                 @test_node,
                 :terrier,
                 %{worktree_path: "."},
                 @ds_name
               )

      assert is_binary(run_id)
      assert String.starts_with?(run_id, "dist_")
    end
  end

  # ── list_nodes ────────────────────────────────────────────────────────────

  describe "list_nodes/0" do
    test "returns empty list when no nodes added" do
      assert DistributedSupervisor.list_nodes(@ds_name) == []
    end

    test "lists connected nodes after add_node" do
      DistributedSupervisor.add_node(@test_node,
        supervisor_name: @ds_name,
        proxy_opts: mock_proxy_opts()
      )

      assert DistributedSupervisor.list_nodes(@ds_name) == [@test_node]

      other_node = :pup_other_worker@localhost

      DistributedSupervisor.add_node(other_node,
        supervisor_name: @ds_name,
        proxy_opts: mock_proxy_opts()
      )

      nodes = DistributedSupervisor.list_nodes(@ds_name)
      assert @test_node in nodes
      assert other_node in nodes
      assert length(nodes) == 2
    end

    test "reflects removal" do
      DistributedSupervisor.add_node(@test_node,
        supervisor_name: @ds_name,
        proxy_opts: mock_proxy_opts()
      )

      DistributedSupervisor.remove_node(@test_node, @ds_name)
      assert DistributedSupervisor.list_nodes(@ds_name) == []
    end
  end

  # ── status ────────────────────────────────────────────────────────────────

  describe "status/0" do
    test "returns expected structure with empty state" do
      status = DistributedSupervisor.status(@ds_name)

      assert %{
               connected: [],
               workers_active: 0,
               workers_total: 0
             } = status
    end

    test "returns expected structure with connected nodes" do
      DistributedSupervisor.add_node(@test_node,
        supervisor_name: @ds_name,
        proxy_opts: mock_proxy_opts()
      )

      DistributedSupervisor.add_node(:pup_other@localhost,
        supervisor_name: @ds_name,
        proxy_opts: mock_proxy_opts()
      )

      status = DistributedSupervisor.status(@ds_name)

      assert %{
               connected: [_, _],
               workers_active: 2,
               workers_total: 2
             } = status

      assert @test_node in status.connected
      assert :pup_other@localhost in status.connected
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp find_proxy_pid(sup_pid) do
    children = Supervisor.which_children(sup_pid)

    {:remote_node_proxy, proxy_pid, :worker, _mods} =
      Enum.find(children, fn {id, _pid, _type, _mods} -> id == :remote_node_proxy end)

    proxy_pid
  end
end
