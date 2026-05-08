defmodule CodePuppyControl.LLM.RoundRobinModelWave4Test do
  @moduledoc """
  Additional round-robin tests ported from tests/test_round_robin_model.py.

  The existing round_robin_model_test.exs covers basics; this file adds:
  - Three-model rotation sequences
  - Large rotate_every values
  - Rotation tracking correctness (request_count, current_index)
  - Model name display formatting
  - Single model no-rotation invariant
  - Advance-and-get detailed state tracking
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.RoundRobinModel

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RoundRobinModel)
    :ok = RoundRobinModel.configure(models: ["model-a", "model-b", "model-c"])
    :ok
  end

  # ── Three-Model Rotation ────────────────────────────────────────────────

  describe "three-model rotation" do
    test "cycles through all three models and repeats" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2", "m3"], rotate_every: 1)

      expected = ["m1", "m2", "m3", "m1", "m2", "m3"]
      actual = for _ <- 1..6, do: RoundRobinModel.advance_and_get()
      assert actual == expected
    end

    test "rotation with rotate_every=2 stays on each model twice" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2"], rotate_every: 2)

      # Two calls → stay on m1
      assert RoundRobinModel.advance_and_get() == "m1"
      assert RoundRobinModel.advance_and_get() == "m1"

      # Two calls → stay on m2
      assert RoundRobinModel.advance_and_get() == "m2"
      assert RoundRobinModel.advance_and_get() == "m2"

      # Wrap → m1 again
      assert RoundRobinModel.advance_and_get() == "m1"
    end
  end

  # ── Large rotate_every ──────────────────────────────────────────────────

  describe "large rotate_every" do
    test "stays on first model for many calls before rotating" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2"], rotate_every: 5)

      # First 4 calls: stay on m1 (count goes 1-4)
      for _ <- 1..4 do
        assert RoundRobinModel.advance_and_get() == "m1"
      end

      state = RoundRobinModel.get_state()
      assert state.request_count == 4
      assert state.current_index == 0

      # 5th call: returns m1, but rotates to m2 after
      assert RoundRobinModel.advance_and_get() == "m1"
      state = RoundRobinModel.get_state()
      assert state.current_index == 1
      assert state.request_count == 0

      # Next call returns m2
      assert RoundRobinModel.advance_and_get() == "m2"
    end

    test "large rotate_every=100" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2"], rotate_every: 100)

      # 99 calls: stay on m1
      for _ <- 1..99 do
        assert RoundRobinModel.advance_and_get() == "m1"
      end

      state = RoundRobinModel.get_state()
      assert state.request_count == 99
      assert state.current_index == 0

      # 100th call: returns m1 but triggers rotation
      assert RoundRobinModel.advance_and_get() == "m1"
      state = RoundRobinModel.get_state()
      assert state.current_index == 1
      assert state.request_count == 0

      # Next call returns m2
      assert RoundRobinModel.advance_and_get() == "m2"
    end
  end

  # ── Single Model Invariant ─────────────────────────────────────────────

  describe "single model no-rotation invariant" do
    test "single model always returns same model regardless of rotate_every" do
      :ok = RoundRobinModel.configure(models: ["only-one"], rotate_every: 3)

      for _ <- 1..10 do
        assert RoundRobinModel.advance_and_get() == "only-one"
      end

      state = RoundRobinModel.get_state()
      # With single model, index wraps back to 0 each time
      assert state.current_index == 0
    end
  end

  # ── State Tracking ─────────────────────────────────────────────────────

  describe "rotation state tracking" do
    test "tracks request_count correctly with rotate_every=3" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2"], rotate_every: 3)

      # Call 1
      RoundRobinModel.advance_and_get()
      state = RoundRobinModel.get_state()
      assert state.request_count == 1
      assert state.current_index == 0

      # Call 2
      RoundRobinModel.advance_and_get()
      state = RoundRobinModel.get_state()
      assert state.request_count == 2
      assert state.current_index == 0

      # Call 3 — rotates
      RoundRobinModel.advance_and_get()
      state = RoundRobinModel.get_state()
      assert state.request_count == 0
      assert state.current_index == 1
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────

  describe "configure validation" do
    test "rejects empty models list" do
      assert {:error, :empty_models} = RoundRobinModel.configure(models: [])
    end

    test "rejects rotate_every of 0" do
      assert {:error, :invalid_rotate_every} =
               RoundRobinModel.configure(models: ["m1"], rotate_every: 0)
    end

    test "rejects negative rotate_every" do
      assert {:error, :invalid_rotate_every} =
               RoundRobinModel.configure(models: ["m1"], rotate_every: -5)
    end
  end

  # ── get_state/0 ─────────────────────────────────────────────────────────

  describe "get_state/0" do
    test "returns map with expected keys" do
      :ok = RoundRobinModel.configure(models: ["a", "b"], rotate_every: 2)
      state = RoundRobinModel.get_state()

      assert Map.has_key?(state, :models)
      assert Map.has_key?(state, :current_index)
      assert Map.has_key?(state, :rotate_every)
      assert Map.has_key?(state, :request_count)
      assert state.models == ["a", "b"]
      assert state.rotate_every == 2
    end
  end

  # ── list_models/0 ──────────────────────────────────────────────────────

  describe "list_models/0" do
    test "returns configured models list" do
      :ok = RoundRobinModel.configure(models: ["x", "y", "z"])
      assert RoundRobinModel.list_models() == ["x", "y", "z"]
    end
  end
end
