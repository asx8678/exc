defmodule CodePuppyControl.Pack.DispatcherTest do
  @moduledoc """
  Tests for Pack.Dispatcher — round-robin worker selection with capability matching.

  These tests start their own Dispatcher GenServer (not relying on the
  application supervision tree) and manage the ETS table lifecycle
  via setup/teardown.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.Dispatcher

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
    start_supervised!({Dispatcher, [name: Dispatcher]})

    on_exit(fn ->
      # Clear any leftover ETS data
      if :ets.whereis(:pack_dispatcher) != :undefined do
        :ets.delete_all_objects(:pack_dispatcher)
      end
    end)

    :ok
  end

  # ── Registration ─────────────────────────────────────────────────────────

  describe "register_worker/2" do
    test "registers a worker with capabilities" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert Dispatcher.available_workers() == [@linux_worker_a]
    end

    test "registers multiple workers" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@macos_worker, @macos_caps_shepherd)

      workers = Dispatcher.available_workers()
      assert length(workers) == 2
      assert @linux_worker_a in workers
      assert @macos_worker in workers
    end

    test "replaces existing registration for same node" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)

      # Verify terrier is supported
      assert Dispatcher.available_workers(sub_agent_type: :terrier) == [@linux_worker_a]

      # Re-register with different capabilities
      replaced_caps = %{
        sub_agents: [:watchdog],
        host_os: "linux",
        max_concurrent_runs: 2
      }

      assert :ok = Dispatcher.register_worker(@linux_worker_a, replaced_caps)

      # Should no longer be available for terrier
      assert Dispatcher.available_workers(sub_agent_type: :terrier) == []

      # But should be available for watchdog
      assert Dispatcher.available_workers(sub_agent_type: :watchdog) == [@linux_worker_a]
    end

    test "registers worker with empty sub_agents list" do
      assert :ok =
               Dispatcher.register_worker(@linux_worker_a, %{
                 sub_agents: [],
                 host_os: "linux"
               })

      assert Dispatcher.available_workers() == [@linux_worker_a]
      assert Dispatcher.available_workers(sub_agent_type: :terrier) == []
    end
  end

  # ── Unregistration ───────────────────────────────────────────────────────

  describe "unregister_worker/1" do
    test "unregisters a worker" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert Dispatcher.available_workers() == [@linux_worker_a]

      assert :ok = Dispatcher.unregister_worker(@linux_worker_a)
      assert Dispatcher.available_workers() == []
    end

    test "unregistering a worker removes it from agent indices" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert Dispatcher.available_workers(sub_agent_type: :terrier) == [@linux_worker_a]

      assert :ok = Dispatcher.unregister_worker(@linux_worker_a)
      assert Dispatcher.available_workers(sub_agent_type: :terrier) == []
    end

    test "unregistering unknown worker is a no-op" do
      assert :ok = Dispatcher.unregister_worker(:nonexistent@test)
    end

    test "unregistering one worker does not affect others" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)

      assert :ok = Dispatcher.unregister_worker(@linux_worker_a)

      workers = Dispatcher.available_workers()
      assert length(workers) == 1
      assert hd(workers) == @linux_worker_b
    end
  end

  # ── Round-Robin Dispatch ─────────────────────────────────────────────────

  describe "dispatch/2 round-robin" do
    test "selects workers in order across sequential dispatches" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)

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
                   Dispatcher.register_worker(node, %{
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

      # The sequence should be: w0, w1, w2, w3, w4, w0, w1, w2, w3, w4
      expected_cycle = workers ++ workers
      assert results == expected_cycle
    end

    test "round-robin hits all workers before repeating" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)
      assert :ok = Dispatcher.register_worker(@macos_worker, @macos_caps_shepherd)

      # Only @linux_worker_a and @linux_worker_b support :terrier
      {:ok, first} = Dispatcher.dispatch(:terrier)
      {:ok, second} = Dispatcher.dispatch(:terrier)
      {:ok, third} = Dispatcher.dispatch(:terrier)

      # With 2 workers: must be alternating A, B, A
      assert first != second
      assert third == first
    end

    test "dispatch order is deterministic for the same set of workers" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)

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
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)
      assert :ok = Dispatcher.register_worker(@win_worker, @win_caps_all)

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
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)

      # Dispatch :terrier a bunch of times (counter for :terrier advances)
      Enum.each(1..10, fn _ -> Dispatcher.dispatch(:terrier) end)

      # :watchdog dispatch should still start at index 0
      caps = %{sub_agents: [:watchdog], host_os: "linux", max_concurrent_runs: 2}
      assert :ok = Dispatcher.register_worker(@win_worker, caps)

      {:ok, w1} = Dispatcher.dispatch(:watchdog)
      {:ok, w2} = Dispatcher.dispatch(:watchdog)

      # With 2 watchdog workers: should alternate
      assert w1 != w2
    end
  end

  # ── Capability Matching ──────────────────────────────────────────────────

  describe "capability matching in dispatch" do
    test "only dispatches to workers that support the sub-agent type" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@macos_worker, @macos_caps_shepherd)

      # @macos_worker does NOT support :terrier
      {:ok, t1} = Dispatcher.dispatch(:terrier)
      {:ok, t2} = Dispatcher.dispatch(:terrier)

      assert t1 == @linux_worker_a
      assert t2 == @linux_worker_a
    end

    test "filters by host_os" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@macos_worker, @macos_caps_shepherd)

      # @macos_worker doesn't support terrier
      assert {:ok, node} = Dispatcher.dispatch(:terrier, host_os: "linux")
      assert node == @linux_worker_a

      # @linux_worker_a doesn't support shepherd
      assert {:ok, node} = Dispatcher.dispatch(:shepherd, host_os: "macos")
      assert node == @macos_worker
    end

    test "filters by model" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)

      # Both support :terrier, only @linux_worker_b has claude-haiku-3-5
      assert {:ok, node} = Dispatcher.dispatch(:terrier, model: "claude-haiku-3-5")
      assert node == @linux_worker_b
    end

    test "returns error when no workers match the filter" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)

      assert {:error, :no_workers_available} =
               Dispatcher.dispatch(:terrier, host_os: "macos")

      assert {:error, :no_workers_available} =
               Dispatcher.dispatch(:terrier, model: "nonexistent-model")
    end

    test "round-robin respects filtered subsets" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)
      assert :ok = Dispatcher.register_worker(@macos_worker, @macos_caps_shepherd)

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
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert {:error, :no_workers_available} = Dispatcher.dispatch(:shepherd)
    end

    test "returns error after unregistering all workers" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert {:ok, _} = Dispatcher.dispatch(:terrier)

      assert :ok = Dispatcher.unregister_worker(@linux_worker_a)
      assert {:error, :no_workers_available} = Dispatcher.dispatch(:terrier)
    end
  end

  # ── available_workers/1 ──────────────────────────────────────────────────

  describe "available_workers/1" do
    test "returns empty list when no workers registered" do
      assert Dispatcher.available_workers() == []
    end

    test "returns all workers when no filters given" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@macos_worker, @macos_caps_shepherd)

      workers = Dispatcher.available_workers()
      assert length(workers) == 2
      assert @linux_worker_a in workers
      assert @macos_worker in workers
    end

    test "filters by sub_agent_type" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@macos_worker, @macos_caps_shepherd)
      assert :ok = Dispatcher.register_worker(@win_worker, @win_caps_all)

      terrier_workers = Dispatcher.available_workers(sub_agent_type: :terrier)
      assert length(terrier_workers) == 2
      assert @linux_worker_a in terrier_workers
      assert @win_worker in terrier_workers

      shepherd_workers = Dispatcher.available_workers(sub_agent_type: :shepherd)
      assert length(shepherd_workers) == 2
      assert @macos_worker in shepherd_workers
      assert @win_worker in shepherd_workers

      retriever_workers = Dispatcher.available_workers(sub_agent_type: :retriever)
      assert length(retriever_workers) == 3
      assert @linux_worker_a in retriever_workers
      assert @macos_worker in retriever_workers
      assert @win_worker in retriever_workers
    end

    test "returns empty when no workers match sub_agent_type" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert Dispatcher.available_workers(sub_agent_type: :nonexistent) == []
    end
  end

  # ── status/0 ─────────────────────────────────────────────────────────────

  describe "status/0" do
    test "returns zero workers and empty round_robin when empty" do
      status = Dispatcher.status()
      assert status.workers == 0
      assert status.round_robin == %{}
    end

    test "reflects registered workers count" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert Dispatcher.status().workers == 1

      assert :ok = Dispatcher.register_worker(@macos_worker, @macos_caps_shepherd)
      assert Dispatcher.status().workers == 2
    end

    test "shows round-robin counters after dispatches" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)

      assert Dispatcher.status().round_robin == %{}

      Dispatcher.dispatch(:terrier)
      assert Dispatcher.status().round_robin == %{terrier: 1}

      Dispatcher.dispatch(:watchdog)
      assert Dispatcher.status().round_robin == %{terrier: 1, watchdog: 1}
    end

    test "counts workers even after dispatches" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      Dispatcher.dispatch(:terrier)
      assert Dispatcher.status().workers == 1
    end
  end

  # ── Telemetry ────────────────────────────────────────────────────────────

  describe "telemetry emission" do
    test "emits [:code_puppy, :distributed_pack, :dispatch, :selected] on dispatch" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)

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

      assert {:ok, @linux_worker_a} = Dispatcher.dispatch(:terrier)

      assert_received {:dispatch_selected, %{system_time: _},
                       %{
                         sub_agent_type: :terrier,
                         worker_node: @linux_worker_a,
                         matching_workers: 1
                       }}

      :telemetry.detach(handler_id)
    end

    test "emits telemetry with matching count for multiple workers" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)
      assert :ok = Dispatcher.register_worker(@linux_worker_b, @linux_caps_watchdog)

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

      assert {:ok, _node} = Dispatcher.dispatch(:terrier)

      assert_received {:dispatch_selected, %{system_time: _},
                       %{
                         sub_agent_type: :terrier,
                         matching_workers: 2
                       }}

      :telemetry.detach(handler_id)
    end
  end

  # ── Edge Cases ───────────────────────────────────────────────────────────

  describe "edge cases" do
    test "single worker always gets the dispatch" do
      assert :ok = Dispatcher.register_worker(@linux_worker_a, @linux_caps_terrier)

      results = Enum.map(1..5, fn _ -> Dispatcher.dispatch(:terrier) end)

      assert Enum.all?(results, fn {:ok, node} -> node == @linux_worker_a end)
    end

    test "registering same worker multiple times preserves last registration" do
      caps_a = %{sub_agents: [:terrier], host_os: "linux", max_concurrent_runs: 2}
      caps_b = %{sub_agents: [:watchdog], host_os: "macos", max_concurrent_runs: 4}

      assert :ok = Dispatcher.register_worker(@linux_worker_a, caps_a)
      assert :ok = Dispatcher.register_worker(@linux_worker_a, caps_b)

      # Should have been updated to caps_b
      assert Dispatcher.available_workers(sub_agent_type: :watchdog) == [@linux_worker_a]
      assert Dispatcher.available_workers(sub_agent_type: :terrier) == []
    end
  end
end
