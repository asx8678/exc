defmodule CodePuppyControl.CLI.SlashCommands.Commands.UCTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.UC
  alias CodePuppyControl.Tools.UniversalConstructor.Registry, as: UCRegistry

  @tmp_dir System.tmp_dir!()
  @test_uc_dir Path.join(@tmp_dir, "uc_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@test_uc_dir)

    # Ensure the UC Registry GenServer is running with our test tools dir.
    # If already started (e.g. by the application supervisor), repoint it
    # to our isolated test directory using set_tools_dir/1 rather than
    # trying to stop and restart (which conflicts with the supervisor).
    case Process.whereis(UCRegistry) do
      nil ->
        start_supervised!({UCRegistry, tools_dir: @test_uc_dir})

      _pid ->
        # Already running — repoint to test directory
        UCRegistry.set_tools_dir(@test_uc_dir)
    end

    # Start the Slash Commands Registry GenServer if not already running
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()

    # Register /uc command
    :ok =
      Registry.register(
        CommandInfo.new(
          name: "uc",
          description: "Browse and manage Universal Constructor tools",
          handler: &UC.handle_uc/2,
          usage: "/uc [toggle <name> | info <name>]",
          aliases: ["universal_constructor"],
          category: "context"
        )
      )

    original_tools_dir = UCRegistry.tools_dir()

    on_exit(fn ->
      Registry.clear()
      Registry.register_builtin_commands()
      # Restore original tools dir so we don't pollute other tests
      try do
        UCRegistry.set_tools_dir(original_tools_dir)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(@test_uc_dir)
    end)

    :ok
  end

  describe "/uc (no args) — empty tools dir" do
    test "shows Universal Constructor Tools header" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc", %{})
        end)

      assert output =~ "Universal Constructor Tools"
    end

    test "shows 'no tools found' when empty" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc", %{})
        end)

      assert output =~ "No UC tools found"
    end

    test "shows usage hint" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc", %{})
        end)

      assert output =~ "/uc toggle"
      assert output =~ "/uc info"
    end

    test "returns continue" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, %{}} = UC.handle_uc("/uc", %{})
      end)
    end
  end

  describe "/uc (no args) — with tools" do
    setup do
      # Create a test UC tool file
      tool_content = """
      defmodule TestGreeter do
        @uc_tool %{
          name: "greeter",
          namespace: "",
          description: "Says hello to someone",
          enabled: true,
          version: "1.0.0",
          author: "test"
        }

        def run(args) do
          "Hello, \#{Map.get(args, "name", "World")}!"
        end
      end
      """

      File.write!(Path.join(@test_uc_dir, "greeter.ex"), tool_content)

      # Create a disabled tool
      disabled_content = """
      defmodule TestDisabled do
        @uc_tool %{
          name: "disabled_tool",
          namespace: "",
          description: "A disabled tool",
          enabled: false,
          version: "1.0.0",
          author: "test"
        }

        def run(_args) do
          :ok
        end
      end
      """

      File.write!(Path.join(@test_uc_dir, "disabled_tool.ex"), disabled_content)

      # Reload registry to pick up new tools
      UCRegistry.reload()

      :ok
    end

    test "lists tools with enabled count" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc", %{})
        end)

      assert output =~ "1 enabled of 2 total"
    end

    test "shows tool names with on/off status" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc", %{})
        end)

      assert output =~ "[on]"
      assert output =~ "[off]"
      assert output =~ "greeter"
      assert output =~ "disabled_tool"
    end
  end

  describe "/uc info <tool_name>" do
    setup do
      tool_content = """
      defmodule TestInfoTool do
        @uc_tool %{
          name: "infotool",
          namespace: "",
          description: "A tool for testing info display",
          enabled: true,
          version: "2.1.0",
          author: "test_author"
        }

        def run(args) do
          Map.get(args, "key", "default")
        end
      end
      """

      File.write!(Path.join(@test_uc_dir, "infotool.ex"), tool_content)
      UCRegistry.reload()

      :ok
    end

    test "shows tool details" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc info infotool", %{})
        end)

      assert output =~ "Tool:"
      assert output =~ "infotool"
      assert output =~ "A tool for testing info display"
      assert output =~ "ENABLED"
      assert output =~ "2.1.0"
      assert output =~ "test_author"
    end

    test "shows source path" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc info infotool", %{})
        end)

      assert output =~ "infotool.ex"
    end

    test "shows signature" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc info infotool", %{})
        end)

      assert output =~ "Signature:"
    end

    test "shows error for unknown tool" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc info nonexistent", %{})
        end)

      assert output =~ "Unknown tool"
      assert output =~ "nonexistent"
    end
  end

  describe "/uc toggle <tool_name>" do
    setup do
      tool_content = """
      defmodule TestToggleTool do
        @uc_tool %{
          name: "toggleme",
          namespace: "",
          description: "A tool for testing toggle",
          enabled: true,
          version: "1.0.0",
          author: "test"
        }

        def run(_args) do
          :ok
        end
      end
      """

      File.write!(Path.join(@test_uc_dir, "toggleme.ex"), tool_content)
      UCRegistry.reload()

      :ok
    end

    test "toggles enabled tool to disabled" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc toggle toggleme", %{})
        end)

      assert output =~ "disabled"

      # Verify the file was actually modified
      content = File.read!(Path.join(@test_uc_dir, "toggleme.ex"))
      assert content =~ "enabled: false"
    end

    test "toggles disabled tool back to enabled" do
      # First toggle: enabled → disabled
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, _} = UC.handle_uc("/uc toggle toggleme", %{})
      end)

      # Second toggle: disabled → enabled
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc toggle toggleme", %{})
        end)

      assert output =~ "enabled"

      content = File.read!(Path.join(@test_uc_dir, "toggleme.ex"))
      assert content =~ "enabled: true"
    end

    test "shows error for unknown tool" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc toggle unknown_tool", %{})
        end)

      assert output =~ "Unknown tool"
    end
  end

  describe "/uc with invalid usage" do
    test "shows usage for unknown subcommand" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc delete something", %{})
        end)

      assert output =~ "Usage"
      assert output =~ "/uc"
    end

    test "shows usage for toggle without tool name" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc toggle", %{})
        end)

      assert output =~ "Usage"
    end

    test "shows usage for info without tool name" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = UC.handle_uc("/uc info", %{})
        end)

      assert output =~ "Usage"
    end
  end

  describe "registration and dispatch" do
    test "/uc is registered and dispatchable" do
      assert {:ok, _} = Registry.get("uc")
    end

    test "/uc dispatches via Dispatcher" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, {:continue, _}} = Dispatcher.dispatch("/uc", %{})
        end)

      assert output =~ "Universal Constructor Tools"
    end

    test "/uc appears in all_names for tab completion" do
      names = Registry.all_names()
      assert "uc" in names
    end

    test "/uc is in context category" do
      commands = Registry.list_by_category("context")
      uc_cmd = Enum.find(commands, &(&1.name == "uc"))
      assert uc_cmd != nil
      assert uc_cmd.category == "context"
    end

    test "/uc has alias 'universal_constructor'" do
      assert {:ok, cmd} = Registry.get("universal_constructor")
      assert cmd.name == "uc"
    end

    test "/uc usage is correct" do
      {:ok, cmd} = Registry.get("uc")
      assert cmd.usage =~ "/uc"
    end
  end

  describe "register_builtin_commands/0" do
    test "registers /uc after clear and re-register" do
      Registry.clear()
      # The built-in registration should add /uc back
      Registry.register_builtin_commands()
      assert {:ok, cmd} = Registry.get("uc")
      assert cmd.name == "uc"
    end

    test "registers /uc with alias 'universal_constructor' via builtin" do
      Registry.clear()
      Registry.register_builtin_commands()
      assert {:ok, cmd} = Registry.get("universal_constructor")
      assert cmd.name == "uc"
    end
  end

  describe "/uc toggle — targeted replacement" do
    setup do
      # Create a tool file with MULTIPLE 'enabled:' occurrences — one inside
      # @uc_tool and one in regular code. Toggle must ONLY modify the @uc_tool one.
      tool_content = """
      defmodule TestTargetedToggle do
        @uc_tool %{
          name: "targeted",
          namespace: "",
          description: "Tests targeted toggle replacement",
          enabled: true,
          version: "1.0.0",
          author: "test"
        }

        # Config that also has 'enabled:' — must NOT be modified
        @feature_flag %{enabled: true, name: "other_feature"}

        def run(_args) do
          :ok
        end
      end
      """

      File.write!(Path.join(@test_uc_dir, "targeted.ex"), tool_content)
      UCRegistry.reload()

      :ok
    end

    test "toggle only rewrites @uc_tool enabled, not other enabled: occurrences" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, _} = UC.handle_uc("/uc toggle targeted", %{})
      end)

      content = File.read!(Path.join(@test_uc_dir, "targeted.ex"))

      # The @uc_tool block should now have enabled: false
      assert content =~ "enabled: false"

      # The @feature_flag must still have enabled: true
      assert content =~ "@feature_flag %{enabled: true"
    end

    test "toggle round-trips without corrupting other enabled: fields" do
      # Toggle off
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, _} = UC.handle_uc("/uc toggle targeted", %{})
      end)

      # Toggle back on
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, _} = UC.handle_uc("/uc toggle targeted", %{})
      end)

      content = File.read!(Path.join(@test_uc_dir, "targeted.ex"))

      # @uc_tool should be back to enabled: true
      assert content =~ "enabled: true"

      # @feature_flag must still be enabled: true throughout
      assert content =~ "@feature_flag %{enabled: true"
    end
  end

  describe "/uc toggle — safe replacement (regression test)" do
    setup do
      # Create a tool file where @uc_tool has 'enabled:' in a description string.
      # The toggle should only replace the top-level enabled field, not touch the string.
      # Note: nested maps in @uc_tool break the registry's regex extraction, so we put
      # the nested map in a separate module attribute to test it's not corrupted.
      tool_content = """
      defmodule SafeToggle2 do
        @uc_tool %{
          name: "safe_toggle2",
          namespace: "",
          description: "Has enabled: true in the string",
          enabled: true,
          version: "1.0.0",
          author: "test"
        }

        # Config with nested enabled — should NOT be modified by toggle
        @config %{nested: %{enabled: true, name: "inner"}}

        def run(_args) do
          :ok
        end
      end
      """

      File.write!(Path.join(@test_uc_dir, "safe_toggle2.ex"), tool_content)
      UCRegistry.reload()

      :ok
    end

    test "toggle only replaces top-level enabled, not strings or nested maps" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, _} = UC.handle_uc("/uc toggle safe_toggle2", %{})
      end)

      content = File.read!(Path.join(@test_uc_dir, "safe_toggle2.ex"))

      # Top-level enabled should be toggled to false
      assert content =~ ~r/@uc_tool %\{[^}]*enabled: false/s

      # Description string must be unchanged (still has 'enabled: true' in the string)
      assert content =~ ~r/description: "Has enabled: true in the string"/s

      # The @config nested map must be unchanged
      assert content =~ ~r/@config %\{nested: %\{enabled: true/s
    end

    test "toggle round-trip preserves strings and nested maps" do
      # Toggle off
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, _} = UC.handle_uc("/uc toggle safe_toggle2", %{})
      end)

      # Toggle back on
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, _} = UC.handle_uc("/uc toggle safe_toggle2", %{})
      end)

      content = File.read!(Path.join(@test_uc_dir, "safe_toggle2.ex"))

      # Top-level enabled should be back to true
      assert content =~ ~r/@uc_tool %\{[^}]*enabled: true/s

      # Description string must still be unchanged
      assert content =~ ~r/description: "Has enabled: true in the string"/s

      # The @config nested map must still be unchanged
      assert content =~ ~r/@config %\{nested: %\{enabled: true/s
    end
  end

  describe "structural toggle — nested map inside @uc_tool" do
    setup do
      # File with a nested map INSIDE @uc_tool containing its own enabled: key.
      # The registry cannot parse this, so we test toggle_enabled_in_source directly.
      dir = Path.join(System.tmp_dir!(), "uc_struct_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      file_path = Path.join(dir, "nested_map.ex")

      content = """
      defmodule NestedMapTool do
        @uc_tool %{
          name: "nested_map",
          namespace: "",
          description: "Tool with nested config",
          enabled: true,
          version: "1.0.0",
          author: "test",
          config: %{
            enabled: false,
            label: "inner"
          }
        }

        def run(_args), do: :ok
      end
      """

      File.write!(file_path, content)

      on_exit(fn -> File.rm_rf!(dir) end)

      %{file_path: file_path, dir: dir}
    end

    test "toggle replaces only top-level enabled, not nested map's enabled", %{file_path: path} do
      assert :ok = UC.toggle_enabled_in_source(path, true)

      content = File.read!(path)

      # Top-level enabled should be toggled to false
      assert content =~ ~r/@uc_tool %\{.*enabled: false/s

      # Nested config.enabled must remain false (unchanged)
      assert content =~ ~r/config: %\{.*enabled: false/s
    end

    test "toggle round-trip preserves nested map", %{file_path: path} do
      assert :ok = UC.toggle_enabled_in_source(path, true)
      assert :ok = UC.toggle_enabled_in_source(path, false)

      content = File.read!(path)

      # Top-level enabled should be back to true
      assert content =~ ~r/@uc_tool %\{.*enabled: true/s

      # Nested config.enabled must still be false
      assert content =~ ~r/config: %\{.*enabled: false/s
    end
  end

  describe "structural toggle — string with enabled: inside @uc_tool" do
    setup do
      dir = Path.join(System.tmp_dir!(), "uc_struct_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      file_path = Path.join(dir, "string_enabled.ex")

      # The description string contains "enabled: true" as text.
      # The toggle must NOT replace the text inside the string.
      content = """
      defmodule StringEnabledTool do
        @uc_tool %{
          name: "string_enabled",
          namespace: "",
          description: "Contains enabled: true in text",
          enabled: true,
          version: "1.0.0",
          author: "test"
        }

        def run(_args), do: :ok
      end
      """

      File.write!(file_path, content)

      on_exit(fn -> File.rm_rf!(dir) end)

      %{file_path: file_path}
    end

    test "toggle does not replace enabled: inside a string literal", %{file_path: path} do
      assert :ok = UC.toggle_enabled_in_source(path, true)

      content = File.read!(path)

      # Top-level enabled should be toggled to false
      assert content =~ ~r/enabled: false/

      # The description string must still contain 'enabled: true' as text
      assert content =~ ~r/description: "Contains enabled: true in text"/
    end

    test "toggle round-trip preserves string content", %{file_path: path} do
      assert :ok = UC.toggle_enabled_in_source(path, true)
      assert :ok = UC.toggle_enabled_in_source(path, false)

      content = File.read!(path)

      # Top-level enabled should be back to true
      assert content =~ ~r/enabled: true/

      # The description string must still contain 'enabled: true' as text
      assert content =~ ~r/description: "Contains enabled: true in text"/
    end
  end

  describe "structural toggle — top-level enabled IS changed" do
    setup do
      dir = Path.join(System.tmp_dir!(), "uc_struct_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      file_path = Path.join(dir, "toplevel.ex")

      content = """
      defmodule TopLevelTool do
        @uc_tool %{
          name: "toplevel",
          namespace: "",
          description: "Simple tool",
          enabled: true,
          version: "1.0.0",
          author: "test"
        }

        def run(_args), do: :ok
      end
      """

      File.write!(file_path, content)

      on_exit(fn -> File.rm_rf!(dir) end)

      %{file_path: file_path}
    end

    test "toggle flips top-level enabled from true to false", %{file_path: path} do
      assert :ok = UC.toggle_enabled_in_source(path, true)
      content = File.read!(path)
      assert content =~ "enabled: false"
      refute content =~ "enabled: true"
    end

    test "toggle flips top-level enabled from false to true" do
      dir = Path.join(System.tmp_dir!(), "uc_struct_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      file_path = Path.join(dir, "disabled_tool.ex")

      content = """
      defmodule DisabledTool do
        @uc_tool %{
          name: "disabled",
          namespace: "",
          description: "Starts disabled",
          enabled: false,
          version: "1.0.0",
          author: "test"
        }

        def run(_args), do: :ok
      end
      """

      File.write!(file_path, content)

      assert :ok = UC.toggle_enabled_in_source(file_path, false)
      new_content = File.read!(file_path)
      assert new_content =~ "enabled: true"
      refute new_content =~ "enabled: false"

      File.rm_rf!(dir)
    end
  end

  describe "/uc without running registry" do
    test "shows friendly error when registry is not running" do
      # Temporarily unregister the name to test the graceful fallback.
      # We use unregister/2 to detach the name without killing the process,
      # then re-register after the test.
      case Process.whereis(UCRegistry) do
        nil ->
          # Already not running — just test directly
          output =
            ExUnit.CaptureIO.capture_io(fn ->
              assert {:continue, _} = UC.handle_uc("/uc", %{})
            end)

          assert output =~ "registry is not running"

        pid ->
          # Unregister the name so Process.whereis returns nil
          :erlang.unregister(UCRegistry)

          output =
            ExUnit.CaptureIO.capture_io(fn ->
              assert {:continue, _} = UC.handle_uc("/uc", %{})
            end)

          assert output =~ "registry is not running"

          # Re-register the name so other tests work
          :erlang.register(UCRegistry, pid)
      end
    end
  end
end
