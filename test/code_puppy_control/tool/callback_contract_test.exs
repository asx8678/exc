defmodule CodePuppyControl.Tool.CallbackContractTest do
  @moduledoc """
  Tests for the Tool behaviour callback contract.

  Ports the spirit of Python's test_tool_schema.py @tool decorator tests:
  - A module using `use CodePuppyControl.Tool` satisfies all callbacks
  - tool_schema/0 is consistent with name/0, description/0, parameters/0
  - invoke/2 with custom implementation overrides default
  - permission_check/2 default returns :ok; custom override works
  - to_llm_format/1 produces correct structure for LLM consumption

  These are Wave 2 tests for .
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tool

  # ── Test Modules ─────────────────────────────────────────────────────────

  defmodule SimpleTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :simple_tool

    @impl true
    def description, do: "A simple test tool"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string", "description" => "Input text"}
        },
        "required" => ["input"]
      }
    end

    @impl true
    def invoke(%{"input" => input}, _ctx), do: {:ok, "echo: #{input}"}
  end

  defmodule MultiParamTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :multi_param

    @impl true
    def description, do: "Tool with multiple parameter types"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path"},
          "count" => %{"type" => "integer", "description" => "Number of items"},
          "verbose" => %{"type" => "boolean", "description" => "Verbose output"},
          "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
        },
        "required" => ["path", "count"]
      }
    end

    @impl true
    def invoke(%{"path" => p, "count" => c}, _ctx), do: {:ok, "#{p}:#{c}"}
  end

  defmodule ErrorTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :error_tool

    @impl true
    def description, do: "A tool that always errors"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def invoke(_args, _ctx), do: {:error, "deliberate failure"}
  end

  defmodule RestrictedTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :restricted_tool

    @impl true
    def description, do: "A tool with permission checks"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def permission_check(%{"admin" => true}, _ctx), do: :ok
    def permission_check(_args, _ctx), do: {:deny, "admin required"}

    @impl true
    def invoke(_args, _ctx), do: {:ok, "restricted result"}
  end

  defmodule LegacyCompatTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :legacy_compat

    @impl true
    def description, do: "Tool using execute/1 pattern"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    # No invoke/2 — relies on execute/1
    def execute(args), do: {:ok, "legacy: #{inspect(args)}"}
  end

  # Module WITHOUT using the behaviour — only has the 3 core functions
  defmodule BareTool do
    def name, do: :bare_tool
    def description, do: "A bare tool without behaviour"
    def parameters, do: %{"type" => "object", "properties" => %{}}
  end

  # ── Callback contract tests ─────────────────────────────────────────────

  describe "use CodePuppyControl.Tool satisfies all callbacks" do
    test "SimpleTool exports all required callbacks" do
      assert function_exported?(SimpleTool, :name, 0)
      assert function_exported?(SimpleTool, :description, 0)
      assert function_exported?(SimpleTool, :parameters, 0)
      assert function_exported?(SimpleTool, :invoke, 2)
      assert function_exported?(SimpleTool, :permission_check, 2)
      assert function_exported?(SimpleTool, :tool_schema, 0)
    end

    test "callback return types match contract" do
      # name/0 returns atom
      assert is_atom(SimpleTool.name())

      # description/0 returns string
      assert is_binary(SimpleTool.description())

      # parameters/0 returns map
      assert is_map(SimpleTool.parameters())

      # invoke/2 returns {:ok, _} or {:error, _}
      assert {:ok, _} = SimpleTool.invoke(%{"input" => "test"}, %{})

      # permission_check/2 returns :ok or {:deny, _}
      assert :ok = SimpleTool.permission_check(%{}, %{})

      # tool_schema/0 returns map
      assert is_map(SimpleTool.tool_schema())
    end
  end

  # ── tool_schema/0 consistency ────────────────────────────────────────────

  describe "tool_schema/0 is consistent with name/description/parameters" do
    test "default tool_schema builds from name/description/parameters" do
      schema = SimpleTool.tool_schema()

      assert schema.type == "function"
      assert schema.function.name == to_string(SimpleTool.name())
      assert schema.function.description == SimpleTool.description()
      assert schema.function.parameters == SimpleTool.parameters()
    end

    test "tool_schema function name is a string (not atom)" do
      schema = SimpleTool.tool_schema()
      assert is_binary(schema.function.name)
    end

    test "multi-param tool schema has correct parameter types" do
      schema = MultiParamTool.tool_schema()
      params = schema.function.parameters

      assert params["properties"]["path"]["type"] == "string"
      assert params["properties"]["count"]["type"] == "integer"
      assert params["properties"]["verbose"]["type"] == "boolean"
      assert params["properties"]["tags"]["type"] == "array"
      assert params["required"] == ["path", "count"]
    end
  end

  # ── invoke/2 contract ───────────────────────────────────────────────────

  describe "invoke/2 contract" do
    test "returns {:ok, result} on success" do
      assert {:ok, "echo: hello"} = SimpleTool.invoke(%{"input" => "hello"}, %{})
    end

    test "returns {:error, reason} on failure" do
      assert {:error, "deliberate failure"} = ErrorTool.invoke(%{}, %{})
    end

    test "receives args and context" do
      ctx = %{run_id: 42, agent_module: SomeModule}
      assert {:ok, "/path:10"} = MultiParamTool.invoke(%{"path" => "/path", "count" => 10}, ctx)
    end

    test "context is passed through but not modified" do
      ctx = %{extra: "data"}
      {:ok, _} = SimpleTool.invoke(%{"input" => "test"}, ctx)
      # Context should be unchanged — just passed through
    end
  end

  # ── Legacy execute/1 delegation ─────────────────────────────────────────

  describe "legacy execute/1 delegation" do
    test "default invoke/2 delegates to execute/1 when defined" do
      args = %{"key" => "value"}
      assert {:ok, result} = LegacyCompatTool.invoke(args, %{})
      assert result =~ "legacy:"
      assert result =~ "key"
    end
  end

  # ── permission_check/2 contract ──────────────────────────────────────────

  describe "permission_check/2 contract" do
    test "default implementation always returns :ok" do
      assert :ok = SimpleTool.permission_check(%{}, %{})
      assert :ok = SimpleTool.permission_check(%{"anything" => true}, %{run_id: 1})
    end

    test "custom implementation can return {:deny, reason}" do
      assert :ok = RestrictedTool.permission_check(%{"admin" => true}, %{})
      assert {:deny, "admin required"} = RestrictedTool.permission_check(%{}, %{})
    end

    test "permission_check runs before invoke in the contract" do
      # If permission is denied, invoke should not be called
      result = RestrictedTool.permission_check(%{}, %{})
      assert {:deny, _} = result
      # The tool still works when permission is granted
      assert :ok = RestrictedTool.permission_check(%{"admin" => true}, %{})
      assert {:ok, _} = RestrictedTool.invoke(%{}, %{})
    end
  end

  # ── to_llm_format/1 ──────────────────────────────────────────────────────

  describe "Tool.to_llm_format/1" do
    test "produces correct LLM function format for behaviour modules" do
      result = Tool.to_llm_format(SimpleTool)

      assert result.type == "function"
      assert result.function.name == "simple_tool"
      assert result.function.description == "A simple test tool"
      assert result.function.parameters["type"] == "object"
      assert result.function.parameters["properties"]["input"]["type"] == "string"
    end

    test "produces correct format for multi-param tool" do
      result = Tool.to_llm_format(MultiParamTool)

      assert result.type == "function"
      assert result.function.name == "multi_param"
      assert length(Map.keys(result.function.parameters["properties"])) == 4
    end

    test "works for modules without the behaviour (fallback)" do
      result = Tool.to_llm_format(BareTool)

      assert result.type == "function"
      assert result.function.name == "bare_tool"
      assert result.function.description == "A bare tool without behaviour"
    end

    test "fallback converts atom name to string" do
      result = Tool.to_llm_format(BareTool)
      assert is_binary(result.function.name)
    end
  end

  # ── Empty parameters edge case ───────────────────────────────────────────

  describe "edge cases" do
    test "tool with empty parameters still produces valid schema" do
      schema = ErrorTool.tool_schema()

      assert schema.type == "function"
      assert schema.function.name == "error_tool"
      assert schema.function.parameters == %{"type" => "object", "properties" => %{}}
    end

    test "invoke with empty args map" do
      assert {:error, _} = ErrorTool.invoke(%{}, %{})
    end

    test "tool name is always an atom" do
      assert is_atom(SimpleTool.name())
      assert is_atom(MultiParamTool.name())
      assert is_atom(ErrorTool.name())
      assert is_atom(RestrictedTool.name())
    end

    test "description is always a string" do
      assert is_binary(SimpleTool.description())
      assert is_binary(MultiParamTool.description())
    end
  end
end
