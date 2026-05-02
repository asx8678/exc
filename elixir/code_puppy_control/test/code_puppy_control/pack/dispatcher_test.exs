defmodule CodePuppyControl.Pack.DispatcherTest do
  @moduledoc """
  Tests for Pack.Dispatcher — round-robin worker selection via NamingService.

  These tests start both NamingService and Dispatcher GenServers (not relying
  on the application supervision tree) and manage lifecycle via setup/teardown.

  Workers are registered via NamingService.register_node/2 — the Dispatcher
  queries NamingService at dispatch-time for capability-matching.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.{Dispatcher, NamingService}

  # ── Test Workers ─────────────────────────────────────────────────────────

  @linux_worker_a :disp_linux_a@test
  @linux_worker_b :disp_linux_b@test
  @macos_worker :disp_macos_c@test
  @win_worker :disp_win_d@test

  @linux_caps_terrier %{
    sub_agents: [:terrier, :retriever],
    host_os: "linux",
    max_concurrent_runs: 4,
    available_models: ["claude-sonnet-4-20250514"]
  }

  @linux_caps_watchdog %{
    sub_agents: [:terrier, :watchdog],
    host_os: "linux",
    max_concurrent_runs: 2,
    available_models: ["claude-sonnet-4-20250514", "claude-haiku-3-5"]
  }

  @macos_caps_shepherd %{
    sub_agents: [:shepherd, :retriever],
    host_os: "macos",
    max_concurrent_runs: 8,
    available_models: ["claude-sonnet-4-20250514"]
  }

  @win_caps_all %{
    sub_agents: [:terrier, :watchdog, :shepherd, :retriever],
    host_os: "windows",
    max_concurrent_runs: 2,
    available_models: ["claude-haiku-3-5"]
  }

  # ── Setup ────────────────────────────────────────────────────────────────

  setup do
    # If app already started NamingService/Dispatcher, just clear them.
    # If running with --no-start, start them manually.
    unless Process.whereis(NamingService) do
      start_supervised!({NamingService, []})
    end

    unless Process.whereis(Dispatcher) do
      start_supervised!({Dispatcher, []})
    end

    # Clear state for test isolation
    NamingService.clear()
    Dispatcher.clear()

    on_exit(fn ->
      # Detach any telemetry handlers left by tests
      for prefix <- [
            [:code_puppy, :distributed_pack, :dispatch],
            [:code_puppy, :pack, :dispatcher]
          ] do
        :telemetry.list_handlers(prefix)
        |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)
      end

      # Clear NamingService ETS table
      if Process.whereis(NamingService) != nil do
        NamingService.clear()
      end
    end)

    :ok
  end

  # ── Round-Robin Dispatch ─────────────────────────────────────────────────

  describe "dispatch/2 round-robin" do
    test "selects workers in order across sequential dispatches" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      # Both workers support :terrier
      {:ok, first} = Dispatcher.dispatch(:terrier)
      {:ok, second} = Dispatcher.dispatch(:terrier)
      {:ok, third} = Dispatcher.dispatch(:terrier)

      # First two should be different (A then B), third wraps to A
      assert first != second
      assert second != third
      assert third == first
    end

    test "round-robin wraps around correctly with many workers" do
      workers =
        Enum.map(1..5, fn i ->
          node = :"disp_rr_#{i}@test"

          assert :ok =
                   NamingService.register_node(node, %{
                     sub_agents: [:terrier],
                     host_os: "linux",
                     max_concurrent_runs: 4
                   })

          node
        end)

      # Dispatch 10 times and verify we see all workers in order
      results =
        Enum.map(1..10, fn _ ->
          {:ok, node} = Dispatcher.dispatch(:terrier)
          node
        end)

      # NamingService prepends workers to index lists (most recently registered first),
      # so the round-robin order is reverse registration order: w4, w3, w2, w1, w0, ...
      reversed_workers = Enum.reverse(workers)
      expected_cycle = reversed_workers ++ reversed_workers
      assert results == expected_cycle
    end

    test "round-robin hits all workers before repeating" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)
      assert :ok = NamingService.register_node(@macos_worker, @macos_caps_shepherd)

      # Only @linux_worker_a and @linux_worker_b support :terrier
      {:ok, first} = Dispatcher.dispatch(:terrier)
      {:ok, second} = Dispatcher.dispatch(:terrier)
      {:ok, third} = Dispatcher.dispatch(:terrier)

      # With 2 workers: must be alternating A, B, A
      assert first != second
      assert third == first
    end

    test "dispatch order is deterministic for the same set of workers" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      results1 = Enum.map(1..4, fn _ -> elem(Dispatcher.dispatch(:terrier), 1) end)
      results2 = Enum.map(1..4, fn _ -> elem(Dispatcher.dispatch(:terrier), 1) end)

      # Two different sequential attempts should produce the same pattern
      # (from a clean state — but note the counter persists across calls)
      assert results1 == results2
    end
  end

  # ── Per-Agent-Type Independence ──────────────────────────────────────────

  describe "independent round-robin counters per sub-agent type" do
    test "terrier and watchdog rotate independently" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)
      assert :ok = NamingService.register_node(@win_worker, @win_caps_all)

      # @linux_worker_a: terrier, retriever
      # @linux_worker_b: terrier, watchdog
      # @win_worker: terrier, watchdog, shepherd, retriever

      # Dispatch :terrier twice (should rotate across 3 workers)
      {:ok, t1} = Dispatcher.dispatch(:terrier)
      {:ok, t2} = Dispatcher.dispatch(:terrier)
      {:ok, t3} = Dispatcher.dispatch(:terrier)

      # All 3 dispatches should be different workers
      assert length(Enum.uniq([t1, t2, t3])) == 3

      # Now dispatch :watchdog — should start from first worker in that list
      # (2 workers: @linux_worker_b and @win_worker)
      {:ok, w1} = Dispatcher.dispatch(:watchdog)
      {:ok, w2} = Dispatcher.dispatch(:watchdog)
      {:ok, w3} = Dispatcher.dispatch(:watchdog)

      # Should alternate between 2 workers: B, Win, B
      assert w1 != w2
      assert w3 == w1
    end

    test "dispatch on one type doesn't affect another type" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      # Dispatch :terrier a bunch of times (counter for :terrier advances)
      Enum.each(1..10, fn _ -> Dispatcher.dispatch(:terrier) end)

      # :watchdog dispatch should still start at index 0
      caps = %{sub_agents: [:watchdog], host_os: "linux", max_concurrent_runs: 2}
      assert :ok = NamingService.register_node(@win_worker, caps)

      {:ok, w1} = Dispatcher.dispatch(:watchdog)
      {:ok, w2} = Dispatcher.dispatch(:watchdog)

      # With 2 watchdog workers: should alternate
      assert w1 != w2
    end
  end

  # ── Capability Matching ──────────────────────────────────────────────────

  describe "capability matching in dispatch" do
    test "only dispatches to workers that support the sub-agent type" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@macos_worker, @macos_caps_shepherd)

      # @macos_worker does NOT support :terrier
      {:ok, t1} = Dispatcher.dispatch(:terrier)
      {:ok, t2} = Dispatcher.dispatch(:terrier)

      assert t1 == @linux_worker_a
      assert t2 == @linux_worker_a
    end

    test "filters by host_os" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@macos_worker, @macos_caps_shepherd)

      # @macos_worker doesn't support terrier
      assert {:ok, node} = Dispatcher.dispatch(:terrier, host_os: "linux")
      assert node == @linux_worker_a

      # @linux_worker_a doesn't support shepherd
      assert {:ok, node} = Dispatcher.dispatch(:shepherd, host_os: "macos")
      assert node == @macos_worker
    end

    test "filters by model" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      # Both support :terrier, only @linux_worker_b has claude-haiku-3-5
      assert {:ok, node} = Dispatcher.dispatch(:terrier, model: "claude-haiku-3-5")
      assert node == @linux_worker_b
    end

    test "returns error when no workers match the filter" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)

      assert {:error, :no_workers_available} =
               Dispatcher.dispatch(:terrier, host_os: "macos")

      assert {:error, :no_workers_available} =
               Dispatcher.dispatch(:terrier, model: "nonexistent-model")
    end

    test "round-robin respects filtered subsets" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)
      assert :ok = NamingService.register_node(@macos_worker, @macos_caps_shepherd)

      # Two workers with :terrier on linux, one on macos (but macos doesn't have terrier)
      # Filter to linux: only @linux_worker_a and @linux_worker_b
      {:ok, first} = Dispatcher.dispatch(:terrier, host_os: "linux")
      {:ok, second} = Dispatcher.dispatch(:terrier, host_os: "linux")
      {:ok, third} = Dispatcher.dispatch(:terrier, host_os: "linux")

      assert first != second
      assert third == first
    end
  end

  # ── Empty Pool ───────────────────────────────────────────────────────────

  describe "dispatch with no workers" do
    test "returns error when no workers registered" do
      assert {:error, :no_workers_available} = Dispatcher.dispatch(:terrier)
    end

    test "returns error when no workers support the sub-agent type" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert {:error, :no_workers_available} = Dispatcher.dispatch(:shepherd)
    end

    test "returns error after unregistering all workers" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert {:ok, _} = Dispatcher.dispatch(:terrier)

      assert :ok = NamingService.unregister_node(@linux_worker_a)
      assert {:error, :no_workers_available} = Dispatcher.dispatch(:terrier)
    end
  end

  # ── Graceful Degradation ─────────────────────────────────────────────────

  describe "graceful degradation" do
    test "returns :dispatcher_not_started when Dispatcher is not running" do
      assert {:error, :dispatcher_not_started} =
               Dispatcher.dispatch(:terrier, [], :nonexistent_dispatcher)
    end
  end

  # ── status/0 ─────────────────────────────────────────────────────────────

  describe "status/0" do
    test "returns empty round_robin when no dispatches have occurred" do
      status = Dispatcher.status()
      assert status.round_robin == %{}
    end

    test "shows round-robin counters after dispatches" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      assert Dispatcher.status().round_robin == %{}

      Dispatcher.dispatch(:terrier)
      assert Dispatcher.status().round_robin == %{terrier: 1}

      Dispatcher.dispatch(:watchdog)
      assert Dispatcher.status().round_robin == %{terrier: 1, watchdog: 1}
    end
  end

  # ── Telemetry ────────────────────────────────────────────────────────────

  describe "telemetry emission" do
    test "emits [:code_puppy, :distributed_pack, :dispatch, :selected] on dispatch" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)

      handler_id = make_ref()
      events = [:code_puppy, :distributed_pack, :dispatch, :selected]

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:dispatch_selected, measurements, metadata})
        end,
        self()
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      assert {:ok, @linux_worker_a} = Dispatcher.dispatch(:terrier)

      assert_received {:dispatch_selected, %{system_time: _},
                       %{
                         sub_agent_type: :terrier,
                         worker_node: @linux_worker_a,
                         matching_workers: 1
                       }}
    end

    test "emits telemetry with matching count for multiple workers" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      handler_id = make_ref()
      events = [:code_puppy, :distributed_pack, :dispatch, :selected]

      :telemetry.attach(
        handler_id,
        events,
        fn _name, measurements, metadata, acc ->
          send(acc, {:dispatch_selected, measurements, metadata})
        end,
        self()
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)
      end)

      assert {:ok, _node} = Dispatcher.dispatch(:terrier)

      assert_received {:dispatch_selected, %{system_time: _},
                       %{
                         sub_agent_type: :terrier,
                         matching_workers: 2
                       }}
    end
  end

  # ── Edge Cases ───────────────────────────────────────────────────────────

  describe "edge cases" do
    test "single worker always gets the dispatch" do
      assert :ok = NamingService.register_node(@linux_worker_a, @linux_caps_terrier)

      results = Enum.map(1..5, fn _ -> Dispatcher.dispatch(:terrier) end)

      assert Enum.all?(results, fn {:ok, node} -> node == @linux_worker_a end)
    end

    test "re-registering a worker with different caps updates capability matching" do
      caps_a = %{sub_agents: [:terrier], host_os: "linux", max_concurrent_runs: 2}
      caps_b = %{sub_agents: [:watchdog], host_os: "macos", max_concurrent_runs: 4}

      assert :ok = NamingService.register_node(@linux_worker_a, caps_a)
      assert {:ok, @linux_worker_a} = Dispatcher.dispatch(:terrier)
      assert {:error, :no_workers_available} = Dispatcher.dispatch(:watchdog)

      # Re-register with different capabilities
      assert :ok = NamingService.register_node(@linux_worker_a, caps_b)

      # Should now match :watchdog but not :terrier
      assert {:ok, @linux_worker_a} = Dispatcher.dispatch(:watchdog)
      assert {:error, :no_workers_available} = Dispatcher.dispatch(:terrier)
    end

    test "darwin OS is normalized to macos by NamingService" do
      darwin_caps = %{
        sub_agents: [:terrier],
        host_os: "darwin",
        max_concurrent_runs: 2
      }

      assert :ok = NamingService.register_node(@macos_worker, darwin_caps)

      # Should be findable with "macos" filter
      assert {:ok, @macos_worker} = Dispatcher.dispatch(:terrier, host_os: "macos")
    end
  end

  # ── Slot Acquisition & Release ────────────────────────────────────────────

  describe "acquire_slot/1 and release_slot/1" do
    test "acquire returns :ok when worker has capacity" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.acquire_slot(@linux_worker_a)
    end

    test "acquire initializes slot from NamingService max_concurrent_runs" do
      # @linux_caps_terrier has max_concurrent_runs: 4
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.acquire_slot(@linux_worker_a)
      assert {:ok, %{active: 1, max: 4}} = Dispatcher.worker_load(@linux_worker_a)
    end

    test "acquire respects per-worker max from NamingService" do
      # @linux_caps_watchdog has max_concurrent_runs: 2
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      assert :ok = Dispatcher.acquire_slot(@linux_worker_b)
      assert :ok = Dispatcher.acquire_slot(@linux_worker_b)
      assert {:error, :at_capacity} = Dispatcher.acquire_slot(@linux_worker_b)
    end

    test "acquire defaults to 4 max for unknown workers" do
      # Don't register in NamingService — should get default max
      assert :ok = Dispatcher.acquire_slot(:unknown_worker@test)
      assert {:ok, %{active: 1, max: 4}} = Dispatcher.worker_load(:unknown_worker@test)
    end

    test "release decrements active count" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      Dispatcher.acquire_slot(@linux_worker_a)
      Dispatcher.acquire_slot(@linux_worker_a)
      assert {:ok, %{active: 2, max: 4}} = Dispatcher.worker_load(@linux_worker_a)

      Dispatcher.release_slot(@linux_worker_a)
      assert {:ok, %{active: 1, max: 4}} = Dispatcher.worker_load(@linux_worker_a)
    end

    test "release never goes below zero" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      Dispatcher.acquire_slot(@linux_worker_a)
      Dispatcher.release_slot(@linux_worker_a)
      Dispatcher.release_slot(@linux_worker_a)
      Dispatcher.release_slot(@linux_worker_a)

      assert {:ok, %{active: 0}} = Dispatcher.worker_load(@linux_worker_a)
    end

    test "release is idempotent for untracked workers" do
      assert :ok = Dispatcher.release_slot(:never_seen@test)
    end

    test "acquire then release full cycle" do
      # max_concurrent_runs: 2
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      assert :ok = Dispatcher.acquire_slot(@linux_worker_b)
      assert :ok = Dispatcher.acquire_slot(@linux_worker_b)
      assert {:error, :at_capacity} = Dispatcher.acquire_slot(@linux_worker_b)

      # Release one, now we can acquire again
      assert :ok = Dispatcher.release_slot(@linux_worker_b)
      assert :ok = Dispatcher.acquire_slot(@linux_worker_b)
      assert {:error, :at_capacity} = Dispatcher.acquire_slot(@linux_worker_b)
    end
  end

  # ── Dispatch Respects Capacity ───────────────────────────────────────────

  describe "dispatch skips overloaded workers" do
    test "skips workers at max capacity" do
      # @linux_caps_watchdog: max 2, @linux_caps_terrier: max 4
      # Both support :terrier
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      # Fill worker_b to capacity (max 2)
      Dispatcher.acquire_slot(@linux_worker_b)
      Dispatcher.acquire_slot(@linux_worker_b)

      # All :terrier dispatches should now go to worker_a
      results =
        Enum.map(1..4, fn _ ->
          {:ok, node} = Dispatcher.dispatch(:terrier)
          node
        end)

      assert Enum.all?(results, &(&1 == @linux_worker_a))
    end

    test "returns :all_workers_at_capacity when every candidate is full" do
      # Both workers have max_concurrent_runs: 2
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)
      NamingService.register_node(@win_worker, @win_caps_all)

      # Fill both to capacity
      Dispatcher.acquire_slot(@linux_worker_b)
      Dispatcher.acquire_slot(@linux_worker_b)
      Dispatcher.acquire_slot(@win_worker)
      Dispatcher.acquire_slot(@win_worker)

      assert {:error, :all_workers_at_capacity} = Dispatcher.dispatch(:watchdog)
    end

    test "resumes dispatching after slot is released" do
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      # Fill to capacity (max 2)
      Dispatcher.acquire_slot(@linux_worker_b)
      Dispatcher.acquire_slot(@linux_worker_b)

      assert {:error, :all_workers_at_capacity} = Dispatcher.dispatch(:watchdog)

      # Release a slot — dispatch should work again
      Dispatcher.release_slot(@linux_worker_b)
      assert {:ok, @linux_worker_b} = Dispatcher.dispatch(:watchdog)
    end

    test "no_workers_available takes precedence over at_capacity" do
      # No workers registered at all — should be :no_workers_available, not :at_capacity
      assert {:error, :no_workers_available} = Dispatcher.dispatch(:terrier)
    end

    test "round-robin rotates across available (non-full) workers" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)
      NamingService.register_node(@win_worker, @win_caps_all)

      # All three support :terrier. Fill worker_b to capacity (max 2)
      Dispatcher.acquire_slot(@linux_worker_b)
      Dispatcher.acquire_slot(@linux_worker_b)

      # Dispatch should round-robin between worker_a and win_worker only
      {:ok, first} = Dispatcher.dispatch(:terrier)
      {:ok, second} = Dispatcher.dispatch(:terrier)
      {:ok, third} = Dispatcher.dispatch(:terrier)

      refute first == @linux_worker_b
      refute second == @linux_worker_b
      refute third == @linux_worker_b

      assert first != second
      assert third == first
    end
  end

  # ── worker_load & active_slots ───────────────────────────────────────────

  describe "worker_load/1" do
    test "returns :unknown_worker for untracked nodes" do
      assert {:error, :unknown_worker} = Dispatcher.worker_load(:nobody@test)
    end

    test "returns load after acquire" do
      NamingService.register_node(@macos_worker, @macos_caps_shepherd)
      Dispatcher.acquire_slot(@macos_worker)

      assert {:ok, %{active: 1, max: 8}} = Dispatcher.worker_load(@macos_worker)
    end
  end

  describe "active_slots/0" do
    test "returns empty map when no slots tracked" do
      assert %{} = Dispatcher.active_slots()
    end

    test "returns all tracked workers" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)

      Dispatcher.acquire_slot(@linux_worker_a)
      Dispatcher.acquire_slot(@linux_worker_b)
      Dispatcher.acquire_slot(@linux_worker_b)

      slots = Dispatcher.active_slots()

      assert %{active: 1, max: 4} = slots[@linux_worker_a]
      assert %{active: 2, max: 2} = slots[@linux_worker_b]
    end
  end

  # ── Slot Telemetry ───────────────────────────────────────────────────────

  describe "slot telemetry" do
    test "emits :slot_acquired on successful acquire" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)

      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :pack, :dispatcher, :slot_acquired],
        fn _name, measurements, metadata, acc ->
          send(acc, {:acquired, measurements, metadata})
        end,
        self()
      )

      Dispatcher.acquire_slot(@linux_worker_a)

      assert_received {:acquired, %{active: 1, max: 4}, %{worker_node: @linux_worker_a}}
    end

    test "emits :slot_released on release" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      Dispatcher.acquire_slot(@linux_worker_a)

      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :pack, :dispatcher, :slot_released],
        fn _name, measurements, metadata, acc ->
          send(acc, {:released, measurements, metadata})
        end,
        self()
      )

      Dispatcher.release_slot(@linux_worker_a)

      assert_received {:released, %{active: 0, max: 4}, %{worker_node: @linux_worker_a}}
    end

    test "emits :at_capacity when acquire is rejected" do
      # max 2
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)
      Dispatcher.acquire_slot(@linux_worker_b)
      Dispatcher.acquire_slot(@linux_worker_b)

      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :pack, :dispatcher, :at_capacity],
        fn _name, measurements, metadata, acc ->
          send(acc, {:at_cap, measurements, metadata})
        end,
        self()
      )

      assert {:error, :at_capacity} = Dispatcher.acquire_slot(@linux_worker_b)

      assert_received {:at_cap, %{active: 2, max: 2}, %{worker_node: @linux_worker_b}}
    end

    test "emits :at_capacity when all dispatch candidates are full" do
      NamingService.register_node(@linux_worker_b, @linux_caps_watchdog)
      Dispatcher.acquire_slot(@linux_worker_b)
      Dispatcher.acquire_slot(@linux_worker_b)

      handler_id = make_ref()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :pack, :dispatcher, :at_capacity],
        fn _name, measurements, metadata, acc ->
          send(acc, {:dispatch_at_cap, measurements, metadata})
        end,
        self()
      )

      assert {:error, :all_workers_at_capacity} = Dispatcher.dispatch(:watchdog)

      assert_received {:dispatch_at_cap, %{candidate_count: 1}, %{sub_agent_type: :watchdog}}
    end
  end

  # ── Status includes slots ────────────────────────────────────────────────

  describe "status/0 with slots" do
    test "includes slot data in status" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      Dispatcher.acquire_slot(@linux_worker_a)

      status = Dispatcher.status()
      assert %{active: 1, max: 4} = status.slots[@linux_worker_a]
    end

    test "clear resets slots" do
      NamingService.register_node(@linux_worker_a, @linux_caps_terrier)
      Dispatcher.acquire_slot(@linux_worker_a)

      Dispatcher.clear()

      assert %{} = Dispatcher.active_slots()
      assert {:error, :unknown_worker} = Dispatcher.worker_load(@linux_worker_a)
    end
  end

  describe "validate capability maps on registration" do
    test "rejects invalid OS" do
      caps = %{
        sub_agents: [:terrier],
        host_os: "mars",
        max_concurrent_runs: 2
      }

      assert {:error, :invalid_capabilities} = NamingService.register_node(:invalid_os@test, caps)
    end

    test "rejects invalid sub_agents" do
      caps = %{
        sub_agents: [:nonexistent_agent],
        host_os: "linux",
        max_concurrent_runs: 2
      }

      assert {:error, :invalid_capabilities} = NamingService.register_node(@linux_worker_a, caps)
    end

    test "does not crash on malformed input — empty caps default gracefully" do
      # NamingService accepts empty maps: host_os defaults to "unknown", sub_agents to []
      result = NamingService.register_node(@linux_worker_a, %{})
      assert result == :ok
    end
  end
end
