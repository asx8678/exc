defmodule CodePuppyControl.RequestTrackerTest do
  @moduledoc """
  Tests for the RequestTracker module.

  The RequestTracker is responsible for:
  - Registering pending requests
  - Correlating responses with their original requests via request_id
  - Handling timeouts
  - Cleaning up stale requests
  """

  use ExUnit.Case, async: true

  @moduletag :integration

  alias CodePuppyControl.RequestTracker

  # Start a fresh RequestTracker for each test to avoid interference
  setup do
    # Start an isolated RequestTracker
    {:ok, tracker} = RequestTracker.start_link(name: __MODULE__)

    # Override module attribute for this test
    on_exit(fn ->
      if Process.alive?(tracker), do: GenServer.stop(tracker)
    end)

    %{tracker: tracker}
  end

  describe "pending request tracking" do
    test "tracks pending request and resolves on response", %{tracker: tracker} do
      request_id = "test-req-1"
      method = "initialize"

      # Spawn a task to await the request (simulating the PythonWorker.Port call)
      caller = self()

      spawn(fn ->
        # We need to use the named tracker
        result = GenServer.call(tracker, {:register, request_id, method, 5000})
        send(caller, {:result, result})
      end)

      # Small delay to ensure registration
      Process.sleep(50)

      # Check stats - should have 1 pending
      stats = GenServer.call(tracker, :stats)
      assert stats.pending == 1

      # Complete the request
      assert :ok = GenServer.call(tracker, {:complete, request_id, %{"status" => "ok"}})

      # Caller should receive the result
      assert_receive {:result, {:ok, %{"status" => "ok"}}}, 1000

      # Stats should show 0 pending
      stats = GenServer.call(tracker, :stats)
      assert stats.pending == 0
    end

    test "completes multiple concurrent requests correctly", %{tracker: tracker} do
      # Start multiple concurrent requests
      caller = self()

      for i <- 1..5 do
        spawn(fn ->
          result = GenServer.call(tracker, {:register, "req-#{i}", "test", 5000})
          send(caller, {:result, i, result})
        end)
      end

      Process.sleep(50)

      # Complete them in reverse order
      for i <- 5..1//-1 do
        assert :ok = GenServer.call(tracker, {:complete, "req-#{i}", %{"index" => i}})
      end

      # Collect results to verify completion
      for i <- 1..5 do
        assert_receive {:result, ^i, {:ok, %{"index" => ^i}}}, 1000
      end

      # All should have been completed
      stats = GenServer.call(tracker, :stats)
      assert stats.pending == 0
    end

    test "completes request with error response", %{tracker: tracker} do
      request_id = "test-req-error"
      method = "risky_operation"

      caller = self()

      spawn(fn ->
        result = GenServer.call(tracker, {:register, request_id, method, 5000})
        send(caller, {:result, result})
      end)

      Process.sleep(50)

      # Fail the request
      assert :ok =
               GenServer.call(
                 tracker,
                 {:fail, request_id, %{"code" => -32600, "message" => "Invalid"}}
               )

      # Caller should receive error
      assert_receive {:result, {:error, %{"code" => -32600, "message" => "Invalid"}}}, 1000
    end

    test "ignores unknown prompt_id responses", %{tracker: tracker} do
      # Try to complete a request that doesn't exist
      result = GenServer.call(tracker, {:complete, "nonexistent-id", %{"status" => "ok"}})
      assert result == {:error, :not_found}

      # Try to fail a request that doesn't exist
      result = GenServer.call(tracker, {:fail, "nonexistent-id", "error"})
      assert result == {:error, :not_found}
    end

    test "double completion is idempotent (second returns not_found)", %{tracker: tracker} do
      request_id = "test-double"

      spawn(fn ->
        GenServer.call(tracker, {:register, request_id, "test", 5000})
      end)

      Process.sleep(50)

      # First completion works
      assert :ok = GenServer.call(tracker, {:complete, request_id, %{"status" => "ok"}})

      # Second completion returns not_found (already completed)
      assert {:error, :not_found} =
               GenServer.call(tracker, {:complete, request_id, %{"status" => "ok"}})
    end
  end

  describe "timeout handling" do
    test "times out stale requests", %{tracker: tracker} do
      request_id = "test-timeout"
      method = "slow_operation"

      caller = self()

      spawn(fn ->
        result = GenServer.call(tracker, {:register, request_id, method, 100})
        send(caller, {:result, result})
      end)

      Process.sleep(50)

      # Check it's pending
      stats = GenServer.call(tracker, :stats)
      assert stats.pending == 1

      # Wait for timeout (100ms + margin)
      assert_receive {:result, {:error, :timeout}}, 500

      # Should be removed from pending
      stats = GenServer.call(tracker, :stats)
      assert stats.pending == 0
    end

    test "timeout timer is cancelled on successful completion", %{tracker: tracker} do
      request_id = "test-no-timeout"
      method = "fast_operation"

      caller = self()

      spawn(fn ->
        # Register with 200ms timeout
        result = GenServer.call(tracker, {:register, request_id, method, 200})
        send(caller, {:result, result})
      end)

      Process.sleep(50)

      # Complete quickly (before timeout)
      assert :ok = GenServer.call(tracker, {:complete, request_id, %{"fast" => true}})

      # Should receive success immediately
      assert_receive {:result, {:ok, %{"fast" => true}}}, 100

      # Wait past the original timeout to make sure no timeout message arrives
      refute_receive {:result, {:error, :timeout}}, 300
    end
  end

  describe "stats tracking" do
    test "returns correct pending count", %{tracker: tracker} do
      # Initially empty
      stats = GenServer.call(tracker, :stats)
      assert stats.pending == 0
      assert stats.oldest_ms == nil

      # Add some requests (fire and forget registrations)
      for i <- 1..3 do
        spawn(fn ->
          GenServer.call(tracker, {:register, "stat-req-#{i}", "test", 5000})
        end)
      end

      Process.sleep(50)

      stats = GenServer.call(tracker, :stats)
      assert stats.pending == 3
      assert stats.oldest_ms >= 0
    end

    @tag :flaky
    test "oldest_ms reflects age of oldest pending request", %{tracker: tracker} do
      # This test is timing-sensitive and may be flaky on slower systems
      caller = self()

      # Add first request
      spawn(fn ->
        result = GenServer.call(tracker, {:register, "first-req", "test", 5000})
        send(caller, {:first_done, result})
      end)

      # Wait for first request to be pending
      Process.sleep(50)

      stats_first = GenServer.call(tracker, :stats)
      assert stats_first.pending == 1
      first_oldest = stats_first.oldest_ms

      # Should have some age after 50ms
      assert first_oldest >= 40

      # Add another request
      spawn(fn ->
        result = GenServer.call(tracker, {:register, "second-req", "test", 5000})
        send(caller, {:second_done, result})
      end)

      Process.sleep(20)

      stats_second = GenServer.call(tracker, :stats)
      # Should now have 2 pending requests
      assert stats_second.pending == 2
      # The oldest is still from first-req
      # The second request is newer, so oldest should still be first_oldest or greater
      assert stats_second.oldest_ms >= first_oldest

      # Complete both
      GenServer.call(tracker, {:complete, "first-req", :ok})
      GenServer.call(tracker, {:complete, "second-req", :ok})

      # Wait for completions
      assert_receive {:first_done, {:ok, :ok}}, 500
      assert_receive {:second_done, {:ok, :ok}}, 500
    end
  end

  describe "edge cases" do
    test "handles rapid register/complete cycles", %{tracker: tracker} do
      # Rapidly create and complete many requests
      for i <- 1..100 do
        caller = self()
        req_id = "rapid-#{i}"

        spawn(fn ->
          result = GenServer.call(tracker, {:register, req_id, "test", 1000})
          send(caller, {:done, i, result})
        end)

        Process.sleep(1)
        GenServer.call(tracker, {:complete, req_id, %{"i" => i}})

        assert_receive {:done, ^i, {:ok, %{"i" => ^i}}}, 500
      end

      stats = GenServer.call(tracker, :stats)
      assert stats.pending == 0
    end

    test "survives completing already-timed-out request", %{tracker: tracker} do
      request_id = "race-condition"

      spawn(fn ->
        GenServer.call(tracker, {:register, request_id, "test", 50})
      end)

      Process.sleep(50)

      # Try to complete after timeout (race condition scenario)
      # This should return not_found since it's already timed out
      result = GenServer.call(tracker, {:complete, request_id, %{"late" => true}})
      assert result == {:error, :not_found}
    end

    test "handles mixed success and failure completions", %{tracker: tracker} do
      caller = self()

      # Start 4 requests
      for i <- 1..4 do
        spawn(fn ->
          result = GenServer.call(tracker, {:register, "mixed-#{i}", "test", 1000})
          send(caller, {:result, i, result})
        end)
      end

      Process.sleep(50)

      # Complete some successfully, fail others
      GenServer.call(tracker, {:complete, "mixed-1", %{"status" => "ok"}})
      GenServer.call(tracker, {:fail, "mixed-2", %{"error" => "failed"}})
      GenServer.call(tracker, {:complete, "mixed-3", %{"status" => "ok"}})
      GenServer.call(tracker, {:fail, "mixed-4", %{"error" => "also failed"}})

      # Collect all results
      results =
        for _ <- 1..4 do
          receive do
            {:result, i, result} -> {i, result}
          after
            500 -> {0, :timeout}
          end
        end
        |> Map.new()

      assert map_size(results) == 4
      assert results[1] == {:ok, %{"status" => "ok"}}
      assert results[2] == {:error, %{"error" => "failed"}}
      assert results[3] == {:ok, %{"status" => "ok"}}
      assert results[4] == {:error, %{"error" => "also failed"}}
    end
  end

  describe "different request_id types" do
    test "handles string request_ids", %{tracker: tracker} do
      caller = self()

      spawn(fn ->
        result = GenServer.call(tracker, {:register, "string-id", "test", 1000})
        send(caller, {:result, result})
      end)

      Process.sleep(10)
      GenServer.call(tracker, {:complete, "string-id", %{"ok" => true}})

      assert_receive {:result, {:ok, %{"ok" => true}}}, 500
    end

    test "handles integer request_ids", %{tracker: tracker} do
      caller = self()

      spawn(fn ->
        result = GenServer.call(tracker, {:register, 42, "test", 1000})
        send(caller, {:result, result})
      end)

      Process.sleep(10)
      GenServer.call(tracker, {:complete, 42, %{"ok" => true}})

      assert_receive {:result, {:ok, %{"ok" => true}}}, 500
    end
  end
end
