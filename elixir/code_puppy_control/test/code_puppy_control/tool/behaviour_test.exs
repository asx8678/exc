defmodule CodePuppyControl.Tool.BehaviourTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Tool

  # ── Test Tool Modules ─────────────────────────────────────────────────────

  # Minimal tool implementing all callbacks directly
  defmodule MinimalTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :minimal_tool

    @impl true
    def description, do: "A minimal test tool"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string"}
        }
      }
    end

    @impl true
    def invoke(%{"input" => input}, _ctx) do
      {:ok, "processed: #{input}"}
    end
  end

  # Tool relying on default invoke/2 that delegates to execute/1
  defmodule LegacyTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :legacy_tool

    @impl true
    def description, do: "A tool using legacy execute/1 pattern"

    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{}}
    end

    # Define execute/1 instead of invoke/2
    def execute(args) do
      {:ok, "legacy result: #{inspect(args)}"}
    end
  end

  # Tool with neither invoke/2 nor execute/1 - should error
  defmodule IncompleteTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :incomplete_tool

    @impl true
    def description, do: "A tool without invoke or execute"

    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{}}
    end
  end

  # Tool with overridden permission_check
  defmodule CustomPermissionTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :custom_permission_tool

    @impl true
    def description, do: "A tool with custom permission check"

    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{}}
    end

    @impl true
    def permission_check(args, _ctx) do
      if Map.get(args, "allowed") == true do
        :ok
      else
        {:deny, "Not allowed"}
      end
    end

    @impl true
    def invoke(_args, _ctx) do
      {:ok, "executed"}
    end
  end

  # Tool with overridden tool_schema
  defmodule CustomSchemaTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :custom_schema_tool

    @impl true
    def description, do: "A tool with custom schema"

    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{}}
    end

    @impl true
    def tool_schema do
      %{
        type: "custom_function",
        custom_data: "extra info",
        function: %{
          name: "custom_name",
          description: description(),
          parameters: parameters()
        }
      }
    end

    @impl true
    def invoke(_args, _ctx) do
      {:ok, "executed"}
    end
  end

  # Tool with overridden invoke/2 (not using default delegation)
  defmodule CustomInvokeTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :custom_invoke_tool

    @impl true
    def description, do: "A tool with custom invoke"

    @impl true
    def parameters do
      %{"type" => "object", "properties" => %{}}
    end

    @impl true
    def invoke(args, ctx) do
      context_info = Map.get(ctx, :test_context, "none")
      {:ok, "invoked with context: #{context_info}, args: #{inspect(args)}"}
    end
  end

  # Tool that only implements name/0, description/0, parameters/0 (no tool_schema)
  defmodule BasicTool do
    # Note: does NOT use CodePuppyControl.Tool, only implements the core 3 callbacks
    def name, do: :basic_tool
    def description, do: "A basic tool without behaviour"
    def parameters, do: %{"type" => "object", "properties" => %{}}
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "minimal module using the behaviour" do
    test "compiles and satisfies all @behaviour callbacks" do
      # Verify all required callbacks are exported
      assert function_exported?(MinimalTool, :name, 0)
      assert function_exported?(MinimalTool, :description, 0)
      assert function_exported?(MinimalTool, :parameters, 0)
      assert function_exported?(MinimalTool, :invoke, 2)
      assert function_exported?(MinimalTool, :permission_check, 2)
      assert function_exported?(MinimalTool, :tool_schema, 0)
    end

    test "returns correct values from all callbacks" do
      assert MinimalTool.name() == :minimal_tool
      assert MinimalTool.description() == "A minimal test tool"
      assert is_map(MinimalTool.parameters())
      assert MinimalTool.parameters()["type"] == "object"
    end
  end

  describe "default permission_check/2" do
    test "returns :ok for MinimalTool" do
      assert MinimalTool.permission_check(%{}, %{}) == :ok
      assert MinimalTool.permission_check(%{"anything" => true}, %{run_id: 123}) == :ok
    end

    test "returns :ok for LegacyTool" do
      assert LegacyTool.permission_check(%{}, %{}) == :ok
    end
  end

  describe "default tool_schema/0" do
    test "builds correct map structure" do
      schema = MinimalTool.tool_schema()

      assert schema.type == "function"
      assert is_map(schema.function)
      assert schema.function.name == "minimal_tool"
      assert schema.function.description == "A minimal test tool"
      assert is_map(schema.function.parameters)
      assert schema.function.parameters["type"] == "object"
    end

    test "uses string name from atom name/0" do
      schema = LegacyTool.tool_schema()
      assert schema.function.name == "legacy_tool"
    end
  end

  describe "default invoke/2 delegating to execute/1" do
    test "delegates to execute/1 when defined" do
      args = %{"key" => "value"}
      assert LegacyTool.invoke(args, %{}) == {:ok, "legacy result: #{inspect(args)}"}
    end

    test "returns result from execute/1 unchanged" do
      # Test with empty args
      result = LegacyTool.invoke(%{}, %{})
      assert {:ok, "legacy result: %{}"} = result
    end
  end

  describe "default invoke/2 without execute/1" do
    test "returns {:error, msg} when neither invoke/2 nor execute/1 is overridden" do
      result = IncompleteTool.invoke(%{}, %{})
      assert {:error, message} = result
      assert message =~ "incomplete_tool"
      assert message =~ "does not implement invoke/2 or execute/1"
    end
  end

  describe "defoverridable works for user overrides" do
    test "can override permission_check/2" do
      # CustomPermissionTool has custom permission check
      assert CustomPermissionTool.permission_check(%{"allowed" => true}, %{}) == :ok

      assert CustomPermissionTool.permission_check(%{"allowed" => false}, %{}) ==
               {:deny, "Not allowed"}

      assert CustomPermissionTool.permission_check(%{}, %{}) == {:deny, "Not allowed"}
    end

    test "can override tool_schema/0" do
      schema = CustomSchemaTool.tool_schema()
      assert schema.type == "custom_function"
      assert schema.custom_data == "extra info"
      assert schema.function.name == "custom_name"
    end

    test "can override invoke/2" do
      result = CustomInvokeTool.invoke(%{"test" => true}, %{test_context: "hello"})
      assert {:ok, "invoked with context: hello, args:" <> _} = result
    end

    test "overridden invoke/2 receives args and context" do
      result = CustomInvokeTool.invoke(%{key: "value"}, %{test_context: "world"})
      assert result == {:ok, "invoked with context: world, args: %{key: \"value\"}"}
    end
  end

  describe "Tool.to_llm_format/1" do
    test "uses tool_schema/0 when available" do
      result = Tool.to_llm_format(CustomSchemaTool)

      # Should use the custom tool_schema/0
      assert result.type == "custom_function"
      assert result.custom_data == "extra info"
      assert result.function.name == "custom_name"
    end

    test "uses fallback path when module has only name/0, description/0, parameters/0" do
      result = Tool.to_llm_format(BasicTool)

      # Fallback should build from the 3 core callbacks
      assert result.type == "function"
      assert result.function.name == "basic_tool"
      assert result.function.description == "A basic tool without behaviour"
      assert result.function.parameters == %{"type" => "object", "properties" => %{}}
    end

    test "fallback path converts atom name to string" do
      result = Tool.to_llm_format(BasicTool)
      assert is_binary(result.function.name)
      assert result.function.name == "basic_tool"
    end

    test "works with modules using the full behaviour" do
      result = Tool.to_llm_format(MinimalTool)
      assert result.type == "function"
      assert result.function.name == "minimal_tool"
      assert is_map(result.function.parameters)
    end
  end
end
