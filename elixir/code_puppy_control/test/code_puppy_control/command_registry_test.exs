defmodule CodePuppyControl.CommandRegistryTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.CommandRegistry
  alias CodePuppyControl.CLI.SlashCommands.Registry

  setup do
    # Ensure the Registry GenServer is started and populated with builtins
    case GenServer.whereis(Registry) do
      nil ->
        {:ok, _pid} = Registry.start_link()
        Registry.register_builtin_commands()

      _pid ->
        # Already running — just make sure builtins are registered
        :ok
    end

    :ok
  end

  describe "list_commands/0" do
    test "returns a list of maps with required keys" do
      commands = CommandRegistry.list_commands()
      assert is_list(commands)
      assert length(commands) > 0

      Enum.each(commands, fn cmd ->
        assert is_binary(cmd.name)
        assert is_binary(cmd.description)
        assert is_binary(cmd.usage)
        assert is_list(cmd.aliases)
        assert is_binary(cmd.category)
      end)
    end

    test "includes built-in commands like help and quit" do
      commands = CommandRegistry.list_commands()
      names = Enum.map(commands, & &1.name)

      assert "help" in names
      assert "quit" in names
      assert "model" in names
    end
  end

  describe "get_command/1" do
    test "finds a command by exact name" do
      assert {:ok, cmd} = CommandRegistry.get_command("help")
      assert cmd.name == "help"
      assert cmd.description == "Show available commands"
    end

    test "finds a command registered under its own name" do
      # /exit is registered as its own command
      assert {:ok, cmd} = CommandRegistry.get_command("exit")
      assert cmd.name == "exit"
    end

    test "is case-insensitive" do
      assert {:ok, cmd} = CommandRegistry.get_command("HELP")
      assert cmd.name == "help"
    end

    test "returns :not_found for unknown commands" do
      assert {:error, :not_found} = CommandRegistry.get_command("nonexistent")
    end
  end

  describe "autocomplete/1" do
    test "returns all commands for empty query" do
      suggestions = CommandRegistry.autocomplete("/")
      assert length(suggestions) > 0
    end

    test "returns prefix matches" do
      suggestions = CommandRegistry.autocomplete("/h")
      names = Enum.map(suggestions, & &1.name)

      assert "help" in names
      assert "history" in names
    end

    test "is case-insensitive for prefix matching" do
      suggestions = CommandRegistry.autocomplete("/HE")
      names = Enum.map(suggestions, & &1.name)

      assert "help" in names
    end

    test "returns empty list for non-matching query" do
      suggestions = CommandRegistry.autocomplete("/zzzzz")
      assert suggestions == []
    end
  end
end
