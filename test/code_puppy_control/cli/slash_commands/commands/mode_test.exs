defmodule CodePuppyControl.CLI.SlashCommands.Commands.ModeTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.Mode
  alias CodePuppyControl.Config.{Loader, Writer}

  @tmp_dir System.tmp_dir!()
  @test_cfg_dir Path.join(@tmp_dir, "mode_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@test_cfg_dir)
    test_cfg = Path.join(@test_cfg_dir, "puppy.cfg")

    # Start with a semi-matching config
    File.write!(test_cfg, """
    [puppy]
    yolo_mode = false
    enable_pack_agents = false
    enable_universal_constructor = true
    safety_permission_level = medium
    compaction_strategy = summarization
    enable_streaming = true
    """)

    Loader.load(test_cfg)

    # Start Writer if not already running
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

    # Register /mode command
    :ok =
      Registry.register(
        CommandInfo.new(
          name: "mode",
          description: "Show or switch configuration preset",
          handler: &Mode.handle_mode/2,
          usage: "/mode [preset_name]",
          category: "context"
        )
      )

    on_exit(fn ->
      # Restore registry builtins so subsequent tests aren't poisoned
      Registry.clear()
      Registry.register_builtin_commands()
      Loader.invalidate()
      File.rm_rf!(@test_cfg_dir)
    end)

    {:ok, cfg_path: test_cfg}
  end

  describe "/mode (no args)" do
    test "shows Configuration Mode header" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode", %{})
        end)

      assert output =~ "Configuration Mode"
    end

    test "shows current mode name" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode", %{})
        end)

      assert output =~ "Current mode:"
    end

    test "lists all available presets" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode", %{})
        end)

      assert output =~ "basic"
      assert output =~ "semi"
      assert output =~ "full"
      assert output =~ "pack"
    end

    test "shows hint to switch modes" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode", %{})
        end)

      assert output =~ "/mode <preset>"
    end

    test "returns continue" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, %{}} = Mode.handle_mode("/mode", %{})
      end)
    end
  end

  describe "/mode with matched preset" do
    test "shows preset display name when config matches" do
      # Config matches "semi" preset
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode", %{})
        end)

      assert output =~ "Semi"
    end

    test "shows Custom when config doesn't match any preset", %{cfg_path: cfg_path} do
      File.write!(cfg_path, """
      [puppy]
      yolo_mode = false
      enable_pack_agents = false
      enable_universal_constructor = false
      safety_permission_level = high
      compaction_strategy = summarization
      enable_streaming = true
      """)

      Loader.load(cfg_path)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode", %{})
        end)

      assert output =~ "Custom"
    end
  end

  describe "/mode <preset>" do
    test "applies basic preset" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode basic", %{})
        end)

      assert output =~ "Basic"
      assert output =~ "Applied"
    end

    test "applies full preset" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode full", %{})
        end)

      assert output =~ "Full"
      assert output =~ "Applied"
    end

    test "shows YOLO warning for full preset" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode full", %{})
        end)

      assert output =~ "YOLO mode is now enabled"
    end

    test "does NOT show YOLO warning for basic preset" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode basic", %{})
        end)

      refute output =~ "YOLO mode is now enabled"
    end

    test "applies pack preset" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode pack", %{})
        end)

      assert output =~ "Pack"
      assert output =~ "Applied"
    end

    test "handles case-insensitive preset name" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode FULL", %{})
        end)

      assert output =~ "Full"
    end

    test "shows error for unknown preset" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode nonexistent", %{})
        end)

      assert output =~ "Unknown preset"
      assert output =~ "Available:"
    end

    test "returns continue for all valid presets" do
      for name <- ["basic", "semi", "full", "pack"] do
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, %{}} = Mode.handle_mode("/mode #{name}", %{})
        end)
      end
    end
  end

  describe "/mode with invalid usage" do
    test "shows usage for too many args" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode basic extra", %{})
        end)

      assert output =~ "Usage"
      assert output =~ "/mode"
    end

    test "shows usage hint to use /mode without args" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode basic extra", %{})
        end)

      assert output =~ "without arguments"
    end
  end

  describe "/mode with whitespace-only args" do
    test "whitespace-only args behave like bare /mode" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode ", %{})
        end)

      assert output =~ "Configuration Mode"
      assert output =~ "Available presets"
    end

    test "does not show unknown-preset error for whitespace-only args" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode ", %{})
        end)

      refute output =~ "Unknown preset"
    end
  end

  describe "/mode basic via supervised Writer (app-path)" do
    setup do
      # Start Writer under supervision — mimics the real app path where
      # CodePuppyControl.Application supervises Config.Writer.
      # This test does NOT call Writer.start_link() manually.
      case Process.whereis(Writer) do
        nil -> start_supervised!(Writer)
        _pid -> :ok
      end

      :ok
    end

    test "/mode basic succeeds without manual Writer startup" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode basic", %{})
        end)

      assert output =~ "Applied"
      assert output =~ "Basic"
    end

    test "/mode full succeeds and shows YOLO warning" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode full", %{})
        end)

      assert output =~ "Applied"
      assert output =~ "YOLO mode is now enabled"
    end

    test "/mode pack succeeds via supervised Writer" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Mode.handle_mode("/mode pack", %{})
        end)

      assert output =~ "Applied"
      assert output =~ "Pack"
    end
  end

  describe "registration and dispatch" do
    test "/mode is registered and dispatchable" do
      assert {:ok, _} = Registry.get("mode")
    end

    test "/mode dispatches via Dispatcher" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, {:continue, _}} = Dispatcher.dispatch("/mode", %{})
        end)

      assert output =~ "Configuration Mode"
    end

    test "/mode basic dispatches via Dispatcher" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, {:continue, _}} = Dispatcher.dispatch("/mode basic", %{})
        end)

      assert output =~ "Applied"
    end

    test "/mode appears in all_names for tab completion" do
      names = Registry.all_names()
      assert "mode" in names
    end

    test "/mode appears in list_all" do
      commands = Registry.list_all()
      assert Enum.any?(commands, &(&1.name == "mode"))
    end

    test "/mode is in context category" do
      commands = Registry.list_by_category("context")
      mode_cmd = Enum.find(commands, &(&1.name == "mode"))
      assert mode_cmd != nil
      assert mode_cmd.category == "context"
    end

    test "/mode usage is correct" do
      {:ok, cmd} = Registry.get("mode")
      assert cmd.usage == "/mode [preset_name]"
    end
  end
end
