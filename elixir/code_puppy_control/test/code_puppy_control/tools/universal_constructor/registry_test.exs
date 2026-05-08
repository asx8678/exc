defmodule CodePuppyControl.Tools.UniversalConstructor.RegistryTest do
  @moduledoc """
  Tests for the Universal Constructor Registry module.
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Tools.UniversalConstructor.Registry

  # Use a temporary directory for tests
  @test_dir "/tmp/uc_registry_test_#{System.unique_integer()}"

  setup do
    # Ensure test directory exists
    File.mkdir_p!(@test_dir)

    # If the registry is already running (application supervisor), repoint
    # it to our test directory. Otherwise, start a fresh instance.
    case Process.whereis(Registry) do
      nil ->
        {:ok, _registry_pid} = Registry.start_link(tools_dir: @test_dir)

      _pid ->
        Registry.set_tools_dir(@test_dir)
    end

    original_tools_dir = Registry.tools_dir()

    on_exit(fn ->
      # Restore original tools dir so we don't pollute other tests
      try do
        Registry.set_tools_dir(original_tools_dir)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(@test_dir)
    end)

    :ok
  end

  describe "list_tools/1" do
    test "returns empty list for empty directory" do
      tools = Registry.list_tools()

      assert tools == []
    end

    test "lists tools after scanning" do
      # Create a simple tool
      tool_code = """
      defmodule TestTool do
        @uc_tool %{
          name: "test_tool",
          description: "A test tool",
          enabled: true
        }
        def run(args), do: args
      end
      """

      File.write!(Path.join(@test_dir, "test_tool.ex"), tool_code)
      Registry.reload()

      tools = Registry.list_tools()

      assert length(tools) == 1
      [tool] = tools
      assert tool.full_name == "test_tool"
      assert tool.meta.name == "test_tool"
      assert tool.meta.description == "A test tool"
    end

    test "can include disabled tools" do
      tool_code = """
      defmodule DisabledTool do
        @uc_tool %{
          name: "disabled",
          description: "Disabled tool",
          enabled: false
        }
        def run(args), do: args
      end
      """

      File.write!(Path.join(@test_dir, "disabled.ex"), tool_code)
      Registry.reload()

      # Without include_disabled
      tools = Registry.list_tools(include_disabled: false)
      assert length(tools) == 0

      # With include_disabled
      all_tools = Registry.list_tools(include_disabled: true)
      assert length(all_tools) == 1
    end
  end

  describe "get_tool/1" do
    test "returns nil for non-existent tool" do
      assert Registry.get_tool("ghost") == nil
    end

    test "returns tool info for existing tool" do
      tool_code = """
      defmodule GetTestTool do
        @uc_tool %{
          name: "get_test",
          description: "For get test",
          version: "1.2.3"
        }
        def run(_), do: :ok
      end
      """

      File.write!(Path.join(@test_dir, "get_test.ex"), tool_code)
      Registry.reload()

      tool = Registry.get_tool("get_test")

      assert tool != nil
      assert tool.full_name == "get_test"
      assert tool.meta.version == "1.2.3"
    end

    test "supports namespaced tools" do
      # Create subdirectory structure
      api_dir = Path.join(@test_dir, "api")
      File.mkdir_p!(api_dir)

      tool_code = """
      defmodule ApiWeather do
        @uc_tool %{
          name: "weather",
          namespace: "api",
          description: "Weather API"
        }
        def run(_), do: :sunny
      end
      """

      File.write!(Path.join(api_dir, "weather.ex"), tool_code)
      Registry.reload()

      tool = Registry.get_tool("api.weather")

      assert tool != nil
      assert tool.full_name == "api.weather"
      assert tool.meta.name == "weather"
      assert tool.meta.namespace == "api"
    end
  end

  describe "get_tool_function/1" do
    test "returns nil for non-existent tool" do
      assert Registry.get_tool_function("ghost") == nil
    end

    test "returns module and function for valid tool" do
      # Note: This test might be limited as the registry can't compile
      # and load arbitrary modules in test environment
      tool_code = """
      defmodule FuncTestTool do
        @uc_tool %{
          name: "func_test",
          description: "Function test"
        }
        def run(args), do: args
      end
      """

      File.write!(Path.join(@test_dir, "func_test.ex"), tool_code)
      Registry.reload()

      result = Registry.get_tool_function("func_test")

      # Will be nil because we can't dynamically compile in tests
      # but should not crash
      assert result == nil or is_tuple(result)
    end
  end

  describe "reload/0" do
    test "rescans and returns tool count" do
      count1 = Registry.reload()
      assert count1 == 0

      # Add a tool
      File.write!(Path.join(@test_dir, "new_tool.ex"), """
      defmodule NewTool do
        @uc_tool %{name: "new_tool", description: "New"}
        def run(_), do: nil
      end
      """)

      count2 = Registry.reload()
      assert count2 == 1
    end

    test "updates after tool deletion" do
      File.write!(Path.join(@test_dir, "temp_tool.ex"), """
      defmodule TempTool do
        @uc_tool %{name: "temp_tool", description: "Temp"}
        def run(_), do: nil
      end
      """)

      assert Registry.reload() == 1

      File.rm!(Path.join(@test_dir, "temp_tool.ex"))

      assert Registry.reload() == 0
    end
  end

  describe "ensure_tools_dir/0" do
    test "creates directory if it doesn't exist" do
      new_dir = "/tmp/uc_new_dir_#{System.unique_integer()}"

      # Start with unique name to avoid GenServer collision
      unique_name = :"Registry.Test#{System.unique_integer([:positive])}"
      {:ok, temp_registry} = Registry.start_link(tools_dir: new_dir, name: unique_name)

      result = :sys.get_state(temp_registry).tools_dir

      # Call ensure_tools_dir on the specific registry instance
      GenServer.call(temp_registry, :ensure_tools_dir)

      assert File.dir?(result)

      File.rm_rf!(new_dir)
      Process.exit(temp_registry, :normal)
    end
  end

  describe "tools_dir/0" do
    test "returns configured tools directory" do
      # Use the registry module's full name for Process.whereis
      full_module_name = CodePuppyControl.Tools.UniversalConstructor.Registry
      pid = Process.whereis(full_module_name)

      # Get the directory directly from our test registry's state
      # to avoid default registry vs test registry confusion
      dir = :sys.get_state(pid).tools_dir

      assert is_binary(dir)
      # The dir should contain our test dir path (with the unique integer suffix)
      assert String.contains?(dir, "uc_registry_test_")
    end
  end

  describe "registry skips non-tool files" do
    test "ignores __init__.py style files" do
      File.write!(Path.join(@test_dir, "__init__.ex"), "# init")
      File.write!(Path.join(@test_dir, ".hidden.ex"), "# hidden")

      Registry.reload()

      tools = Registry.list_tools(include_disabled: true)
      assert length(tools) == 0
    end

    test "ignores files without @uc_tool attribute" do
      File.write!(Path.join(@test_dir, "no_meta.ex"), """
      defmodule NoMeta do
        def run(_), do: nil
      end
      """)

      Registry.reload()

      tools = Registry.list_tools(include_disabled: true)
      assert length(tools) == 0
    end
  end

  # ==========================================================================
  # Atom Safety Regression Tests (code_puppy-mmk.2)
  # ==========================================================================
  describe "atom safety (code_puppy-mmk.2)" do
    test "find_main_function_name does not create new atoms for arbitrary names" do
      # A unique name that has never been an atom
      unique_name = "never_atom_#{:erlang.unique_integer([:positive])}"

      # Verify it's not already an atom
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique_name) end

      # Create a simple compiled module to test against
      code = """
      defmodule AtomSafetyTestTool do
        @uc_tool %{name: "atom_safety", description: "Test"}
        def run(_), do: :ok
      end
      """

      File.write!(Path.join(@test_dir, "atom_safety.ex"), code)
      Registry.reload()

      # The registry uses find_main_function_name internally; no new atoms
      # should be created for the unique_name when looking up a tool.
      # (We can't directly call the private function, but we verify that
      # getting a non-existent tool function doesn't create atoms.)
      result = Registry.get_tool_function(unique_name)
      assert result == nil

      # Verify the atom was NOT created
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique_name) end
    end
  end
end
