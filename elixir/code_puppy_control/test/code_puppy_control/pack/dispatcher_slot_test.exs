defmodule CodePuppyControl.Pack.DispatcherSlotTest do
  @moduledoc """
  Tests for Pack.Dispatcher slot tracking — acquire, release, capacity gating.

  Split from `DispatcherTest` to keep test files under 600 lines.
  Round-robin and capability tests remain in `dispatcher_test.exs`.
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
    unless Process.whereis(NamingService) do
      start_supervised!({NamingService, []})
    end

    unless Process.whereis(Dispatcher) do
      start_supervised!({Dispatcher, []})
    end

    NamingService.clear()
    Dispatcher.clear()

    on_exit(fn ->
      for prefix <- [
            [:code_puppy, :distributed_pack, :dispatch],
            [:code_puppy, :pack, :dispatcher]
          ] do
        :telemetry.list_handlers(prefix)
        |> Enum.each(fn %{id: id} -> :telemetry.detach(id) end)
      end

      if Process.whereis(NamingService) != nil do
        NamingService.clear()
      end
    end)

    :ok
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
end
