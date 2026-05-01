defmodule CodePuppyControl.Pack.NamingServiceTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias CodePuppyControl.Pack.NamingService

  setup do
    # Ensure the NamingService GenServer is started (it's a singleton named
    # __MODULE__, so only one exists per test session). Reset the ETS table
    # state between tests for isolation via the GenServer (the ETS table is
    # :protected, so only the owning process can write).
    if Process.whereis(NamingService) do
      NamingService.clear()
    else
      {:ok, _pid} = NamingService.start_link([])
    end

    :ok
  end

  # ── register_node/2 ────────────────────────────────────────────────

  describe "register_node/2" do
    test "registers a node with basic capabilities" do
      node = :pup_worker@test

      capabilities = %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 4
      }

      assert :ok = NamingService.register_node(node, capabilities)

      # Node should appear in list
      assert node in NamingService.list_nodes()

      # Capabilities should be retrievable
      caps = NamingService.node_capabilities(node)
      assert caps[:sub_agents] == [:terrier, :watchdog]
      assert caps[:host_os] == "linux"
      assert caps[:max_concurrent_runs] == 4
    end

    test "registers a node with full capabilities including models" do
      node = :"pup_builder@build-01"

      capabilities = %{
        sub_agents: [:retriever, :shepherd, :terrier, :watchdog],
        host_os: "macos",
        max_concurrent_runs: 8,
        available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"],
        features: %{file_ops: true, shell_access: true}
      }

      assert :ok = NamingService.register_node(node, capabilities)
      assert node in NamingService.list_nodes()

      caps = NamingService.node_capabilities(node)
      assert caps[:available_models] == ["claude-sonnet-4-20250514", "claude-haiku-3-5"]
      assert caps[:max_concurrent_runs] == 8
    end

    test "updates existing node capabilities and replaces index entries" do
      node = :pup_worker@host

      # Register with terrier capability
      NamingService.register_node(node, %{
        sub_agents: [:terrier],
        host_os: "linux"
      })

      assert [node] == NamingService.find_nodes(:terrier, %{host_os: "linux"})

      # Update — now only watchdog on macos
      NamingService.register_node(node, %{
        sub_agents: [:watchdog],
        host_os: "macos"
      })

      # Should NOT find it as a terrier on linux anymore
      assert [] == NamingService.find_nodes(:terrier, %{host_os: "linux"})

      # Should find it as a watchdog on macos
      assert [node] == NamingService.find_nodes(:watchdog, %{host_os: "macos"})
    end

    test "returns error for invalid host_os" do
      node = :bad_os_node@test

      assert {:error, :invalid_capabilities} =
               NamingService.register_node(node, %{
                 sub_agents: [:terrier],
                 host_os: "nonexistent_os"
               })

      # Node should NOT be registered
      assert nil == NamingService.node_capabilities(node)
      refute node in NamingService.list_nodes()
    end

    test "returns error for invalid sub_agent type" do
      node = :bad_agent_node@test

      assert {:error, :invalid_capabilities} =
               NamingService.register_node(node, %{
                 sub_agents: [:invalid_agent_type],
                 host_os: "linux"
               })

      # Node should NOT be registered
      assert nil == NamingService.node_capabilities(node)
      refute node in NamingService.list_nodes()
    end

    test "returns error when sub_agents contain a mix of valid and invalid types" do
      node = :mixed_agents_node@test

      assert {:error, :invalid_capabilities} =
               NamingService.register_node(node, %{
                 sub_agents: [:terrier, :invalid_extra],
                 host_os: "linux"
               })

      # Node should NOT be registered — all-or-nothing validation
      assert nil == NamingService.node_capabilities(node)
      refute node in NamingService.list_nodes()
    end

    test "converts string sub_agent types from JSON to atoms via allowlist" do
      node = :json_string_agents@test

      assert :ok =
               NamingService.register_node(node, %{
                 sub_agents: ["terrier", "watchdog"],
                 host_os: "linux"
               })

      caps = NamingService.node_capabilities(node)
      assert caps[:sub_agents] == [:terrier, :watchdog]

      # Should be findable via atom-based lookup
      assert [node] == NamingService.find_nodes(:terrier, %{host_os: "linux"})
    end

    test "accepts darwin as an alias for macos" do
      node = :darwin_aliased@test

      assert :ok =
               NamingService.register_node(node, %{
                 sub_agents: [:terrier],
                 host_os: "darwin"
               })

      # Should be findable via :macos lookup
      assert [node] == NamingService.find_nodes(:terrier, %{host_os: "macos"})
    end

    test "accepts unknown as a valid OS" do
      node = :unknown_os_node@test

      assert :ok =
               NamingService.register_node(node, %{
                 sub_agents: [:terrier],
                 host_os: "unknown"
               })

      assert node in NamingService.list_nodes()
    end
  end

  # ── unregister_node/1 ──────────────────────────────────────────────

  describe "unregister_node/1" do
    test "removes a node and cleans up its index entries" do
      node = :pup_worker@test

      capabilities = %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux"
      }

      NamingService.register_node(node, capabilities)
      assert node in NamingService.list_nodes()

      # Before unregister, it should be findable
      assert [node] == NamingService.find_nodes(:terrier, %{host_os: "linux"})

      # Unregister
      assert :ok = NamingService.unregister_node(node)

      # Node should be gone
      refute node in NamingService.list_nodes()
      assert nil == NamingService.node_capabilities(node)

      # Index entries should be cleaned up
      assert [] == NamingService.find_nodes(:terrier, %{host_os: "linux"})
      assert [] == NamingService.find_nodes(:watchdog, %{host_os: "linux"})
    end

    test "unregistering a non-existent node is a no-op" do
      assert :ok = NamingService.unregister_node(:nonexistent@host)
    end

    test "removing one node doesn't affect index entries for other nodes" do
      node_a = :pup_worker_a@test
      node_b = :pup_worker_b@test

      NamingService.register_node(node_a, %{
        sub_agents: [:terrier],
        host_os: "linux"
      })

      NamingService.register_node(node_b, %{
        sub_agents: [:terrier],
        host_os: "linux"
      })

      # Both should be findable
      nodes = NamingService.find_nodes(:terrier, %{host_os: "linux"})
      assert node_a in nodes
      assert node_b in nodes

      # Remove node_a
      NamingService.unregister_node(node_a)

      # node_b should still be findable
      assert [node_b] == NamingService.find_nodes(:terrier, %{host_os: "linux"})
    end
  end

  # ── find_nodes/2 ───────────────────────────────────────────────────

  describe "find_nodes/2" do
    setup :register_test_nodes

    test "finds nodes by agent type only" do
      nodes = NamingService.find_nodes(:terrier)
      assert length(nodes) == 3
    end

    test "finds nodes filtered by host_os" do
      linux_nodes = NamingService.find_nodes(:terrier, %{host_os: "linux"})
      assert length(linux_nodes) == 2

      mac_nodes = NamingService.find_nodes(:terrier, %{host_os: "macos"})
      assert length(mac_nodes) == 1
    end

    test "finds nodes filtered by model availability" do
      nodes_with_haiku =
        NamingService.find_nodes(:terrier, %{model: "claude-haiku-3-5"})

      # Only pup_builder has haiku
      assert nodes_with_haiku == [:"pup_builder@build-01"]
    end

    test "finds nodes filtered by both host_os and model" do
      nodes =
        NamingService.find_nodes(:watchdog, %{
          host_os: "linux",
          model: "claude-sonnet-4-20250514"
        })

      # pup_worker_b runs watchdog on linux with sonnet
      assert nodes == [:pup_worker_b@dev]
    end

    test "returns empty list for non-existent agent type" do
      assert [] == NamingService.find_nodes(:nonexistent_agent)
    end

    test "returns empty list when no nodes match filters" do
      assert [] == NamingService.find_nodes(:terrier, %{host_os: "windows"})
    end

    test "returns empty list for unrecognized OS string filter" do
      assert [] == NamingService.find_nodes(:terrier, %{host_os: "bogus_os"})
    end
  end

  # ── dump/0 ─────────────────────────────────────────────────────────

  describe "dump/0" do
    setup :register_test_nodes

    test "returns human-readable index" do
      result = NamingService.dump()

      assert is_map(result)
      assert is_map(result.index)

      expected_nodes = [
        :"pup_builder@build-01",
        :pup_worker_a@dev,
        :pup_worker_b@dev
      ]

      assert Enum.sort(result.nodes) == Enum.sort(expected_nodes)

      # Should have index entries for each sub_agent × host_os combo
      assert Map.has_key?(result.index, "terrier/linux")
      assert Map.has_key?(result.index, "watchdog/linux")
      assert Map.has_key?(result.index, "shepherd/macos")
    end
  end

  # ── node_capabilities/1 ────────────────────────────────────────────

  describe "node_capabilities/1" do
    setup :register_test_nodes

    test "returns capabilities for a registered node" do
      caps = NamingService.node_capabilities(:"pup_builder@build-01")
      assert caps[:host_os] == "macos"
      assert :terrier in caps[:sub_agents]
    end

    test "returns nil for unregistered node" do
      assert nil == NamingService.node_capabilities(:unknown@host)
    end
  end

  # ── list_nodes/0 ───────────────────────────────────────────────────

  describe "list_nodes/0" do
    test "returns empty list when no nodes registered" do
      assert NamingService.list_nodes() == []
    end

    test "lists all registered nodes" do
      NamingService.register_node(:alpha@host, %{sub_agents: [:terrier], host_os: "linux"})
      NamingService.register_node(:beta@host, %{sub_agents: [:watchdog], host_os: "macos"})

      nodes = NamingService.list_nodes()
      assert length(nodes) == 2
      assert :alpha@host in nodes
      assert :beta@host in nodes
    end
  end

  # ── normalize_os/1 ─────────────────────────────────────────────────

  describe "normalize_os/1" do
    test "returns {:ok, atom} for known OS strings" do
      assert {:ok, :linux} = NamingService.normalize_os("linux")
      assert {:ok, :macos} = NamingService.normalize_os("macos")
      assert {:ok, :windows} = NamingService.normalize_os("windows")
      assert {:ok, :unknown} = NamingService.normalize_os("unknown")
    end

    test "maps darwin to macos" do
      assert {:ok, :macos} = NamingService.normalize_os("darwin")
    end

    test "handles case insensitivity" do
      assert {:ok, :linux} = NamingService.normalize_os("Linux")
      assert {:ok, :macos} = NamingService.normalize_os("Darwin")
      assert {:ok, :windows} = NamingService.normalize_os("WINDOWS")
    end

    test "handles whitespace" do
      assert {:ok, :linux} = NamingService.normalize_os("  linux  ")
    end

    test "accepts existing atoms" do
      assert {:ok, :linux} = NamingService.normalize_os(:linux)
      assert {:ok, :macos} = NamingService.normalize_os(:macos)
    end

    test "returns {:error, :invalid_os} for unknown strings" do
      assert {:error, :invalid_os} = NamingService.normalize_os("nonexistent_os")
    end

    test "returns {:error, :invalid_os} for unsupported atom" do
      assert {:error, :invalid_os} = NamingService.normalize_os(:bogus)
    end

    test "returns {:error, :invalid_os} for non-string non-atom" do
      assert {:error, :invalid_os} = NamingService.normalize_os(42)
      assert {:error, :invalid_os} = NamingService.normalize_os(nil)
    end
  end

  # ── Concurrent Access ──────────────────────────────────────────────

  describe "concurrent access" do
    test "handles concurrent registrations from multiple tasks" do
      nodes =
        Enum.map(1..20, fn i ->
          :"concurrent_#{i}@host"
        end)

      tasks =
        Enum.map(nodes, fn node ->
          Task.async(fn ->
            os = if Integer.mod(:erlang.phash2(node), 2) == 0, do: "linux", else: "macos"

            NamingService.register_node(node, %{
              sub_agents: [:terrier, :watchdog],
              host_os: os
            })
          end)
        end)

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))

      registered = NamingService.list_nodes()
      assert length(registered) == 20
    end

    test "handles concurrent register and unregister without crash" do
      node = :race_test@host

      NamingService.register_node(node, %{
        sub_agents: [:terrier],
        host_os: "linux"
      })

      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            if rem(i, 2) == 0 do
              NamingService.unregister_node(node)
            else
              NamingService.register_node(node, %{
                sub_agents: [:terrier],
                host_os: ~w(linux macos windows) |> Enum.at(rem(i, 3))
              })
            end
          end)
        end)

      _results = Task.await_many(tasks, 10_000)

      # Final state should be consistent — either registered or not.
      # No crash should have occurred.
      _ = NamingService.list_nodes()
      _ = NamingService.find_nodes(:terrier)
    end
  end

  # ── Capability Invariants ──────────────────────────────────────────

  describe "capability invariants" do
    setup :register_test_nodes

    test "find_nodes always returns subsets of registered nodes" do
      all_nodes = NamingService.list_nodes()

      agent_types = [:terrier, :watchdog, :shepherd, :retriever]
      host_oses = ["linux", "macos", "windows"]

      for agent_type <- agent_types, host_os <- host_oses do
        nodes = NamingService.find_nodes(agent_type, %{host_os: host_os})

        assert Enum.all?(nodes, &(&1 in all_nodes)),
               "Node in results for #{agent_type}/#{host_os} not in registered set"
      end
    end

    test "every registered node has valid capability structure" do
      Enum.each(NamingService.list_nodes(), fn node ->
        caps = NamingService.node_capabilities(node)
        assert is_map(caps), "Capabilities should be a map for #{inspect(node)}"
        assert Map.has_key?(caps, :sub_agents), "Missing sub_agents for #{inspect(node)}"
        assert is_list(caps[:sub_agents]), "sub_agents should be a list for #{inspect(node)}"
        assert Map.has_key?(caps, :host_os), "Missing host_os for #{inspect(node)}"
        assert is_binary(caps[:host_os]), "host_os should be a string for #{inspect(node)}"
      end)
    end

    test "every indexed node has a corresponding metadata entry" do
      result = NamingService.dump()

      all_indexed_nodes =
        result.index
        |> Map.values()
        |> List.flatten()
        |> Enum.uniq()

      Enum.each(all_indexed_nodes, fn node ->
        assert node in result.nodes,
               "Node #{inspect(node)} appears in index but has no metadata entry"
      end)
    end
  end

  # ── Property-based: Capability Advertisement Shapes ────────────────

  describe "property-based capability shapes" do
    property "advertised sub_agents always map to findable nodes" do
      import StreamData

      check all(
              node_name <- member_of([:worker_a@h, :worker_b@h, :worker_c@h]),
              sub_agents <-
                list_of(member_of([:terrier, :watchdog, :shepherd, :retriever]),
                  min_length: 1,
                  max_length: 4
                ),
              host_os <- member_of(["linux", "macos", "windows"]),
              max_runs <- integer(1..16),
              max_runs: 50
            ) do
        NamingService.register_node(node_name, %{
          sub_agents: sub_agents,
          host_os: host_os,
          max_concurrent_runs: max_runs
        })

        for agent <- sub_agents do
          found = NamingService.find_nodes(agent)

          assert node_name in found,
                 "#{node_name} advertises #{agent} but find_nodes(#{agent}) returned #{inspect(found)}"
        end

        NamingService.unregister_node(node_name)
      end
    end

    property "unregister always cleans up all index entries" do
      import StreamData

      check all(
              node_name <- member_of([:prop_worker@h]),
              sub_agents <-
                list_of(member_of([:terrier, :watchdog, :shepherd, :retriever]),
                  min_length: 1,
                  max_length: 4
                ),
              host_os <- member_of(["linux", "macos"]),
              max_runs: 50
            ) do
        NamingService.register_node(node_name, %{
          sub_agents: sub_agents,
          host_os: host_os
        })

        NamingService.unregister_node(node_name)

        for agent <- sub_agents do
          found = NamingService.find_nodes(agent)

          refute node_name in found,
                 "#{node_name} still found for #{agent} after unregister"
        end

        assert nil == NamingService.node_capabilities(node_name)
        refute node_name in NamingService.list_nodes()
      end
    end
  end

  # ── Test Helpers ───────────────────────────────────────────────────

  defp register_test_nodes(_context) do
    NamingService.register_node(:pup_worker_a@dev, %{
      sub_agents: [:terrier, :retriever],
      host_os: "linux",
      available_models: ["claude-sonnet-4-20250514"]
    })

    NamingService.register_node(:pup_worker_b@dev, %{
      sub_agents: [:terrier, :watchdog],
      host_os: "linux",
      available_models: ["claude-sonnet-4-20250514"]
    })

    NamingService.register_node(:"pup_builder@build-01", %{
      sub_agents: [:terrier, :watchdog, :shepherd],
      host_os: "macos",
      available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"],
      max_concurrent_runs: 8,
      features: %{file_ops: true, shell_access: true, docker_access: true}
    })

    :ok
  end
end
