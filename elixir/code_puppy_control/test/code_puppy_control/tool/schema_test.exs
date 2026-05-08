defmodule CodePuppyControl.Tool.SchemaTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Tool.Schema

  describe "validate/2 — type checking" do
    test "string passes through unchanged" do
      assert {:ok, "hello"} = Schema.validate(%{"type" => "string"}, "hello")
    end

    test "integer from integer" do
      assert {:ok, 42} = Schema.validate(%{"type" => "integer"}, 42)
    end

    test "integer from string passes validation (valid cast possible)" do
      # validate/2 checks validity without coercion — returns original data
      assert {:ok, "42"} = Schema.validate(%{"type" => "integer"}, "42")
    end

    test "float passes integer validation (truncable)" do
      # validate/2 checks if cast is possible, doesn't coerce
      assert {:ok, 3.9} = Schema.validate(%{"type" => "integer"}, 3.9)
    end

    test "number from numeric value" do
      assert {:ok, 3.14} = Schema.validate(%{"type" => "number"}, 3.14)
      assert {:ok, 42} = Schema.validate(%{"type" => "number"}, 42)
    end

    test "number from string passes validation" do
      assert {:ok, "3.14"} = Schema.validate(%{"type" => "number"}, "3.14")
    end

    test "boolean true passes" do
      assert {:ok, true} = Schema.validate(%{"type" => "boolean"}, true)
    end

    test "boolean false passes" do
      assert {:ok, false} = Schema.validate(%{"type" => "boolean"}, false)
    end

    test "boolean from string fails (type check, not cast)" do
      # validate_type checks actual type, not if cast is possible
      assert {:error, violations} = Schema.validate(%{"type" => "boolean"}, "true")
      assert Enum.any?(violations, &String.contains?(&1, "expected boolean"))
    end

    test "array passes through" do
      assert {:ok, [1, 2, 3]} = Schema.validate(%{"type" => "array"}, [1, 2, 3])
    end

    test "object passes through" do
      assert {:ok, %{"a" => 1}} = Schema.validate(%{"type" => "object"}, %{"a" => 1})
    end
  end

  describe "validate/2 — required fields" do
    test "missing required field fails" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      assert {:error, violations} = Schema.validate(schema, %{})
      assert Enum.any?(violations, &String.contains?(&1, "missing required field: name"))
    end

    test "all required fields present passes" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name", "age"]
      }

      assert {:ok, _} = Schema.validate(schema, %{"name" => "alice", "age" => 30})
    end

    test "extra fields allowed when not required" do
      schema = %{
        "type" => "object",
        "properties" => %{"name" => %{"type" => "string"}},
        "required" => ["name"]
      }

      assert {:ok, _} = Schema.validate(schema, %{"name" => "alice", "extra" => "field"})
    end
  end

  describe "validate/2 — enum" do
    test "value in enum passes" do
      schema = %{"type" => "string", "enum" => ["a", "b", "c"]}
      assert {:ok, "b"} = Schema.validate(schema, "b")
    end

    test "value not in enum fails" do
      schema = %{"type" => "string", "enum" => ["a", "b", "c"]}
      assert {:error, violations} = Schema.validate(schema, "d")
      assert Enum.any?(violations, &String.contains?(&1, "not in enum"))
    end
  end

  describe "validate/2 — string constraints" do
    test "minLength" do
      schema = %{"type" => "string", "minLength" => 3}
      assert {:ok, "abc"} = Schema.validate(schema, "abc")
      assert {:error, _} = Schema.validate(schema, "ab")
    end

    test "maxLength" do
      schema = %{"type" => "string", "maxLength" => 5}
      assert {:ok, "hello"} = Schema.validate(schema, "hello")
      assert {:error, _} = Schema.validate(schema, "toolong")
    end
  end

  describe "validate/2 — numeric constraints" do
    test "minimum" do
      schema = %{"type" => "integer", "minimum" => 0}
      assert {:ok, 5} = Schema.validate(schema, 5)
      assert {:ok, 0} = Schema.validate(schema, 0)
      assert {:error, _} = Schema.validate(schema, -1)
    end

    test "maximum" do
      schema = %{"type" => "integer", "maximum" => 100}
      assert {:ok, 100} = Schema.validate(schema, 100)
      assert {:error, _} = Schema.validate(schema, 101)
    end
  end

  describe "validate/2 — array constraints" do
    test "minItems" do
      schema = %{"type" => "array", "minItems" => 2}
      assert {:ok, [1, 2]} = Schema.validate(schema, [1, 2])
      assert {:error, _} = Schema.validate(schema, [1])
    end

    test "maxItems" do
      schema = %{"type" => "array", "maxItems" => 3}
      assert {:ok, [1, 2, 3]} = Schema.validate(schema, [1, 2, 3])
      assert {:error, _} = Schema.validate(schema, [1, 2, 3, 4])
    end

    test "items validation" do
      schema = %{
        "type" => "array",
        "items" => %{"type" => "integer"}
      }

      assert {:ok, [1, 2, 3]} = Schema.validate(schema, [1, 2, 3])
      assert {:error, violations} = Schema.validate(schema, [1, "bad", 3])
      assert Enum.any?(violations, &String.contains?(&1, "expected integer"))
    end
  end

  describe "validate/2 — nested objects" do
    test "nested property validation" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "user" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"}
            },
            "required" => ["name"]
          }
        },
        "required" => ["user"]
      }

      assert {:ok, _} = Schema.validate(schema, %{"user" => %{"name" => "alice"}})

      assert {:error, violations} = Schema.validate(schema, %{"user" => %{}})
      assert Enum.any?(violations, &String.contains?(&1, "user: missing required field: name"))
    end
  end

  describe "validate/2 — type mismatch errors" do
    test "string expected, integer given" do
      assert {:error, violations} = Schema.validate(%{"type" => "string"}, 42)
      assert Enum.any?(violations, &String.contains?(&1, "expected string"))
    end

    test "array expected, map given" do
      assert {:error, violations} = Schema.validate(%{"type" => "array"}, %{})
      assert Enum.any?(violations, &String.contains?(&1, "expected array"))
    end

    test "object expected, string given" do
      assert {:error, violations} = Schema.validate(%{"type" => "object"}, "hello")
      assert Enum.any?(violations, &String.contains?(&1, "expected object"))
    end
  end

  describe "validate/2 — no type specified" do
    test "accepts any value when type is omitted" do
      schema = %{"required" => ["x"]}
      assert {:ok, _} = Schema.validate(schema, %{"x" => 42})
      assert {:error, _} = Schema.validate(schema, %{})
    end
  end

  describe "validate!/2" do
    test "returns result on success" do
      assert "hello" = Schema.validate!(%{"type" => "string"}, "hello")
    end

    test "raises ArgumentError on failure" do
      assert_raise ArgumentError, ~r/Schema validation failed/, fn ->
        Schema.validate!(%{"type" => "string"}, 42)
      end
    end
  end

  describe "violations/2" do
    test "returns empty list for valid data" do
      assert [] = Schema.violations(%{"type" => "string"}, "hello")
    end

    test "returns list of violations for invalid data" do
      violations = Schema.violations(%{"type" => "string"}, 42)
      assert is_list(violations)
      assert length(violations) >= 1
    end
  end

  describe "cast/2" do
    test "string type" do
      assert {:ok, "hello"} = Schema.cast("string", "hello")
      assert {:ok, "42"} = Schema.cast("string", 42)
    end

    test "integer type" do
      assert {:ok, 42} = Schema.cast("integer", 42)
      assert {:ok, 42} = Schema.cast("integer", 42.7)
      assert {:ok, 42} = Schema.cast("integer", "42")
      assert {:error, _} = Schema.cast("integer", "not_a_number")
    end

    test "number type" do
      assert {:ok, 3.14} = Schema.cast("number", 3.14)
      assert {:ok, 42} = Schema.cast("number", 42)
      assert {:ok, 3.14} = Schema.cast("number", "3.14")
      assert {:error, _} = Schema.cast("number", "not_a_number")
    end

    test "boolean type" do
      assert {:ok, true} = Schema.cast("boolean", true)
      assert {:ok, false} = Schema.cast("boolean", false)
      assert {:ok, true} = Schema.cast("boolean", "true")
      assert {:ok, false} = Schema.cast("boolean", "false")
      assert {:ok, true} = Schema.cast("boolean", "True")
      assert {:ok, false} = Schema.cast("boolean", "False")
    end

    test "array type" do
      assert {:ok, [1, 2]} = Schema.cast("array", [1, 2])
    end

    test "object type" do
      assert {:ok, %{"a" => 1}} = Schema.cast("object", %{"a" => 1})
    end

    test "unsupported type" do
      assert {:error, _} = Schema.cast("unknown_type", "value")
    end
  end

  describe "format validation" do
    test "email format" do
      schema = %{"type" => "string", "format" => "email"}
      assert {:ok, _} = Schema.validate(schema, "user@example.com")
      assert {:error, violations} = Schema.validate(schema, "not-an-email")
      assert Enum.any?(violations, &String.contains?(&1, "invalid email format"))
    end

    test "uri format" do
      schema = %{"type" => "string", "format" => "uri"}
      assert {:ok, _} = Schema.validate(schema, "https://example.com")
      assert {:ok, _} = Schema.validate(schema, "http://example.com")
      assert {:error, violations} = Schema.validate(schema, "not-a-uri")
      assert Enum.any?(violations, &String.contains?(&1, "invalid uri format"))
    end
  end

  describe "complex real-world schema" do
    test "command_runner-like schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "minLength" => 1,
            "description" => "Shell command to execute"
          },
          "timeout" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 300
          }
        },
        "required" => ["command"]
      }

      # Valid input — validate checks validity, returns original data (no coercion)
      assert {:ok, result} = Schema.validate(schema, %{"command" => "ls -la", "timeout" => "30"})
      assert result["command"] == "ls -la"
      # timeout stays as "30" (string) — cast is possible but validate doesn't coerce
      assert result["timeout"] == "30"

      # Missing required
      assert {:error, _} = Schema.validate(schema, %{"timeout" => 30})

      # Command too short (minLength=1, empty string)
      assert {:error, _} = Schema.validate(schema, %{"command" => ""})

      # Timeout out of range
      assert {:error, _} = Schema.validate(schema, %{"command" => "ls", "timeout" => 500})
    end
  end
end
