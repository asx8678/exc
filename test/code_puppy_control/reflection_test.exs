defmodule CodePuppyControl.ReflectionTest do
  @moduledoc """
  Tests for the Reflection module.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Reflection

  describe "resolve_function/1" do
    test "resolves simple module.function path" do
      assert {:ok, func} = Reflection.resolve_function("Elixir.String.split")
      assert is_function(func)
    end

    test "resolves module.function/arity path" do
      assert {:ok, func} = Reflection.resolve_function("Elixir.String.split/3")
      assert is_function(func, 3)

      # Verify it actually works
      assert func.("a,b,c", ",", []) == ["a", "b", "c"]
    end

    test "resolves atom function" do
      fun = &String.length/1
      assert {:ok, ^fun} = Reflection.resolve_function(fun)
    end

    test "returns error for non-existent module" do
      assert {:error, :module_not_found} =
               Reflection.resolve_function("Elixir.NonExistent.Module.function")
    end

    test "returns error for non-existent function in existing module" do
      assert {:error, :function_not_found} =
               Reflection.resolve_function("Elixir.String.nonexistent_function_xyz")
    end

    test "returns error for invalid path format (single component)" do
      assert {:error, :invalid_path} = Reflection.resolve_function("SingleComponent")
    end

    test "returns error for invalid path format (empty)" do
      assert {:error, :invalid_path} = Reflection.resolve_function("")
    end
  end

  describe "resolve_function!/1" do
    test "returns function for valid path" do
      func = Reflection.resolve_function!("Elixir.String.split")
      assert is_function(func)
    end

    test "returns function with correct arity" do
      func = Reflection.resolve_function!("Elixir.String.split/3")
      assert is_function(func, 3)
    end

    test "raises for invalid path" do
      assert_raise ArgumentError, fn ->
        Reflection.resolve_function!("Invalid.path")
      end
    end

    test "raises for non-existent module" do
      assert_raise ArgumentError, fn ->
        Reflection.resolve_function!("NonExistent.Module.function")
      end
    end

    test "raises for non-existent function" do
      assert_raise ArgumentError, fn ->
        Reflection.resolve_function!("Elixir.String.nonexistent")
      end
    end
  end

  describe "list_functions/1" do
    test "returns list of functions for existing module" do
      assert {:ok, functions} = Reflection.list_functions("Elixir.String")
      assert is_list(functions)
      assert "split/3" in functions
      assert "length/1" in functions
      assert "upcase/1" in functions
    end

    test "returns sorted list of functions" do
      assert {:ok, functions} = Reflection.list_functions("Elixir.String")
      assert functions == Enum.sort(functions)
    end

    test "returns error for non-existent module" do
      assert {:error, :module_not_found} =
               Reflection.list_functions("Elixir.NonExistentModule123")
    end
  end

  describe "list_attributes/1" do
    test "returns list of attribute names for existing module" do
      assert {:ok, attributes} = Reflection.list_attributes("Elixir.String")
      assert is_list(attributes)
      assert "split" in attributes
      assert "length" in attributes
      assert "upcase" in attributes
    end

    test "returns unique attributes (no duplicates for multiple arities)" do
      assert {:ok, attributes} = Reflection.list_attributes("Elixir.String")
      # split has multiple arities (1, 2, 3) but should appear once
      split_count = Enum.count(attributes, &(&1 == "split"))
      assert split_count == 1
    end

    test "returns error for non-existent module" do
      assert {:error, :module_not_found} =
               Reflection.list_attributes("Elixir.NonExistentModule123")
    end
  end

  describe "package_hint/1" do
    test "returns hint for known optional dependency" do
      assert Reflection.package_hint("NimbleParsec") == "nimble_parsec"
      assert Reflection.package_hint("Phoenix") == "phoenix"
      assert Reflection.package_hint("Ecto") == "ecto"
    end

    test "returns nil for unknown module" do
      assert Reflection.package_hint("UnknownModule") == nil
    end
  end

  describe "complex module paths" do
    test "handles nested module paths" do
      # Use CodePuppyControl modules which should exist
      assert {:ok, func} =
               Reflection.resolve_function("Elixir.CodePuppyControl.Reflection.resolve_function")

      assert is_function(func, 1)
    end

    test "handles deeply nested paths" do
      # Test with Enum module function
      assert {:ok, func} = Reflection.resolve_function("Elixir.Enum.map/2")
      assert is_function(func, 2)
    end
  end

  describe "arity handling" do
    test "returns first arity when none specified" do
      # String.split has arities 1, 2, 3 - should get one of them
      assert {:ok, func} = Reflection.resolve_function("Elixir.String.split")
      assert is_function(func)
    end

    test "returns specific arity when requested" do
      assert {:ok, func_2} = Reflection.resolve_function("Elixir.String.split/2")
      assert is_function(func_2, 2)

      assert {:ok, func_3} = Reflection.resolve_function("Elixir.String.split/3")
      assert is_function(func_3, 3)
    end

    test "returns error for wrong arity" do
      # String.first only has arity 1, requesting arity 2 should fail
      assert {:error, :arity_not_found} =
               Reflection.resolve_function("Elixir.String.first/99")
    end
  end
end
