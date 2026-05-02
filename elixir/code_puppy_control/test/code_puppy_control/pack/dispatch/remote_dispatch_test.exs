defmodule CodePuppyControl.Pack.Dispatch.RemoteDispatchTest do
  @moduledoc """
  Tests for RemoteDispatch — dispatching agent invocations to remote workers.

  Uses mock proxy opts (monitor_fn, handshake_fn, name) so tests run
  without a real remote Erlang node or distribution layer. All tests
  use async: false because they share the DistributedSupervisor and
  NamingService processes started by the application tree.

  Tagged with `@moduletag :distributed` — these tests verify distributed
  dispatch logic but do NOT require actual Erlang distribution.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.Dispatch.RemoteDispatch
  alias CodePuppyControl.Pack.DistributedSupervisor
  alias CodePuppyControl.Pack.NamingService

  @moduletag :distributed

  @test_node :pup_rd_test_worker@localhost
  @ds_name :test_rd_distributed_supervisor

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Mock proxy opts — avoid Node.monitor/2 (crashes without distribution)
  # and GenServer.call to a non-existent remote node during handshake.
  # The handshake_fn returns {:ok, caps} so the proxy transitions to
  # :connected after init (handle_continue :handshake).
  defp mock_proxy_opts do
    [
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout ->
        {:ok, %{sub_agents: [:terrier, :watchdog], host_os: "linux"}}
      end,
      name: nil
    ]
  end

  # Shared opts that point to the test-named DistributedSupervisor.
  defp supervisor_opts do
    [supervisor_name: @ds_name]
  end

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    # Start a fresh DistributedSupervisor for test isolation.
    start_supervised!({DistributedSupervisor, name: @ds_name})

    # Ensure NamingService GenServer is available (singleton).
    # If the app tree started it, just clear; otherwise start it.
    if Process.whereis(NamingService) do
      NamingService.clear()
    else
      {:ok, _pid} = NamingService.start_link([])
    end

    on_exit(fn ->
      if Process.whereis(NamingService) do
        NamingService.clear()
      end
    end)

    %{ds_name: @ds_name}
  end

  # ── node_available?/1 ────────────────────────────────────────────────────

  describe "node_available?/1" do
    test "returns false when no nodes are connected" do
      assert RemoteDispatch.node_available?(@test_node, supervisor_opts()) == false
    end

    test "returns true when the node is tracked by DistributedSupervisor" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      assert RemoteDispatch.node_available?(@test_node, supervisor_opts()) == true
    end

    test "returns false for unknown node even when other nodes are connected" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      assert RemoteDispatch.node_available?(:unknown_node@nowhere, supervisor_opts()) == false
    end
  end

  # ── dispatch_to_node/3 ──────────────────────────────────────────────────

  describe "dispatch_to_node/3" do
    test "returns error when node is not connected" do
      result =
        RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"},
          node: @test_node,
          supervisor_name: @ds_name
        )

      assert {:error, {:node_not_available, @test_node}} = result
    end

    test "returns error when node option is missing" do
      result =
        RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"}, [])

      assert {:error, {:invalid_node, nil}} = result
    end

    test "returns error when node option is not an atom" do
      result =
        RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"}, node: "not_an_atom")

      assert {:error, {:invalid_node, "not_an_atom"}} = result
    end

    test "returns ok with run_id when dispatching to a connected node" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      result =
        RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"},
          node: @test_node,
          run_id: "test-run-123",
          supervisor_name: @ds_name
        )

      assert {:ok, "test-run-123"} = result
    end

    test "uses caller-provided run_id when present" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      result =
        RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"},
          node: @test_node,
          run_id: "my-custom-run-id",
          supervisor_name: @ds_name
        )

      assert {:ok, "my-custom-run-id"} = result
    end

    test "generates run_id automatically when not provided" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      result =
        RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"},
          node: @test_node,
          supervisor_name: @ds_name
        )

      assert {:ok, run_id} = result
      assert String.starts_with?(run_id, "terrier-")
      # The suffix is Base.url_encode64 of 8 random bytes (11 chars, no padding)
      assert byte_size(run_id) > 8
    end
  end

  # ── dispatch_auto/3 ─────────────────────────────────────────────────────

  describe "dispatch_auto/3" do
    test "falls back to {:ok, :local} when no remote workers available" do
      result =
        RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
          supervisor_name: @ds_name
        )

      assert result == {:ok, :local}
    end

    test "dispatches to remote worker when available" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      result =
        RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
          supervisor_name: @ds_name
        )

      assert {:ok, {:remote, @test_node, run_id}} = result
      assert String.starts_with?(run_id, "terrier-")
    end

    test "uses NamingService for node selection when index has entries" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      # Register the node with NamingService so it's discoverable
      :ok =
        NamingService.register_node(@test_node, %{
          sub_agents: [:terrier],
          host_os: "linux"
        })

      result =
        RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
          supervisor_name: @ds_name
        )

      assert {:ok, {:remote, @test_node, _run_id}} = result
    end

    test "dispatch_auto returns {:ok, :local} when NamingService is not running" do
      # NamingService may not be running in test env
      result =
        RemoteDispatch.dispatch_auto(:terrier, %{task: "test"},
          supervisor_name: :nonexistent_supervisor
        )

      assert result == {:ok, :local}
    end

    test "falls back to local when NamingService has entries but no nodes connected" do
      # Register a node with NamingService but don't add it to DistributedSupervisor.
      # The naming service knows about it but it's not actually connected.
      :ok =
        NamingService.register_node(:nonexistent_node@host, %{
          sub_agents: [:terrier],
          host_os: "linux"
        })

      result =
        RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
          run_id: "auto-test-id",
          supervisor_name: @ds_name
        )

      assert result == {:ok, :local}
    end

    test "generates run_id with sub_agent prefix" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      result =
        RemoteDispatch.dispatch_auto(:watchdog, %{worktree_path: "../wt"},
          supervisor_name: @ds_name
        )

      assert {:ok, {:remote, _node, run_id}} = result
      assert String.starts_with?(run_id, "watchdog-")
    end
  end

  # ── run_id generation ───────────────────────────────────────────────────

  describe "run_id generation" do
    test "generated run_ids are unique across calls" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      results =
        for _ <- 1..10 do
          RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"},
            node: @test_node,
            supervisor_name: @ds_name
          )
        end

      run_ids = Enum.map(results, fn {:ok, id} -> id end)
      assert length(Enum.uniq(run_ids)) == 10
    end

    test "explicit run_id is used as-is" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      result =
        RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"},
          node: @test_node,
          run_id: "explicit-id-42",
          supervisor_name: @ds_name
        )

      assert {:ok, "explicit-id-42"} = result
    end
  end

  # ── telemetry ────────────────────────────────────────────────────────────

  describe "telemetry" do
    test "emits :start telemetry on successful dispatch_to_node" do
      {:ok, _pid} =
        DistributedSupervisor.add_node(@test_node,
          supervisor_name: @ds_name,
          proxy_opts: mock_proxy_opts()
        )

      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :distributed_pack, :remote_dispatch, :start],
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_start, measurements, metadata})
        end,
        self()
      )

      RemoteDispatch.dispatch_to_node(:terrier, %{worktree_path: "../wt"},
        node: @test_node,
        run_id: "telemetry-test",
        supervisor_name: @ds_name
      )

      assert_received {:telemetry_start, measurements, metadata}
      assert measurements.run_id == "telemetry-test"
      assert metadata.node == @test_node
      assert metadata.sub_agent == :terrier
      assert metadata.mode == :explicit

      :telemetry.detach(handler_id)
    end

    test "emits :fallback telemetry when dispatch_auto has no remote workers" do
      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :distributed_pack, :remote_dispatch, :fallback],
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_fallback, measurements, metadata})
        end,
        self()
      )

      RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
        run_id: "fallback-test",
        supervisor_name: @ds_name
      )

      assert_received {:telemetry_fallback, measurements, metadata}
      assert measurements.run_id == "fallback-test"
      assert metadata.sub_agent == :terrier
      assert metadata.reason == :no_remote_workers

      :telemetry.detach(handler_id)
    end
  end

  # ── Failover helpers ─────────────────────────────────────────────────────

  # Get the proxy PID from a RemoteNodeSupervisor PID by querying its children.
  defp get_proxy_pid(sup_pid) do
    [{:remote_node_proxy, proxy_pid, :worker, _}] = Supervisor.which_children(sup_pid)
    proxy_pid
  end

  # Transition a proxy to :disconnected by sending a :nodedown message.
  # Uses RemoteNodeProxy.status/1 as a synchronization barrier to ensure
  # the handle_info has completed before we return.
  defp disconnect_proxy!(sup_pid, node_name) do
    proxy_pid = get_proxy_pid(sup_pid)
    send(proxy_pid, {:nodedown, node_name})
    # GenServer.call synchronizes — guarantees nodedown was processed
    status = CodePuppyControl.Pack.RemoteNodeProxy.status(proxy_pid)
    assert status.status == :disconnected
    proxy_pid
  end

  # Sets up a node that is connected, registered in NamingService, then
  # disconnected (but still supervised + re-registered in NamingService).
  # This creates the TOCTOU scenario: the node is findable but dispatch fails.
  defp setup_disconnected_node(opts \\ []) do
    sub_agents = Keyword.get(opts, :sub_agents, [:terrier])

    {:ok, sup_pid} =
      DistributedSupervisor.add_node(@test_node,
        supervisor_name: @ds_name,
        proxy_opts: mock_proxy_opts()
      )

    :ok =
      NamingService.register_node(@test_node, %{
        sub_agents: sub_agents,
        host_os: "linux"
      })

    # Disconnect the proxy — simulates a nodedown event
    _proxy_pid = disconnect_proxy!(sup_pid, @test_node)

    # Re-register in NamingService after the nodedown unregistered it.
    # This is the key: the node is findable via NamingService and
    # DistributedSupervisor, but the proxy will reject dispatch.
    :ok =
      NamingService.register_node(@test_node, %{
        sub_agents: sub_agents,
        host_os: "linux"
      })

    sup_pid
  end

  # ── dispatch_auto/3 failover ─────────────────────────────────────────────

  describe "dispatch_auto/3 failover" do
    test "falls back to local when selected remote node is disconnected" do
      setup_disconnected_node()

      result =
        RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
          supervisor_name: @ds_name
        )

      assert result == {:ok, :local}
    end

    test "returns error when fallback: :none and remote node fails" do
      setup_disconnected_node()

      result =
        RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
          supervisor_name: @ds_name,
          fallback: :none
        )

      assert {:error, {:remote_dispatch_failed, @test_node, :nodedown}} = result
    end

    test "default fallback is :local" do
      setup_disconnected_node()

      # No :fallback option — should default to :local
      result =
        RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
          supervisor_name: @ds_name
        )

      # Must not return an error — default is always safe local fallback
      assert {:ok, :local} = result
    end

    test "emits [:code_puppy, :pack, :dispatch, :failover] telemetry on failover" do
      setup_disconnected_node()

      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :pack, :dispatch, :failover],
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_failover, measurements, metadata})
        end,
        self()
      )

      RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
        run_id: "failover-telemetry-test",
        supervisor_name: @ds_name
      )

      assert_received {:telemetry_failover, measurements, metadata}
      assert measurements.run_id == "failover-telemetry-test"
      assert is_integer(measurements.system_time)
      assert metadata.original_node == @test_node
      assert metadata.sub_agent == :terrier
      assert metadata.reason == :nodedown
      assert metadata.fallback == :local

      :telemetry.detach(handler_id)
    end

    test "does not emit failover telemetry when fallback is :none" do
      setup_disconnected_node()

      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :pack, :dispatch, :failover],
        fn _name, measurements, metadata, acc ->
          send(acc, {:telemetry_failover, measurements, metadata})
        end,
        self()
      )

      RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
        supervisor_name: @ds_name,
        fallback: :none
      )

      refute_received {:telemetry_failover, _, _}

      :telemetry.detach(handler_id)
    end

    test "still falls back to local normally when no remote workers exist" do
      # This tests backward compat: when no nodes are registered at all,
      # the existing :no_remote_workers path still works (NOT failover).
      result =
        RemoteDispatch.dispatch_auto(:terrier, %{worktree_path: "../wt"},
          supervisor_name: @ds_name
        )

      assert result == {:ok, :local}
    end
  end

  # ── classify_failure/1 ───────────────────────────────────────────────────

  describe "classify_failure/1" do
    test "classifies node-unavailability errors as :nodedown" do
      assert RemoteDispatch.classify_failure({:node_not_available, :n@h}) == :nodedown
      assert RemoteDispatch.classify_failure({:node_not_connected, :n@h}) == :nodedown
      assert RemoteDispatch.classify_failure({:node_disconnected, :n@h}) == :nodedown
      assert RemoteDispatch.classify_failure({:node_not_ready, :n@h}) == :nodedown
    end

    test "classifies timeout errors as :timeout" do
      assert RemoteDispatch.classify_failure(:timeout) == :timeout
      assert RemoteDispatch.classify_failure({:timeout, make_ref()}) == :timeout
    end

    test "classifies dispatch crashes as :error" do
      assert RemoteDispatch.classify_failure({:dispatch_crashed, "kaboom"}) == :error
    end

    test "classifies unknown errors as :error" do
      assert RemoteDispatch.classify_failure(:something_unexpected) == :error
      assert RemoteDispatch.classify_failure({:unknown, :stuff}) == :error
      assert RemoteDispatch.classify_failure("a string error") == :error
    end
  end
end
