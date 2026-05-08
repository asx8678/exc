defmodule CodePuppyControl.Tools.ContextFilterTest do
  @moduledoc """
  Tests for the ContextFilter module.

  Covers:
  - Context filtering (removes parent-specific keys)
  - Excluded keys detection
  - Nil context handling
  - Custom excluded keys
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.ContextFilter

  describe "filter_context/1" do
    test "filters excluded parent-specific keys" do
      parent_context = %{
        "session_id" => "parent-123",
        "tool_outputs" => [%{"result" => "data"}],
        "user_prompt" => "Help me with this"
      }

      child_context = ContextFilter.filter_context(parent_context)

      assert child_context["session_id"] == "parent-123"
      assert child_context["user_prompt"] == "Help me with this"
      assert not Map.has_key?(child_context, "tool_outputs")
    end

    test "filters all excluded keys" do
      parent_context = %{
        "parent_session_id" => "abc",
        "agent_session_id" => "def",
        "session_history" => [1, 2, 3],
        "previous_tool_results" => ["result"],
        "tool_call_history" => ["call1"],
        "tool_outputs" => [%{}],
        "_private_state" => %{},
        "_internal_metadata" => %{},
        "callback_registry" => %{},
        "hook_state" => %{},
        "render_context" => %{},
        "console_state" => %{},
        "keep_this_key" => "value"
      }

      child_context = ContextFilter.filter_context(parent_context)

      # All excluded keys should be removed
      refute Map.has_key?(child_context, "parent_session_id")
      refute Map.has_key?(child_context, "agent_session_id")
      refute Map.has_key?(child_context, "session_history")
      refute Map.has_key?(child_context, "previous_tool_results")
      refute Map.has_key?(child_context, "tool_call_history")
      refute Map.has_key?(child_context, "tool_outputs")
      refute Map.has_key?(child_context, "_private_state")
      refute Map.has_key?(child_context, "_internal_metadata")
      refute Map.has_key?(child_context, "callback_registry")
      refute Map.has_key?(child_context, "hook_state")
      refute Map.has_key?(child_context, "render_context")
      refute Map.has_key?(child_context, "console_state")

      # Non-excluded key should remain
      assert child_context["keep_this_key"] == "value"
    end

    test "returns empty map for nil context" do
      assert %{} == ContextFilter.filter_context(nil)
    end

    test "returns empty map for non-map inputs" do
      assert %{} == ContextFilter.filter_context("string")
      assert %{} == ContextFilter.filter_context(123)
      assert %{} == ContextFilter.filter_context([1, 2, 3])
      assert %{} == ContextFilter.filter_context(:atom)
    end

    test "preserves all non-excluded keys" do
      context = %{
        "user_prompt" => "Hello",
        "session_id" => "abc",
        "custom_key" => "custom_value",
        "another_key" => 123
      }

      filtered = ContextFilter.filter_context(context)

      assert filtered["user_prompt"] == "Hello"
      assert filtered["session_id"] == "abc"
      assert filtered["custom_key"] == "custom_value"
      assert filtered["another_key"] == 123
    end

    test "handles atom keys in input" do
      context = %{
        :user_prompt => "Hello",
        :tool_outputs => [%{}],
        "string_key" => "value"
      }

      filtered = ContextFilter.filter_context(context)

      assert Map.has_key?(filtered, "string_key")
      assert Map.has_key?(filtered, :user_prompt)
      refute Map.has_key?(filtered, :tool_outputs)
    end

    test "handles empty map" do
      assert %{} == ContextFilter.filter_context(%{})
    end
  end

  describe "excluded?/1" do
    test "returns true for excluded keys as strings" do
      assert ContextFilter.excluded?("tool_outputs")
      assert ContextFilter.excluded?("session_history")
      assert ContextFilter.excluded?("parent_session_id")
      assert ContextFilter.excluded?("console_state")
    end

    test "returns true for excluded keys as atoms" do
      assert ContextFilter.excluded?(:tool_outputs)
      assert ContextFilter.excluded?(:session_history)
      assert ContextFilter.excluded?(:parent_session_id)
      assert ContextFilter.excluded?(:console_state)
    end

    test "returns false for non-excluded keys" do
      refute ContextFilter.excluded?("user_prompt")
      refute ContextFilter.excluded?("session_id")
      refute ContextFilter.excluded?("custom_key")
    end
  end

  describe "excluded_keys/0" do
    test "returns a map set of excluded keys" do
      keys = ContextFilter.excluded_keys()

      assert MapSet.member?(keys, "tool_outputs")
      assert MapSet.member?(keys, "session_history")
      assert MapSet.member?(keys, "parent_session_id")
      assert MapSet.member?(keys, "console_state")
    end
  end

  describe "filter_context_with_custom/2" do
    test "filters default excluded keys plus custom ones" do
      context = %{
        "tool_outputs" => [%{}],
        "custom_exclude" => "value1",
        "keep_this" => "value2"
      }

      filtered = ContextFilter.filter_context_with_custom(context, ["custom_exclude"])

      refute Map.has_key?(filtered, "tool_outputs")
      refute Map.has_key?(filtered, "custom_exclude")
      assert filtered["keep_this"] == "value2"
    end

    test "accepts atom keys for custom exclusions" do
      context = %{
        "tool_outputs" => [%{}],
        :custom_exclude => "value"
      }

      filtered = ContextFilter.filter_context_with_custom(context, [:custom_exclude])

      refute Map.has_key?(filtered, "tool_outputs")
      refute Map.has_key?(filtered, :custom_exclude)
    end

    test "handles nil context" do
      assert %{} == ContextFilter.filter_context_with_custom(nil, ["key"])
    end

    test "handles empty custom exclusions" do
      context = %{
        "tool_outputs" => [%{}],
        "keep_this" => "value"
      }

      filtered = ContextFilter.filter_context_with_custom(context, [])

      # Default exclusions still apply
      refute Map.has_key?(filtered, "tool_outputs")
      assert filtered["keep_this"] == "value"
    end
  end
end
