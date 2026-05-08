defmodule CodePuppyControl.Runtime.ConcurrencyLimiterTest do
  @moduledoc """
  Tests for Concurrency.Limiter — ETS-backed concurrency control with
  GenServer-coordinated blocking.

  Validates try_acquire, acquire/release, status, and fairness.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Concurrency.Limiter

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Concurrency.Supervisor
    )

    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(Limiter)

    Limiter.reset()

    :ok
  end

  # ---------------------------------------------------------------------------
  # Status
  # ---------------------------------------------------------------------------

  describe "status/0" do
    test "returns map with all limiter types" do
      status = Limiter.status()

      assert Map.has_key?(status, :file_ops)
      assert Map.has_key?(status, :api_calls)
      assert Map.has_key?(status, :tool_calls)
    end

    test "each type has limit, available, and in_use" do
      status = Limiter.status()

      for {_type, info} <- status do
        assert Map.has_key?(info, :limit)
        assert Map.has_key?(info, :available)
        assert Map.has_key?(info, :in_use)
        assert info.in_use == 0
        assert info.available == info.limit
      end
    end
  end

  # ---------------------------------------------------------------------------
  # try_acquire (non-blocking)
  # ---------------------------------------------------------------------------

  describe "try_acquire/1" do
    test "succeeds when capacity is available" do
      assert {:ok, _ref} = Limiter.try_acquire(:file_ops)
    end

    test "fails when capacity is exhausted" do
      # Get the limit
      status = Limiter.status()
      limit = status[:file_ops].limit

      # Consume all slots
      _refs =
        for _ <- 1..limit do
          assert {:ok, ref} = Limiter.try_acquire(:file_ops)
          ref
        end

      # Next should fail
      assert {:error, :unavailable} = Limiter.try_acquire(:file_ops)
    end

    test "returns error for uninitialized type" do
      # :nonexistent_type is not in the accepted types, so it should fail
      assert_raise FunctionClauseError, fn ->
        Limiter.try_acquire(:nonexistent_type_xyz)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # acquire (blocking)
  # ---------------------------------------------------------------------------

  describe "acquire/2" do
    test "acquires a slot immediately when available" do
      assert :ok = Limiter.acquire(:api_calls, timeout: 1_000)
    end

    test "returns timeout when no slot available" do
      # Get the limit and fill it
      status = Limiter.status()
      limit = status[:api_calls].limit

      for _ <- 1..limit do
        {:ok, _} = Limiter.try_acquire(:api_calls)
      end

      # Next acquire should timeout
      assert {:error, :timeout} = Limiter.acquire(:api_calls, timeout: 100)
    end
  end

  # ---------------------------------------------------------------------------
  # Release
  # ---------------------------------------------------------------------------

  describe "release/1" do
    test "releases a slot making it available again" do
      status = Limiter.status()
      limit = status[:tool_calls].limit

      # Fill all slots
      for _ <- 1..limit do
        {:ok, _} = Limiter.try_acquire(:tool_calls)
      end

      # Should be full
      assert {:error, :unavailable} = Limiter.try_acquire(:tool_calls)

      # Release one
      :ok = Limiter.release(:tool_calls)

      # Give the GenServer time to process the cast
      Limiter.ping()

      # Should be available again
      assert {:ok, _} = Limiter.try_acquire(:tool_calls)
    end

    test "release wakes a waiting caller" do
      status = Limiter.status()
      limit = status[:file_ops].limit

      # Fill all slots
      for _ <- 1..limit do
        {:ok, _} = Limiter.try_acquire(:file_ops)
      end

      # Start a waiting caller in another process
      caller = self()

      spawn(fn ->
        result = Limiter.acquire(:file_ops, timeout: 5_000)
        send(caller, {:acquired, result})
      end)

      # Give it a moment to register as a waiter
      Process.sleep(50)

      # Release a slot — should wake the waiter
      :ok = Limiter.release(:file_ops)

      # The waiting caller should acquire
      assert_receive {:acquired, :ok}, 2_000
    end
  end

  # ---------------------------------------------------------------------------
  # Ping
  # ---------------------------------------------------------------------------

  describe "ping/0" do
    test "returns :pong" do
      assert :pong = Limiter.ping()
    end
  end
end
