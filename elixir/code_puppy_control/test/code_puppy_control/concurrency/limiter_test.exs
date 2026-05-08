defmodule CodePuppyControl.Concurrency.LimiterTest do
  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Concurrency.Limiter

  setup do
    Limiter.reset()

    :ok
  end

  describe "status/0" do
    test "returns map with all limiter types" do
      status = Limiter.status()

      assert Map.has_key?(status, :file_ops)
      assert Map.has_key?(status, :api_calls)
      assert Map.has_key?(status, :tool_calls)

      assert status.file_ops.limit == 3
      assert status.api_calls.limit == 2
      assert status.tool_calls.limit == 4
    end

    test "available equals limit when no slots are in use" do
      status = Limiter.status()

      assert status.file_ops.available == status.file_ops.limit
      assert status.api_calls.available == status.api_calls.limit
      assert status.tool_calls.available == status.tool_calls.limit
      assert status.file_ops.in_use == 0
    end
  end

  describe "acquire/1 and release/1" do
    test "acquire returns :ok and increments in_use" do
      assert :ok = Limiter.acquire(:file_ops)

      status = Limiter.status()
      assert status.file_ops.in_use == 1
      assert status.file_ops.available == 2

      Limiter.release(:file_ops)
      Limiter.ping()

      status = Limiter.status()
      assert status.file_ops.in_use == 0
      assert status.file_ops.available == 3
    end

    test "acquire blocks when all slots are taken" do
      # Acquire all 2 api_calls slots
      :ok = Limiter.acquire(:api_calls)
      :ok = Limiter.acquire(:api_calls)

      status = Limiter.status()
      assert status.api_calls.available == 0

      test_pid = self()

      blocker =
        spawn(fn ->
          result = Limiter.acquire(:api_calls, timeout: 5_000)
          send(test_pid, {:acquired, result})
        end)

      # Give the acquire call time to reach the GenServer and be queued
      Process.sleep(300)

      # Release one slot — this should wake the blocker
      Limiter.release(:api_calls)

      # The blocker should now get the slot
      assert_receive {:acquired, :ok}, 5_000

      # Clean up
      Limiter.release(:api_calls)
      Process.exit(blocker, :kill)
    end

    test "acquire returns {:error, :timeout} on timeout" do
      # Acquire all 2 api_calls slots
      :ok = Limiter.acquire(:api_calls)
      :ok = Limiter.acquire(:api_calls)

      # Try to acquire with very short timeout
      result = Limiter.acquire(:api_calls, timeout: 100)

      assert result == {:error, :timeout}

      # Clean up
      Limiter.release(:api_calls)
      Limiter.release(:api_calls)
    end

    test "timed-out acquire is removed from waiter queue" do
      :ok = Limiter.acquire(:api_calls)
      :ok = Limiter.acquire(:api_calls)

      assert {:error, :timeout} = Limiter.acquire(:api_calls, timeout: 50)

      test_pid = self()

      spawn(fn ->
        result = Limiter.acquire(:api_calls, timeout: 5_000)
        send(test_pid, {:acquired_after_timeout, result})
      end)

      Process.sleep(100)
      Limiter.release(:api_calls)

      assert_receive {:acquired_after_timeout, :ok}, 5_000

      Limiter.release(:api_calls)
      Limiter.release(:api_calls)
    end

    test "FIFO ordering for waiters" do
      # Acquire all 2 api_calls slots
      :ok = Limiter.acquire(:api_calls)
      :ok = Limiter.acquire(:api_calls)

      test_pid = self()

      # Spawn first waiter
      spawn(fn ->
        :ok = Limiter.acquire(:api_calls, timeout: 10_000)
        send(test_pid, {:acquired, :first})
      end)

      # Ensure first waiter is queued
      Process.sleep(200)

      # Spawn second waiter
      spawn(fn ->
        :ok = Limiter.acquire(:api_calls, timeout: 10_000)
        send(test_pid, {:acquired, :second})
      end)

      # Ensure second waiter is queued
      Process.sleep(200)

      # Release first slot — first waiter should get it (FIFO)
      Limiter.release(:api_calls)
      assert_receive {:acquired, :first}, 5_000

      # Release second slot — second waiter should get it
      Limiter.release(:api_calls)
      assert_receive {:acquired, :second}, 5_000
    end
  end

  describe "try_acquire/1" do
    test "returns {:ok, ref} when slot available" do
      {:ok, ref} = Limiter.try_acquire(:file_ops)
      assert is_reference(ref)

      status = Limiter.status()
      assert status.file_ops.in_use == 1

      Limiter.release(:file_ops)
      Limiter.ping()
    end

    test "returns {:error, :unavailable} when no slots" do
      # Acquire all 2 api_calls slots
      {:ok, _} = Limiter.try_acquire(:api_calls)
      {:ok, _} = Limiter.try_acquire(:api_calls)

      assert {:error, :unavailable} = Limiter.try_acquire(:api_calls)

      Limiter.release(:api_calls)
      Limiter.release(:api_calls)
      Limiter.ping()
    end

    test "does not block" do
      # Acquire all slots
      for _ <- 1..2, do: {:ok, _} = Limiter.try_acquire(:api_calls)

      # This should return immediately, not block
      start = System.monotonic_time(:millisecond)
      result = Limiter.try_acquire(:api_calls)
      elapsed = System.monotonic_time(:millisecond) - start

      assert result == {:error, :unavailable}
      assert elapsed < 100

      # Clean up
      for _ <- 1..2, do: Limiter.release(:api_calls)
      Limiter.ping()
    end
  end

  describe "concurrent acquire/release" do
    test "maintains correct count under concurrent load" do
      # Spawn 20 processes that each acquire and release
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            :ok = Limiter.acquire(:tool_calls)
            Process.sleep(:rand.uniform(20))
            Limiter.release(:tool_calls)
            :ok
          end)
        end

      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, &(&1 == :ok))

      # Flush all pending casts
      Limiter.ping()

      # After all tasks complete, all slots should be free
      status = Limiter.status()
      assert status.tool_calls.in_use == 0
      assert status.tool_calls.available == 4
    end
  end

  describe "telemetry events" do
    test "emits acquire event on successful acquire" do
      handler_id = "test-acquire-#{:erlang.unique_integer()}"

      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:code_puppy, :concurrency, :acquire],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      :ok = Limiter.acquire(:file_ops)

      assert_receive {:telemetry, [:code_puppy, :concurrency, :acquire], measurements, metadata},
                     1_000

      assert Map.has_key?(measurements, :count)
      assert Map.has_key?(measurements, :limit)
      assert metadata.type == :file_ops

      :telemetry.detach(handler_id)
      Limiter.release(:file_ops)
    end

    test "emits release event on release" do
      handler_id = "test-release-#{:erlang.unique_integer()}"

      test_pid = self()

      :ok = Limiter.acquire(:file_ops)

      :telemetry.attach(
        handler_id,
        [:code_puppy, :concurrency, :release],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Limiter.release(:file_ops)

      assert_receive {:telemetry, [:code_puppy, :concurrency, :release], measurements, metadata},
                     1_000

      assert Map.has_key?(measurements, :count)
      assert Map.has_key?(measurements, :limit)
      assert metadata.type == :file_ops

      :telemetry.detach(handler_id)
    end
  end
end
