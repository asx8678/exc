defmodule CodePuppyControl.Pack.LoadBalancerTest do
  @moduledoc """
  Tests for the Pack.LoadBalancer — load-aware worker selection.

  Validates:
  - start_link/1 starts cleanly
  - select_worker/1 returns :none when no workers registered
  - select_worker/1 with one worker returns that worker
  - select_worker/1 round-robins across multiple eligible workers
  - record_dispatch/2 increments active_dispatches
  - record_completion/3 decrements active_dispatches
  - Worker at capacity is excluded from selection
  - available_slots/1 returns correct value
  - load_snapshot/0 returns all tracked nodes
  - sync_node/1 loads capabilities from NamingService
  - remove_node/1 removes node from tracking
  - Round-robin wraps correctly after many selections
  - Unknown node has default capacity assumption

  (Phase I.4 — code_puppy-yge.2)
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.LoadBalancer
  alias CodePuppyControl.Pack.NamingService

  # async: false because we start named GenServers (LoadBalancer, NamingService)

  setup do
    # Start NamingService for tests
    {:ok, _} = start_supervised({NamingService, []})

    # Start LoadBalancer for tests
    {:ok, _} = start_supervised({LoadBalancer, []})

    # Register some test workers
    on_exit(fn ->
      try do
        NamingService.unregister_node(:"pup_lb_a@localhost")
        NamingService.unregister_node(:"pup_lb_b@localhost")
        NamingService.unregister_node(:"pup_lb_c@localhost")
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # start_link/1
  # ---------------------------------------------------------------------------

  describe "start_link/1" do
    test "starts cleanly" do
      # Already started in setup — verify it's alive
      pid = GenServer.whereis(LoadBalancer)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # select_worker/1
  # ---------------------------------------------------------------------------

  describe "select_worker/1" do
    test "returns :none when no workers registered" do
      assert LoadBalancer.select_worker(:terrier) == :none
    end

    test "returns :none when workers exist but none match sub_agent type" do
      NamingService.register_capabilities(
        :"pup_lb_a@localhost",
        %{sub_agents: [:watchdog], max_concurrent_runs: 2}
      )

      assert LoadBalancer.select_worker(:terrier) == :none
    end

    test "with one worker registered returns that worker" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      # Sync so LoadBalancer knows about the node's capacity
      LoadBalancer.sync_node(node_a)

      assert {:ok, ^node_a} = LoadBalancer.select_worker(:terrier)
    end

    test "round-robins across multiple eligible workers" do
      node_a = :"pup_lb_a@localhost"
      node_b = :"pup_lb_b@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      NamingService.register_capabilities(
        node_b,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)
      LoadBalancer.sync_node(node_b)

      # Select multiple times — should round-robin
      results =
        for _ <- 1..4 do
          LoadBalancer.select_worker(:terrier)
        end

      nodes = for {:ok, n} <- results, do: n

      # Both nodes should appear at least once
      assert node_a in nodes
      assert node_b in nodes
    end

    test "round-robin wraps correctly after many selections" do
      node_a = :"pup_lb_a@localhost"
      node_b = :"pup_lb_b@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      NamingService.register_capabilities(
        node_b,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)
      LoadBalancer.sync_node(node_b)

      # Select 20 times — should cycle without errors
      results =
        for _ <- 1..20 do
          LoadBalancer.select_worker(:terrier)
        end

      assert length(results) == 20

      for {:ok, n} <- results do
        assert n in [node_a, node_b]
      end
    end

    test "respects constraints in selection" do
      node_a = :"pup_lb_a@localhost"
      node_b = :"pup_lb_b@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], host_os: "linux", max_concurrent_runs: 4}
      )

      NamingService.register_capabilities(
        node_b,
        %{sub_agents: [:terrier], host_os: "macos", max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)
      LoadBalancer.sync_node(node_b)

      # Only linux node should be eligible
      assert {:ok, ^node_a} = LoadBalancer.select_worker(:terrier, host_os: "linux")
    end
  end

  # ---------------------------------------------------------------------------
  # record_dispatch/2
  # ---------------------------------------------------------------------------

  describe "record_dispatch/2" do
    test "increments active_dispatches" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)

      # Initial state
      assert LoadBalancer.available_slots(node_a) == 4

      # Record a dispatch
      LoadBalancer.record_dispatch(node_a, "run-1")

      # Give cast time to process
      Process.sleep(50)

      assert LoadBalancer.available_slots(node_a) == 3

      # Verify snapshot
      snapshot = LoadBalancer.load_snapshot()
      assert snapshot[node_a].active_dispatches == 1
      assert snapshot[node_a].total_dispatches == 1
    end

    test "initializes unknown node with default capacity" do
      unknown_node = :"pup_unknown@localhost"

      LoadBalancer.record_dispatch(unknown_node, "run-x")
      Process.sleep(50)

      # Unknown node gets default max_concurrent (4)
      assert LoadBalancer.available_slots(unknown_node) == 3

      snapshot = LoadBalancer.load_snapshot()
      assert snapshot[unknown_node].active_dispatches == 1
      assert snapshot[unknown_node].max_concurrent == 4
    end
  end

  # ---------------------------------------------------------------------------
  # record_completion/3
  # ---------------------------------------------------------------------------

  describe "record_completion/3" do
    test "decrements active_dispatches on success" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)
      LoadBalancer.record_dispatch(node_a, "run-1")
      Process.sleep(50)

      assert LoadBalancer.available_slots(node_a) == 3

      LoadBalancer.record_completion(node_a, "run-1", :success)
      Process.sleep(50)

      assert LoadBalancer.available_slots(node_a) == 4

      snapshot = LoadBalancer.load_snapshot()
      assert snapshot[node_a].total_completions == 1
      assert snapshot[node_a].total_failures == 0
    end

    test "increments failure counter on failure" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)
      LoadBalancer.record_dispatch(node_a, "run-2")
      Process.sleep(50)

      LoadBalancer.record_completion(node_a, "run-2", :failure)
      Process.sleep(50)

      snapshot = LoadBalancer.load_snapshot()
      assert snapshot[node_a].active_dispatches == 0
      assert snapshot[node_a].total_completions == 0
      assert snapshot[node_a].total_failures == 1
    end

    test "increments failure counter on rejection" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)
      LoadBalancer.record_dispatch(node_a, "run-3")
      Process.sleep(50)

      LoadBalancer.record_completion(node_a, "run-3", :rejected)
      Process.sleep(50)

      snapshot = LoadBalancer.load_snapshot()
      assert snapshot[node_a].total_failures == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Worker at capacity
  # ---------------------------------------------------------------------------

  describe "capacity exclusion" do
    test "worker at capacity is excluded from selection" do
      node_a = :"pup_lb_a@localhost"
      node_b = :"pup_lb_b@localhost"

      # node_a has capacity 1, node_b has capacity 4
      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 1}
      )

      NamingService.register_capabilities(
        node_b,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)
      LoadBalancer.sync_node(node_b)

      # Fill node_a to capacity
      LoadBalancer.record_dispatch(node_a, "run-cap-1")
      Process.sleep(50)

      # node_a should be excluded — only node_b available
      # May need multiple selections to hit node_b since rr_index is unknown
      results =
        for _ <- 1..10 do
          LoadBalancer.select_worker(:terrier)
        end

      nodes = for {:ok, n} <- results, do: n

      # node_a should never be selected (it's at capacity)
      refute node_a in nodes
      assert node_b in nodes
    end

    test "returns :none when ALL workers are at capacity" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 1}
      )

      LoadBalancer.sync_node(node_a)

      # Fill to capacity
      LoadBalancer.record_dispatch(node_a, "run-full-1")
      Process.sleep(50)

      assert LoadBalancer.select_worker(:terrier) == :none
    end
  end

  # ---------------------------------------------------------------------------
  # available_slots/1
  # ---------------------------------------------------------------------------

  describe "available_slots/1" do
    test "returns correct value for tracked node" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)

      assert LoadBalancer.available_slots(node_a) == 4

      LoadBalancer.record_dispatch(node_a, "run-slots-1")
      Process.sleep(50)

      assert LoadBalancer.available_slots(node_a) == 3
    end

    test "returns default for unknown node" do
      # Unknown node gets default max_concurrent of 4
      assert LoadBalancer.available_slots(:"pup_totally_unknown@nowhere") == 4
    end
  end

  # ---------------------------------------------------------------------------
  # load_snapshot/0
  # ---------------------------------------------------------------------------

  describe "load_snapshot/0" do
    test "returns all tracked nodes" do
      node_a = :"pup_lb_a@localhost"
      node_b = :"pup_lb_b@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      NamingService.register_capabilities(
        node_b,
        %{sub_agents: [:watchdog], max_concurrent_runs: 2}
      )

      LoadBalancer.sync_node(node_a)
      LoadBalancer.sync_node(node_b)

      snapshot = LoadBalancer.load_snapshot()

      assert Map.has_key?(snapshot, node_a)
      assert Map.has_key?(snapshot, node_b)
      assert snapshot[node_a].max_concurrent == 4
      assert snapshot[node_b].max_concurrent == 2
    end
  end

  # ---------------------------------------------------------------------------
  # sync_node/1
  # ---------------------------------------------------------------------------

  describe "sync_node/1" do
    test "loads capabilities from NamingService" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 8}
      )

      LoadBalancer.sync_node(node_a)
      Process.sleep(50)

      snapshot = LoadBalancer.load_snapshot()
      assert snapshot[node_a].max_concurrent == 8
      assert snapshot[node_a].active_dispatches == 0
    end

    test "updates max_concurrent on re-sync" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 2}
      )

      LoadBalancer.sync_node(node_a)
      Process.sleep(50)

      # Update capabilities
      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 8}
      )

      LoadBalancer.sync_node(node_a)
      Process.sleep(50)

      snapshot = LoadBalancer.load_snapshot()
      assert snapshot[node_a].max_concurrent == 8
    end

    test "uses default when NamingService has no capabilities" do
      # A node not in NamingService gets default max_concurrent
      LoadBalancer.sync_node(:"pup_no_caps@localhost")
      Process.sleep(50)

      snapshot = LoadBalancer.load_snapshot()
      assert snapshot[:"pup_no_caps@localhost"].max_concurrent == 4
    end
  end

  # ---------------------------------------------------------------------------
  # remove_node/1
  # ---------------------------------------------------------------------------

  describe "remove_node/1" do
    test "removes node from tracking" do
      node_a = :"pup_lb_a@localhost"

      NamingService.register_capabilities(
        node_a,
        %{sub_agents: [:terrier], max_concurrent_runs: 4}
      )

      LoadBalancer.sync_node(node_a)
      Process.sleep(50)

      assert Map.has_key?(LoadBalancer.load_snapshot(), node_a)

      LoadBalancer.remove_node(node_a)
      Process.sleep(50)

      refute Map.has_key?(LoadBalancer.load_snapshot(), node_a)
    end

    test "removing unknown node is a no-op" do
      # Should not crash
      LoadBalancer.remove_node(:"pup_nonexistent@nowhere")
      Process.sleep(50)

      snapshot = LoadBalancer.load_snapshot()
      refute Map.has_key?(snapshot, :"pup_nonexistent@nowhere")
    end
  end
end
