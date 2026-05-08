defmodule CodePuppyControl.CLI.SlashCommands.Commands.DiffTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.Diff
  alias CodePuppyControl.Config.{Loader, TUI, Writer}

  # async: false because Registry and Writer are named singletons and we
  # write config.

  @tmp_dir System.tmp_dir!()
  @test_cfg_dir Path.join(@tmp_dir, "diff_test_#{:erlang.unique_integer([:positive])}")

  setup do
    # Isolate config: write to a temp puppy.cfg so tests never touch the
    # real user config.  Follows the same pattern as mode_test.exs.
    File.mkdir_p!(@test_cfg_dir)
    test_cfg = Path.join(@test_cfg_dir, "puppy.cfg")
    File.write!(test_cfg, "[puppy]\n")
    Loader.load(test_cfg)

    # Start Writer if not already running (needed by TUI.set_diff_*_color)
    case GenServer.whereis(Writer) do
      nil -> {:ok, _} = Writer.start_link()
      _pid -> :ok
    end

    # Start the Registry GenServer if not already running
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()

    # Register /diff command
    :ok =
      Registry.register(
        CommandInfo.new(
          name: "diff",
          description: "Show or configure diff highlighting colors",
          handler: &Diff.handle_diff/2,
          usage: "/diff [additions|deletions] <color>",
          category: "config"
        )
      )

    on_exit(fn ->
      # Restore registry builtins so subsequent tests aren't poisoned
      Registry.clear()
      Registry.register_builtin_commands()
      Loader.invalidate()
      File.rm_rf!(@test_cfg_dir)
    end)

    state = %{session_id: "test-session", running: true}
    {:ok, state: state}
  end

  describe "/diff (no args)" do
    test "shows current diff colors" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff", %{})
        end)

      assert output =~ "Diff Highlight Colors"
      assert output =~ "Additions:"
      assert output =~ "Deletions:"
    end

    test "shows context lines" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff", %{})
        end)

      assert output =~ "Context:"
      assert output =~ "lines"
    end

    test "shows usage hint" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff", %{})
        end)

      assert output =~ "additions|deletions"
    end

    test "returns continue" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, %{}} = Diff.handle_diff("/diff", %{})
      end)
    end
  end

  describe "/diff additions <color>" do
    test "sets addition color" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff additions dark_green", %{})
        end)

      assert output =~ "Additions color set to"
      assert output =~ "dark_green"
    end

    test "persists the color via TUI" do
      ExUnit.CaptureIO.capture_io(fn ->
        Diff.handle_diff("/diff additions chartreuse1", %{})
      end)

      assert TUI.diff_addition_color() == "chartreuse1"
    end

    test "accepts 'addition' alias" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff addition sea_green", %{})
        end)

      assert output =~ "Additions color set to"
      assert TUI.diff_addition_color() == "sea_green"
    end

    test "accepts 'add' alias" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff add lime", %{})
        end)

      assert output =~ "Additions color set to"
      assert TUI.diff_addition_color() == "lime"
    end

    test "accepts case-insensitive subcommand" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff ADDITIONS green3", %{})
        end)

      assert output =~ "Additions color set to"
      assert TUI.diff_addition_color() == "green3"
    end

    test "accepts mixed-case subcommand" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff Add forest_green", %{})
        end)

      assert output =~ "Additions color set to"
    end

    test "accepts hex color" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff additions #0b1f0b", %{})
        end)

      assert output =~ "Additions color set to"
      assert TUI.diff_addition_color() == "#0b1f0b"
    end
  end

  describe "/diff deletions <color>" do
    test "sets deletion color" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff deletions dark_red", %{})
        end)

      assert output =~ "Deletions color set to"
      assert output =~ "dark_red"
    end

    test "persists the color via TUI" do
      ExUnit.CaptureIO.capture_io(fn ->
        Diff.handle_diff("/diff deletions indian_red", %{})
      end)

      assert TUI.diff_deletion_color() == "indian_red"
    end

    test "accepts 'deletion' alias" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff deletion orange1", %{})
        end)

      assert output =~ "Deletions color set to"
      assert TUI.diff_deletion_color() == "orange1"
    end

    test "accepts 'del' alias" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff del bright_red", %{})
        end)

      assert output =~ "Deletions color set to"
      assert TUI.diff_deletion_color() == "bright_red"
    end

    test "accepts case-insensitive subcommand" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff DELETIONS red3", %{})
        end)

      assert output =~ "Deletions color set to"
      assert TUI.diff_deletion_color() == "red3"
    end

    test "accepts hex color" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff deletions #390e1a", %{})
        end)

      assert output =~ "Deletions color set to"
      assert TUI.diff_deletion_color() == "#390e1a"
    end
  end

  describe "/diff <subcommand> (bare subcommand — no color)" do
    test "shows addition color when subcommand is 'additions'" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff additions", %{})
        end)

      assert output =~ "Additions color:"
    end

    test "shows deletion color when subcommand is 'deletions'" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff deletions", %{})
        end)

      assert output =~ "Deletions color:"
    end

    test "shows usage for unknown bare subcommand" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff bogus", %{})
        end)

      assert output =~ "Usage:"
    end
  end

  describe "invalid usage" do
    test "shows usage for unknown subcommand with color" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff unknown red", %{})
        end)

      assert output =~ "Unknown subcommand"
      assert output =~ "Usage:"
    end

    test "shows usage for too many arguments" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff additions red extra", %{})
        end)

      assert output =~ "Usage:"
    end

    test "returns continue even on invalid usage" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, %{}} = Diff.handle_diff("/diff bogus", %{})
      end)
    end
  end

  describe "registration and dispatch" do
    test "/diff is registered and dispatchable" do
      assert {:ok, _} = Registry.get("diff")
    end

    test "/diff dispatches via Dispatcher" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, {:continue, _}} = Dispatcher.dispatch("/diff", %{})
        end)

      assert output =~ "Diff Highlight Colors"
    end

    test "/diff appears in all_names for tab completion" do
      names = Registry.all_names()
      assert "diff" in names
    end

    test "/diff appears in list_all" do
      commands = Registry.list_all()
      assert Enum.any?(commands, &(&1.name == "diff"))
    end

    test "/diff is in config category" do
      commands = Registry.list_by_category("config")
      diff_cmd = Enum.find(commands, &(&1.name == "diff"))
      assert diff_cmd != nil
      assert diff_cmd.category == "config"
    end

    test "/diff usage is correct" do
      {:ok, cmd} = Registry.get("diff")
      assert cmd.usage == "/diff [additions|deletions] <color>"
    end
  end

  describe "whitespace robustness" do
    test "/diff with trailing whitespace shows current colors" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff   ", %{})
        end)

      assert output =~ "Diff Highlight Colors"
    end

    test "/diff with extra spaces between tokens still sets color" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Diff.handle_diff("/diff  additions  green", %{})
        end)

      assert output =~ "Additions color set to"
      assert TUI.diff_addition_color() == "green"
    end
  end
end
