defmodule CodePuppyControl.Messaging.ValidationTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.Validation — shared validation helpers.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.Validation

  # ===========================================================================
  # generate_id/0
  # ===========================================================================

  describe "generate_id/0" do
    test "returns 32-char hex string" do
      id = Validation.generate_id()
      assert is_binary(id)
      assert String.length(id) == 32
      assert id =~ ~r/^[0-9a-f]{32}$/
    end

    test "generates unique ids" do
      ids = for _ <- 1..100, do: Validation.generate_id()
      assert length(Enum.uniq(ids)) == 100
    end
  end

  # ===========================================================================
  # resolve_timestamp/1
  # ===========================================================================

  describe "resolve_timestamp/1" do
    test "defaults to current time when absent" do
      before = System.system_time(:millisecond)
      {:ok, ts} = Validation.resolve_timestamp(%{})
      after_ms = System.system_time(:millisecond)
      assert ts >= before and ts <= after_ms
    end

    test "accepts explicit integer" do
      assert {:ok, 1234} = Validation.resolve_timestamp(%{"timestamp_unix_ms" => 1234})
    end

    test "rejects float" do
      assert {:error, {:invalid_timestamp_unix_ms, 1.5}} =
               Validation.resolve_timestamp(%{"timestamp_unix_ms" => 1.5})
    end

    test "rejects string" do
      assert {:error, {:invalid_timestamp_unix_ms, "1000"}} =
               Validation.resolve_timestamp(%{"timestamp_unix_ms" => "1000"})
    end
  end

  # ===========================================================================
  # require_string/2
  # ===========================================================================

  describe "require_string/2" do
    test "accepts string" do
      assert {:ok, "hello"} = Validation.require_string(%{"key" => "hello"}, "key")
    end

    test "rejects missing" do
      assert {:error, {:missing_required_field, "key"}} = Validation.require_string(%{}, "key")
    end

    test "rejects non-string" do
      assert {:error, {:invalid_field_type, "key", 42}} =
               Validation.require_string(%{"key" => 42}, "key")
    end
  end

  # ===========================================================================
  # optional_string/2
  # ===========================================================================

  describe "optional_string/2" do
    test "accepts string" do
      assert {:ok, "val"} = Validation.optional_string(%{"key" => "val"}, "key")
    end

    test "accepts nil" do
      assert {:ok, nil} = Validation.optional_string(%{"key" => nil}, "key")
    end

    test "defaults to nil when absent" do
      assert {:ok, nil} = Validation.optional_string(%{}, "key")
    end

    test "rejects non-string" do
      assert {:error, {:invalid_field_type, "key", 42}} =
               Validation.optional_string(%{"key" => 42}, "key")
    end
  end

  # ===========================================================================
  # require_integer/2
  # ===========================================================================

  describe "require_integer/2" do
    test "accepts integer" do
      assert {:ok, 5} = Validation.require_integer(%{"n" => 5}, "n")
    end

    test "accepts integer with min: 0" do
      assert {:ok, 0} = Validation.require_integer(%{"n" => 0}, "n", min: 0)
    end

    test "rejects below min" do
      assert {:error, {:value_below_min, "n", -1, 0}} =
               Validation.require_integer(%{"n" => -1}, "n", min: 0)
    end

    test "rejects float" do
      assert {:error, {:invalid_field_type, "n", 1.5}} =
               Validation.require_integer(%{"n" => 1.5}, "n")
    end

    test "rejects missing" do
      assert {:error, {:missing_required_field, "n"}} = Validation.require_integer(%{}, "n")
    end
  end

  # ===========================================================================
  # optional_integer/2
  # ===========================================================================

  describe "optional_integer/2" do
    test "accepts nil" do
      assert {:ok, nil} = Validation.optional_integer(%{"n" => nil}, "n")
    end

    test "defaults to nil when absent" do
      assert {:ok, nil} = Validation.optional_integer(%{}, "n")
    end

    test "accepts integer with min" do
      assert {:ok, 3} = Validation.optional_integer(%{"n" => 3}, "n", min: 0)
    end

    test "rejects below min" do
      assert {:error, {:value_below_min, "n", -1, 0}} =
               Validation.optional_integer(%{"n" => -1}, "n", min: 0)
    end

    test "rejects non-integer" do
      assert {:error, {:invalid_field_type, "n", "3"}} =
               Validation.optional_integer(%{"n" => "3"}, "n")
    end
  end

  # ===========================================================================
  # require_number/2
  # ===========================================================================

  describe "require_number/2" do
    test "accepts integer" do
      assert {:ok, 5} = Validation.require_number(%{"n" => 5}, "n")
    end

    test "accepts float" do
      assert {:ok, 1.5} = Validation.require_number(%{"n" => 1.5}, "n")
    end

    test "rejects below min" do
      assert {:error, {:value_below_min, "n", -0.1, 0}} =
               Validation.require_number(%{"n" => -0.1}, "n", min: 0)
    end

    test "rejects string" do
      assert {:error, {:invalid_field_type, "n", "5"}} =
               Validation.require_number(%{"n" => "5"}, "n")
    end
  end

  # ===========================================================================
  # optional_number/2
  # ===========================================================================

  describe "optional_number/2" do
    test "defaults to nil" do
      assert {:ok, nil} = Validation.optional_number(%{}, "n")
    end

    test "accepts nil" do
      assert {:ok, nil} = Validation.optional_number(%{"n" => nil}, "n")
    end

    test "rejects below min" do
      assert {:error, {:value_below_min, "n", -1.0, 0}} =
               Validation.optional_number(%{"n" => -1.0}, "n", min: 0)
    end
  end

  # ===========================================================================
  # require_boolean/2
  # ===========================================================================

  describe "require_boolean/2" do
    test "accepts true" do
      assert {:ok, true} = Validation.require_boolean(%{"b" => true}, "b")
    end

    test "accepts false" do
      assert {:ok, false} = Validation.require_boolean(%{"b" => false}, "b")
    end

    test "rejects non-boolean" do
      assert {:error, {:invalid_field_type, "b", "yes"}} =
               Validation.require_boolean(%{"b" => "yes"}, "b")
    end

    test "rejects missing" do
      assert {:error, {:missing_required_field, "b"}} = Validation.require_boolean(%{}, "b")
    end
  end

  # ===========================================================================
  # optional_boolean/3
  # ===========================================================================

  describe "optional_boolean/3" do
    test "defaults to false" do
      assert {:ok, false} = Validation.optional_boolean(%{}, "b")
    end

    test "defaults to custom value" do
      assert {:ok, true} = Validation.optional_boolean(%{}, "b", true)
    end

    test "rejects non-boolean" do
      assert {:error, {:invalid_field_type, "b", 1}} =
               Validation.optional_boolean(%{"b" => 1}, "b")
    end
  end

  # ===========================================================================
  # require_literal/3
  # ===========================================================================

  describe "require_literal/3" do
    test "accepts valid literal" do
      assert {:ok, "file"} = Validation.require_literal(%{"t" => "file"}, "t", ~w(file dir))
    end

    test "rejects invalid literal" do
      assert {:error, {:invalid_literal, "t", "bad", ~w(file dir)}} =
               Validation.require_literal(%{"t" => "bad"}, "t", ~w(file dir))
    end

    test "rejects non-string" do
      assert {:error, {:invalid_field_type, "t", 42}} =
               Validation.require_literal(%{"t" => 42}, "t", ~w(file dir))
    end

    test "rejects missing" do
      assert {:error, {:missing_required_field, "t"}} =
               Validation.require_literal(%{}, "t", ~w(file dir))
    end
  end

  # ===========================================================================
  # optional_literal/3
  # ===========================================================================

  describe "optional_literal/3" do
    test "defaults to nil" do
      assert {:ok, nil} = Validation.optional_literal(%{}, "t", ~w(a b))
    end

    test "accepts nil" do
      assert {:ok, nil} = Validation.optional_literal(%{"t" => nil}, "t", ~w(a b))
    end

    test "accepts valid literal" do
      assert {:ok, "a"} = Validation.optional_literal(%{"t" => "a"}, "t", ~w(a b))
    end

    test "rejects invalid literal" do
      assert {:error, {:invalid_literal, "t", "c", ~w(a b)}} =
               Validation.optional_literal(%{"t" => "c"}, "t", ~w(a b))
    end
  end

  # ===========================================================================
  # validate_category_default/2
  # ===========================================================================

  describe "validate_category_default/2" do
    test "uses default when absent" do
      assert {:ok, "system"} = Validation.validate_category_default(%{}, "system")
    end

    test "accepts matching category" do
      assert {:ok, "agent"} =
               Validation.validate_category_default(%{"category" => "agent"}, "agent")
    end

    test "rejects mismatched category" do
      assert {:error, {:category_mismatch, expected: "system", got: "agent"}} =
               Validation.validate_category_default(%{"category" => "agent"}, "system")
    end

    test "rejects invalid category" do
      assert {:error, {:invalid_category, "nope"}} =
               Validation.validate_category_default(%{"category" => "nope"}, "system")
    end
  end

  # ===========================================================================
  # validate_list/3
  # ===========================================================================

  describe "validate_list/3" do
    test "defaults to empty list when absent" do
      assert {:ok, []} = Validation.validate_list(%{}, "items", &{:ok, &1})
    end

    test "validates each element" do
      validator = fn m -> {:ok, Map.put(m, "validated", true)} end

      assert {:ok, results} =
               Validation.validate_list(
                 %{"items" => [%{"a" => 1}, %{"b" => 2}]},
                 "items",
                 validator
               )

      assert length(results) == 2
      assert Enum.all?(results, & &1["validated"])
    end

    test "rejects non-map element" do
      assert {:error, {:invalid_list_element, "items", {:not_a_map, "x"}}} =
               Validation.validate_list(%{"items" => ["x"]}, "items", &{:ok, &1})
    end

    test "propagates element validator errors" do
      validator = fn _m -> {:error, :bad_element} end

      assert {:error, {:invalid_list_element, "items", :bad_element}} =
               Validation.validate_list(%{"items" => [%{}]}, "items", validator)
    end

    test "rejects non-list" do
      assert {:error, {:invalid_field_type, "items", "not-list"}} =
               Validation.validate_list(%{"items" => "not-list"}, "items", &{:ok, &1})
    end
  end

  # ===========================================================================
  # optional_string_map/2
  # ===========================================================================

  describe "optional_string_map/2" do
    test "defaults to empty map" do
      assert {:ok, %{}} = Validation.optional_string_map(%{}, "f")
    end

    test "accepts string→string map" do
      assert {:ok, %{"a" => "1"}} =
               Validation.optional_string_map(%{"f" => %{"a" => "1"}}, "f")
    end

    test "rejects non-string values" do
      assert {:error, {:invalid_field_type, "f", :not_string_to_string_map}} =
               Validation.optional_string_map(%{"f" => %{"a" => 1}}, "f")
    end

    test "rejects non-map" do
      assert {:error, {:invalid_field_type, "f", "x"}} =
               Validation.optional_string_map(%{"f" => "x"}, "f")
    end
  end

  # ===========================================================================
  # reject_extra_keys/2
  # ===========================================================================

  describe "reject_extra_keys/2" do
    test "passes with no extra keys" do
      assert :ok = Validation.reject_extra_keys(%{"a" => 1, "b" => 2}, MapSet.new(~w(a b c)))
    end

    test "rejects extra keys" do
      assert {:error, {:extra_fields_not_allowed, extra}} =
               Validation.reject_extra_keys(%{"a" => 1, "extra" => 2}, MapSet.new(~w(a)))

      # extra should contain "extra" (order not guaranteed)
      assert "extra" in extra
    end
  end

  # ===========================================================================
  # assemble_base/2
  # ===========================================================================

  describe "assemble_base/2" do
    test "assembles base message fields" do
      {:ok, base} = Validation.assemble_base(%{}, "system")

      assert is_binary(base["id"])
      assert base["category"] == "system"
      assert is_integer(base["timestamp_unix_ms"])
      assert base["run_id"] == nil
      assert base["session_id"] == nil
    end

    test "preserves explicit id and timestamp" do
      {:ok, base} =
        Validation.assemble_base(
          %{"id" => "my-id", "timestamp_unix_ms" => 999, "run_id" => "r1"},
          "agent"
        )

      assert base["id"] == "my-id"
      assert base["timestamp_unix_ms"] == 999
      assert base["run_id"] == "r1"
    end

    test "rejects invalid category" do
      assert {:error, {:invalid_category, "nope"}} = Validation.assemble_base(%{}, "nope")
    end
  end
end
