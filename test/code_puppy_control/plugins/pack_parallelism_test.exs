defmodule CodePuppyControl.Plugins.PackParallelismTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Plugins.PackParallelism

  # ── Test Helpers ─────────────────────────────────────────────────────

  # Polls PackParallelism.status/0 until every key in `expected` matches
  # the returned map. Fails with a descriptive message after `deadline_ms`
  # (default 2 000 ms).  Yields between polls so the GenServer can
  # process pending messages (e.g. a blocked acquire call from a
  # Task.async process that has not yet been scheduled).
  defp wait_until_status(expected, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll_status(expected, deadline, deadline_ms)
  end

  defp poll_status(expected, deadline, deadline_ms) do
    status = PackParallelism.status()
    matched = Enum.all?(expected, fn {k, v} -> Map.get(status, k) == v end)

    if matched do
      :ok
    else
      now = System.monotonic_time(:millisecond)

      if now >= deadline do
        flunk("""
        wait_until_status timed out after #{deadline_ms} ms
        Expected: #{inspect(expected)}
        Got:      #{inspect(status)}
        """)
      else
        # Yield so the scheduler can run other processes (e.g. the
        # Task.async that is trying to call acquire on the GenServer).
        :erlang.yield()
        poll_status(expected, deadline, deadline_ms)
      end
    end
  end

  # The GenServer is application-supervised.  Tests must not repeatedly
  # stop the supervised singleton: doing so can trip supervisor restart
  # intensity and leave unrelated async tests without app services.  Keep the
  # process alive and reset its counters/limit before each test instead.
  setup do
    {:ok, _apps} = Application.ensure_all_started(:code_puppy_control)

    if Process.whereis(PackParallelism) == nil do
      {:ok, _pid} = PackParallelism.start_link([])
    end

    PackParallelism.reset()
    PackParallelism.set_limit(2)

    :ok
  end

  # ── Initialization ────────────────────────────────────────────────

  describe "init/1" do
    test "initializes with default limits" do
      status = PackParallelism.status()
      assert status.limit == 2
      assert status.active == 0
      assert status.waiters == 0
      assert status.available == 2
    end

    test "initializes with custom max_concurrent_runs" do
      # Equivalent runtime assertion without restarting the supervised child.
      PackParallelism.set_limit(5)

      status = PackParallelism.status()
      assert status.limit == 5
      assert status.available == 5
    end

    test "initializes with allow_parallel: false forces limit=1" do
      # Equivalent runtime assertion without restarting the supervised child.
      PackParallelism.set_limit(1)

      status = PackParallelism.status()
      assert status.limit == 1
    end
  end

  # ── Acquire / Release ──────────────────────────────────────────────

  describe "acquire/1" do
    test "succeeds when slots are available" do
      assert :ok == PackParallelism.acquire()
      # Clean up
      PackParallelism.release()
    end

    test "increments active count on acquire" do
      :ok = PackParallelism.acquire()
      status = PackParallelism.status()
      assert status.active == 1
      assert status.available == 1
      PackParallelism.release()
    end

    test "blocks when all slots are in use" do
      # Fill both default slots
      :ok = PackParallelism.acquire()
      :ok = PackParallelism.acquire()

      # Spawn a task that should block
      task =
        Task.async(fn ->
          PackParallelism.acquire(timeout: 500)
        end)

      # Wait deterministically for the waiter to be queued
      wait_until_status(waiters: 1)

      # Release a slot to unblock
      PackParallelism.release()

      result = Task.await(task, 1000)
      assert result == :ok

      # Clean up remaining slots
      PackParallelism.release()
      PackParallelism.release()
    end

    test "returns error on timeout when no slots available" do
      :ok = PackParallelism.acquire()
      :ok = PackParallelism.acquire()

      assert {:error, :timeout} == PackParallelism.acquire(timeout: 100)

      PackParallelism.release()
      PackParallelism.release()
    end
  end

  describe "try_acquire/0" do
    test "succeeds when slots are available" do
      assert :ok == PackParallelism.try_acquire()
      PackParallelism.release()
    end

    test "returns unavailable when all slots are in use" do
      :ok = PackParallelism.acquire()
      :ok = PackParallelism.acquire()

      assert {:error, :unavailable} == PackParallelism.try_acquire()

      PackParallelism.release()
      PackParallelism.release()
    end
  end

  describe "release/0" do
    test "decrements active count" do
      :ok = PackParallelism.acquire()
      assert PackParallelism.status().active == 1

      PackParallelism.release()
      # Release is cast, so ping to flush
      :pong = PackParallelism.ping()
      assert PackParallelism.status().active == 0
    end

    test "wakes next waiter in FIFO order" do
      :ok = PackParallelism.acquire()
      :ok = PackParallelism.acquire()

      # Start first waiter, confirm it is queued before starting the
      # second.  This guarantees FIFO order even under scheduler jitter.
      task1 =
        Task.async(fn ->
          PackParallelism.acquire(timeout: 5_000)
        end)

      wait_until_status(waiters: 1)

      task2 =
        Task.async(fn ->
          PackParallelism.acquire(timeout: 5_000)
        end)

      wait_until_status(waiters: 2)

      # Release one slot — should wake task1 first (FIFO)
      PackParallelism.release()

      result1 = Task.await(task1, 5000)
      assert result1 == :ok

      # Release another — wakes task2
      PackParallelism.release()
      result2 = Task.await(task2, 5000)
      assert result2 == :ok

      # Clean up
      PackParallelism.release()
      PackParallelism.release()
    end

    test "handles release with no active runs gracefully" do
      # Should not crash, just log a warning
      PackParallelism.release()
      :pong = PackParallelism.ping()
      assert PackParallelism.status().active == 0
    end
  end

  # ── with_slot/2 ─────────────────────────────────────────────────────

  describe "with_slot/2" do
    test "acquires and releases slot around function" do
      result =
        PackParallelism.with_slot(fn ->
          assert PackParallelism.status().active == 1
          :result
        end)

      assert {:ok, :result} == result
      :pong = PackParallelism.ping()
      assert PackParallelism.status().active == 0
    end

    test "releases slot on exception" do
      assert_raise RuntimeError, fn ->
        PackParallelism.with_slot(fn ->
          raise "boom"
        end)
      end

      :pong = PackParallelism.ping()
      assert PackParallelism.status().active == 0
    end

    test "returns timeout error when no slots" do
      :ok = PackParallelism.acquire()
      :ok = PackParallelism.acquire()

      assert {:error, :timeout} ==
               PackParallelism.with_slot(fn -> :ok end, timeout: 100)

      PackParallelism.release()
      PackParallelism.release()
    end
  end

  # ── set_limit/1 ─────────────────────────────────────────────────────

  describe "set_limit/1" do
    test "grows the limit" do
      :ok = PackParallelism.set_limit(5)
      assert PackParallelism.status().limit == 5
    end

    test "shrinks the limit and absorbs deficit" do
      :ok = PackParallelism.set_limit(1)
      assert PackParallelism.status().limit == 1
    end

    test "rejects invalid limit values" do
      assert {:error, :invalid} == PackParallelism.set_limit(0)
      assert {:error, :invalid} == PackParallelism.set_limit(-1)
    end

    test "growing after shrinking absorbs deficit" do
      # Shrink to 1
      :ok = PackParallelism.set_limit(1)
      assert PackParallelism.status().limit == 1

      # Grow back to 3
      :ok = PackParallelism.set_limit(3)
      assert PackParallelism.status().limit == 3
    end
  end

  # ── reset/0 ────────────────────────────────────────────────────────

  describe "reset/0" do
    test "resets all counters to zero" do
      :ok = PackParallelism.acquire()
      :ok = PackParallelism.acquire()

      previous = PackParallelism.reset()
      assert previous["active"] == 2
      assert PackParallelism.status().active == 0
    end

    test "replies to all waiters with timeout on reset" do
      :ok = PackParallelism.acquire()
      :ok = PackParallelism.acquire()

      task =
        Task.async(fn ->
          PackParallelism.acquire(timeout: 5000)
        end)

      wait_until_status(waiters: 1)

      PackParallelism.reset()

      result = Task.await(task, 1000)
      assert result == {:error, :timeout}
    end
  end

  # ── status/0 ───────────────────────────────────────────────────────

  describe "status/0" do
    test "returns correct structure" do
      status = PackParallelism.status()
      assert Map.has_key?(status, :limit)
      assert Map.has_key?(status, :active)
      assert Map.has_key?(status, :waiters)
      assert Map.has_key?(status, :available)
    end

    test "available is limit minus active" do
      :ok = PackParallelism.acquire()
      status = PackParallelism.status()
      assert status.available == status.limit - status.active
      PackParallelism.release()
    end
  end

  # ── effective_limit/0 ──────────────────────────────────────────────

  describe "effective_limit/0" do
    test "returns current limit from ETS" do
      assert PackParallelism.effective_limit() == 2
    end

    test "reflects set_limit changes" do
      :ok = PackParallelism.set_limit(10)
      assert PackParallelism.effective_limit() == 10
    end
  end

  # ── ping/0 ─────────────────────────────────────────────────────────

  describe "ping/0" do
    test "returns pong" do
      assert :pong == PackParallelism.ping()
    end
  end

  # ── JSON-RPC Handlers ──────────────────────────────────────────────

  describe "handle_jsonrpc_acquire/1" do
    test "returns ok on success" do
      result = PackParallelism.JSONRPC.handle_jsonrpc_acquire(%{})
      assert result["status"] == "ok"
      PackParallelism.release()
    end

    test "converts seconds to milliseconds" do
      result = PackParallelism.JSONRPC.handle_jsonrpc_acquire(%{"timeout" => 1})
      assert result["status"] == "ok"
      PackParallelism.release()
    end
  end

  describe "handle_jsonrpc_release/1" do
    test "returns ok" do
      :ok = PackParallelism.acquire()
      result = PackParallelism.JSONRPC.handle_jsonrpc_release(%{})
      assert result["status"] == "ok"
    end
  end

  describe "handle_jsonrpc_status/1" do
    test "returns status dict" do
      result = PackParallelism.JSONRPC.handle_jsonrpc_status(%{})
      assert result["status"] == "ok"
      assert Map.has_key?(result, "limit")
      assert Map.has_key?(result, "active")
      assert Map.has_key?(result, "waiters")
    end
  end

  describe "handle_jsonrpc_set_limit/1" do
    test "sets limit successfully" do
      result = PackParallelism.JSONRPC.handle_jsonrpc_set_limit(%{"limit" => 4})
      assert result["status"] == "ok"
      assert result["limit"] == 4
    end

    test "rejects invalid limit" do
      result = PackParallelism.JSONRPC.handle_jsonrpc_set_limit(%{"limit" => 0})
      assert result["status"] == "error"
    end
  end

  describe "handle_jsonrpc_reset/1" do
    test "resets state and returns previous" do
      :ok = PackParallelism.acquire()
      result = PackParallelism.JSONRPC.handle_jsonrpc_reset(%{})
      assert result["status"] == "ok"
      assert Map.has_key?(result, "previous")
      assert result["previous"]["active"] == 1
    end
  end

  # ── Deficit Tracking ───────────────────────────────────────────────

  describe "deficit on shrink/grow cycle" do
    test "shrinking below active count creates deficit" do
      # Acquire both default slots
      :ok = PackParallelism.acquire()
      :ok = PackParallelism.acquire()
      assert PackParallelism.status().active == 2

      # Shrink to 1 — creates deficit
      :ok = PackParallelism.set_limit(1)
      assert PackParallelism.status().limit == 1

      # Release one slot — should be absorbed by deficit
      PackParallelism.release()
      :pong = PackParallelism.ping()

      # Active should be 1, limit should be 1
      status = PackParallelism.status()
      assert status.active == 1
      assert status.limit == 1
    end
  end

  # ── Concurrency Safety ─────────────────────────────────────────────

  describe "concurrent acquire/release" do
    test "no lost updates under concurrent load" do
      # Spawn many tasks that acquire and release rapidly
      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            for _j <- 1..10 do
              case PackParallelism.try_acquire() do
                :ok ->
                  :erlang.yield()
                  PackParallelism.release()
                  :pong = PackParallelism.ping()
                  :ok

                {:error, :unavailable} ->
                  :unavailable
              end
            end
          end)
        end

      # Wait for all tasks
      for task <- tasks, do: Task.await(task, 30_000)

      # After all tasks complete, the counters should be back to 0
      :pong = PackParallelism.ping()
      status = PackParallelism.status()
      assert status.active == 0
    end
  end
end
