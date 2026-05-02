defmodule CodePuppyControl.Pack.Dispatch.CapabilityQueryTest do
  @moduledoc """
  Tests for CapabilityQuery — high-level worker discovery for Pack Leader.

  Uses the application-tree DistributedSupervisor (started under default name)
  and a manually-started NamingService singleton. Tagged `@moduletag :distributed`
  because tests rely on Registry processes started by the application tree.
  """

  use ExUnit.Case, async: false

  @moduletag :distributed

  alias CodePuppyControl.Pack.Dispatch.CapabilityQuery
  alias CodePuppyControl.Pack.{NamingService, DistributedSupervisor}

  # ── Mock proxy opts ──────────────────────────────────────────────────────

  defp mock_proxy_opts(caps) do
    [
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:ok, caps} end
    ]
  end

  # ── Test Node Atoms ──────────────────────────────────────────────────────

  @linux_terrier :cq_linux_terrier@test
  @linux_watchdog :cq_linux_watchdog@test
  @macos_terrier :cq_macos_terrier@test

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp register_test_nodes do
    NamingService.register_node(@linux_terrier, %{
      sub_agents: [:terrier, :retriever],
      host_os: "linux",
      max_concurrent_runs: 4,
      available_models: ["claude-sonnet-4-20250514"]
    })

    NamingService.register_node(@linux_watchdog, %{
      sub_agents: [:terrier, :watchdog],
      host_os: "linux",
      max_concurrent_runs: 2,
      available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"]
    })

    NamingService.register_node(@macos_terrier, %{
      sub_agents: [:terrier, :shepherd],
      host_os: "macos",
      max_concurrent_runs: 8,
      available_models: ["claude-sonnet-4-20250514"]
    })

    :ok
  end

  defp add_connected_worker(node_name, caps) do
    NamingService.register_node(node_name, caps)

    {:ok, _supervisor_pid} =
      DistributedSupervisor.add_node(node_name,
        supervisor_name: DistributedSupervisor,
        proxy_opts: mock_proxy_opts(caps)
      )

    # Wait for the proxy to finish handshake (handle_continue) and
    # reach :connected state before the test proceeds
    wait_for_proxy_connected(node_name)

    # Register cleanup — runs before next setup clears NamingService
    on_exit(fn ->
      DistributedSupervisor.remove_node(node_name, DistributedSupervisor)
    end)

    :ok
  end

  defp wait_for_proxy_connected(node_name, timeout_ms \\ 500) do
    deadline =
      System.monotonic_time() + System.convert_time_unit(timeout_ms, :millisecond, :native)

    poll_proxy_connected(node_name, deadline)
  end

  defp poll_proxy_connected(node_name, deadline) do
    if System.monotonic_time() >= deadline do
      raise "Timed out waiting for proxy #{inspect(node_name)} to reach :connected state"
    end

    case Registry.lookup(CodePuppyControl.Pack.RemoteNodeProxy.Registry, node_name) do
      [{pid, _}] ->
        status = CodePuppyControl.Pack.RemoteNodeProxy.status(pid)

        if status.status == :connected do
          :ok
        else
          Process.sleep(5)
          poll_proxy_connected(node_name, deadline)
        end

      [] ->
        Process.sleep(5)
        poll_proxy_connected(node_name, deadline)
    end
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    ensure_naming_service!()
    :ok
  end

  defp ensure_naming_service! do
    case Process.whereis(CodePuppyControl.Pack.NamingService) do
      nil ->
        case CodePuppyControl.Pack.NamingService.start_link([]) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            CodePuppyControl.Pack.NamingService.clear()
        end

      _pid ->
        CodePuppyControl.Pack.NamingService.clear()
    end
  end

  # ── find_eligible/2 ──────────────────────────────────────────────────────

  describe "find_eligible/2" do
    test "returns empty list when no nodes are registered in NamingService" do
      assert CapabilityQuery.find_eligible(:terrier) == []
    end

    test "returns empty list when nodes are registered but none connected" do
      register_test_nodes()
      assert CapabilityQuery.find_eligible(:terrier) == []
    end

    test "returns connected workers matching sub-agent type" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier, :retriever],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      result = CapabilityQuery.find_eligible(:terrier)

      assert length(result) == 1
      assert %{node: @linux_terrier, status: :connected} = hd(result)
      assert hd(result).capabilities[:sub_agents] == [:terrier, :retriever]
    end

    test "filters by host_os when provided" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier, :retriever],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      add_connected_worker(@macos_terrier, %{
        sub_agents: [:terrier, :shepherd],
        host_os: "macos",
        max_concurrent_runs: 8
      })

      linux_workers = CapabilityQuery.find_eligible(:terrier, %{host_os: "linux"})
      assert length(linux_workers) == 1
      assert hd(linux_workers).node == @linux_terrier

      mac_workers = CapabilityQuery.find_eligible(:terrier, %{host_os: "macos"})
      assert length(mac_workers) == 1
      assert hd(mac_workers).node == @macos_terrier
    end

    test "filters by model when provided" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier, :retriever],
        host_os: "linux",
        max_concurrent_runs: 4,
        available_models: ["claude-sonnet-4-20250514"]
      })

      add_connected_worker(@linux_watchdog, %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 2,
        available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"]
      })

      haiku_workers =
        CapabilityQuery.find_eligible(:terrier, %{model: "claude-haiku-3-5"})

      assert length(haiku_workers) == 1
      assert hd(haiku_workers).node == @linux_watchdog
    end

    test "filters by both host_os and model" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier, :retriever],
        host_os: "linux",
        max_concurrent_runs: 4,
        available_models: ["claude-sonnet-4-20250514"]
      })

      add_connected_worker(@linux_watchdog, %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 2,
        available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"]
      })

      add_connected_worker(@macos_terrier, %{
        sub_agents: [:terrier, :shepherd],
        host_os: "macos",
        max_concurrent_runs: 8,
        available_models: ["claude-sonnet-4-20250514"]
      })

      result =
        CapabilityQuery.find_eligible(:terrier, %{
          host_os: "linux",
          model: "claude-sonnet-4-20250514"
        })

      assert length(result) == 2
      nodes = Enum.map(result, & &1.node)
      assert @linux_terrier in nodes
      assert @linux_watchdog in nodes
    end

    test "returns only connected nodes even when NamingService has more matches" do
      register_test_nodes()

      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier, :retriever],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      result = CapabilityQuery.find_eligible(:terrier, %{host_os: "linux"})
      assert length(result) == 1
      assert hd(result).node == @linux_terrier
    end

    test "includes full capabilities map in result" do
      add_connected_worker(@linux_watchdog, %{
        sub_agents: [:watchdog],
        host_os: "linux",
        max_concurrent_runs: 2,
        available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"]
      })

      result = CapabilityQuery.find_eligible(:watchdog)
      assert length(result) == 1

      worker = hd(result)
      assert worker.capabilities[:host_os] == "linux"
      assert worker.capabilities[:max_concurrent_runs] == 2

      assert worker.capabilities[:available_models] == [
               "claude-sonnet-4-20250514",
               "claude-haiku-3-5"
             ]
    end

    test "returns empty list for non-existent sub-agent type" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      assert CapabilityQuery.find_eligible(:nonexistent) == []
    end
  end

  # ── any_eligible?/2 ──────────────────────────────────────────────────────

  describe "any_eligible?/2" do
    test "returns false when no workers registered in NamingService" do
      refute CapabilityQuery.any_eligible?(:terrier)
    end

    test "returns false when workers registered but none connected" do
      register_test_nodes()
      refute CapabilityQuery.any_eligible?(:terrier)
    end

    test "returns true when at least one connected worker matches" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      assert CapabilityQuery.any_eligible?(:terrier)
    end

    test "returns false when no workers match the filter" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      refute CapabilityQuery.any_eligible?(:nonexistent)
    end
  end

  # ── best_worker/2 ────────────────────────────────────────────────────────

  describe "best_worker/2" do
    test "returns {:error, :no_eligible_workers} when no workers registered" do
      assert {:error, :no_eligible_workers} = CapabilityQuery.best_worker(:terrier)
    end

    test "returns {:error, :no_eligible_workers} when registered but none connected" do
      register_test_nodes()
      assert {:error, :no_eligible_workers} = CapabilityQuery.best_worker(:terrier)
    end

    test "returns the only eligible worker when one is available" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      assert {:ok, worker} = CapabilityQuery.best_worker(:terrier)
      assert worker.node == @linux_terrier
      assert worker.status == :connected
      assert is_integer(worker.active_runs)
    end

    test "returns the worker with fewest active runs when multiple are eligible" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      add_connected_worker(@linux_watchdog, %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 2
      })

      add_connected_worker(@macos_terrier, %{
        sub_agents: [:terrier, :shepherd],
        host_os: "macos",
        max_concurrent_runs: 8
      })

      assert {:ok, worker} = CapabilityQuery.best_worker(:terrier)
      assert worker.node in [@linux_terrier, @linux_watchdog, @macos_terrier]
      assert worker.status == :connected
      assert worker.active_runs == 0
    end

    test "respects host_os filter" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      add_connected_worker(@macos_terrier, %{
        sub_agents: [:terrier],
        host_os: "macos",
        max_concurrent_runs: 8
      })

      assert {:ok, worker} = CapabilityQuery.best_worker(:terrier, %{host_os: "macos"})
      assert worker.node == @macos_terrier
    end
  end

  # ── cluster_summary/0 ────────────────────────────────────────────────────

  describe "cluster_summary/0" do
    test "returns empty summary when nothing is registered" do
      summary = CapabilityQuery.cluster_summary()

      assert %{
               total_workers: 0,
               connected_workers: 0,
               total_capacity: 0,
               available_agents: [],
               available_models: []
             } = summary
    end

    test "aggregates across all registered nodes (not just connected)" do
      register_test_nodes()

      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier, :retriever],
        host_os: "linux",
        max_concurrent_runs: 4,
        available_models: ["claude-sonnet-4-20250514"]
      })

      add_connected_worker(@linux_watchdog, %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 2,
        available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"]
      })

      summary = CapabilityQuery.cluster_summary()

      assert summary.total_workers == 3
      assert summary.connected_workers == 2

      assert summary.total_capacity == 14

      assert :terrier in summary.available_agents
      assert :watchdog in summary.available_agents
      assert :retriever in summary.available_agents
      assert :shepherd in summary.available_agents

      assert "claude-sonnet-4-20250514" in summary.available_models
      assert "claude-haiku-3-5" in summary.available_models
    end
  end

  # ── Graceful Fallback ────────────────────────────────────────────────────

  describe "graceful fallback when services are down" do
    setup do
      on_exit(fn ->
        ensure_naming_service!()
      end)

      :ok
    end

    test "find_eligible returns empty when NamingService is not running" do
      :ok = GenServer.stop(NamingService)
      assert CapabilityQuery.find_eligible(:terrier) == []
    end

    test "any_eligible? returns false when NamingService is not running" do
      :ok = GenServer.stop(NamingService)
      refute CapabilityQuery.any_eligible?(:terrier)
    end

    test "best_worker returns error when NamingService is not running" do
      :ok = GenServer.stop(NamingService)
      assert {:error, :no_eligible_workers} = CapabilityQuery.best_worker(:terrier)
    end

    test "cluster_summary returns empty when NamingService is not running" do
      :ok = GenServer.stop(NamingService)

      summary = CapabilityQuery.cluster_summary()
      assert summary.total_workers == 0
      assert summary.connected_workers == 0
      assert summary.total_capacity == 0
    end
  end

  # ── Edge Cases ──────────────────────────────────────────────────────────

  describe "edge cases" do
    test "empty filters hash is equivalent to no filters" do
      add_connected_worker(@linux_terrier, %{
        sub_agents: [:terrier],
        host_os: "linux",
        max_concurrent_runs: 4
      })

      add_connected_worker(@macos_terrier, %{
        sub_agents: [:terrier],
        host_os: "macos",
        max_concurrent_runs: 8
      })

      result_empty = CapabilityQuery.find_eligible(:terrier, %{})
      result_none = CapabilityQuery.find_eligible(:terrier)

      assert result_empty == result_none
    end
  end
end
