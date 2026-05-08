defmodule CodePuppyControl.LLM.ModelAvailabilityTest do
  @moduledoc """
  Port of tests/test_model_availability.py — ModelAvailability circuit breaker.

  Covers:
  - Initially all models are healthy
  - mark_terminal makes a model unavailable
  - mark_healthy clears terminal state
  - Sticky retry: available until consumed
  - Terminal not downgraded to sticky
  - select_first_available skips terminal models
  - reset_turn restores consumed sticky retries
  - reset_turn does NOT restore terminal models
  - reset_all clears everything
  - Last-resort model tracking
  - Concurrent access safety
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.ModelAvailability

  setup do
    # Ensure GenServer is running and reset to clean state
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelAvailability)
    ModelAvailability.reset_all()
    :ok
  end

  # ── Health Snapshots ─────────────────────────────────────────────────────

  describe "snapshot/1" do
    test "initially all models are healthy" do
      snap = ModelAvailability.snapshot("gpt-4")
      assert snap.available == true
      assert snap.reason == nil
    end

    test "mark_terminal makes model unavailable with reason" do
      ModelAvailability.mark_terminal("gpt-4", :quota)
      snap = ModelAvailability.snapshot("gpt-4")
      assert snap.available == false
      assert snap.reason == :quota
    end

    test "mark_healthy clears terminal state" do
      ModelAvailability.mark_terminal("gpt-4", :quota)
      ModelAvailability.mark_healthy("gpt-4")
      snap = ModelAvailability.snapshot("gpt-4")
      assert snap.available == true
      assert snap.reason == nil
    end

    test "mark_healthy is idempotent on healthy model" do
      ModelAvailability.mark_healthy("gpt-4")
      snap = ModelAvailability.snapshot("gpt-4")
      assert snap.available == true
    end
  end

  # ── Sticky Retry ────────────────────────────────────────────────────────

  describe "sticky retry" do
    test "sticky retry model is available until consumed" do
      ModelAvailability.mark_sticky_retry("gpt-4")
      assert ModelAvailability.snapshot("gpt-4").available == true

      ModelAvailability.consume_sticky_attempt("gpt-4")
      assert ModelAvailability.snapshot("gpt-4").available == false
    end

    test "terminal model is NOT downgraded to sticky" do
      ModelAvailability.mark_terminal("gpt-4", :quota)
      ModelAvailability.mark_sticky_retry("gpt-4")

      snap = ModelAvailability.snapshot("gpt-4")
      assert snap.available == false
      assert snap.reason == :quota
    end

    test "consume_sticky on non-sticky model is a no-op" do
      ModelAvailability.consume_sticky_attempt("never-sticky")
      # Should still be healthy (no entry in ETS)
      snap = ModelAvailability.snapshot("never-sticky")
      assert snap.available == true
    end

    test "double consume_sticky stays unavailable" do
      ModelAvailability.mark_sticky_retry("gpt-4")
      ModelAvailability.consume_sticky_attempt("gpt-4")
      ModelAvailability.consume_sticky_attempt("gpt-4")

      assert ModelAvailability.snapshot("gpt-4").available == false
    end
  end

  # ── Select First Available ──────────────────────────────────────────────

  describe "select_first_available/1" do
    test "selects first healthy model" do
      result = ModelAvailability.select_first_available(["model-a", "model-b", "model-c"])
      assert result.selected_model == "model-a"
      assert result.skipped == []
    end

    test "skips terminal models" do
      ModelAvailability.mark_terminal("model-a", :quota)
      result = ModelAvailability.select_first_available(["model-a", "model-b", "model-c"])
      assert result.selected_model == "model-b"
      assert length(result.skipped) == 1
      assert hd(result.skipped) == {"model-a", :quota}
    end

    test "returns nil when all models are down" do
      ModelAvailability.mark_terminal("a", :quota)
      ModelAvailability.mark_terminal("b", :capacity)
      result = ModelAvailability.select_first_available(["a", "b"])
      assert result.selected_model == nil
      assert length(result.skipped) == 2
    end

    test "skips consumed sticky models" do
      ModelAvailability.mark_sticky_retry("m1")
      ModelAvailability.consume_sticky_attempt("m1")

      result = ModelAvailability.select_first_available(["m1", "m2"])
      assert result.selected_model == "m2"
    end

    test "returns empty result for empty list" do
      result = ModelAvailability.select_first_available([])
      assert result.selected_model == nil
      assert result.skipped == []
    end
  end

  # ── Reset Turn ─────────────────────────────────────────────────────────

  describe "reset_turn/0" do
    test "restores consumed sticky retries" do
      ModelAvailability.mark_sticky_retry("gpt-4")
      ModelAvailability.consume_sticky_attempt("gpt-4")
      assert ModelAvailability.snapshot("gpt-4").available == false

      ModelAvailability.reset_turn()
      assert ModelAvailability.snapshot("gpt-4").available == true
    end

    test "does NOT restore terminal models" do
      ModelAvailability.mark_terminal("gpt-4", :quota)
      ModelAvailability.reset_turn()
      assert ModelAvailability.snapshot("gpt-4").available == false
    end
  end

  # ── Reset All ──────────────────────────────────────────────────────────

  describe "reset_all/0" do
    test "clears all health states" do
      ModelAvailability.mark_terminal("a", :quota)
      ModelAvailability.mark_sticky_retry("b")
      ModelAvailability.reset_all()
      assert ModelAvailability.snapshot("a").available == true
      assert ModelAvailability.snapshot("b").available == true
    end
  end

  # ── Last Resort ────────────────────────────────────────────────────────

  describe "last resort tracking" do
    test "mark and check last resort" do
      ModelAvailability.mark_as_last_resort("cheap-model", true)
      assert ModelAvailability.is_last_resort("cheap-model") == true
    end

    test "unmark last resort" do
      ModelAvailability.mark_as_last_resort("cheap-model", true)
      ModelAvailability.mark_as_last_resort("cheap-model", false)
      assert ModelAvailability.is_last_resort("cheap-model") == false
    end

    test "not last resort by default" do
      assert ModelAvailability.is_last_resort("unknown-model") == false
    end

    test "list last resort models" do
      ModelAvailability.mark_as_last_resort("model-a", true)
      ModelAvailability.mark_as_last_resort("model-b", true)
      models = ModelAvailability.get_last_resort_models() |> Enum.sort()
      assert "model-a" in models
      assert "model-b" in models
    end

    test "reset_all does NOT clear last resort table" do
      ModelAvailability.mark_as_last_resort("survivor", true)
      ModelAvailability.reset_all()
      assert ModelAvailability.is_last_resort("survivor") == true
    end
  end

  # ── Concurrent Access ─────────────────────────────────────────────────

  describe "concurrent access" do
    test "concurrent marks from multiple processes do not corrupt state" do
      tasks =
        for i <- 1..8 do
          Task.async(fn ->
            model_id = "m-#{i}"

            for _ <- 1..100 do
              ModelAvailability.mark_terminal(model_id, :quota)
              ModelAvailability.snapshot(model_id)
              ModelAvailability.mark_healthy(model_id)
              ModelAvailability.mark_sticky_retry(model_id)
              ModelAvailability.consume_sticky_attempt(model_id)
              ModelAvailability.reset_turn()
            end

            :ok
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end
end
