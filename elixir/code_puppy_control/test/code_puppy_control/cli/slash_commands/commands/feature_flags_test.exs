defmodule CodePuppyControl.CLI.SlashCommands.Commands.FeatureFlagsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias CodePuppyControl.CLI.SlashCommands.Commands.FeatureFlags, as: FeatureFlagsCommand
  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.FeatureFlags.Flags

  # async: false because this command exercises the named FeatureFlags and
  # Registry processes, plus PUP_EX_HOME path resolution.

  setup do
    test_dir = Path.join(System.tmp_dir!(), "feature_flags_command_test_#{unique_id()}")
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

    {:ok, flags_path: flags_path, state: %{running: true, session_id: "ff-command-test"}}
  end

  describe "/feature-flags list" do
    test "lists current flags with statuses", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags("/feature-flags list", state)
        end)

      assert output =~ "Feature Flags"
      assert output =~ "disabled"

      for capability <- Flags.names() do
        assert output =~ Atom.to_string(capability)
      end
    end

    test "bare /feature-flags behaves like list", %{state: state} do
      bare_output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags("/feature-flags", state)
        end)

      list_output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags("/feature-flags list", state)
        end)

      assert bare_output == list_output
    end
  end

  describe "/feature-flags set" do
    test "sets a known capability to true and subsequent list shows it", %{state: state} do
      set_output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags(
                     "/feature-flags set llm_client true",
                     state
                   )
        end)

      assert set_output =~ "Feature flag llm_client set to true"
      assert FeatureFlags.enabled?(:llm_client)

      list_output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags("/feature-flags list", state)
        end)

      assert list_output =~ "llm_client"
      assert list_output =~ "enabled"
    end

    test "passes source: :slash_command to FeatureFlags.set/3", %{state: state} do
      test_pid = self()
      handler_id = "feature-flags-command-telemetry-#{unique_id()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:code_puppy_control, :feature_flags, :set],
          [:code_puppy, :feature_flags, :invalid]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      try do
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags(
                     "/feature-flags set tools true",
                     state
                   )
        end)

        assert_receive {:telemetry, [:code_puppy_control, :feature_flags, :set], _measurements,
                        metadata},
                       1_000

        assert metadata.source == :slash_command
        assert metadata.flags == %{tools: true}

        refute_receive {:telemetry, [:code_puppy, :feature_flags, :invalid], _measurements,
                        _metadata},
                       100
      after
        :telemetry.detach(handler_id)
      end
    end

    test "invalid FeatureFlags source emits telemetry and falls back to API" do
      test_pid = self()
      handler_id = "feature-flags-invalid-source-#{unique_id()}"

      :telemetry.attach_many(
        handler_id,
        [
          [:code_puppy, :feature_flags, :invalid],
          [:code_puppy_control, :feature_flags, :set]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      try do
        assert :ok = FeatureFlags.set(:plugins, true, source: :bogus_source)

        assert_receive {:telemetry, [:code_puppy, :feature_flags, :invalid], %{count: 1},
                        invalid_metadata},
                       1_000

        assert invalid_metadata.reason == {:invalid_source, :bogus_source}
        assert invalid_metadata.fallback == :api

        assert_receive {:telemetry, [:code_puppy_control, :feature_flags, :set], _measurements,
                        set_metadata},
                       1_000

        assert set_metadata.source == :api
        assert set_metadata.flags == %{plugins: true}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "reports unknown capability clearly without changing existing state", %{state: state} do
      assert :ok = FeatureFlags.set(:plugins, true, source: :test)

      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags("/feature-flags set nope true", state)
        end)

      assert output =~ "Unknown capability \"nope\""
      assert output =~ "Known capabilities:"
      assert output =~ "llm_client"
      assert FeatureFlags.enabled?(:plugins)
    end

    test "reports invalid boolean clearly", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags(
                     "/feature-flags set llm_client notabool",
                     state
                   )
        end)

      assert output =~ "Invalid boolean \"notabool\". Use true/false."
      refute FeatureFlags.enabled?(:llm_client)
    end
  end

  describe "/feature-flags reload" do
    test "re-reads flags from disk", %{flags_path: flags_path, state: state} do
      refute FeatureFlags.enabled?(:cli)

      File.write!(flags_path, Jason.encode!(%{"elixir.cli" => true}, pretty: true) <> "\n")

      refute FeatureFlags.enabled?(:cli)

      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags("/feature-flags reload", state)
        end)

      assert output =~ "Feature flags reloaded from disk"
      assert FeatureFlags.enabled?(:cli)
    end
  end

  describe "validation" do
    test "unknown subcommand returns helpful usage", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags("/feature-flags delete", state)
        end)

      assert output =~ "Unknown subcommand \"delete\""
      assert output =~ "Usage: /feature-flags"
      assert output =~ "list|set"
      assert output =~ "reload"
    end

    test "missing set boolean returns helpful error", %{state: state} do
      output =
        capture_io(fn ->
          assert {:continue, ^state} =
                   FeatureFlagsCommand.handle_feature_flags("/feature-flags set cli", state)
        end)

      assert output =~ "Missing boolean value for capability \"cli\". Use true/false."
    end
  end

  describe "registration and dispatch" do
    test "dispatches through the slash-command registry", %{state: state} do
      output =
        capture_io(fn ->
          assert {:ok, {:continue, ^state}} = Dispatcher.dispatch("/feature-flags list", state)
        end)

      assert output =~ "Feature Flags"
    end

    test "registry exposes command metadata" do
      assert {:ok, cmd} = Registry.get("feature-flags")
      assert cmd.name == "feature-flags"
      assert cmd.category == "config"
      assert cmd.usage == "/feature-flags [list|set <capability> <bool>|reload]"
    end
  end

  defp command_info do
    CommandInfo.new(
      name: "feature-flags",
      description: "List, set, and reload Elixir feature flags",
      handler: &FeatureFlagsCommand.handle_feature_flags/2,
      usage: "/feature-flags [list|set <capability> <bool>|reload]",
      aliases: ["feature_flags"],
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
