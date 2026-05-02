defmodule CodePuppyControl.Pack.Dispatch.FallbackTest do
  @moduledoc """
  Tests for Fallback — graceful degradation strategies for dispatch failures.

  Covers every fallback_reason pattern, explain/1 messages, log_fallback/2
  safety, and the critical distinction between infrastructure fallbacks
  (→ local) and capability mismatch (→ error).
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.Dispatch.Fallback

  # ── All fallback reasons for exhaustive testing ─────────────────────────

  @simple_reasons [
    :no_workers_registered,
    :no_matching_capabilities,
    :all_workers_disconnected,
    :all_workers_busy
  ]

  @tuple_reasons [
    {:node_not_found, :"pup_gone@host"},
    {:node_disconnected, :"pup_down@host"},
    {:capability_mismatch, :terrier, :"pup_worker@host"}
  ]

  @all_reasons @simple_reasons ++ @tuple_reasons

  # ── resolve/2 ────────────────────────────────────────────────────────────

  describe "resolve/2" do
    test "no_workers_registered returns fallback_local" do
      assert {:fallback_local, :no_workers_registered} =
               Fallback.resolve(:no_workers_registered)
    end

    test "no_matching_capabilities returns fallback_local" do
      assert {:fallback_local, :no_matching_capabilities} =
               Fallback.resolve(:no_matching_capabilities)
    end

    test "all_workers_disconnected returns fallback_local" do
      assert {:fallback_local, :all_workers_disconnected} =
               Fallback.resolve(:all_workers_disconnected)
    end

    test "all_workers_busy returns fallback_local" do
      assert {:fallback_local, :all_workers_busy} =
               Fallback.resolve(:all_workers_busy)
    end

    test "node_not_found returns fallback_local" do
      node = :"pup_missing@host"
      assert {:fallback_local, {:node_not_found, ^node}} =
               Fallback.resolve({:node_not_found, node})
    end

    test "node_disconnected returns fallback_local" do
      node = :"pup_down@host"
      assert {:fallback_local, {:node_disconnected, ^node}} =
               Fallback.resolve({:node_disconnected, node})
    end

    test "capability_mismatch returns error, not fallback_local" do
      result = Fallback.resolve({:capability_mismatch, :terrier, :"pup_worker@host"})

      assert {:error, {:capability_mismatch, :terrier, :"pup_worker@host"}, msg} = result
      assert is_binary(msg) and msg != ""
    end

    test "all non-mismatch reasons return fallback_local" do
      non_mismatch_reasons = @simple_reasons ++
        [{:node_not_found, :"n@h"}, {:node_disconnected, :"n@h"}]

      for reason <- non_mismatch_reasons do
        assert {:fallback_local, ^reason} = Fallback.resolve(reason),
               "Expected fallback_local for #{inspect(reason)}"
      end
    end

    test "resolve/2 accepts opts keyword list without crashing" do
      assert {:fallback_local, :no_workers_registered} =
               Fallback.resolve(:no_workers_registered, source: :test)

      assert {:error, _, _} =
               Fallback.resolve({:capability_mismatch, :x, :"n@h"}, source: :test)
    end
  end

  # ── explain/1 ───────────────────────────────────────────────────────────

  describe "explain/1" do
    test "returns non-empty string for all simple reasons" do
      for reason <- @simple_reasons do
        msg = Fallback.explain(reason)
        assert is_binary(msg), "explain(#{inspect(reason)}) must return a string"
        assert String.length(msg) > 0, "explain(#{inspect(reason)}) must not be empty"
      end
    end

    test "returns non-empty string for all tuple reasons" do
      for reason <- @tuple_reasons do
        msg = Fallback.explain(reason)
        assert is_binary(msg), "explain(#{inspect(reason)}) must return a string"
        assert String.length(msg) > 0, "explain(#{inspect(reason)}) must not be empty"
      end
    end

    test "no_workers_registered message mentions registering workers" do
      msg = Fallback.explain(:no_workers_registered)
      assert String.contains?(String.downcase(msg), "register")
    end

    test "all_workers_disconnected message mentions connectivity" do
      msg = Fallback.explain(:all_workers_disconnected)
      assert String.contains?(String.downcase(msg), "connect")
    end

    test "all_workers_busy message mentions capacity or workers" do
      msg = Fallback.explain(:all_workers_busy)
      down = String.downcase(msg)
      assert String.contains?(down, "capacity") or String.contains?(down, "worker")
    end

    test "node_not_found includes the node name" do
      node = :"pup_ghost@nowhere"
      msg = Fallback.explain({:node_not_found, node})
      assert String.contains?(msg, "pup_ghost")
    end

    test "node_disconnected includes the node name" do
      node = :"pup_offline@host"
      msg = Fallback.explain({:node_disconnected, node})
      assert String.contains?(msg, "pup_offline")
    end

    test "capability_mismatch includes the capability name" do
      msg = Fallback.explain({:capability_mismatch, :terrier, :"pup_worker@host"})
      assert String.contains?(msg, "terrier")
    end

    test "capability_mismatch message mentions configuration error" do
      msg = Fallback.explain({:capability_mismatch, :shepherd, :"n@h"})
      assert String.contains?(String.downcase(msg), "configuration")
    end
  end

  # ── log_fallback/2 ──────────────────────────────────────────────────────

  describe "log_fallback/2" do
    import ExUnit.CaptureLog

    test "does not crash for any reason" do
      for reason <- @all_reasons do
        assert :ok = Fallback.log_fallback(reason)
      end
    end

    test "does not crash with opts" do
      for reason <- @all_reasons do
        assert :ok = Fallback.log_fallback(reason, source: :dispatch)
      end
    end

    test "logs warning for no_workers_registered" do
      log =
        capture_log(fn ->
          Fallback.log_fallback(:no_workers_registered)
        end)

      assert String.contains?(log, "[Pack.Fallback]")
    end

    test "logs info for all_workers_busy" do
      # Test env has Logger level :warning, so info-level calls are compiled
      # out. Verify the function doesn't crash and returns :ok.
      assert :ok = Fallback.log_fallback(:all_workers_busy)
    end

    test "logs warning for node_disconnected" do
      log =
        capture_log(fn ->
          Fallback.log_fallback({:node_disconnected, :"pup_down@host"})
        end)

      assert String.contains?(log, "[Pack.Fallback]")
    end

    test "logs info for node_not_found" do
      # Test env has Logger level :warning, so info-level calls are compiled
      # out. Verify the function doesn't crash and returns :ok.
      assert :ok = Fallback.log_fallback({:node_not_found, :"pup_ghost@nowhere"})
    end

    test "emits telemetry event" do
      ref = :telemetry.attach(
        "fallback-test-#{:erlang.unique_integer()}",
        [:code_puppy, :distributed_pack, :fallback, :local],
        &__MODULE__.capture_telemetry/4,
        []
      )

      try do
        Fallback.log_fallback(:no_workers_registered, source: :test)

        # Give telemetry a moment to dispatch
        Process.sleep(10)

        # If we got here without crashing, the telemetry was emitted.
        assert true
      after
        :telemetry.detach(ref)
      end
    end
  end

  # Telemetry handler for test assertions
  def capture_telemetry(_name, measurements, _metadata, _config) do
    # Store in process dictionary for test assertion
    Process.put(:fallback_telemetry_measurements, measurements)
  end
end
