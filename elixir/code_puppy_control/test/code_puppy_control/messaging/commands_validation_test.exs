defmodule CodePuppyControl.Messaging.CommandsValidationTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.Commands

  alias CodePuppyControl.Messaging.Commands.{
    ConfirmationResponse,
    SelectionResponse
  }

  # ---------------------------------------------------------------------------
  # selected_index validation
  # ---------------------------------------------------------------------------

  describe "selected_index validation" do
    test "rejects negative selected_index in from_wire" do
      wire = %{
        "command_type" => "selection_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "selected_index" => -1,
        "selected_value" => "bad"
      }

      assert {:error, :invalid_selected_index} = Commands.from_wire(wire)
    end

    test "rejects float selected_index in from_wire" do
      wire = %{
        "command_type" => "selection_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "selected_index" => 1.5,
        "selected_value" => "bad"
      }

      assert {:error, :invalid_selected_index} = Commands.from_wire(wire)
    end

    test "rejects string selected_index in from_wire" do
      wire = %{
        "command_type" => "selection_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "selected_index" => "two",
        "selected_value" => "bad"
      }

      assert {:error, :invalid_selected_index} = Commands.from_wire(wire)
    end

    test "accepts zero selected_index" do
      wire = %{
        "command_type" => "selection_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "selected_index" => 0,
        "selected_value" => "first"
      }

      assert {:ok, %SelectionResponse{selected_index: 0}} = Commands.from_wire(wire)
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown command_type rejection
  # ---------------------------------------------------------------------------

  describe "unknown command_type rejection" do
    test "rejects unknown command_type" do
      wire = %{"command_type" => "fire_missiles", "id" => "x", "timestamp" => 1}
      assert {:error, :unknown_command_type} = Commands.from_wire(wire)
    end

    test "rejects missing command_type" do
      wire = %{"id" => "x", "timestamp" => 1}
      assert {:error, :missing_command_type} = Commands.from_wire(wire)
    end

    test "rejects non-string command_type" do
      wire = %{"command_type" => 42, "id" => "x", "timestamp" => 1}
      assert {:error, :missing_command_type} = Commands.from_wire(wire)
    end
  end

  # ---------------------------------------------------------------------------
  # Extra / unknown fields rejection
  # ---------------------------------------------------------------------------

  describe "extra fields rejection" do
    test "CancelAgentCommand rejects unknown field" do
      wire = %{
        "command_type" => "cancel_agent",
        "id" => "x",
        "timestamp" => 1,
        "surprise" => "boo"
      }

      assert {:error, :extra_fields_not_allowed} = Commands.from_wire(wire)
    end

    test "UserInputResponse rejects unknown field" do
      wire = %{
        "command_type" => "user_input_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "value" => "v",
        "extra_field" => "nope"
      }

      assert {:error, :extra_fields_not_allowed} = Commands.from_wire(wire)
    end

    test "SelectionResponse rejects unknown field" do
      wire = %{
        "command_type" => "selection_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "selected_index" => 0,
        "selected_value" => "v",
        "bonus" => true
      }

      assert {:error, :extra_fields_not_allowed} = Commands.from_wire(wire)
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed payloads
  # ---------------------------------------------------------------------------

  describe "malformed payload handling" do
    test "rejects non-map input" do
      assert {:error, :not_a_map} = Commands.from_wire("string")
      assert {:error, :not_a_map} = Commands.from_wire(42)
      assert {:error, :not_a_map} = Commands.from_wire(nil)
      assert {:error, :not_a_map} = Commands.from_wire([1, 2, 3])
    end

    test "rejects missing required field: prompt_id on UserInputResponse" do
      wire = %{
        "command_type" => "user_input_response",
        "id" => "x",
        "timestamp" => 1,
        "value" => "v"
      }

      assert {:error, {:missing_required_field, "prompt_id"}} = Commands.from_wire(wire)
    end

    test "rejects missing required field: value on UserInputResponse" do
      wire = %{
        "command_type" => "user_input_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p"
      }

      assert {:error, {:missing_required_field, "value"}} = Commands.from_wire(wire)
    end

    test "rejects missing required field: confirmed on ConfirmationResponse" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p"
      }

      assert {:error, {:missing_required_field, "confirmed"}} = Commands.from_wire(wire)
    end

    test "rejects wrong type for confirmed (string instead of bool)" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "confirmed" => "yes"
      }

      assert {:error, {:invalid_field_type, "confirmed"}} = Commands.from_wire(wire)
    end

    test "rejects wrong type for id (integer instead of string)" do
      wire = %{"command_type" => "cancel_agent", "id" => 123, "timestamp" => 1}
      assert {:error, {:invalid_field_type, "id"}} = Commands.from_wire(wire)
    end

    test "rejects wrong type for timestamp (string instead of integer)" do
      wire = %{"command_type" => "cancel_agent", "id" => "x", "timestamp" => "now"}
      assert {:error, {:invalid_field_type, "timestamp"}} = Commands.from_wire(wire)
    end

    test "rejects wrong type for prompt_id (integer instead of string)" do
      wire = %{
        "command_type" => "user_input_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => 42,
        "value" => "v"
      }

      assert {:error, {:invalid_field_type, "prompt_id"}} = Commands.from_wire(wire)
    end
  end

  # ---------------------------------------------------------------------------
  # Optional field type validation (negative tests)
  # ---------------------------------------------------------------------------

  describe "optional field type validation" do
    # -- feedback on ConfirmationResponse ---------------------------------------

    test "rejects integer feedback on ConfirmationResponse" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "confirmed" => true,
        "feedback" => 42
      }

      assert {:error, {:invalid_field_type, "feedback"}} = Commands.from_wire(wire)
    end

    test "rejects boolean feedback on ConfirmationResponse" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "confirmed" => true,
        "feedback" => true
      }

      assert {:error, {:invalid_field_type, "feedback"}} = Commands.from_wire(wire)
    end

    test "rejects list feedback on ConfirmationResponse" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "confirmed" => true,
        "feedback" => ["nope"]
      }

      assert {:error, {:invalid_field_type, "feedback"}} = Commands.from_wire(wire)
    end

    test "rejects map feedback on ConfirmationResponse" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "confirmed" => true,
        "feedback" => %{"text" => "nope"}
      }

      assert {:error, {:invalid_field_type, "feedback"}} = Commands.from_wire(wire)
    end

    test "accepts nil feedback on ConfirmationResponse" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "confirmed" => true,
        "feedback" => nil
      }

      assert {:ok, %ConfirmationResponse{feedback: nil}} = Commands.from_wire(wire)
    end

    test "accepts string feedback on ConfirmationResponse" do
      wire = %{
        "command_type" => "confirmation_response",
        "id" => "x",
        "timestamp" => 1,
        "prompt_id" => "p",
        "confirmed" => true,
        "feedback" => "approved"
      }

      assert {:ok, %ConfirmationResponse{feedback: "approved"}} = Commands.from_wire(wire)
    end

    # -- reason on CancelAgentCommand -------------------------------------------

    test "rejects integer reason on CancelAgentCommand" do
      wire = %{
        "command_type" => "cancel_agent",
        "id" => "x",
        "timestamp" => 1,
        "reason" => 42
      }

      assert {:error, {:invalid_field_type, "reason"}} = Commands.from_wire(wire)
    end

    test "rejects boolean reason on CancelAgentCommand" do
      wire = %{
        "command_type" => "cancel_agent",
        "id" => "x",
        "timestamp" => 1,
        "reason" => true
      }

      assert {:error, {:invalid_field_type, "reason"}} = Commands.from_wire(wire)
    end

    # -- command_id on InterruptShellCommand -------------------------------------

    test "rejects integer command_id on InterruptShellCommand" do
      wire = %{
        "command_type" => "interrupt_shell",
        "id" => "x",
        "timestamp" => 1,
        "command_id" => 42
      }

      assert {:error, {:invalid_field_type, "command_id"}} = Commands.from_wire(wire)
    end

    test "rejects boolean command_id on InterruptShellCommand" do
      wire = %{
        "command_type" => "interrupt_shell",
        "id" => "x",
        "timestamp" => 1,
        "command_id" => true
      }

      assert {:error, {:invalid_field_type, "command_id"}} = Commands.from_wire(wire)
    end
  end

  # ---------------------------------------------------------------------------
  # JSON encode/decode round-trip
  # ---------------------------------------------------------------------------

  describe "JSON encode/decode round-trip" do
    test "CancelAgentCommand survives JSON serialization" do
      cmd = Commands.cancel_agent(id: "json-1", timestamp: 1111, reason: "json test")
      assert_json_round_trip(cmd)
    end

    test "InterruptShellCommand survives JSON serialization" do
      cmd = Commands.interrupt_shell(id: "json-2", timestamp: 2222, command_id: "sh-j")
      assert_json_round_trip(cmd)
    end

    test "UserInputResponse survives JSON serialization" do
      cmd = Commands.user_input_response("jp-1", "typed", id: "json-3", timestamp: 3333)
      assert_json_round_trip(cmd)
    end

    test "ConfirmationResponse survives JSON serialization" do
      cmd =
        Commands.confirmation_response("jp-2", true,
          id: "json-4",
          timestamp: 4444,
          feedback: "approved"
        )

      assert_json_round_trip(cmd)
    end

    test "ConfirmationResponse false without feedback survives JSON serialization" do
      cmd = Commands.confirmation_response("jp-3", false, id: "json-5", timestamp: 5555)
      assert_json_round_trip(cmd)
    end

    test "SelectionResponse survives JSON serialization" do
      {:ok, cmd} = Commands.selection_response("jp-4", 3, "opt-3", id: "json-6", timestamp: 6666)
      assert_json_round_trip(cmd)
    end

    test "malformed JSON string returns error from from_wire" do
      # This is actually testing that from_wire rejects non-maps
      assert {:error, :not_a_map} = Commands.from_wire("not json")
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp assert_json_round_trip(cmd) do
    wire = Commands.to_wire(cmd)
    {:ok, json} = Jason.encode(wire)
    {:ok, decoded} = Jason.decode(json)
    {:ok, restored} = Commands.from_wire(decoded)

    assert Map.from_struct(cmd) == Map.from_struct(restored),
           "JSON round-trip mismatch.\n  original: #{inspect(cmd)}\n  restored: #{inspect(restored)}"
  end
end
