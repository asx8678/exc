defmodule CodePuppyControl.CLI.SlashCommands.Commands.RolloutTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CodePuppyControl.CLI.SlashCommands.Commands.Rollout
  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.FeatureFlags.Flags

  # async: false because this command exercises the named FeatureFlags and
  # Registry processes, plus PUP_EX_HOME path resolution.

  setup do
    test_dir = Path.join(System.tmp_dir!(), "rollout_command_test_#{unique_id()}")
    File.mkdir_p!(test_dir)
    System.put_env("PUP_EX_HOME", test_dir)

    flags_path = Path.join(test_dir, "flags.json")
    File.rm(flags_path)

    ensure_feature_flags_server!()
    :ok = FeatureFlags.reload()

    ensure_registry!()
    Registry.clear()
    :ok = Registry.register(command_info())

    on_exit(fn ->
      Registry.clear()
      Registry.register_builtin_commands()
      System.delete_env("PUP_EX_HOME")
      File.rm_rf!(test_dir)
    end)

    {:ok, flags_path: flags_path, state: %{running: true, session_id: "rollout-command-test"}}
  end

  describe "/rollout status" do
    test "shows all capabilities with progress bars", %{state: state} do
      :ok = FeatureFlags.set(:llm_client, 50, source: :test)

      output =
        capture_io(fn ->
          assert {:continue, ^state} = Rollout.handle_rollout("/rollout status", state)
        end)

      assert output =~ "Rollout Status"
      assert output =~ "["
      assert output =~ "%"
      assert output =~ "█"
      assert output =~ "░"
      assert output =~ "50%"
      assert output =~ "0%"

      for capability <- Flags.names() do
        assert output =~ Atom.to_string(capability)
      end
    end

    test "bare /rollout behaves like status", %{state: state} do
      bare_output =
        capture_io(fn ->
          assert {:continue, ^state} = Rollout.handle_rollout("/rollout", state)
        end)

      status_output =
        capture_io(fn ->
          assert {:continue, ^state} = Rollout.handle_rollout("/rollout status", state)
        end)

      assert bare_output == status_output
    end

    test "shows updated percentage after setting a capability", %{state: state} do
      :ok = FeatureFlags.set(:tools, 50, source: :test)

      output =
        capture_io(fn ->
          assert {:continue, ^state} = Rollout.handle_rollout("/rollout status", state)
        end)

      assert output =~ "tools"
      assert output =~ "50%"
    end
  end

  describe "/rollout set" do
    test "sets a known capability to a specific percentage", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set llm_client 25", state)
        end)

      assert output =~ "Rollout for llm_client set to 25%"
      assert FeatureFlags.percentage(:llm_client) == 25
    end

    test "sets to 0%", %{state: state} do
      :ok = FeatureFlags.set(:llm_client, 100, source: :test)

      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set llm_client 0", state)
        end)

      assert output =~ "Rollout for llm_client set to 0%"
      assert FeatureFlags.percentage(:llm_client) == 0
    end

    test "sets to 100%", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set base_agent 100", state)
        end)

      assert output =~ "Rollout for base_agent set to 100%"
      assert FeatureFlags.percentage(:base_agent) == 100
    end

    test "rejects percentage outside 0..100", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set tools 101", state)
        end)

      assert output =~ "Invalid percentage"
      assert output =~ "101"
      assert FeatureFlags.percentage(:tools) == 0
    end

    test "rejects negative percentage", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set plugins -5", state)
        end)

      assert output =~ "Invalid percentage"
      assert FeatureFlags.percentage(:plugins) == 0
    end

    test "rejects non-integer values", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set cli fifty", state)
        end)

      assert output =~ "Invalid percentage"
      assert FeatureFlags.percentage(:cli) == 0
    end

    test "reports unknown capability clearly", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set nope 50", state)
        end)

      assert output =~ "Unknown capability \"nope\""
      assert output =~ "Known:"
      assert output =~ "llm_client"
    end

    test "passes source: :slash_command to FeatureFlags.set/3", %{state: state} do
      test_pid = self()
      handler_id = "rollout-set-telemetry-#{unique_id()}"

      :telemetry.attach_many(
        handler_id,
        [[:code_puppy_control, :feature_flags, :set]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      try do
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set tools 25", state)
        end)

        assert_receive {:telemetry, [:code_puppy_control, :feature_flags, :set], _measurements,
                        metadata},
                       1_000

        assert metadata.source == :slash_command
        assert metadata.flags == %{tools: 25}
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "/rollout step-up" do
    test "steps through the rollout ladder: 0→5", %{state: state} do
      assert FeatureFlags.percentage(:llm_client) == 0

      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-up llm_client", state)
        end)

      assert output =~ "stepped up"
      assert output =~ "0% → 5%"
      assert FeatureFlags.percentage(:llm_client) == 5
    end

    test "steps up: 5→25→50→100", %{state: state} do
      :ok = FeatureFlags.set(:llm_client, 5, source: :test)

      output_25 =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-up llm_client", state)
        end)

      assert output_25 =~ "5% → 25%"
      assert FeatureFlags.percentage(:llm_client) == 25

      output_50 =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-up llm_client", state)
        end)

      assert output_50 =~ "25% → 50%"
      assert FeatureFlags.percentage(:llm_client) == 50

      output_100 =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-up llm_client", state)
        end)

      assert output_100 =~ "50% → 100%"
      assert FeatureFlags.percentage(:llm_client) == 100
    end

    test "stays at 100 when already at max", %{state: state} do
      :ok = FeatureFlags.set(:llm_client, 100, source: :test)

      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-up llm_client", state)
        end)

      assert output =~ "already at maximum"
      assert output =~ "100%"
      assert FeatureFlags.percentage(:llm_client) == 100
    end

    test "reports unknown capability", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-up nope", state)
        end)

      assert output =~ "Unknown capability \"nope\""
    end
  end

  describe "/rollout step-down" do
    test "steps through the rollout ladder: 100→50", %{state: state} do
      :ok = FeatureFlags.set(:tools, 100, source: :test)

      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-down tools", state)
        end)

      assert output =~ "stepped down"
      assert output =~ "100% → 50%"
      assert FeatureFlags.percentage(:tools) == 50
    end

    test "steps down: 50→25→5→0", %{state: state} do
      :ok = FeatureFlags.set(:tools, 50, source: :test)

      output_25 =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-down tools", state)
        end)

      assert output_25 =~ "50% → 25%"
      assert FeatureFlags.percentage(:tools) == 25

      output_5 =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-down tools", state)
        end)

      assert output_5 =~ "25% → 5%"
      assert FeatureFlags.percentage(:tools) == 5

      output_0 =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-down tools", state)
        end)

      assert output_0 =~ "5% → 0%"
      assert FeatureFlags.percentage(:tools) == 0
    end

    test "stays at 0 when already at minimum", %{state: state} do
      assert FeatureFlags.percentage(:tools) == 0

      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-down tools", state)
        end)

      assert output =~ "already at minimum"
      assert output =~ "0%"
      assert FeatureFlags.percentage(:tools) == 0
    end

    test "reports unknown capability", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-down nope", state)
        end)

      assert output =~ "Unknown capability \"nope\""
    end
  end

  describe "progress_bar/2" do
    test "renders full bar for 100%" do
      assert Rollout.progress_bar(100) == "[████████████████████]"
    end

    test "renders empty bar for 0%" do
      assert Rollout.progress_bar(0) == "[░░░░░░░░░░░░░░░░░░░░]"
    end

    test "renders half bar for 50%" do
      assert Rollout.progress_bar(50) == "[██████████░░░░░░░░░░]"
    end

    test "renders quarter bar for 25%" do
      assert Rollout.progress_bar(25) == "[█████░░░░░░░░░░░░░░░]"
    end

    test "renders small bar for 5%" do
      assert Rollout.progress_bar(5) == "[█░░░░░░░░░░░░░░░░░░░]"
    end

    test "accepts custom width" do
      assert Rollout.progress_bar(50, 10) == "[█████░░░░░]"
    end

    test "rounds fractionally" do
      # 1% of 20 = 0.2, rounds to 0
      assert Rollout.progress_bar(1) == "[░░░░░░░░░░░░░░░░░░░░]"
      # 99% of 20 = 19.8, rounds to 20
      assert Rollout.progress_bar(99) == "[████████████████████]"
    end
  end

  describe "validation" do
    test "unknown subcommand returns helpful usage", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout delete", state)
        end)

      assert output =~ "Unknown subcommand \"delete\""
      assert output =~ "Usage: /rollout"
    end

    test "missing set percentage returns helpful error", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set cli", state)
        end)

      assert output =~ "Missing percentage for capability \"cli\". Use 0..100."
    end

    test "missing set capability returns helpful error", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set", state)
        end)

      assert output =~ "Missing capability"
    end

    test "missing step-up capability returns helpful error", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-up", state)
        end)

      assert output =~ "Missing capability"
    end

    test "missing step-down capability returns helpful error", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout step-down", state)
        end)

      assert output =~ "Missing capability"
    end

    test "too many args for set", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   Rollout.handle_rollout("/rollout set llm_client 50 extra", state)
        end)

      assert output =~ "Too many arguments"
    end
  end

  describe "registration and dispatch" do
    test "dispatches through the slash-command registry", %{state: state} do
      output =
        capture_io(fn ->
          assert {:ok, {:continue, ^state}} = Dispatcher.dispatch("/rollout status", state)
        end)

      assert output =~ "Rollout Status"
    end

    test "registry exposes command metadata" do
      assert {:ok, cmd} = Registry.get("rollout")
      assert cmd.name == "rollout"
      assert cmd.category == "config"
      assert cmd.usage == "/rollout [status|set <capability> <pct>|step-up <cap>|step-down <cap>]"
    end
  end

  defp command_info do
    CommandInfo.new(
      name: "rollout",
      description: "Manage gradual rollout percentages",
      handler: &Rollout.handle_rollout/2,
      usage: "/rollout [status|set <capability> <pct>|step-up <cap>|step-down <cap>]",
      aliases: [],
      category: "config"
    )
  end

  defp ensure_feature_flags_server! do
    case Process.whereis(FeatureFlags) do
      nil -> start_supervised!({FeatureFlags, name: FeatureFlags})
      _pid -> :ok
    end
  end

  defp ensure_registry! do
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end
  end

  defp unique_id do
    :erlang.unique_integer([:positive, :monotonic])
  end
end
