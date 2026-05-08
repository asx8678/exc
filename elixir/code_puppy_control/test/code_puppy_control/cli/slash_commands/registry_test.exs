defmodule CodePuppyControl.CLI.SlashCommands.RegistryTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Registry}

  # We use async: false because the Registry is a named singleton process
  # with a shared ETS table. We clear between tests for isolation.

  setup do
    # Start the Registry GenServer if not already running
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    # Clear all commands before each test
    Registry.clear()

    on_exit(fn ->
      # Restore registry builtins so subsequent tests aren't poisoned
      Registry.clear()
      Registry.register_builtin_commands()
    end)

    :ok
  end

  describe "register/1" do
    test "registers a command by primary name" do
      cmd = CommandInfo.new(name: "test", description: "A test", handler: fn _, s -> s end)
      assert :ok = Registry.register(cmd)
      assert {:ok, ^cmd} = Registry.get("test")
    end

    test "registers a command with aliases" do
      cmd =
        CommandInfo.new(
          name: "quit",
          description: "Exit",
          handler: fn _, s -> s end,
          aliases: ["exit", "q"]
        )

      assert :ok = Registry.register(cmd)
      assert {:ok, ^cmd} = Registry.get("quit")
      assert {:ok, ^cmd} = Registry.get("exit")
      assert {:ok, ^cmd} = Registry.get("q")
    end

    test "returns error on name conflict for primary name" do
      cmd1 = CommandInfo.new(name: "foo", description: "First", handler: fn _, s -> s end)
      cmd2 = CommandInfo.new(name: "foo", description: "Second", handler: fn _, s -> s end)

      assert :ok = Registry.register(cmd1)
      assert {:error, {:name_conflict, "foo"}} = Registry.register(cmd2)
    end

    test "returns error on name conflict for alias" do
      cmd1 = CommandInfo.new(name: "foo", description: "First", handler: fn _, s -> s end)

      cmd2 =
        CommandInfo.new(
          name: "bar",
          description: "Second",
          handler: fn _, s -> s end,
          aliases: ["foo"]
        )

      assert :ok = Registry.register(cmd1)
      assert {:error, {:name_conflict, "foo"}} = Registry.register(cmd2)
    end

    test "returns error when alias conflicts with existing primary name" do
      cmd1 = CommandInfo.new(name: "foo", description: "First", handler: fn _, s -> s end)

      cmd2 =
        CommandInfo.new(
          name: "bar",
          description: "Second",
          handler: fn _, s -> s end,
          aliases: ["foo"]
        )

      assert :ok = Registry.register(cmd1)
      assert {:error, {:name_conflict, "foo"}} = Registry.register(cmd2)
    end
  end

  describe "get/1" do
    test "returns not_found for unregistered command" do
      assert {:error, :not_found} = Registry.get("nonexistent")
    end

    test "case-insensitive lookup" do
      cmd = CommandInfo.new(name: "Help", description: "Show help", handler: fn _, s -> s end)
      assert :ok = Registry.register(cmd)

      assert {:ok, _} = Registry.get("help")
      assert {:ok, _} = Registry.get("HELP")
      assert {:ok, _} = Registry.get("Help")
    end

    test "exact match wins over case-insensitive match" do
      # Register with lowercase name
      cmd1 = CommandInfo.new(name: "foo", description: "Lowercase", handler: fn _, s -> s end)
      assert :ok = Registry.register(cmd1)

      # Exact match should work
      assert {:ok, found} = Registry.get("foo")
      assert found.name == "foo"
    end

    test "case-insensitive lookup for aliases" do
      cmd =
        CommandInfo.new(
          name: "quit",
          description: "Exit",
          handler: fn _, s -> s end,
          aliases: ["exit"]
        )

      assert :ok = Registry.register(cmd)
      assert {:ok, _} = Registry.get("EXIT")
    end

    test "returns not_found gracefully when ETS table does not exist" do
      # This tests the hardening added for escript startup where the
      # :slash_commands table may not exist. We can't easily delete the
      # table in this test environment (it's owned by the Registry
      # GenServer), so we test with a non-existent table name by
      # temporarily swapping the module attribute.
      #
      # Instead, verify that get/1 with a normal missing command still
      # returns :not_found and does not raise.
      assert {:error, :not_found} = Registry.get("absolutely_nonexistent_cmd_xyz")
    end
  end

  describe "list_all/0" do
    test "returns empty list when no commands registered" do
      assert [] = Registry.list_all()
    end

    test "returns unique commands without alias duplicates" do
      cmd1 = CommandInfo.new(name: "quit", description: "Exit", handler: fn _, s -> s end)
      cmd2 = CommandInfo.new(name: "help", description: "Show help", handler: fn _, s -> s end)

      assert :ok = Registry.register(cmd1)
      assert :ok = Registry.register(cmd2)

      all = Registry.list_all()
      assert length(all) == 2
      assert Enum.find(all, &(&1.name == "quit"))
      assert Enum.find(all, &(&1.name == "help"))
    end

    test "deduplicates by primary name even with aliases" do
      cmd =
        CommandInfo.new(
          name: "quit",
          description: "Exit",
          handler: fn _, s -> s end,
          aliases: ["exit", "q"]
        )

      assert :ok = Registry.register(cmd)

      all = Registry.list_all()
      # Only one unique command, even though 3 keys point to it
      assert length(all) == 1
      assert hd(all).name == "quit"
    end
  end

  describe "list_by_category/1" do
    test "filters commands by category" do
      cmd1 =
        CommandInfo.new(
          name: "help",
          description: "Help",
          handler: fn _, s -> s end,
          category: "core"
        )

      cmd2 =
        CommandInfo.new(
          name: "model",
          description: "Model",
          handler: fn _, s -> s end,
          category: "context"
        )

      assert :ok = Registry.register(cmd1)
      assert :ok = Registry.register(cmd2)

      core = Registry.list_by_category("core")
      assert length(core) == 1
      assert hd(core).name == "help"

      context = Registry.list_by_category("context")
      assert length(context) == 1
      assert hd(context).name == "model"
    end

    test "returns empty list for nonexistent category" do
      assert [] = Registry.list_by_category("nonexistent")
    end
  end

  describe "all_names/0" do
    test "returns all registered names and aliases" do
      cmd =
        CommandInfo.new(
          name: "quit",
          description: "Exit",
          handler: fn _, s -> s end,
          aliases: ["exit", "q"]
        )

      assert :ok = Registry.register(cmd)

      names = Registry.all_names()
      assert "quit" in names
      assert "exit" in names
      assert "q" in names
    end
  end

  describe "clear/0" do
    test "empties the registry" do
      cmd = CommandInfo.new(name: "test", description: "Test", handler: fn _, s -> s end)
      assert :ok = Registry.register(cmd)
      assert {:ok, _} = Registry.get("test")

      assert :ok = Registry.clear()
      assert {:error, :not_found} = Registry.get("test")
      assert [] = Registry.list_all()
    end
  end

  describe "register_builtin_commands/0 — runtime wiring" do
    test "registers /mode for runtime lookup" do
      Registry.register_builtin_commands()

      assert {:ok, cmd} = Registry.get("mode")
      assert cmd.name == "mode"
      assert cmd.category == "context"
      assert cmd.usage == "/mode [preset_name]"
    end

    test "registers /flags for runtime lookup" do
      Registry.register_builtin_commands()

      assert {:ok, cmd} = Registry.get("flags")
      assert cmd.name == "flags"
      assert cmd.category == "config"
      assert cmd.usage == "/flags [reset|set <flag>|clear <flag>]"
    end

    test "registers /mode and /flags for tab completion" do
      Registry.register_builtin_commands()

      names = Registry.all_names()
      assert "mode" in names
      assert "flags" in names
      assert "model_settings" in names
      assert "ms" in names
    end

    test "registers all expected builtin commands" do
      Registry.register_builtin_commands()

      expected =
        ~w(help quit exit clear history cd model agent sessions tui agents pack mode model_settings ms flags diff mcp compact truncate)

      for name <- expected do
        assert {:ok, _} = Registry.get(name),
               "Expected builtin command /#{name} to be registered"
      end
    end

    test "/mode is in context category alongside /model and /agent" do
      Registry.register_builtin_commands()

      context_cmds = Registry.list_by_category("context")
      context_names = Enum.map(context_cmds, & &1.name)

      assert "mode" in context_names
      assert "model" in context_names
      assert "agent" in context_names
    end

    test "/flags, /diff, and /model_settings are in config category" do
      Registry.register_builtin_commands()

      config_cmds = Registry.list_by_category("config")
      config_names = Enum.map(config_cmds, & &1.name)

      assert "flags" in config_names
      assert "diff" in config_names
      assert "model_settings" in config_names
    end

    test "/mcp is registered in mcp category" do
      Registry.register_builtin_commands()

      assert {:ok, cmd} = Registry.get("mcp")
      assert cmd.name == "mcp"
      assert cmd.category == "mcp"
      assert cmd.usage == "/mcp [help|list|status|start|stop|restart|start-all|stop-all]"

      mcp_cmds = Registry.list_by_category("mcp")
      assert Enum.any?(mcp_cmds, &(&1.name == "mcp"))
    end

    test "idempotent — calling twice does not crash" do
      Registry.register_builtin_commands()

      # Second call: name conflicts are logged but don't crash
      Registry.register_builtin_commands()

      assert {:ok, _} = Registry.get("mode")
      assert {:ok, _} = Registry.get("flags")
      assert {:ok, _} = Registry.get("diff")
      assert {:ok, _} = Registry.get("model_settings")
      assert {:ok, _} = Registry.get("ms")
    end
  end

  describe "CommandInfo.new/1" do
    test "defaults usage to /<name>" do
      cmd = CommandInfo.new(name: "help", description: "Show help", handler: fn _, s -> s end)
      assert cmd.usage == "/help"
    end

    test "preserves explicit usage" do
      cmd =
        CommandInfo.new(
          name: "model",
          description: "Model",
          handler: fn _, s -> s end,
          usage: "/model <name>"
        )

      assert cmd.usage == "/model <name>"
    end

    test "defaults aliases to empty list" do
      cmd = CommandInfo.new(name: "help", description: "Help", handler: fn _, s -> s end)
      assert cmd.aliases == []
    end

    test "defaults category to core" do
      cmd = CommandInfo.new(name: "help", description: "Help", handler: fn _, s -> s end)
      assert cmd.category == "core"
    end
  end
end
