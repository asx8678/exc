defmodule CodePuppyControl.CLI.SlashCommands.Commands.PackTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.Pack
  alias CodePuppyControl.ModelPacks

  setup do
    # Start the Registry GenServer if not already running
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()

    # Start ModelPacks GenServer if not already running
    case Process.whereis(ModelPacks) do
      nil -> start_supervised!(ModelPacks)
      _pid -> :ok
    end

    # Reset to default pack for clean state
    ModelPacks.set_current_pack("single")

    # Register /pack command
    :ok =
      Registry.register(
        CommandInfo.new(
          name: "pack",
          description: "Show or switch model pack",
          handler: &Pack.handle_pack/2,
          usage: "/pack [pack_name]",
          category: "context"
        )
      )

    state = %{session_id: "test-session", running: true}

    {:ok, state: state}
  end

  describe "/pack (no args)" do
    test "shows current pack name" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack", %{})
        end)

      assert output =~ "single"
    end

    test "lists available packs" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack", %{})
        end)

      assert output =~ "coding"
      assert output =~ "economical"
      assert output =~ "capacity"
    end

    test "shows current role configuration" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack", %{})
        end)

      assert output =~ "role configuration"
    end

    test "shows hint to switch packs" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack", %{})
        end)

      assert output =~ "/pack <name>"
    end

    test "marks current pack with arrow" do
      ModelPacks.set_current_pack("coding")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack", %{})
        end)

      # coding should appear as current pack
      assert output =~ "coding"
    end

    test "returns continue" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, %{}} = Pack.handle_pack("/pack", %{})
      end)
    end
  end

  describe "/pack <name>" do
    test "switches to the named pack" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack coding", %{})
        end)

      assert output =~ "Switched to pack"
      assert output =~ "coding"
      assert ModelPacks.get_current_pack().name == "coding"
    end

    test "shows pack description after switching" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack coding", %{})
        end)

      assert output =~ "Optimized for coding tasks"
    end

    test "shows role configuration after switching" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack coding", %{})
        end)

      assert output =~ "Role configuration"
      assert output =~ "coder"
    end

    test "handles case-insensitive pack name" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack CODING", %{})
        end)

      assert output =~ "Switched to pack"
      assert ModelPacks.get_current_pack().name == "coding"
    end

    test "shows error for unknown pack" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack nonexistent", %{})
        end)

      assert output =~ "Unknown pack"
      # Should remain on current pack
      assert ModelPacks.get_current_pack().name == "single"
    end

    test "shows available packs on error" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack bogus", %{})
        end)

      assert output =~ "Available:"
      assert output =~ "coding"
    end

    test "switches to economical pack" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack economical", %{})
        end)

      assert output =~ "Switched to pack"
      assert ModelPacks.get_current_pack().name == "economical"
    end

    test "switches to capacity pack" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack capacity", %{})
        end)

      assert output =~ "Switched to pack"
      assert ModelPacks.get_current_pack().name == "capacity"
    end

    test "returns continue" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, %{}} = Pack.handle_pack("/pack coding", %{})
      end)
    end
  end

  describe "/pack (whitespace-only args)" do
    test "whitespace-only args behave like bare /pack" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack   ", %{})
        end)

      assert output =~ "single"
      assert output =~ "Available packs"
    end

    test "tabs in args behave like bare /pack" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack\t", %{})
        end)

      assert output =~ "single"
    end

    test "mixed whitespace args behave like bare /pack" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack  \t  ", %{})
        end)

      assert output =~ "single"
    end

    test "does not show unknown-pack error for whitespace-only args" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack   ", %{})
        end)

      refute output =~ "Unknown pack"
    end
  end

  describe "/pack with invalid usage" do
    test "shows usage hint for too many args" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack foo bar", %{})
        end)

      assert output =~ "Usage"
    end

    test "does not switch pack on invalid usage" do
      ExUnit.CaptureIO.capture_io(fn ->
        Pack.handle_pack("/pack foo bar", %{})
      end)

      assert ModelPacks.get_current_pack().name == "single"
    end
  end

  describe "registration and dispatch" do
    test "/pack is registered and dispatchable" do
      assert {:ok, _} = Registry.get("pack")
    end

    test "/pack dispatches via Dispatcher" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, {:continue, _}} = Dispatcher.dispatch("/pack", %{})
        end)

      assert output =~ "single"
    end

    test "/pack coding dispatches via Dispatcher" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, {:continue, _}} = Dispatcher.dispatch("/pack coding", %{})
        end)

      assert output =~ "Switched to pack"
    end

    test "/pack appears in all_names for tab completion" do
      names = Registry.all_names()
      assert "pack" in names
    end

    test "/pack appears in list_all" do
      commands = Registry.list_all()
      assert Enum.any?(commands, &(&1.name == "pack"))
    end

    test "/pack is in context category" do
      commands = Registry.list_by_category("context")
      pack_cmd = Enum.find(commands, &(&1.name == "pack"))
      assert pack_cmd != nil
      assert pack_cmd.category == "context"
    end

    test "/pack usage is correct" do
      {:ok, cmd} = Registry.get("pack")
      assert cmd.usage == "/pack [pack_name]"
    end
  end

  describe "pack command with coding pack roles" do
    setup do
      ModelPacks.set_current_pack("coding")
      :ok
    end

    test "shows fallback chains for coding pack" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack", %{})
        end)

      # coding pack coder role has fallbacks
      assert output =~ "wafer-glm-5.1"
    end

    test "switches back to single from coding" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = Pack.handle_pack("/pack single", %{})
        end)

      assert output =~ "Switched to pack"
      assert ModelPacks.get_current_pack().name == "single"
    end
  end
end
