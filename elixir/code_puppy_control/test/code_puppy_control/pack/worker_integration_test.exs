defmodule CodePuppyControl.Pack.WorkerIntegrationTest do
  @moduledoc """
  Integration tests for the distributed pack worker lifecycle.

  Tests the full flow: worker startup → capability registration →
  leader handshake → dispatch → result reporting.

  Uses local processes (no real Erlang distribution) with injected
  mock functions for node connectivity. This is a **simulated**
  integration test — NOT real distributed Erlang (too heavy for CI).

  ## Tagging

  Tagged with `@moduletag :integration` and `@moduletag :distributed`.
  Run via:

      mix test --only integration --only distributed
  """

  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :distributed

  alias CodePuppyControl.Pack.Worker
  alias CodePuppyControl.Pack.NamingService
  alias CodePuppyControl.Pack.Worker.Application, as: WorkerApp

  # Unique names to avoid cross-test collisions
  @worker_lifecycle :test_int_lifecycle_worker
  @worker_dispatch :test_int_dispatch_worker
  @worker_dup :test_int_dup_worker
  @worker_malformed :test_int_malformed_worker
  @worker_concurrency :test_int_concurrency_worker
  @test_node :test_int_worker@localhost

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    ensure_naming_service_started()

    on_exit(fn ->
      for name <- [
            @worker_lifecycle,
            @worker_dispatch,
            @worker_dup,
            @worker_malformed,
            @worker_concurrency
          ] do
        safe_stop(name)
      end

      safe_unregister(@test_node)
    end)

    :ok
  end

  # ── 1. Full Lifecycle: Start → Register → Handshake → Dispatch → Result ─

  describe "full worker lifecycle" do
    test "worker starts, advertises capabilities, accepts handshake, processes dispatch, reports result" do
      test_pid = self()

      # Step 1: Start worker
      {:ok, worker_pid} =
        Worker.start_link(
          name: @worker_lifecycle,
          host_os: :linux,
          max_concurrent_runs: 3,
          available_models: ["claude-sonnet-4-20250514"]
        )

      assert Process.alive?(worker_pid)

      # Step 2: Leader performs capability handshake
      caps = GenServer.call(@worker_lifecycle, :request_capabilities)

      assert is_map(caps)
      assert caps.max_concurrent_runs == 3
      assert caps.host_os == :linux
      assert "claude-sonnet-4-20250514" in caps.available_models
      assert :terrier in caps.sub_agents

      # Step 3: Leader registers worker capabilities in NamingService
      :ok =
        NamingService.register_node(@test_node, %{
          sub_agents: caps.sub_agents,
          host_os: Atom.to_string(caps.host_os),
          max_concurrent_runs: caps.max_concurrent_runs,
          available_models: caps.available_models
        })

      # Verify NamingService can find the worker
      nodes = NamingService.find_nodes(:terrier)
      assert @test_node in nodes

      stored = NamingService.node_capabilities(@test_node)
      assert stored.max_concurrent_runs == 3

      # Step 4: Leader health-checks worker
      assert :pong == GenServer.call(@worker_lifecycle, :ping)

      # Step 5: Leader dispatches work to worker
      dispatch_msg = %{
        run_id: "lifecycle-run-001",
        sub_agent: :terrier,
        params: %{task_description: "integration test task"},
        leader_node: Node.self(),
        leader_pid: test_pid
      }

      GenServer.cast(@worker_lifecycle, {:dispatch, dispatch_msg})
      _ = :sys.get_state(worker_pid)

      # Step 6: Simulate run completion — worker reports result to leader
      send(worker_pid, {:run_completed, "lifecycle-run-001", %{status: :success, output: "done"}})
      _ = :sys.get_state(worker_pid)

      assert_receive {:"$gen_cast", {:result, "lifecycle-run-001", result}}, 500
      assert result.status == :success
      assert result.output == "done"

      # Step 7: Leader unregisters worker on disconnect
      :ok = NamingService.unregister_node(@test_node)
      assert nil == NamingService.node_capabilities(@test_node)
    end

    test "worker stays alive after dispatch even without sub-agent infrastructure" do
      test_pid = self()

      {:ok, worker_pid} =
        Worker.start_link(
          name: @worker_dispatch,
          host_os: :macos,
          max_concurrent_runs: 2
        )

      dispatch_msg = %{
        run_id: "orphan-run-001",
        sub_agent: :watchdog,
        params: %{task_description: "test task"},
        leader_node: Node.self(),
        leader_pid: test_pid
      }

      GenServer.cast(@worker_dispatch, {:dispatch, dispatch_msg})

      # Worker should accept dispatch and stay alive even though no real
      # sub-agent infrastructure is running to complete the run
      _ = :sys.get_state(worker_pid)
      assert Process.alive?(worker_pid)
      assert :pong == GenServer.call(@worker_dispatch, :ping)
    end
  end

  # ── 2. Dispatch Guard: Duplicate run_id ──────────────────────────────────

  describe "duplicate run_id rejection" do
    test "worker rejects dispatch with duplicate run_id and notifies leader" do
      test_pid = self()

      {:ok, worker_pid} =
        Worker.start_link(
          name: @worker_dup,
          host_os: :linux,
          max_concurrent_runs: 5
        )

      base_dispatch = %{
        run_id: "dup-run-001",
        sub_agent: :terrier,
        params: %{task_description: "first dispatch"},
        leader_node: Node.self(),
        leader_pid: test_pid
      }

      # First dispatch — should succeed (no rejection message)
      GenServer.cast(@worker_dup, {:dispatch, base_dispatch})
      _ = :sys.get_state(worker_pid)

      refute_receive {:"$gen_cast", {:result, "dup-run-001", _}}, 100

      # Second dispatch with same run_id — should be rejected
      GenServer.cast(@worker_dup, {:dispatch, %{base_dispatch | params: %{task_description: "dupe"}}})
      _ = :sys.get_state(worker_pid)

      assert_receive {:"$gen_cast", {:result, "dup-run-001", result}}, 500
      assert result.status == :failure
      assert String.contains?(result.error, "duplicate_run_id")

      # Worker must survive the rejection
      assert Process.alive?(worker_pid)
      assert :pong == GenServer.call(@worker_dup, :ping)
    end
  end

  # ── 3. Dispatch Guard: Malformed Messages ────────────────────────────────

  describe "malformed dispatch rejection" do
    test "worker rejects dispatch missing required fields and notifies leader" do
      test_pid = self()

      {:ok, worker_pid} =
        Worker.start_link(
          name: @worker_malformed,
          host_os: :linux,
          max_concurrent_runs: 5
        )

      # Missing run_id
      malformed = %{
        sub_agent: :terrier,
        params: %{task_description: "test"},
        leader_node: Node.self(),
        leader_pid: test_pid
      }

      GenServer.cast(@worker_malformed, {:dispatch, malformed})
      _ = :sys.get_state(worker_pid)

      assert_receive {:"$gen_cast", {:result, "unknown", result}}, 500
      assert result.status == :failure
      assert String.contains?(result.error, "malformed_dispatch")

      # Worker must survive
      assert Process.alive?(worker_pid)
      assert :pong == GenServer.call(@worker_malformed, :ping)
    end

    test "worker handles non-map dispatch without crashing" do
      {:ok, worker_pid} =
        Worker.start_link(
          name: @worker_malformed,
          host_os: :linux
        )

      GenServer.cast(@worker_malformed, {:dispatch, "not a map at all"})
      _ = :sys.get_state(worker_pid)

      assert Process.alive?(worker_pid)
      assert :pong == GenServer.call(@worker_malformed, :ping)
    end
  end

  # ── 4. Dispatch Guard: Concurrency Limit ─────────────────────────────────

  describe "concurrency limit enforcement" do
    test "worker rejects dispatch when max concurrent runs exceeded" do
      test_pid = self()

      {:ok, worker_pid} =
        Worker.start_link(
          name: @worker_concurrency,
          host_os: :linux,
          max_concurrent_runs: 1
        )

      # Fill the single slot
      first = dispatch_msg("concurrency-run-001", :terrier, test_pid)
      GenServer.cast(@worker_concurrency, {:dispatch, first})
      _ = :sys.get_state(worker_pid)

      # Second dispatch should be rejected
      second = dispatch_msg("concurrency-run-002", :terrier, test_pid)
      GenServer.cast(@worker_concurrency, {:dispatch, second})
      _ = :sys.get_state(worker_pid)

      assert_receive {:"$gen_cast", {:result, "concurrency-run-002", result}}, 500
      assert result.status == :failure
      assert String.contains?(result.error, "max_concurrent_runs_exceeded")

      # Complete the first run — slot freed
      send(worker_pid, {:run_completed, "concurrency-run-001", %{status: :success, output: "ok"}})
      _ = :sys.get_state(worker_pid)

      # Now a third dispatch should succeed
      third = dispatch_msg("concurrency-run-003", :terrier, test_pid)
      GenServer.cast(@worker_concurrency, {:dispatch, third})
      _ = :sys.get_state(worker_pid)

      refute_receive {:"$gen_cast", {:result, "concurrency-run-003", _}}, 100

      assert Process.alive?(worker_pid)
    end
  end

  # ── 5. Worker.Application Child Specs ────────────────────────────────────

  describe "Worker.Application children/1" do
    test "produces valid child specs for a configured leader" do
      children = WorkerApp.children(leader: :test_leader@localhost)

      assert is_list(children)
      assert length(children) >= 8

      for child <- children do
        assert valid_child_spec?(child),
               "Invalid child spec shape: #{inspect(child)}"
      end
    end

    test "includes both Worker and NamingService in the tree" do
      children = WorkerApp.children(leader: :test_leader@localhost)
      child_ids = Enum.map(children, &extract_child_id/1)

      assert Worker in child_ids,
             "Expected Pack.Worker in children: #{inspect(child_ids)}"

      assert NamingService in child_ids,
             "Expected NamingService in children: #{inspect(child_ids)}"
    end

    test "worker child spec uses :pack_worker as registered name" do
      children = WorkerApp.children(leader: :test_leader@localhost)

      worker_spec =
        Enum.find(children, fn
          {Worker, _opts} -> true
          _ -> false
        end)

      assert worker_spec, "Pack.Worker child spec not found"

      {_mod, opts} = worker_spec
      assert opts[:name] == :pack_worker
    end
  end

  # ── 6. NamingService Round-Trip ──────────────────────────────────────────

  describe "NamingService register → query → unregister" do
    test "registers worker capabilities and queries by agent type" do
      caps = %{
        sub_agents: [:terrier, :watchdog],
        host_os: "linux",
        max_concurrent_runs: 4,
        available_models: ["claude-sonnet-4-20250514"]
      }

      :ok = NamingService.register_node(@test_node, caps)

      # Query by agent type
      terrier_nodes = NamingService.find_nodes(:terrier)
      assert @test_node in terrier_nodes

      watchdog_nodes = NamingService.find_nodes(:watchdog)
      assert @test_node in watchdog_nodes

      # Agent type the worker doesn't support
      shepherd_nodes = NamingService.find_nodes(:shepherd)
      refute @test_node in shepherd_nodes

      # Query stored capabilities
      stored = NamingService.node_capabilities(@test_node)
      assert stored.max_concurrent_runs == 4
      assert stored[:available_models] == ["claude-sonnet-4-20250514"]

      # Cleanup — unregister and verify gone
      :ok = NamingService.unregister_node(@test_node)
      assert nil == NamingService.node_capabilities(@test_node)
      assert @test_node not in NamingService.find_nodes(:terrier)
    end

    test "find_nodes filters by host_os" do
      :ok =
        NamingService.register_node(@test_node, %{
          sub_agents: [:terrier],
          host_os: "linux",
          max_concurrent_runs: 2
        })

      assert @test_node in NamingService.find_nodes(:terrier, %{host_os: "linux"})
      refute @test_node in NamingService.find_nodes(:terrier, %{host_os: "macos"})
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp dispatch_msg(run_id, sub_agent, leader_pid) do
    %{
      run_id: run_id,
      sub_agent: sub_agent,
      params: %{task_description: "test task"},
      leader_node: Node.self(),
      leader_pid: leader_pid
    }
  end

  defp ensure_naming_service_started do
    if Process.whereis(NamingService) do
      NamingService.clear()
    else
      {:ok, _pid} = NamingService.start_link([])
    end
  end

  defp safe_stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1_000)
    end
  catch
    :exit, _ -> :ok
  end

  defp safe_unregister(node_name) do
    if Process.whereis(NamingService) do
      NamingService.unregister_node(node_name)
    end
  catch
    :exit, _ -> :ok
  end

  defp valid_child_spec?({mod, _opts}) when is_atom(mod), do: true
  defp valid_child_spec?(mod) when is_atom(mod), do: true
  defp valid_child_spec?(%{id: _}), do: true
  defp valid_child_spec?(_), do: false

  defp extract_child_id(%{id: id}), do: id
  defp extract_child_id({mod, _opts}) when is_atom(mod), do: mod
  defp extract_child_id(mod) when is_atom(mod), do: mod

  defp extract_child_id(other) do
    try do
      spec = Supervisor.child_spec(other, [])
      spec.id
    rescue
      _ -> other
    end
  end
end
