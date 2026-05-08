defmodule CodePuppyControl.Messaging.CommandsTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.Commands

  alias CodePuppyControl.Messaging.Commands.{
    CancelAgentCommand,
    InterruptShellCommand,
    UserInputResponse,
    ConfirmationResponse,
    SelectionResponse
  }

  # ---------------------------------------------------------------------------
  # Constructor tests
  # ---------------------------------------------------------------------------

  describe "cancel_agent/1" do
    test "builds with defaults" do
      cmd = Commands.cancel_agent()
      assert %CancelAgentCommand{} = cmd
      assert cmd.command_type == :cancel_agent
      assert byte_size(cmd.id) == 32
      assert is_integer(cmd.timestamp) and cmd.timestamp > 0
      assert cmd.reason == nil
    end

    test "accepts explicit id, timestamp, and reason" do
      cmd = Commands.cancel_agent(id: "custom-id", timestamp: 1234, reason: "too slow")
      assert cmd.id == "custom-id"
      assert cmd.timestamp == 1234
      assert cmd.reason == "too slow"
    end
  end

  describe "interrupt_shell/1" do
    test "builds with defaults" do
      cmd = Commands.interrupt_shell()
      assert %InterruptShellCommand{} = cmd
      assert cmd.command_type == :interrupt_shell
      assert cmd.command_id == nil
    end

    test "accepts command_id" do
      cmd = Commands.interrupt_shell(command_id: "shell-42")
      assert cmd.command_id == "shell-42"
    end
  end

  describe "user_input_response/3" do
    test "builds with prompt_id and value" do
      cmd = Commands.user_input_response("prompt-1", "hello world")
      assert %UserInputResponse{} = cmd
      assert cmd.prompt_id == "prompt-1"
      assert cmd.value == "hello world"
    end
  end

  describe "confirmation_response/3" do
    test "builds confirmed with feedback" do
      cmd = Commands.confirmation_response("prompt-2", true, feedback: "looks good")
      assert %ConfirmationResponse{} = cmd
      assert cmd.prompt_id == "prompt-2"
      assert cmd.confirmed == true
      assert cmd.feedback == "looks good"
    end

    test "builds denied without feedback" do
      cmd = Commands.confirmation_response("prompt-3", false)
      assert cmd.confirmed == false
      assert cmd.feedback == nil
    end
  end

  describe "selection_response/4" do
    test "returns ok tuple with valid index" do
      assert {:ok, cmd} = Commands.selection_response("prompt-4", 0, "option-a")
      assert %SelectionResponse{} = cmd
      assert cmd.prompt_id == "prompt-4"
      assert cmd.selected_index == 0
      assert cmd.selected_value == "option-a"
    end

    test "returns error tuple on negative selected_index" do
      assert {:error, {:invalid_selected_index, -1}} =
               Commands.selection_response("p", -1, "bad")
    end

    test "returns error tuple on non-integer selected_index" do
      assert {:error, {:invalid_selected_index, 1.5}} =
               Commands.selection_response("p", 1.5, "bad")
    end
  end

  describe "selection_response!/4" do
    test "returns struct directly on valid index" do
      cmd = Commands.selection_response!("prompt-5", 2, "opt-2")
      assert %SelectionResponse{} = cmd
      assert cmd.selected_index == 2
    end

    test "raises on negative selected_index" do
      assert_raise ArgumentError, ~r/non-negative/, fn ->
        Commands.selection_response!("p", -1, "bad")
      end
    end

    test "raises on non-integer selected_index" do
      assert_raise ArgumentError, ~r/non-negative/, fn ->
        Commands.selection_response!("p", 1.5, "bad")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Default id / timestamp generation
  # ---------------------------------------------------------------------------

  describe "default id and timestamp generation" do
    test "id is 32-char lowercase hex" do
      cmd = Commands.cancel_agent()
      assert Regex.match?(~r/^[0-9a-f]{32}$/, cmd.id)
    end

    test "ids are unique across calls" do
      ids = for _ <- 1..100, do: Commands.cancel_agent().id
      assert length(Enum.uniq(ids)) == 100
    end

    test "timestamp is positive integer (unix ms)" do
      cmd = Commands.cancel_agent()
      assert is_integer(cmd.timestamp)
      assert cmd.timestamp > 0
      # Should be a reasonable recent timestamp (after 2020-01-01)
      assert cmd.timestamp > 1_577_836_800_000
    end

    test "timestamp is auto-generated when absent in wire map" do
      wire = %{"command_type" => "cancel_agent"}
      assert {:ok, cmd} = Commands.from_wire(wire)
      assert is_integer(cmd.timestamp) and cmd.timestamp > 0
    end

    test "id is auto-generated when absent in wire map" do
      wire = %{"command_type" => "cancel_agent"}
      assert {:ok, cmd} = Commands.from_wire(wire)
      assert Regex.match?(~r/^[0-9a-f]{32}$/, cmd.id)
    end
  end

  # ---------------------------------------------------------------------------
  # to_wire / from_wire round-trip
  # ---------------------------------------------------------------------------

  describe "to_wire/1" do
    test "CancelAgentCommand serializes to string-keyed map" do
      cmd = Commands.cancel_agent(id: "abc", timestamp: 9999, reason: "stop")
      wire = Commands.to_wire(cmd)

      assert wire["command_type"] == "cancel_agent"
      assert wire["id"] == "abc"
      assert wire["timestamp"] == 9999
      assert wire["reason"] == "stop"
    end

    test "nil optional fields are omitted" do
      cmd = Commands.cancel_agent(id: "abc", timestamp: 9999)
      wire = Commands.to_wire(cmd)
      refute Map.has_key?(wire, "reason")
    end

    test "InterruptShellCommand with nil command_id omits it" do
      cmd = Commands.interrupt_shell(id: "x", timestamp: 1)
      wire = Commands.to_wire(cmd)
      refute Map.has_key?(wire, "command_id")
    end
  end

  describe "to_wire/from_wire round-trip" do
    test "CancelAgentCommand round-trip" do
      cmd = Commands.cancel_agent(id: "r1", timestamp: 1111, reason: "done")
      assert_round_trip(cmd)
    end

    test "CancelAgentCommand round-trip without reason" do
      cmd = Commands.cancel_agent(id: "r2", timestamp: 2222)
      assert_round_trip(cmd)
    end

    test "InterruptShellCommand round-trip with command_id" do
      cmd = Commands.interrupt_shell(id: "r3", timestamp: 3333, command_id: "sh-1")
      assert_round_trip(cmd)
    end

    test "InterruptShellCommand round-trip without command_id" do
      cmd = Commands.interrupt_shell(id: "r4", timestamp: 4444)
      assert_round_trip(cmd)
    end

    test "UserInputResponse round-trip" do
      cmd = Commands.user_input_response("p1", "my value", id: "r5", timestamp: 5555)
      assert_round_trip(cmd)
    end

    test "ConfirmationResponse round-trip confirmed with feedback" do
      cmd = Commands.confirmation_response("p2", true, id: "r6", timestamp: 6666, feedback: "ok")
      assert_round_trip(cmd)
    end

    test "ConfirmationResponse round-trip denied without feedback" do
      cmd = Commands.confirmation_response("p3", false, id: "r7", timestamp: 7777)
      assert_round_trip(cmd)
    end

    test "SelectionResponse round-trip" do
      {:ok, cmd} = Commands.selection_response("p4", 2, "choice-c", id: "r8", timestamp: 8888)
      assert_round_trip(cmd)
    end

    test "SelectionResponse round-trip with index 0" do
      {:ok, cmd} = Commands.selection_response("p5", 0, "first", id: "r9", timestamp: 9999)
      assert_round_trip(cmd)
    end
  end

  # ---------------------------------------------------------------------------
  # prompt_id correlation
  # ---------------------------------------------------------------------------

  describe "prompt_id correlation" do
    test "UserInputResponse preserves prompt_id through wire" do
      wire = %{
        "command_type" => "user_input_response",
        "id" => "w1",
        "timestamp" => 1000,
        "prompt_id" => "corr-1",
        "value" => "typed"
      }

      assert {:ok, %UserInputResponse{prompt_id: "corr-1", value: "typed"}} =
               Commands.from_wire(wire)
    end

    test "ConfirmationResponse preserves prompt_id through wire" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "w2",
        "timestamp" => 2000,
        "prompt_id" => "corr-2",
        "confirmed" => true
      }

      assert {:ok, %ConfirmationResponse{prompt_id: "corr-2", confirmed: true}} =
               Commands.from_wire(wire)
    end

    test "SelectionResponse preserves prompt_id through wire" do
      wire = %{
        "command_type" => "selection_response",
        "id" => "w3",
        "timestamp" => 3000,
        "prompt_id" => "corr-3",
        "selected_index" => 5,
        "selected_value" => "opt-5"
      }

      assert {:ok, %SelectionResponse{prompt_id: "corr-3", selected_index: 5}} =
               Commands.from_wire(wire)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp assert_round_trip(cmd) do
    wire = Commands.to_wire(cmd)
    {:ok, restored} = Commands.from_wire(wire)

    # All struct fields must match
    assert Map.from_struct(cmd) == Map.from_struct(restored),
           "Round-trip mismatch.\n  original: #{inspect(cmd)}\n  restored: #{inspect(restored)}"
  end
end
