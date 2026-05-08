defmodule CodePuppyControl.ModelAvailabilityTest do
  @moduledoc """
  Tests for the ModelAvailability GenServer.

  Covers:
  - Starting fresh (all models healthy by default)
  - Terminal state marking and clearing
  - Sticky retry logic (available on first attempt, unavailable after consumed)
  - Not downgrading terminal to sticky
  - select_first_available picking first healthy, skipping unhealthy
  - select_first_available with all unavailable
  - reset_turn clearing consumed flags
  - reset_all clearing everything
  - Last resort model tracking (mark, check, list)
  - Concurrent access safety
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.ModelAvailability

  setup do
    # Clear last-resort table directly (no public API for full clear)
    # Wrapped in try/rescue as table may not exist if GenServer isn't running
    try do
      :ets.delete_all_objects(:model_last_resort)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # ============================================================================
  # Fresh State Tests
  # ============================================================================

  describe "fresh state" do
    test "all models are healthy by default" do
      assert ModelAvailability.snapshot("any-model") == %{available: true, reason: nil}
    end

    test "select_first_available picks first model when all healthy" do
      result = ModelAvailability.select_first_available(["model-a", "model-b", "model-c"])
      assert result.selected_model == "model-a"
      assert result.skipped == []
    end
  end

  # ============================================================================
  # Terminal State Tests
  # ============================================================================

  describe "mark_terminal/2" do
    test "marks model as unavailable" do
      assert :ok = ModelAvailability.mark_terminal("gpt-4", :quota)
      assert ModelAvailability.snapshot("gpt-4") == %{available: false, reason: :quota}
    end

    test "supports different reasons" do
      assert :ok = ModelAvailability.mark_terminal("gpt-4", :capacity)
      assert ModelAvailability.snapshot("gpt-4") == %{available: false, reason: :capacity}
    end

    test "defaults reason to :quota" do
      assert :ok = ModelAvailability.mark_terminal("gpt-4")
      assert ModelAvailability.snapshot("gpt-4") == %{available: false, reason: :quota}
    end
  end

  describe "mark_healthy/1" do
    test "clears terminal state" do
      :ok = ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok = ModelAvailability.mark_healthy("gpt-4")

      assert ModelAvailability.snapshot("gpt-4") == %{available: true, reason: nil}
    end

    test "succeeds for already-healthy model" do
      assert :ok = ModelAvailability.mark_healthy("never-marked")
      assert ModelAvailability.snapshot("never-marked") == %{available: true, reason: nil}
    end

    test "clears sticky state" do
      :ok = ModelAvailability.mark_sticky_retry("claude-3")
      :ok = ModelAvailability.consume_sticky_attempt("claude-3")
      :ok = ModelAvailability.mark_healthy("claude-3")

      assert ModelAvailability.snapshot("claude-3") == %{available: true, reason: nil}
    end
  end

  # ============================================================================
  # Sticky Retry Tests
  # ============================================================================

  describe "mark_sticky_retry/1" do
    test "model is available before consumed" do
      :ok = ModelAvailability.mark_sticky_retry("claude-3")
      assert ModelAvailability.snapshot("claude-3") == %{available: true, reason: nil}
    end

    test "model is unavailable after consumed" do
      :ok = ModelAvailability.mark_sticky_retry("claude-3")
      :ok = ModelAvailability.consume_sticky_attempt("claude-3")

      assert ModelAvailability.snapshot("claude-3") == %{
               available: false,
               reason: :retry_once_per_turn
             }
    end

    test "does not downgrade terminal to sticky" do
      :ok = ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok = ModelAvailability.mark_sticky_retry("gpt-4")

      # Should remain terminal, not sticky
      assert ModelAvailability.snapshot("gpt-4") == %{available: false, reason: :quota}
    end

    test "preserves consumed flag when re-marking sticky" do
      :ok = ModelAvailability.mark_sticky_retry("claude-3")
      :ok = ModelAvailability.consume_sticky_attempt("claude-3")

      # Re-marking sticky should preserve consumed state
      :ok = ModelAvailability.mark_sticky_retry("claude-3")

      assert ModelAvailability.snapshot("claude-3") == %{
               available: false,
               reason: :retry_once_per_turn
             }
    end
  end

  describe "consume_sticky_attempt/1" do
    test "marks sticky retry as consumed" do
      :ok = ModelAvailability.mark_sticky_retry("claude-3")
      :ok = ModelAvailability.consume_sticky_attempt("claude-3")

      assert ModelAvailability.snapshot("claude-3") == %{
               available: false,
               reason: :retry_once_per_turn
             }
    end

    test "succeeds for non-sticky models" do
      # No-op, shouldn't crash
      assert :ok = ModelAvailability.consume_sticky_attempt("healthy-model")
      assert :ok = ModelAvailability.consume_sticky_attempt("terminal-model")
    end
  end

  # ============================================================================
  # Model Selection Tests
  # ============================================================================

  describe "select_first_available/1" do
    test "picks first healthy model" do
      :ok = ModelAvailability.mark_terminal("model-a", :quota)
      :ok = ModelAvailability.mark_terminal("model-b", :capacity)

      result = ModelAvailability.select_first_available(["model-a", "model-b", "model-c"])

      assert result.selected_model == "model-c"
      assert result.skipped == [{"model-a", :quota}, {"model-b", :capacity}]
    end

    test "skips consumed sticky models" do
      :ok = ModelAvailability.mark_sticky_retry("model-a")
      :ok = ModelAvailability.consume_sticky_attempt("model-a")

      result = ModelAvailability.select_first_available(["model-a", "model-b"])

      assert result.selected_model == "model-b"
      assert result.skipped == [{"model-a", :retry_once_per_turn}]
    end

    test "picks unconsumed sticky models" do
      :ok = ModelAvailability.mark_sticky_retry("model-a")
      # Not consumed, so should be available

      result = ModelAvailability.select_first_available(["model-a", "model-b"])

      assert result.selected_model == "model-a"
      assert result.skipped == []
    end

    test "returns nil when all models unavailable" do
      :ok = ModelAvailability.mark_terminal("model-a", :quota)
      :ok = ModelAvailability.mark_terminal("model-b", :capacity)
      :ok = ModelAvailability.mark_sticky_retry("model-c")
      :ok = ModelAvailability.consume_sticky_attempt("model-c")

      result = ModelAvailability.select_first_available(["model-a", "model-b", "model-c"])

      assert result.selected_model == nil

      assert Enum.sort(result.skipped) == [
               {"model-a", :quota},
               {"model-b", :capacity},
               {"model-c", :retry_once_per_turn}
             ]
    end

    test "handles empty list" do
      result = ModelAvailability.select_first_available([])
      assert result.selected_model == nil
      assert result.skipped == []
    end
  end

  # ============================================================================
  # Reset Tests
  # ============================================================================

  describe "reset_turn/0" do
    test "clears consumed flag on sticky models" do
      :ok = ModelAvailability.mark_sticky_retry("claude-3")
      :ok = ModelAvailability.consume_sticky_attempt("claude-3")
      assert ModelAvailability.snapshot("claude-3").available == false

      :ok = ModelAvailability.reset_turn()

      assert ModelAvailability.snapshot("claude-3") == %{available: true, reason: nil}
    end

    test "preserves terminal state" do
      :ok = ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok = ModelAvailability.reset_turn()

      assert ModelAvailability.snapshot("gpt-4") == %{available: false, reason: :quota}
    end

    test "preserves unconsumed sticky state" do
      :ok = ModelAvailability.mark_sticky_retry("claude-3")
      # Don't consume
      :ok = ModelAvailability.reset_turn()

      assert ModelAvailability.snapshot("claude-3") == %{available: true, reason: nil}
    end
  end

  describe "reset_all/0" do
    test "clears terminal state" do
      :ok = ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok = ModelAvailability.reset_all()

      assert ModelAvailability.snapshot("gpt-4") == %{available: true, reason: nil}
    end

    test "clears sticky state" do
      :ok = ModelAvailability.mark_sticky_retry("claude-3")
      :ok = ModelAvailability.consume_sticky_attempt("claude-3")
      :ok = ModelAvailability.reset_all()

      assert ModelAvailability.snapshot("claude-3") == %{available: true, reason: nil}
    end

    test "does not affect last-resort tracking" do
      :ok = ModelAvailability.mark_terminal("gpt-4", :quota)
      :ok = ModelAvailability.mark_as_last_resort("gpt-4", true)
      :ok = ModelAvailability.reset_all()

      # Health cleared
      assert ModelAvailability.snapshot("gpt-4") == %{available: true, reason: nil}
      # Last-resort preserved
      assert ModelAvailability.is_last_resort("gpt-4") == true
    end
  end

  # ============================================================================
  # Last Resort Tests
  # ============================================================================

  describe "last-resort tracking" do
    test "mark_as_last_resort adds model" do
      :ok = ModelAvailability.mark_as_last_resort("cheap-model", true)
      assert ModelAvailability.is_last_resort("cheap-model") == true
    end

    test "mark_as_last_resort removes model when false" do
      :ok = ModelAvailability.mark_as_last_resort("cheap-model", true)
      :ok = ModelAvailability.mark_as_last_resort("cheap-model", false)
      assert ModelAvailability.is_last_resort("cheap-model") == false
    end

    test "get_last_resort_models returns all marked models" do
      :ok = ModelAvailability.mark_as_last_resort("model-a", true)
      :ok = ModelAvailability.mark_as_last_resort("model-b", true)
      :ok = ModelAvailability.mark_as_last_resort("model-c", true)

      models = ModelAvailability.get_last_resort_models()
      assert length(models) == 3
      assert "model-a" in models
      assert "model-b" in models
      assert "model-c" in models
    end

    test "unmarked models return false" do
      assert ModelAvailability.is_last_resort("never-marked") == false
    end

    test "returns empty list when no last-resort models" do
      assert ModelAvailability.get_last_resort_models() == []
    end
  end

  # ============================================================================
  # Concurrent Access Tests
  # ============================================================================

  describe "concurrent access" do
    test "multiple processes can read snapshots concurrently" do
      :ok = ModelAvailability.mark_terminal("terminal-model", :quota)
      :ok = ModelAvailability.mark_sticky_retry("sticky-model")

      tasks =
        for _ <- 1..100 do
          Task.async(fn ->
            snap1 = ModelAvailability.snapshot("terminal-model")
            snap2 = ModelAvailability.snapshot("sticky-model")
            snap3 = ModelAvailability.snapshot("healthy-model")
            {snap1, snap2, snap3}
          end)
        end

      results = Task.await_many(tasks)

      # All results should be consistent
      for {snap1, snap2, snap3} <- results do
        assert snap1 == %{available: false, reason: :quota}
        assert snap2 == %{available: true, reason: nil}
        assert snap3 == %{available: true, reason: nil}
      end
    end

    test "concurrent writes are properly serialized" do
      # Race multiple processes to mark models terminal
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            model = "model-#{rem(i, 10)}"
            :ok = ModelAvailability.mark_terminal(model, :quota)
            :ok = ModelAvailability.mark_sticky_retry(model)
            ModelAvailability.snapshot(model)
          end)
        end

      results = Task.await_many(tasks)

      # All snapshots should show either terminal or sticky (not corrupted)
      for snap <- results do
        assert snap.available == false or snap.reason in [:quota, :retry_once_per_turn]
      end
    end

    test "concurrent select_first_available is safe" do
      # Mark every other model as terminal
      for i <- 0..9 do
        if rem(i, 2) == 0 do
          :ok = ModelAvailability.mark_terminal("model-#{i}", :quota)
        end
      end

      models = for i <- 0..9, do: "model-#{i}"

      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            ModelAvailability.select_first_available(models)
          end)
        end

      results = Task.await_many(tasks)

      # All results should consistently pick the first odd-numbered model
      for result <- results do
        assert result.selected_model == "model-1"
        assert length(result.skipped) == 1
      end
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration scenarios" do
    test "typical quota-aware failover flow" do
      # Initial selection from preferred models
      preferred = ["gpt-4", "claude-3-opus", "claude-3-sonnet"]

      # GPT-4 hits quota
      :ok = ModelAvailability.mark_terminal("gpt-4", :quota)

      # Next selection skips GPT-4
      result = ModelAvailability.select_first_available(preferred)
      assert result.selected_model == "claude-3-opus"
      assert result.skipped == [{"gpt-4", :quota}]

      # Opus also hits quota
      :ok = ModelAvailability.mark_terminal("claude-3-opus", :quota)

      # Now falls back to sonnet
      result = ModelAvailability.select_first_available(preferred)
      assert result.selected_model == "claude-3-sonnet"
      assert result.skipped == [{"gpt-4", :quota}, {"claude-3-opus", :quota}]

      # All exhausted
      :ok = ModelAvailability.mark_terminal("claude-3-sonnet", :capacity)
      result = ModelAvailability.select_first_available(preferred)
      assert result.selected_model == nil
    end

    test "sticky retry flow" do
      # Model gets rate limited, try once more
      :ok = ModelAvailability.mark_sticky_retry("claude-3-haiku")

      # First attempt - available
      snap = ModelAvailability.snapshot("claude-3-haiku")
      assert snap.available == true

      # Consume the attempt
      :ok = ModelAvailability.consume_sticky_attempt("claude-3-haiku")

      # Now unavailable
      snap = ModelAvailability.snapshot("claude-3-haiku")
      assert snap.available == false

      # New turn resets
      :ok = ModelAvailability.reset_turn()
      snap = ModelAvailability.snapshot("claude-3-haiku")
      assert snap.available == true
    end
  end
end
