defmodule CodePuppyControl.Messaging.UserInteractionTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.UserInteraction — user interaction message constructors.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.{UserInteraction, WireEvent}

  # ===========================================================================
  # UserInputRequest
  # ===========================================================================

  describe "user_input_request/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        UserInteraction.user_input_request(%{
          "prompt_id" => "pid-1",
          "prompt_text" => "Enter your name:"
        })

      assert msg["category"] == "user_interaction"
      assert msg["prompt_id"] == "pid-1"
      assert msg["prompt_text"] == "Enter your name:"
      assert msg["default_value"] == nil
      assert msg["input_type"] == "text"
    end

    test "accepts password input_type" do
      {:ok, msg} =
        UserInteraction.user_input_request(%{
          "prompt_id" => "pid-2",
          "prompt_text" => "Enter password:",
          "input_type" => "password"
        })

      assert msg["input_type"] == "password"
    end

    test "accepts default_value" do
      {:ok, msg} =
        UserInteraction.user_input_request(%{
          "prompt_id" => "p",
          "prompt_text" => "t",
          "default_value" => "admin"
        })

      assert msg["default_value"] == "admin"
    end

    test "rejects invalid input_type" do
      assert {:error, {:invalid_literal, "input_type", "number", ~w(text password)}} =
               UserInteraction.user_input_request(%{
                 "prompt_id" => "p",
                 "prompt_text" => "t",
                 "input_type" => "number"
               })
    end

    test "rejects missing prompt_id" do
      assert {:error, {:missing_required_field, "prompt_id"}} =
               UserInteraction.user_input_request(%{"prompt_text" => "t"})
    end

    test "rejects missing prompt_text" do
      assert {:error, {:missing_required_field, "prompt_text"}} =
               UserInteraction.user_input_request(%{"prompt_id" => "p"})
    end

    test "rejects category mismatch" do
      assert {:error, {:category_mismatch, expected: "user_interaction", got: "agent"}} =
               UserInteraction.user_input_request(%{
                 "prompt_id" => "p",
                 "prompt_text" => "t",
                 "category" => "agent"
               })
    end

    test "JSON round-trip" do
      {:ok, msg} =
        UserInteraction.user_input_request(%{
          "prompt_id" => "p1",
          "prompt_text" => "Name?",
          "input_type" => "password"
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["input_type"] == "password"
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        UserInteraction.user_input_request(%{
          "prompt_id" => "p1",
          "prompt_text" => "Enter value",
          "default_value" => "default"
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["prompt_id"] == "p1"
      assert restored["default_value"] == "default"
    end
  end

  # ===========================================================================
  # ConfirmationRequest
  # ===========================================================================

  describe "confirmation_request/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        UserInteraction.confirmation_request(%{
          "prompt_id" => "conf-1",
          "title" => "Confirm delete?",
          "description" => "This will delete the file"
        })

      assert msg["options"] == ["Yes", "No"]
      assert msg["allow_feedback"] == false
    end

    test "accepts custom options" do
      {:ok, msg} =
        UserInteraction.confirmation_request(%{
          "prompt_id" => "conf-1",
          "title" => "Choose action",
          "description" => "Pick one",
          "options" => ["Overwrite", "Skip", "Cancel"]
        })

      assert msg["options"] == ["Overwrite", "Skip", "Cancel"]
    end

    test "accepts allow_feedback" do
      {:ok, msg} =
        UserInteraction.confirmation_request(%{
          "prompt_id" => "conf-1",
          "title" => "OK?",
          "description" => "d",
          "allow_feedback" => true
        })

      assert msg["allow_feedback"] == true
    end

    test "rejects non-string elements in options" do
      assert {:error, {:invalid_field_type, "options", :not_all_strings}} =
               UserInteraction.confirmation_request(%{
                 "prompt_id" => "p",
                 "title" => "t",
                 "description" => "d",
                 "options" => ["Yes", 42]
               })
    end

    test "rejects non-list options" do
      assert {:error, {:invalid_field_type, "options", "yes"}} =
               UserInteraction.confirmation_request(%{
                 "prompt_id" => "p",
                 "title" => "t",
                 "description" => "d",
                 "options" => "yes"
               })
    end

    test "rejects non-boolean allow_feedback" do
      assert {:error, {:invalid_field_type, "allow_feedback", "yes"}} =
               UserInteraction.confirmation_request(%{
                 "prompt_id" => "p",
                 "title" => "t",
                 "description" => "d",
                 "allow_feedback" => "yes"
               })
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        UserInteraction.confirmation_request(%{
          "prompt_id" => "c1",
          "title" => "Proceed?",
          "description" => "d",
          "allow_feedback" => true
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["title"] == "Proceed?"
      assert restored["allow_feedback"] == true
    end
  end

  # ===========================================================================
  # SelectionRequest
  # ===========================================================================

  describe "selection_request/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        UserInteraction.selection_request(%{
          "prompt_id" => "sel-1",
          "prompt_text" => "Pick a color:",
          "options" => ["Red", "Green", "Blue"]
        })

      assert msg["allow_cancel"] == true
      assert msg["options"] == ["Red", "Green", "Blue"]
    end

    test "allow_cancel can be set to false" do
      {:ok, msg} =
        UserInteraction.selection_request(%{
          "prompt_id" => "sel-1",
          "prompt_text" => "Must choose:",
          "options" => ["A", "B"],
          "allow_cancel" => false
        })

      assert msg["allow_cancel"] == false
    end

    test "rejects missing options" do
      assert {:error, {:missing_required_field, "options"}} =
               UserInteraction.selection_request(%{
                 "prompt_id" => "p",
                 "prompt_text" => "t"
               })
    end

    test "rejects non-string elements in options" do
      assert {:error, {:invalid_field_type, "options", :not_all_strings}} =
               UserInteraction.selection_request(%{
                 "prompt_id" => "p",
                 "prompt_text" => "t",
                 "options" => [1, 2, 3]
               })
    end

    test "rejects non-list options" do
      assert {:error, {:invalid_field_type, "options", "single"}} =
               UserInteraction.selection_request(%{
                 "prompt_id" => "p",
                 "prompt_text" => "t",
                 "options" => "single"
               })
    end

    test "rejects missing prompt_text" do
      assert {:error, {:missing_required_field, "prompt_text"}} =
               UserInteraction.selection_request(%{
                 "prompt_id" => "p",
                 "options" => ["A"]
               })
    end

    test "JSON round-trip" do
      {:ok, msg} =
        UserInteraction.selection_request(%{
          "prompt_id" => "s1",
          "prompt_text" => "Pick:",
          "options" => ["X", "Y"],
          "allow_cancel" => false
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["options"] == ["X", "Y"]
      assert decoded["allow_cancel"] == false
    end
  end
end
