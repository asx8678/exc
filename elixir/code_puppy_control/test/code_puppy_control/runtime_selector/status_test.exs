defmodule CodePuppyControl.RuntimeSelector.StatusTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.RuntimeSelector
  alias CodePuppyControl.RuntimeSelector.Status
  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.FeatureFlags.Flags

  # async: false because we manipulate shared env vars and GenServers.

  @tmp_dir Path.join(
             System.tmp_dir!(),
             "rs_status_test_#{:erlang.unique_integer([:positive])}"
           )

  setup do
    File.mkdir_p!(@tmp_dir)
    System.put_env("PUP_EX_HOME", @tmp_dir)

    flags_path = Path.join(@tmp_dir, "flags.json")
    File.rm(flags_path)

    if Process.whereis(FeatureFlags) do
      FeatureFlags.reload()
    end

    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_RUNTIME")
      File.rm_rf!(@tmp_dir)
    end)

    %{flags_path: flags_path}
  end

  # ── report/0 structure ─────────────────────────────────────────────────

  describe "report/0" do
    test "returns a map with required keys" do
      report = Status.report()

      assert Map.has_key?(report, :mode)
      assert Map.has_key?(report, :pup_runtime_env)
      assert Map.has_key?(report, :capabilities)
      assert Map.has_key?(report, :feature_flags)
    end

    test "mode is one of the valid modes" do
      report = Status.report()
      assert report.mode in [:python, :elixir, :auto]
    end

    test "pup_runtime_env reflects PUP_RUNTIME env var" do
      System.put_env("PUP_RUNTIME", "elixir")
      report = Status.report()
      assert report.pup_runtime_env == "elixir"

      System.delete_env("PUP_RUNTIME")
      report = Status.report()
      assert report.pup_runtime_env == nil
    end

    test "capabilities maps each known capability to a runtime" do
      report = Status.report()

      for cap <- Flags.names() do
        assert Map.has_key?(report.capabilities, cap),
               "Missing capability #{cap} in report"

        assert report.capabilities[cap] in [:python, :elixir],
               "Capability #{cap} has invalid runtime: #{inspect(report.capabilities[cap])}"
      end
    end

    test "feature_flags maps each known capability to a boolean" do
      report = Status.report()

      for cap <- Flags.names() do
        assert Map.has_key?(report.feature_flags, cap),
               "Missing capability #{cap} in feature_flags"

        assert is_boolean(report.feature_flags[cap]),
               "Capability #{cap} feature flag is not boolean: #{inspect(report.feature_flags[cap])}"
      end
    end

    test "no extra capabilities beyond known ones" do
      report = Status.report()
      known = MapSet.new(Flags.names())
      reported = MapSet.new(Map.keys(report.capabilities))

      assert MapSet.subset?(reported, known),
             "Extra capabilities reported: #{MapSet.difference(reported, known) |> MapSet.to_list() |> inspect()}"
    end
  end

  # ── report with different modes ──────────────────────────────────────────

  describe "report/0 with different modes" do
    test "python mode routes all capabilities to :python" do
      server = start_fresh_selector(mode: :python)

      # Temporarily point the Status module at our test server
      # Since Status uses the global RuntimeSelector, we set the global mode.
      set_global_mode(:python)

      report = Status.report()
      assert report.mode == :python

      for cap <- Flags.names() do
        assert report.capabilities[cap] == :python
      end

      stop_test_server(server)
    end

    test "elixir mode routes all capabilities to :elixir" do
      set_global_mode(:elixir)

      report = Status.report()
      assert report.mode == :elixir

      for cap <- Flags.names() do
        assert report.capabilities[cap] == :elixir
      end

      set_global_mode(:auto)
    end

    test "auto mode respects feature flags" do
      FeatureFlags.set(:llm_client, true, source: :test)
      FeatureFlags.set(:tools, false, source: :test)

      set_global_mode(:auto)

      report = Status.report()
      assert report.mode == :auto
      assert report.capabilities[:llm_client] == :elixir
      assert report.capabilities[:tools] == :python

      # Cleanup
      FeatureFlags.set(:llm_client, false, source: :test)
      set_global_mode(:auto)
    end
  end

  # ── run_checks/0 ─────────────────────────────────────────────────────────

  describe "run_checks/0" do
    test "returns a list of check maps with required keys" do
      checks = Status.run_checks()

      assert is_list(checks)
      assert length(checks) > 0

      for check <- checks do
        assert Map.has_key?(check, :name)
        assert Map.has_key?(check, :status)
        assert Map.has_key?(check, :detail)
        assert check.status in [:pass, :warn, :fail, :info]
        assert is_binary(check.name)
        assert is_binary(check.detail)
      end
    end

    test "reports RuntimeSelector GenServer as running when alive" do
      # The global RuntimeSelector should be running in test env
      checks = Status.run_checks()

      alive_check =
        Enum.find(checks, &String.contains?(&1.name, "RuntimeSelector GenServer is running"))

      assert alive_check != nil
      assert alive_check.status == :pass
    end

    test "reports FeatureFlags GenServer as running when alive" do
      checks = Status.run_checks()

      flags_check =
        Enum.find(checks, &String.contains?(&1.name, "FeatureFlags GenServer is running"))

      assert flags_check != nil
      assert flags_check.status in [:pass, :warn]
    end

    test "detects mode inconsistency" do
      System.delete_env("PUP_RUNTIME")

      # If we set mode dynamically to :elixir, but PUP_RUNTIME is unset,
      # the consistency check should notice
      set_global_mode(:elixir)

      checks = Status.run_checks()

      consistency_check =
        Enum.find(checks, &String.contains?(&1.name, "mode matches PUP_RUNTIME"))

      assert consistency_check != nil
      # Dynamic mode change without env var → warn
      assert consistency_check.status == :warn

      set_global_mode(:auto)
    end
  end

  # ── format_report/0 ──────────────────────────────────────────────────────

  describe "format_report/0" do
    test "output contains Runtime Selector Status header" do
      output = Status.format_report()
      assert output =~ "Runtime Selector Status"
    end

    test "output contains Mode line" do
      output = Status.format_report()
      assert output =~ "Mode:"
    end

    test "output contains PUP_RUNTIME line" do
      System.delete_env("PUP_RUNTIME")
      output = Status.format_report()
      assert output =~ "PUP_RUNTIME:"
    end

    test "output contains Capabilities section" do
      output = Status.format_report()
      assert output =~ "Capabilities:"
    end

    test "output includes each capability name" do
      output = Status.format_report()

      for cap <- Flags.names() do
        assert output =~ Atom.to_string(cap),
               "Missing capability #{cap} in formatted output"
      end
    end

    test "output shows runtime routing for each capability" do
      output = Status.format_report()
      # Format uses atom-to-string (e.g. "python" or "elixir"), not :python syntax
      assert output =~ "python" or output =~ "elixir"
    end

    test "output includes mode description" do
      set_global_mode(:auto)
      output = Status.format_report()
      assert output =~ "per-capability via feature flags"
    after
      set_global_mode(:auto)
    end
  end

  # ── Degraded: FeatureFlags down ─────────────────────────────────────────

  describe "degraded mode when FeatureFlags unavailable" do
    test "report still succeeds when FeatureFlags is down" do
      # Stop the global FeatureFlags GenServer.
      # RuntimeSelector and Status should still work, just with degraded data.
      pid = Process.whereis(FeatureFlags)

      if pid do
        Process.exit(pid, :kill)
        Process.sleep(20)
      end

      # This should NOT raise
      report = Status.report()
      assert Map.has_key?(report, :mode)
      assert Map.has_key?(report, :capabilities)

      # feature_flags may have an error key or may be a partial map
      # depending on whether the supervisor restarted FeatureFlags
      assert is_map(report.feature_flags)

      # Give supervisor time to restart FeatureFlags
      Process.sleep(50)

      if Process.whereis(FeatureFlags) == nil do
        # Start it back if supervisor didn't
        FeatureFlags.start_link([])
      end
    end

    test "run_checks flags FeatureFlags as warn when down" do
      pid = Process.whereis(FeatureFlags)

      if pid do
        Process.exit(pid, :kill)
        Process.sleep(20)
      end

      checks = Status.run_checks()

      flags_check =
        Enum.find(checks, &String.contains?(&1.name, "FeatureFlags GenServer is running"))

      # Either it got restarted (pass) or it's down (warn) — both valid
      assert flags_check.status in [:pass, :warn]

      Process.sleep(50)

      if Process.whereis(FeatureFlags) == nil do
        FeatureFlags.start_link([])
      end
    end
  end

  # ── Test helpers ────────────────────────────────────────────────────────

  defp start_fresh_selector(opts) do
    name = :"rs_status_test_#{:erlang.unique_integer([:positive])}"

    if mode = Keyword.get(opts, :mode) do
      System.put_env("PUP_RUNTIME", Atom.to_string(mode))
    end

    start_supervised!({RuntimeSelector, name: name}, id: name)
    name
  end

  defp stop_test_server(server) do
    GenServer.stop(server, :normal)
  catch
    :exit, _ -> :ok
  end

  # Set mode on the global RuntimeSelector (used by Status.report).
  defp set_global_mode(mode) do
    case Process.whereis(RuntimeSelector) do
      nil -> :ok
      _pid -> RuntimeSelector.set_mode(mode)
    end
  end
end
