defmodule CodePuppyControl.AgentModelPinningTest do
  @moduledoc """
  Tests for the AgentModelPinning module.

  Covers:
  - Basic get/set/clear operations
  - List pins functionality
  - Effective model with fallback
  - Apply pinned model (matching Python API)
  - (unpin) marker handling
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.AgentModelPinning

  describe "get_pinned_model/1" do
    test "returns nil when agent has no pin" do
      assert AgentModelPinning.get_pinned_model("nonexistent-agent") == nil
    end

    test "returns the pinned model after setting" do
      :ok = AgentModelPinning.set_pinned_model("test-agent", "claude-sonnet")
      assert AgentModelPinning.get_pinned_model("test-agent") == "claude-sonnet"
    end
  end

  describe "set_pinned_model/2" do
    test "creates a new pin for an agent" do
      assert :ok = AgentModelPinning.set_pinned_model("agent-1", "model-a")
      assert AgentModelPinning.get_pinned_model("agent-1") == "model-a"
    end

    test "updates existing pin for an agent" do
      :ok = AgentModelPinning.set_pinned_model("agent-1", "model-a")
      :ok = AgentModelPinning.set_pinned_model("agent-1", "model-b")
      assert AgentModelPinning.get_pinned_model("agent-1") == "model-b"
    end

    test "handles multiple agents independently" do
      :ok = AgentModelPinning.set_pinned_model("agent-a", "model-1")
      :ok = AgentModelPinning.set_pinned_model("agent-b", "model-2")

      assert AgentModelPinning.get_pinned_model("agent-a") == "model-1"
      assert AgentModelPinning.get_pinned_model("agent-b") == "model-2"
    end
  end

  describe "clear_pinned_model/1" do
    test "removes the pin for an agent" do
      :ok = AgentModelPinning.set_pinned_model("agent-1", "model-a")
      :ok = AgentModelPinning.clear_pinned_model("agent-1")
      assert AgentModelPinning.get_pinned_model("agent-1") == nil
    end

    test "is idempotent - clearing nonexistent pin is ok" do
      assert :ok = AgentModelPinning.clear_pinned_model("never-pinned-agent")
      assert AgentModelPinning.get_pinned_model("never-pinned-agent") == nil
    end
  end

  describe "list_pins/0" do
    test "returns empty map when no pins exist" do
      assert AgentModelPinning.list_pins() == %{}
    end

    test "returns all pins as a map" do
      :ok = AgentModelPinning.set_pinned_model("agent-a", "model-1")
      :ok = AgentModelPinning.set_pinned_model("agent-b", "model-2")
      :ok = AgentModelPinning.set_pinned_model("agent-c", "model-3")

      pins = AgentModelPinning.list_pins()

      assert pins["agent-a"] == "model-1"
      assert pins["agent-b"] == "model-2"
      assert pins["agent-c"] == "model-3"
      assert map_size(pins) == 3
    end

    test "reflects cleared pins" do
      :ok = AgentModelPinning.set_pinned_model("agent-a", "model-1")
      :ok = AgentModelPinning.set_pinned_model("agent-b", "model-2")
      :ok = AgentModelPinning.clear_pinned_model("agent-a")

      pins = AgentModelPinning.list_pins()

      assert pins["agent-a"] == nil
      assert pins["agent-b"] == "model-2"
      assert map_size(pins) == 1
    end
  end

  describe "effective_model/2" do
    test "returns pinned model when pin exists" do
      :ok = AgentModelPinning.set_pinned_model("agent-1", "pinned-model")
      assert AgentModelPinning.effective_model("agent-1", "fallback-model") == "pinned-model"
    end

    test "returns fallback when no pin exists" do
      assert AgentModelPinning.effective_model("unpinned-agent", "fallback-model") ==
               "fallback-model"
    end

    test "returns nil fallback when no pin and no fallback" do
      assert AgentModelPinning.effective_model("unpinned-agent") == nil
    end
  end

  describe "apply_pinned_model/2" do
    test "sets the pin and returns model name" do
      result = AgentModelPinning.apply_pinned_model("agent-1", "model-a")

      assert result == "model-a"
      assert AgentModelPinning.get_pinned_model("agent-1") == "model-a"
    end

    test "unpins when given (unpin) marker and returns nil" do
      # First set a pin
      AgentModelPinning.set_pinned_model("agent-1", "model-a")
      assert AgentModelPinning.get_pinned_model("agent-1") == "model-a"

      # Then unpin
      result = AgentModelPinning.apply_pinned_model("agent-1", "(unpin)")

      assert result == nil
      assert AgentModelPinning.get_pinned_model("agent-1") == nil
    end

    test "(unpin) on non-pinned agent returns nil" do
      result = AgentModelPinning.apply_pinned_model("never-pinned", "(unpin)")
      assert result == nil
      assert AgentModelPinning.get_pinned_model("never-pinned") == nil
    end

    test "updating pin returns new model name" do
      AgentModelPinning.apply_pinned_model("agent-1", "model-a")
      result = AgentModelPinning.apply_pinned_model("agent-1", "model-b")

      assert result == "model-b"
      assert AgentModelPinning.get_pinned_model("agent-1") == "model-b"
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads safely" do
      :ok = AgentModelPinning.set_pinned_model("agent-1", "model-a")

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            AgentModelPinning.get_pinned_model("agent-1")
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == "model-a"))
    end

    test "handles mixed concurrent reads and writes" do
      :ok = AgentModelPinning.set_pinned_model("agent-1", "initial")

      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            # Alternate between reading and writing
            if rem(i, 2) == 0 do
              AgentModelPinning.set_pinned_model("agent-1", "updated-#{i}")
            else
              AgentModelPinning.get_pinned_model("agent-1")
            end
          end)
        end

      # Should complete without crashes
      Task.await_many(tasks)
      assert is_binary(AgentModelPinning.get_pinned_model("agent-1"))
    end
  end
end
