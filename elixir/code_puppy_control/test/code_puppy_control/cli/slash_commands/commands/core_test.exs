defmodule CodePuppyControl.CLI.SlashCommands.Commands.CoreTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.Core
  alias CodePuppyControl.REPL.{History, Loop}

  setup do
    # Start the Registry GenServer
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()

    # Start History GenServer for tests that need it
    case Process.whereis(History) do
      nil ->
        start_supervised!({History, []})

      _pid ->
        :ok
    end

    # Clear history file for clean state
    File.rm(History.history_path())

    # Register core commands
    :ok =
      Registry.register(
        CommandInfo.new(name: "help", description: "Show help", handler: &Core.handle_help/2)
      )

    :ok =
      Registry.register(
        CommandInfo.new(name: "quit", description: "Exit", handler: &Core.handle_quit/2)
      )

    :ok =
      Registry.register(
        CommandInfo.new(name: "clear", description: "Clear screen", handler: &Core.handle_clear/2)
      )

    :ok =
      Registry.register(
        CommandInfo.new(name: "history", description: "History", handler: &Core.handle_history/2)
      )

    :ok =
      Registry.register(
        CommandInfo.new(
          name: "cd",
          description: "Change directory",
          handler: &Core.handle_cd/2,
          usage: "/cd <dir>"
        )
      )

    state = %Loop{
      agent: "code-puppy",
      model: "gpt-4",
      session_id: "test-session",
      running: true
    }

    {:ok, state: state}
  end

  describe "/help" do
    test "prints registered command names", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_help("/help", state)
        end)

      assert output =~ "help"
      assert output =~ "quit"
      assert output =~ "clear"
      assert output =~ "history"
      assert output =~ "cd"
    end

    test "returns continue", %{state: state} do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Core.handle_help("/help", state)
      end)
    end
  end

  describe "/quit" do
    test "returns halt with running: false", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:halt, new_state} = Core.handle_quit("/quit", state)
          refute new_state.running
        end)

      assert output =~ "👋 Bye!"
    end

    test "/exit via dispatcher acts as quit alias", %{state: state} do
      # Register exit as a separate command with the same handler
      _quit_info = Registry.get("quit")

      :ok =
        Registry.register(
          CommandInfo.new(name: "exit", description: "Exit alias", handler: &Core.handle_quit/2)
        )

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, {:halt, _}} = Dispatcher.dispatch("/exit", state)
        end)

      assert output =~ "👋 Bye!"
    end
  end

  describe "/clear" do
    test "writes ANSI clear sequence and returns continue", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_clear("/clear", state)
        end)

      assert output =~ "\e[2J\e[H"
    end
  end

  describe "/history" do
    test "shows no history when empty", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_history("/history", state)
        end)

      assert output =~ "no history"
    end

    test "shows entries when history exists", %{state: state} do
      History.add("first prompt")
      History.add("second prompt")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_history("/history", state)
        end)

      assert output =~ "first prompt"
      assert output =~ "second prompt"
    end

    test "returns continue", %{state: state} do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, ^state} = Core.handle_history("/history", state)
      end)
    end
  end

  describe "/cd" do
    test "/cd /tmp changes working directory", %{state: state} do
      original = File.cwd!()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_cd("/cd /tmp", state)
        end)

      assert output =~ "Changed directory"
      # macOS resolves /tmp to /private/tmp — just check the path contains "tmp"
      assert File.cwd!() =~ "tmp"

      # Restore
      File.cd!(original)
    end

    test "/cd nonexistent-path prints error and returns continue", %{state: state} do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_cd("/cd /nonexistent/path/xyz123", state)
        end)

      assert output =~ IO.ANSI.red()
      assert output =~ "Failed to change directory"
    end

    test "/cd with no arg prints current working directory", %{state: state} do
      cwd = File.cwd!()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_cd("/cd", state)
        end)

      assert output =~ cwd
    end
  end

  # ── Plugin Help Integration ──────────────────────────────────────

  describe "/help with plugin :custom_command_help entries" do
    setup context do
      # Ensure the Callbacks.Registry is running
      case Process.whereis(CodePuppyControl.Callbacks.Registry) do
        nil -> start_supervised!({CodePuppyControl.Callbacks.Registry, []})
        _pid -> :ok
      end

      # Clear any leftover plugin help callbacks
      CodePuppyControl.Callbacks.clear(:custom_command_help)

      :ok
    end

    test "includes plugin help entries in help output", %{state: state} do
      help_cb = fn -> [{"foo", "Foo command"}, {"bar", "Bar command"}] end
      CodePuppyControl.Callbacks.register(:custom_command_help, help_cb)

      on_exit(fn ->
        CodePuppyControl.Callbacks.unregister(:custom_command_help, help_cb)
      end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_help("/help", state)
        end)

      # Plugin entries should appear in the output
      assert output =~ "foo"
      assert output =~ "Foo command"
      assert output =~ "bar"
      assert output =~ "Bar command"
      # Plugin commands section header should appear
      assert output =~ "Plugin commands"
    end

    test "works when only plugin help exists (no built-in commands)", %{state: state} do
      # Clear all registered commands
      Registry.clear()

      help_cb = fn -> [{"plugin-cmd", "A plugin command"}] end
      CodePuppyControl.Callbacks.register(:custom_command_help, help_cb)

      on_exit(fn ->
        CodePuppyControl.Callbacks.unregister(:custom_command_help, help_cb)
      end)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} = Core.handle_help("/help", state)
        end)

      assert output =~ "plugin-cmd"
      assert output =~ "A plugin command"
    end
  end
end
