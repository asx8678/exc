defmodule CodePuppyControl.CLI.SlashCommands.DispatcherTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}

  setup do
    # Start the slash-command Registry GenServer if not already running
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()

    # Ensure the Callbacks.Registry is running
    case Process.whereis(CodePuppyControl.Callbacks.Registry) do
      nil -> start_supervised!({CodePuppyControl.Callbacks.Registry, []})
      _pid -> :ok
    end

    # Clean up any leftover custom_command callbacks from prior tests
    Callbacks.clear(:custom_command)
    Callbacks.clear(:custom_command_help)

    :ok
  end

  describe "is_slash_command?/1" do
    test "returns true for /foo" do
      assert Dispatcher.is_slash_command?("/foo")
    end

    test "returns true for /model gpt-4" do
      assert Dispatcher.is_slash_command?("/model gpt-4")
    end

    test "returns true for / alone" do
      assert Dispatcher.is_slash_command?("/")
    end

    test "returns false for plain text" do
      refute Dispatcher.is_slash_command?("foo")
    end

    test "returns false for empty string" do
      refute Dispatcher.is_slash_command?("")
    end

    test "returns false for text starting with space" do
      refute Dispatcher.is_slash_command?(" /foo")
    end
  end

  describe "dispatch/2" do
    test "returns not_a_slash_command for non-slash input" do
      assert {:error, :not_a_slash_command} = Dispatcher.dispatch("hello", nil)
    end

    test "returns unknown_command for empty slash (just /)" do
      assert {:error, :unknown_command} = Dispatcher.dispatch("/", nil)
    end

    test "returns unknown_command for unregistered command" do
      assert {:error, :unknown_command} = Dispatcher.dispatch("/bogus", nil)
    end

    test "calls handler and returns {:ok, result} for registered command" do
      handler = fn _line, state -> {:continue, state} end

      cmd = CommandInfo.new(name: "test", description: "Test", handler: handler)

      assert :ok = Registry.register(cmd)

      assert {:ok, {:continue, nil}} = Dispatcher.dispatch("/test", nil)
    end

    test "handler receives full command string including arguments" do
      test_pid = self()

      handler = fn line, _state ->
        send(test_pid, {:handler_called, line})
        {:continue, nil}
      end

      cmd = CommandInfo.new(name: "echo", description: "Echo", handler: handler)

      assert :ok = Registry.register(cmd)

      Dispatcher.dispatch("/echo hello world", nil)

      assert_received {:handler_called, "/echo hello world"}
    end

    test "handler receives the REPL state" do
      test_pid = self()

      handler = fn _line, state ->
        send(test_pid, {:state_received, state})
        {:continue, state}
      end

      cmd = CommandInfo.new(name: "stateful", description: "Stateful", handler: handler)

      assert :ok = Registry.register(cmd)

      Dispatcher.dispatch("/stateful", %{foo: "bar"})

      assert_received {:state_received, %{foo: "bar"}}
    end

    test "dispatch works via alias" do
      handler = fn _line, state -> {:halt, state} end

      cmd =
        CommandInfo.new(
          name: "quit",
          description: "Exit",
          handler: handler,
          aliases: ["exit"]
        )

      assert :ok = Registry.register(cmd)

      # Dispatch via primary name
      assert {:ok, {:halt, nil}} = Dispatcher.dispatch("/quit", nil)

      # Dispatch via alias
      assert {:ok, {:halt, nil}} = Dispatcher.dispatch("/exit", nil)
    end

    test "dispatch is case-insensitive" do
      handler = fn _line, state -> {:continue, state} end

      cmd = CommandInfo.new(name: "help", description: "Help", handler: handler)

      assert :ok = Registry.register(cmd)

      assert {:ok, {:continue, nil}} = Dispatcher.dispatch("/HELP", nil)
    end

    test "returns halt when handler returns halt" do
      handler = fn _line, state -> {:halt, %{state | running: false}} end

      cmd = CommandInfo.new(name: "quit", description: "Exit", handler: handler)

      assert :ok = Registry.register(cmd)

      assert {:ok, {:halt, %{running: false}}} = Dispatcher.dispatch("/quit", %{running: true})
    end
  end

  # ── Plugin Fallback ──────────────────────────────────────────────

  describe "dispatch/2 plugin :custom_command fallback" do
    test "plugin callback returning string handles the command" do
      handler = fn _command, name -> "handled #{name}" end
      Callbacks.register(:custom_command, handler)

      on_exit(fn ->
        Callbacks.unregister(:custom_command, handler)
      end)

      assert {:ok, "handled foo"} = Dispatcher.dispatch("/foo", nil)
    end

    test "plugin callback returning nil falls through to unknown_command" do
      handler = fn _command, _name -> nil end
      Callbacks.register(:custom_command, handler)

      on_exit(fn ->
        Callbacks.unregister(:custom_command, handler)
      end)

      assert {:error, :unknown_command} = Dispatcher.dispatch("/unknown", nil)
    end

    test "first non-nil responder wins when multiple callbacks registered" do
      pass_handler = fn _command, _name -> nil end
      handle_handler = fn _command, _name -> true end

      Callbacks.register(:custom_command, pass_handler)
      Callbacks.register(:custom_command, handle_handler)

      on_exit(fn ->
        Callbacks.unregister(:custom_command, pass_handler)
        Callbacks.unregister(:custom_command, handle_handler)
      end)

      assert {:ok, :handled} = Dispatcher.dispatch("/multi", nil)
    end

    test "built-in Registry commands take precedence over plugin callbacks" do
      # Register a built-in command
      builtin_handler = fn _line, state -> {:continue, state} end

      cmd = CommandInfo.new(name: "builtin", description: "Built-in", handler: builtin_handler)

      assert :ok = Registry.register(cmd)

      # Also register a plugin callback that would handle "/builtin"
      plugin_handler = fn _command, _name -> "plugin handled" end
      Callbacks.register(:custom_command, plugin_handler)

      on_exit(fn ->
        Callbacks.unregister(:custom_command, plugin_handler)
      end)

      # Built-in should win
      assert {:ok, {:continue, nil}} = Dispatcher.dispatch("/builtin", nil)
    end
  end
end
