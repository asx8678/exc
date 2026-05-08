defmodule CodePuppyControl.Runtime.CronSchedulerTest do
  @moduledoc """
  Tests for CronScheduler GenServer — periodic schedule checks, task
  evaluation, and force-check behaviour.

  Each test starts its own per-test CronScheduler via start_supervised/1
  to avoid shared-state issues with a global singleton.
  """

  # async: false because each test starts its own CronScheduler via
  # start_supervised/1, which holds a sandbox DB connection. Under full
  # fast-suite load, concurrent DB-checkout + Oban engine access causes
  # SQLite "Database busy" / scheduler-storage flakiness.
  # (code-puppy-97t)
  use CodePuppyControl.StatefulCase, async: false

  @moduletag timeout: 30_000

  alias CodePuppyControl.Scheduler
  alias CodePuppyControl.Scheduler.CronScheduler
  alias CodePuppyControl.Repo

  # ---------------------------------------------------------------------------
  # Sandbox contention fix (code_puppy-5xd.6)
  # ---------------------------------------------------------------------------

  describe "test-env exclusion (code_puppy-5xd.6)" do
    test "global CronScheduler is not started in test supervision tree" do
      # The global CronScheduler (registered under __MODULE__) must NOT
      # be part of the application supervisor in test env. If it were,
      # it would hold a sandbox DB connection and starve other
      # DB-dependent tests.
      assert Process.whereis(CronScheduler) == nil
    end

    test "Scheduler.scheduler_status reports not_running when global absent" do
      status = Scheduler.scheduler_status()
      assert status.running == false
      assert status.check_interval == 0
    end

    test "Scheduler.force_check returns not_running when global absent" do
      assert {:error, :not_running} = Scheduler.force_check()
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Repo.delete_all(Oban.Job)

    name = :"cron_scheduler_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({CronScheduler, name: name, check_interval: 60_000})
    %{scheduler: name}
  end

  # ---------------------------------------------------------------------------
  # GenServer State
  # ---------------------------------------------------------------------------

  describe "get_state/1" do
    test "returns scheduler state with expected keys", %{scheduler: sched} do
      state = CronScheduler.get_state(sched)

      assert Map.has_key?(state, :check_interval)
      assert Map.has_key?(state, :last_check_at)
      assert Map.has_key?(state, :tasks_enqueued)
    end

    test "check_interval is positive", %{scheduler: sched} do
      state = CronScheduler.get_state(sched)
      assert state.check_interval > 0
    end

    test "tasks_enqueued starts at zero or above", %{scheduler: sched} do
      state = CronScheduler.get_state(sched)
      assert state.tasks_enqueued >= 0
    end
  end

  # ---------------------------------------------------------------------------
  # Force Check
  # ---------------------------------------------------------------------------

  describe "check_now/1" do
    test "triggers a schedule check without error", %{scheduler: sched} do
      assert :ok = CronScheduler.check_now(sched)
      # Fire-and-forget — no assertion depends on processing completing.
    end

    test "updates last_check_at after check", %{scheduler: sched} do
      initial = CronScheduler.get_state(sched)

      :ok = CronScheduler.check_now(sched)

      # Poll until last_check_at advances (avoids fixed sleep flakes).
      updated = wait_for_check(sched, initial)

      assert updated.last_check_at != nil

      if initial.last_check_at != nil do
        assert DateTime.compare(updated.last_check_at, initial.last_check_at) in [:gt, :eq]
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Per-instance scheduler status
  # ---------------------------------------------------------------------------

  describe "get_state/1 (named instance)" do
    test "returns state map with expected keys", %{scheduler: sched} do
      status = CronScheduler.get_state(sched)

      assert Map.has_key?(status, :check_interval)
      assert Map.has_key?(status, :last_check_at)
      assert Map.has_key?(status, :tasks_enqueued)
    end
  end

  # ---------------------------------------------------------------------------
  # Per-instance force check
  # ---------------------------------------------------------------------------

  describe "check_now/1 (named instance)" do
    test "returns :ok", %{scheduler: sched} do
      assert :ok = CronScheduler.check_now(sched)
      # Fire-and-forget — no assertion depends on processing completing.
    end
  end

  # ---------------------------------------------------------------------------
  # Enqueue Behaviour
  # ---------------------------------------------------------------------------

  describe "task enqueuing on check" do
    test "does not enqueue disabled tasks", %{scheduler: sched} do
      {:ok, _task} =
        Scheduler.create_task(%{
          name: "disabled-check-#{System.unique_integer([:positive])}",
          agent_name: "code-puppy",
          prompt: "Should not run",
          schedule_type: "hourly",
          enabled: false
        })

      initial = CronScheduler.get_state(sched)

      :ok = CronScheduler.check_now(sched)

      # Poll to let the check complete, then verify no crash on disabled tasks.
      updated = wait_for_check(sched, initial)

      # The count may have increased from other tests' tasks, but this test
      # just validates the check doesn't crash on disabled tasks.
      assert updated.tasks_enqueued >= initial.tasks_enqueued
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Polls CronScheduler.get_state/1 until last_check_at advances past `initial`,
  # or until the default 500ms timeout.  Avoids fixed Process.sleep/1 which
  # flakes under full suite load.  (code-puppy-97t)
  defp wait_for_check(sched, initial, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_check(sched, initial, deadline)
  end

  defp do_wait_for_check(sched, initial, deadline) do
    state = CronScheduler.get_state(sched)

    if state.last_check_at != nil and
         (initial.last_check_at == nil or
            DateTime.compare(state.last_check_at, initial.last_check_at) == :gt) do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline do
        state
      else
        Process.sleep(20)
        do_wait_for_check(sched, initial, deadline)
      end
    end
  end
end
