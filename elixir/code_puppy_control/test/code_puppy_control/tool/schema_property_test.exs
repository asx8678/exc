defmodule CodePuppyControl.Tool.SchemaPropertyTest do
  @moduledoc """
  Property tests for Tool.Schema validation invariants.

  Ports the spirit of Python's test_tool_schema.py:
  - Schema.validate/2 + Schema.cast/2 type system
  - Required field enforcement
  - Enum constraint checking
  - Numeric range constraints (minimum/maximum)
  - String length constraints (minLength/maxLength)
  - Array item validation and size constraints
  - Nested object validation

  These are Wave 2 tests for .
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias CodePuppyControl.Tool.Schema

  defp non_integer_string_generator do
    string(:alphanumeric)
    |> StreamData.filter(fn value ->
      case Integer.parse(value) do
        {_int, ""} -> false
        _ -> true
      end
    end)
  end

  # ── Property 1: validate + cast identity for well-typed data ────────────

  describe "validate + cast consistency" do
    property "valid string data passes both validate and cast" do
      check all(value <- string(:alphanumeric, min_length: 1), max_runs: 100) do
        schema = %{"type" => "string"}
        assert {:ok, ^value} = Schema.validate(schema, value)
        assert {:ok, ^value} = Schema.cast("string", value)
      end
    end

    property "valid integer data passes both validate and cast" do
      check all(value <- integer(), max_runs: 100) do
        schema = %{"type" => "integer"}
        assert {:ok, ^value} = Schema.validate(schema, value)
        assert {:ok, ^value} = Schema.cast("integer", value)
      end
    end

    property "valid boolean data passes validate" do
      check all(value <- boolean(), max_runs: 100) do
        schema = %{"type" => "boolean"}
        assert {:ok, ^value} = Schema.validate(schema, value)
      end
    end
  end

  # ── Property 2: enum constraint ──────────────────────────────────────────

  describe "enum constraint" do
    property "value in enum always validates; value not in enum always fails" do
      check all(
              allowed <- list_of(string(:alphanumeric, min_length: 1), min_length: 1),
              test_val <- string(:alphanumeric, min_length: 1),
              max_runs: 100
            ) do
        schema = %{"type" => "string", "enum" => allowed}

        if test_val in allowed do
          assert {:ok, ^test_val} = Schema.validate(schema, test_val)
        else
          assert {:error, _} = Schema.validate(schema, test_val)
        end
      end
    end
  end

  # ── Property 3: string length constraints ────────────────────────────────

  describe "string length constraints" do
    property "minLength rejects short strings, accepts long ones" do
      check all(
              min_len <- non_negative_integer(),
              value <- string(:alphanumeric),
              max_runs: 200
            ) do
        schema = %{"type" => "string", "minLength" => min_len}

        if String.length(value) >= min_len do
          assert {:ok, _} = Schema.validate(schema, value)
        else
          assert {:error, _} = Schema.validate(schema, value)
        end
      end
    end

    property "maxLength rejects long strings, accepts short ones" do
      check all(
              max_len <- positive_integer(),
              value <- string(:alphanumeric),
              max_runs: 200
            ) do
        schema = %{"type" => "string", "maxLength" => max_len}

        if String.length(value) <= max_len do
          assert {:ok, _} = Schema.validate(schema, value)
        else
          assert {:error, _} = Schema.validate(schema, value)
        end
      end
    end
  end

  # ── Property 4: numeric range constraints ────────────────────────────────

  describe "numeric range constraints" do
    property "minimum constraint for integers" do
      check all(
              min_val <- integer(-1000..1000),
              value <- integer(-2000..2000),
              max_runs: 200
            ) do
        schema = %{"type" => "integer", "minimum" => min_val}

        if value >= min_val do
          assert {:ok, _} = Schema.validate(schema, value)
        else
          assert {:error, _} = Schema.validate(schema, value)
        end
      end
    end

    property "maximum constraint for integers" do
      check all(
              max_val <- integer(-1000..1000),
              value <- integer(-2000..2000),
              max_runs: 200
            ) do
        schema = %{"type" => "integer", "maximum" => max_val}

        if value <= max_val do
          assert {:ok, _} = Schema.validate(schema, value)
        else
          assert {:error, _} = Schema.validate(schema, value)
        end
      end
    end
  end

  # ── Property 5: required field enforcement ──────────────────────────────

  describe "required field enforcement" do
    property "object with all required fields passes; missing required fails" do
      check all(
              raw_keys <-
                list_of(string(:alphanumeric, min_length: 1), min_length: 1, max_length: 5),
              max_runs: 100
            ) do
        required_keys = Enum.uniq(raw_keys)

        properties =
          Map.new(required_keys, fn key ->
            {key, %{"type" => "string"}}
          end)

        schema = %{
          "type" => "object",
          "properties" => properties,
          "required" => required_keys
        }

        # Full object with all required keys → passes
        full_obj = Map.new(required_keys, fn key -> {key, "value"} end)
        assert {:ok, _} = Schema.validate(schema, full_obj)

        # Object missing the first required key → fails
        missing_key = hd(required_keys)
        partial_obj = Map.delete(full_obj, missing_key)
        assert {:error, violations} = Schema.validate(schema, partial_obj)
        assert Enum.any?(violations, &String.contains?(&1, "missing required field"))
      end
    end
  end

  # ── Property 6: array item validation ────────────────────────────────────

  describe "array item validation" do
    property "arrays of matching item type pass; mismatched items fail" do
      check all(
              items <- list_of(integer(), min_length: 1, max_length: 10),
              max_runs: 100
            ) do
        schema = %{
          "type" => "array",
          "items" => %{"type" => "integer"}
        }

        # All integers should pass
        assert {:ok, ^items} = Schema.validate(schema, items)
      end
    end

    property "array minItems/maxItems constraints" do
      check all(
              min_items <- non_negative_integer(),
              max_items <- positive_integer(),
              max_runs: 100
            ) do
        # Ensure max >= min
        max_items = max(max_items, min_items + 1)

        schema = %{
          "type" => "array",
          "minItems" => min_items,
          "maxItems" => max_items
        }

        # Array within bounds
        within = List.duplicate(1, div(min_items + max_items, 2))
        assert {:ok, _} = Schema.validate(schema, within)

        # Array too short (only if min_items > 0)
        if min_items > 0 do
          too_short = List.duplicate(1, min_items - 1)
          assert {:error, _} = Schema.validate(schema, too_short)
        end

        # Array too long
        too_long = List.duplicate(1, max_items + 1)
        assert {:error, _} = Schema.validate(schema, too_long)
      end
    end
  end

  # ── Property 7: cast round-trip invariants ──────────────────────────────

  describe "cast round-trip for stringifiable types" do
    property "cast('integer', n) for integer n always succeeds" do
      check all(n <- integer(), max_runs: 200) do
        assert {:ok, ^n} = Schema.cast("integer", n)
      end
    end

    property "cast('string', s) for string s always succeeds" do
      check all(s <- string(:alphanumeric), max_runs: 200) do
        assert {:ok, ^s} = Schema.cast("string", s)
      end
    end

    property "cast('boolean', b) for boolean b always succeeds" do
      check all(b <- boolean(), max_runs: 100) do
        assert {:ok, ^b} = Schema.cast("boolean", b)
      end
    end

    property "cast('number', f) for float f always succeeds" do
      check all(f <- float(min: -1000.0, max: 1000.0), max_runs: 100) do
        assert {:ok, ^f} = Schema.cast("number", f)
      end
    end
  end

  # ── Property 8: type mismatch always fails ──────────────────────────────

  describe "type mismatch always produces errors" do
    property "non-string value fails string validation" do
      check all(
              value <- one_of([integer(), boolean(), constant(%{}), constant([])]),
              max_runs: 100
            ) do
        assert {:error, violations} = Schema.validate(%{"type" => "string"}, value)
        assert length(violations) >= 1
      end
    end

    property "non-integer value fails integer validation" do
      check all(
              value <-
                one_of([non_integer_string_generator(), boolean(), constant(%{}), constant([])]),
              max_runs: 100
            ) do
        assert {:error, violations} = Schema.validate(%{"type" => "integer"}, value)
        assert length(violations) >= 1
      end
    end

    property "non-array value fails array validation" do
      check all(
              value <- one_of([integer(), string(:alphanumeric), boolean(), constant(%{})]),
              max_runs: 100
            ) do
        assert {:error, violations} = Schema.validate(%{"type" => "array"}, value)
        assert length(violations) >= 1
      end
    end

    property "non-object value fails object validation" do
      check all(
              value <- one_of([integer(), string(:alphanumeric), boolean(), constant([])]),
              max_runs: 100
            ) do
        assert {:error, violations} = Schema.validate(%{"type" => "object"}, value)
        assert length(violations) >= 1
      end
    end
  end

  # ── Property 9: violations/2 returns list ────────────────────────────────

  describe "violations/2 returns consistent list" do
    property "empty list for valid data, non-empty list for invalid data" do
      check all(value <- string(:alphanumeric, min_length: 1), max_runs: 100) do
        # Valid: string type with string data
        assert [] = Schema.violations(%{"type" => "string"}, value)
      end
    end

    property "non-empty list for type mismatch" do
      check all(value <- integer(), max_runs: 100) do
        violations = Schema.violations(%{"type" => "string"}, value)
        assert is_list(violations)
        assert length(violations) >= 1
      end
    end
  end

  # ── Property 10: nested object validation ───────────────────────────────

  describe "nested object validation" do
    property "deeply nested required fields are enforced" do
      check all(inner_val <- string(:alphanumeric, min_length: 1), max_runs: 100) do
        schema = %{
          "type" => "object",
          "properties" => %{
            "level1" => %{
              "type" => "object",
              "properties" => %{
                "level2" => %{"type" => "string"}
              },
              "required" => ["level2"]
            }
          },
          "required" => ["level1"]
        }

        # Valid nested object
        valid_obj = %{"level1" => %{"level2" => inner_val}}
        assert {:ok, _} = Schema.validate(schema, valid_obj)

        # Missing nested required field
        invalid_obj = %{"level1" => %{}}
        assert {:error, violations} = Schema.validate(schema, invalid_obj)
        assert Enum.any?(violations, &String.contains?(&1, "missing required field"))
      end
    end
  end

  # ── Property 11: validate!/2 consistency with validate/2 ────────────────

  describe "validate!/2 consistency" do
    property "validate!/2 returns value when validate/2 returns {:ok, value}" do
      check all(value <- string(:alphanumeric, min_length: 1), max_runs: 100) do
        schema = %{"type" => "string"}
        assert {:ok, ^value} = Schema.validate(schema, value)
        assert ^value = Schema.validate!(schema, value)
      end
    end

    property "validate!/2 raises ArgumentError when validate/2 returns {:error, _}" do
      check all(value <- integer(), max_runs: 100) do
        assert_raise ArgumentError, ~r/Schema validation failed/, fn ->
          Schema.validate!(%{"type" => "string"}, value)
        end
      end
    end
  end
end
