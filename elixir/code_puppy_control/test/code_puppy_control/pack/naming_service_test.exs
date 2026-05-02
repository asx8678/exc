defmodule CodePuppyControl.Pack.NamingServiceTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.NamingService

  # async: false because we use a named ETS table (:pack_worker_capabilities)
  # that cannot be shared across concurrently running test modules.

  setup do
    # Start NamingService (creates ETS table)
    {:ok, _pid} = start_supervised(NamingService)

    # Clean ETS table between tests
    on_exit(fn ->
      case :ets.whereis(:pack_worker_capabilities) do
        :undefined -> :ok
        _tid -> :ets.delete_all_objects(:pack_worker_capabilities)
      end
    end)

    :ok
  end

  # ── register_capabilities/2 ──────────────────────────────────────────────

  describe "register_capabilities/2" do
    test "stores capabilities for a node" do
      caps = %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        available_models: ["claude-sonnet-4-20250514"]
      }

      assert :ok = NamingService.register_capabilities(:"pup_w1@host1", caps)
      assert NamingService.node_capabilities(:"pup_w1@host1") == caps
    end

    test "upserts — replaces previous capabilities" do
      caps_v1 = %{sub_agents: [:terrier], host_os: "linux"}
      caps_v2 = %{sub_agents: [:terrier, :watchdog], host_os: "macos"}

      NamingService.register_capabilities(:"pup_w2@host2", caps_v1)
      NamingService.register_capabilities(:"pup_w2@host2", caps_v2)

      assert NamingService.node_capabilities(:"pup_w2@host2") == caps_v2
    end
  end

  # ── unregister_node/1 ───────────────────────────────────────────────────

  describe "unregister_node/1" do
    test "removes all entries for a node" do
      caps = %{sub_agents: [:terrier], host_os: "linux"}
      NamingService.register_capabilities(:"pup_w3@host3", caps)

      assert NamingService.node_capabilities(:"pup_w3@host3") == caps

      assert :ok = NamingService.unregister_node(:"pup_w3@host3")

      assert NamingService.node_capabilities(:"pup_w3@host3") == nil
    end

    test "is idempotent — no error for unknown node" do
      assert :ok = NamingService.unregister_node(:"nonexistent@nowhere")
    end
  end

  # ── find_nodes/1 ─────────────────────────────────────────────────────────

  describe "find_nodes/1" do
    test "returns correct nodes for a sub-agent type" do
      NamingService.register_capabilities(:"w1@h1", %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux"
      })

      NamingService.register_capabilities(:"w2@h2", %{
        sub_agents: [:terrier],
        host_os: "macos"
      })

      NamingService.register_capabilities(:"w3@h3", %{
        sub_agents: [:shepherd],
        host_os: "linux"
      })

      terrier_nodes = NamingService.find_nodes(:terrier)
      assert :"w1@h1" in terrier_nodes
      assert :"w2@h2" in terrier_nodes
      refute :"w3@h3" in terrier_nodes

      watchdog_nodes = NamingService.find_nodes(:watchdog)
      assert :"w1@h1" in watchdog_nodes
      refute :"w2@h2" in watchdog_nodes

      shepherd_nodes = NamingService.find_nodes(:shepherd)
      assert [:"w3@h3"] == shepherd_nodes
    end

    test "returns empty list for unknown sub-agent type" do
      NamingService.register_capabilities(:"w1@h1", %{sub_agents: [:terrier]})

      assert NamingService.find_nodes(:nonexistent_agent) == []
    end
  end

  # ── find_nodes/2 with constraints ───────────────────────────────────────

  describe "find_nodes/2 with constraints" do
    test "filters by single constraint" do
      NamingService.register_capabilities(:"w1@h1", %{
        sub_agents: [:terrier],
        host_os: "linux"
      })

      NamingService.register_capabilities(:"w2@h2", %{
        sub_agents: [:terrier],
        host_os: "macos"
      })

      linux_terriers = NamingService.find_nodes(:terrier, host_os: "linux")

      assert :"w1@h1" in linux_terriers
      refute :"w2@h2" in linux_terriers
    end

    test "filters by multiple constraints" do
      NamingService.register_capabilities(:"w1@h1", %{
        sub_agents: [:terrier],
        host_os: "linux",
        available_models: ["claude-sonnet-4-20250514", "gpt-4o"]
      })

      NamingService.register_capabilities(:"w2@h2", %{
        sub_agents: [:terrier],
        host_os: "linux",
        available_models: ["gpt-4o"]
      })

      result =
        NamingService.find_nodes(:terrier,
          host_os: "linux",
          available_models: "claude-sonnet-4-20250514"
        )

      assert :"w1@h1" in result
      refute :"w2@h2" in result
    end

    test "returns empty when no nodes match constraints" do
      NamingService.register_capabilities(:"w1@h1", %{
        sub_agents: [:terrier],
        host_os: "macos"
      })

      assert NamingService.find_nodes(:terrier, host_os: "windows") == []
    end

    test "accepts map constraints in addition to keyword list" do
      NamingService.register_capabilities(:"w1@h1", %{
        sub_agents: [:terrier],
        host_os: "linux"
      })

      result = NamingService.find_nodes(:terrier, %{host_os: "linux"})
      assert :"w1@h1" in result
    end
  end

  # ── all_capabilities/0 ──────────────────────────────────────────────────

  describe "all_capabilities/0" do
    test "returns full map of all registered capabilities" do
      caps1 = %{sub_agents: [:terrier], host_os: "linux"}
      caps2 = %{sub_agents: [:watchdog], host_os: "macos"}

      NamingService.register_capabilities(:"w1@h1", caps1)
      NamingService.register_capabilities(:"w2@h2", caps2)

      all = NamingService.all_capabilities()

      assert Map.get(all, :"w1@h1") == caps1
      assert Map.get(all, :"w2@h2") == caps2
    end

    test "returns empty map when no nodes registered" do
      assert NamingService.all_capabilities() == %{}
    end
  end

  # ── node_capabilities/1 ─────────────────────────────────────────────────

  describe "node_capabilities/1" do
    test "returns nil for unknown node" do
      assert NamingService.node_capabilities(:"nobody@nowhere") == nil
    end

    test "returns capabilities for known node" do
      caps = %{sub_agents: [:terrier], host_os: "linux"}
      NamingService.register_capabilities(:"w1@h1", caps)

      assert NamingService.node_capabilities(:"w1@h1") == caps
    end
  end

  # ── Concurrent Access ────────────────────────────────────────────────────

  describe "concurrent access" do
    test "handles multiple parallel register/unregister operations" do
      # Spin up many concurrent processes doing register/unregister
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            node_name = :"concurrent_#{i}@host"
            caps = %{sub_agents: [:terrier], host_os: "linux", idx: i}

            NamingService.register_capabilities(node_name, caps)

            # Verify we can read it back
            result = NamingService.node_capabilities(node_name)
            assert result.sub_agents == [:terrier]

            NamingService.unregister_node(node_name)

            # Should be gone
            assert NamingService.node_capabilities(node_name) == nil

            :ok
          end)
        end

      # All tasks should succeed without crashing ETS
      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, fn
        :ok -> true
        _ -> false
      end)
    end
  end
end
