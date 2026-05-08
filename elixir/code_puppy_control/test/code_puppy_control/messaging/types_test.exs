defmodule CodePuppyControl.Messaging.TypesTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.Types — MessageLevel and MessageCategory validation.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.Types

  # ===========================================================================
  # MessageLevel validation
  # ===========================================================================

  describe "validate_level/1" do
    test "accepts all allowed levels" do
      for level <- Types.allowed_levels() do
        assert {:ok, ^level} = Types.validate_level(level)
      end
    end

    test "rejects unknown level" do
      assert {:error, {:invalid_level, "critical"}} = Types.validate_level("critical")
    end

    test "rejects non-string level" do
      assert {:error, {:invalid_level, 42}} = Types.validate_level(42)
    end

    test "rejects empty string" do
      assert {:error, {:invalid_level, ""}} = Types.validate_level("")
    end

    test "rejects atom" do
      assert {:error, {:invalid_level, :info}} = Types.validate_level(:info)
    end
  end

  describe "allowed_levels/0" do
    test "returns exactly 5 levels matching Python enum" do
      levels = Types.allowed_levels()
      assert length(levels) == 5
      assert "debug" in levels
      assert "info" in levels
      assert "warning" in levels
      assert "error" in levels
      assert "success" in levels
    end
  end

  # ===========================================================================
  # MessageCategory validation
  # ===========================================================================

  describe "validate_category/1" do
    test "accepts all allowed categories" do
      for cat <- Types.allowed_categories() do
        assert {:ok, ^cat} = Types.validate_category(cat)
      end
    end

    test "rejects unknown category" do
      assert {:error, {:invalid_category, "network"}} = Types.validate_category("network")
    end

    test "rejects non-string category" do
      assert {:error, {:invalid_category, :system}} = Types.validate_category(:system)
    end

    test "rejects empty string" do
      assert {:error, {:invalid_category, ""}} = Types.validate_category("")
    end

    test "rejects partial match" do
      assert {:error, {:invalid_category, "tool"}} = Types.validate_category("tool")
    end
  end

  describe "allowed_categories/0" do
    test "returns exactly 5 categories matching Python enum" do
      cats = Types.allowed_categories()
      assert length(cats) == 5
      assert "system" in cats
      assert "tool_output" in cats
      assert "agent" in cats
      assert "user_interaction" in cats
      assert "divider" in cats
    end
  end
end
