defmodule CodePuppyControl.Messaging.ControlTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.Control — system control message constructors.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.{Control, WireEvent}

  # ===========================================================================
  # SpinnerControl
  # ===========================================================================

  describe "spinner_control/1" do
    @valid_actions ~w(start stop update pause resume)

    test "happy path with all valid actions" do
      for action <- @valid_actions do
        assert {:ok, msg} =
                 Control.spinner_control(%{
                   "action" => action,
                   "spinner_id" => "spinner-1"
                 })

        assert msg["action"] == action
      end
    end

    test "defaults text to nil" do
      {:ok, msg} =
        Control.spinner_control(%{
          "action" => "start",
          "spinner_id" => "s1"
        })

      assert msg["text"] == nil
    end

    test "accepts text for start/update" do
      {:ok, msg} =
        Control.spinner_control(%{
          "action" => "update",
          "spinner_id" => "s1",
          "text" => "Loading..."
        })

      assert msg["text"] == "Loading..."
    end

    test "rejects invalid action" do
      assert {:error, {:invalid_literal, "action", "destroy", @valid_actions}} =
               Control.spinner_control(%{
                 "action" => "destroy",
                 "spinner_id" => "s1"
               })
    end

    test "rejects missing action" do
      assert {:error, {:missing_required_field, "action"}} =
               Control.spinner_control(%{"spinner_id" => "s1"})
    end

    test "rejects missing spinner_id" do
      assert {:error, {:missing_required_field, "spinner_id"}} =
               Control.spinner_control(%{"action" => "start"})
    end

    test "rejects category mismatch" do
      assert {:error, {:category_mismatch, expected: "system", got: "agent"}} =
               Control.spinner_control(%{
                 "action" => "start",
                 "spinner_id" => "s1",
                 "category" => "agent"
               })
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        Control.spinner_control(%{
          "action" => "start",
          "spinner_id" => "s1",
          "text" => "Working..."
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["action"] == "start"
      assert restored["spinner_id"] == "s1"
      assert restored["text"] == "Working..."
      assert restored["category"] == "system"
    end
  end

  # ===========================================================================
  # DividerMessage
  # ===========================================================================

  describe "divider_message/1" do
    @valid_styles ~w(light heavy double)

    test "defaults style to light" do
      {:ok, msg} = Control.divider_message(%{})
      assert msg["style"] == "light"
      assert msg["category"] == "divider"
    end

    test "accepts all valid styles" do
      for style <- @valid_styles do
        assert {:ok, msg} = Control.divider_message(%{"style" => style})
        assert msg["style"] == style
      end
    end

    test "rejects invalid style" do
      assert {:error, {:invalid_literal, "style", "dashed", @valid_styles}} =
               Control.divider_message(%{"style" => "dashed"})
    end

    test "rejects non-string style" do
      assert {:error, {:invalid_literal, "style", 1, @valid_styles}} =
               Control.divider_message(%{"style" => 1})
    end

    test "rejects category mismatch (divider has its own category)" do
      assert {:error, {:category_mismatch, expected: "divider", got: "system"}} =
               Control.divider_message(%{"category" => "system"})
    end

    test "JSON round-trip" do
      {:ok, msg} = Control.divider_message(%{"style" => "heavy"})

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["style"] == "heavy"
      assert decoded["category"] == "divider"
    end

    test "WireEvent round-trip" do
      {:ok, msg} = Control.divider_message(%{"style" => "double"})

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["style"] == "double"
      assert restored["category"] == "divider"
    end
  end

  # ===========================================================================
  # StatusPanelMessage
  # ===========================================================================

  describe "status_panel_message/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        Control.status_panel_message(%{"title" => "Agent Status"})

      assert msg["category"] == "system"
      assert msg["title"] == "Agent Status"
      assert msg["fields"] == %{}
    end

    test "accepts string=>string fields" do
      {:ok, msg} =
        Control.status_panel_message(%{
          "title" => "Status",
          "fields" => %{"model" => "gpt-4", "tokens" => "1500"}
        })

      assert msg["fields"]["model"] == "gpt-4"
      assert msg["fields"]["tokens"] == "1500"
    end

    test "rejects missing title" do
      assert {:error, {:missing_required_field, "title"}} =
               Control.status_panel_message(%{})
    end

    test "rejects non-string title" do
      assert {:error, {:invalid_field_type, "title", 42}} =
               Control.status_panel_message(%{"title" => 42})
    end

    test "rejects non-string values in fields map" do
      assert {:error, {:invalid_field_type, "fields", :not_string_to_string_map}} =
               Control.status_panel_message(%{
                 "title" => "T",
                 "fields" => %{"key" => 42}
               })
    end

    test "rejects non-map fields" do
      assert {:error, {:invalid_field_type, "fields", "not a map"}} =
               Control.status_panel_message(%{
                 "title" => "T",
                 "fields" => "not a map"
               })
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        Control.status_panel_message(%{
          "title" => "Status",
          "fields" => %{"a" => "1", "b" => "2"}
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["title"] == "Status"
      assert restored["fields"]["a"] == "1"
    end
  end

  # ===========================================================================
  # VersionCheckMessage
  # ===========================================================================

  describe "version_check_message/1" do
    test "happy path" do
      {:ok, msg} =
        Control.version_check_message(%{
          "current_version" => "1.0.0",
          "latest_version" => "1.1.0",
          "update_available" => true
        })

      assert msg["category"] == "system"
      assert msg["current_version"] == "1.0.0"
      assert msg["latest_version"] == "1.1.0"
      assert msg["update_available"] == true
    end

    test "no update available" do
      {:ok, msg} =
        Control.version_check_message(%{
          "current_version" => "1.1.0",
          "latest_version" => "1.1.0",
          "update_available" => false
        })

      assert msg["update_available"] == false
    end

    test "rejects missing current_version" do
      assert {:error, {:missing_required_field, "current_version"}} =
               Control.version_check_message(%{
                 "latest_version" => "1.0",
                 "update_available" => false
               })
    end

    test "rejects missing update_available" do
      assert {:error, {:missing_required_field, "update_available"}} =
               Control.version_check_message(%{
                 "current_version" => "1.0",
                 "latest_version" => "1.0"
               })
    end

    test "rejects non-boolean update_available" do
      assert {:error, {:invalid_field_type, "update_available", "yes"}} =
               Control.version_check_message(%{
                 "current_version" => "1.0",
                 "latest_version" => "1.0",
                 "update_available" => "yes"
               })
    end

    test "rejects category mismatch" do
      assert {:error, {:category_mismatch, expected: "system", got: "agent"}} =
               Control.version_check_message(%{
                 "current_version" => "1.0",
                 "latest_version" => "1.0",
                 "update_available" => false,
                 "category" => "agent"
               })
    end

    test "JSON round-trip" do
      {:ok, msg} =
        Control.version_check_message(%{
          "current_version" => "0.9",
          "latest_version" => "1.0",
          "update_available" => true
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["update_available"] == true
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        Control.version_check_message(%{
          "current_version" => "0.9",
          "latest_version" => "1.0",
          "update_available" => true
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["current_version"] == "0.9"
      assert restored["update_available"] == true
    end
  end
end
