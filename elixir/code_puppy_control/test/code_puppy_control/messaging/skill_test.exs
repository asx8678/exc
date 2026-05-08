defmodule CodePuppyControl.Messaging.SkillTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.Skill — skill message constructors.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.{Skill, WireEvent}

  # ===========================================================================
  # SkillListMessage
  # ===========================================================================

  describe "skill_list_message/1" do
    test "happy path with skills" do
      {:ok, msg} =
        Skill.skill_list_message(%{
          "skills" => [
            %{
              "name" => "review",
              "description" => "Code review skill",
              "path" => "/skills/review"
            }
          ],
          "total_count" => 1
        })

      assert msg["category"] == "tool_output"
      assert length(msg["skills"]) == 1
      assert msg["skills"] |> hd() |> Map.get("name") == "review"
      assert msg["query"] == nil
    end

    test "defaults skills to empty list and query to nil" do
      {:ok, msg} =
        Skill.skill_list_message(%{"total_count" => 0})

      assert msg["skills"] == []
      assert msg["query"] == nil
    end

    test "validates nested SkillEntry entries" do
      assert {:error, {:invalid_list_element, "skills", _}} =
               Skill.skill_list_message(%{
                 "skills" => [
                   %{"name" => "s", "description" => "d", "path" => "/p", "extra" => 1}
                 ],
                 "total_count" => 1
               })
    end

    test "rejects non-map elements in skills list" do
      assert {:error, {:invalid_list_element, "skills", {:not_a_map, _}}} =
               Skill.skill_list_message(%{
                 "skills" => ["not a map"],
                 "total_count" => 1
               })
    end

    test "accepts query" do
      {:ok, msg} =
        Skill.skill_list_message(%{
          "total_count" => 2,
          "query" => "review"
        })

      assert msg["query"] == "review"
    end

    test "rejects negative total_count" do
      assert {:error, {:value_below_min, "total_count", -1, 0}} =
               Skill.skill_list_message(%{"total_count" => -1})
    end

    test "rejects missing total_count" do
      assert {:error, {:missing_required_field, "total_count"}} =
               Skill.skill_list_message(%{})
    end

    test "rejects category mismatch" do
      assert {:error, {:category_mismatch, expected: "tool_output", got: "agent"}} =
               Skill.skill_list_message(%{
                 "total_count" => 0,
                 "category" => "agent"
               })
    end

    test "JSON round-trip" do
      {:ok, msg} =
        Skill.skill_list_message(%{
          "skills" => [
            %{
              "name" => "audit",
              "description" => "Security audit",
              "path" => "/skills/audit",
              "tags" => ["security"],
              "enabled" => true
            }
          ],
          "total_count" => 1,
          "query" => "sec"
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert length(decoded["skills"]) == 1
      assert decoded["query"] == "sec"
      assert hd(decoded["skills"])["tags"] == ["security"]
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        Skill.skill_list_message(%{
          "skills" => [
            %{
              "name" => "test",
              "description" => "Test skill",
              "path" => "/p",
              "tags" => ["testing"],
              "enabled" => false
            }
          ],
          "total_count" => 1
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert length(restored["skills"]) == 1
      assert hd(restored["skills"])["enabled"] == false
    end
  end

  # ===========================================================================
  # SkillActivateMessage
  # ===========================================================================

  describe "skill_activate_message/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        Skill.skill_activate_message(%{
          "skill_name" => "review",
          "skill_path" => "/skills/review",
          "content_preview" => "# Review Skill...",
          "resource_count" => 3
        })

      assert msg["category"] == "tool_output"
      assert msg["skill_name"] == "review"
      assert msg["success"] == true
    end

    test "defaults success to true" do
      {:ok, msg} =
        Skill.skill_activate_message(%{
          "skill_name" => "s",
          "skill_path" => "/p",
          "content_preview" => "preview",
          "resource_count" => 0
        })

      assert msg["success"] == true
    end

    test "accepts success=false" do
      {:ok, msg} =
        Skill.skill_activate_message(%{
          "skill_name" => "s",
          "skill_path" => "/p",
          "content_preview" => "preview",
          "resource_count" => 0,
          "success" => false
        })

      assert msg["success"] == false
    end

    test "rejects missing skill_name" do
      assert {:error, {:missing_required_field, "skill_name"}} =
               Skill.skill_activate_message(%{
                 "skill_path" => "/p",
                 "content_preview" => "p",
                 "resource_count" => 0
               })
    end

    test "rejects missing resource_count" do
      assert {:error, {:missing_required_field, "resource_count"}} =
               Skill.skill_activate_message(%{
                 "skill_name" => "s",
                 "skill_path" => "/p",
                 "content_preview" => "p"
               })
    end

    test "rejects negative resource_count" do
      assert {:error, {:value_below_min, "resource_count", -1, 0}} =
               Skill.skill_activate_message(%{
                 "skill_name" => "s",
                 "skill_path" => "/p",
                 "content_preview" => "p",
                 "resource_count" => -1
               })
    end

    test "rejects non-boolean success" do
      assert {:error, {:invalid_field_type, "success", "yes"}} =
               Skill.skill_activate_message(%{
                 "skill_name" => "s",
                 "skill_path" => "/p",
                 "content_preview" => "p",
                 "resource_count" => 0,
                 "success" => "yes"
               })
    end

    test "JSON round-trip" do
      {:ok, msg} =
        Skill.skill_activate_message(%{
          "skill_name" => "deploy",
          "skill_path" => "/skills/deploy",
          "content_preview" => "# Deploy Skill...",
          "resource_count" => 5,
          "success" => true
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["skill_name"] == "deploy"
      assert decoded["resource_count"] == 5
    end

    test "WireEvent round-trip" do
      {:ok, msg} =
        Skill.skill_activate_message(%{
          "skill_name" => "test",
          "skill_path" => "/p",
          "content_preview" => "preview text",
          "resource_count" => 1,
          "success" => false
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["skill_name"] == "test"
      assert restored["success"] == false
      assert restored["content_preview"] == "preview text"
    end
  end
end
