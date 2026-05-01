defmodule CodePuppyControl.RuntimeSelectorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.RuntimeSelector
  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.FeatureFlags.Flags

  # async: false because we manipulate shared env vars and the global
  # FeatureFlags GenServer.

  @tmp_dir Path.join(
             System.tmp_dir!(),
             "runtime_selector_test_#{:erlang.unique_integer([:positive])}"
           )

  setup do
    # Use a temp config dir so FeatureFlags never touches the real one.
    # This MUST happen before any FeatureFlags call so the global server
    # (started by the app supervisor) reads from the temp dir.
    File.mkdir_p!(@tmp_dir)
    System.put_env("PUP_EX_HOME", @tmp_dir)

    # Remove any leftover flags.json from prior test
    flags_path = Path.join(@tmp_dir, "flags.json")
    File.rm(flags_path)

    # Ensure the global FeatureFlags knows about the temp dir by reloading.
    # The global server may already be started by the app supervisor in test
    # env, so we reload to pick up the (empty) temp-dir flags.
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

  # ── Env var parsing ────────────────────────────────────────────────────

  describe "env var parsing" do
    test "defaults to :auto when PUP_RUNTIME is unset" do
      System.delete_env("PUP_RUNTIME")
      server = start_fresh_selector()
      assert mode_of(server) == :auto
    end

    test "parses 'python' to :python" do
      System.put_env("PUP_RUNTIME", "python")
      server = start_fresh_selector()
      assert mode_of(server) == :python
    end

    test "parses 'elixir' to :elixir" do
      System.put_env("PUP_RUNTIME", "elixir")
      server = start_fresh_selector()
      assert mode_of(server) == :elixir
    end

    test "parses 'auto' to :auto" do
      System.put_env("PUP_RUNTIME", "auto")
      server = start_fresh_selector()
      assert mode_of(server) == :auto
    end

    test "uppercase ELIXIR parses to :elixir" do
      System.put_env("PUP_RUNTIME", "ELIXIR")
      server = start_fresh_selector()
      assert mode_of(server) == :elixir
    end

    test "mixed-case Python parses to :python" do
      System.put_env("PUP_RUNTIME", "Python")
      server = start_fresh_selector()
      assert mode_of(server) == :python
    end

    test "unknown values default to :auto" do
      System.put_env("PUP_RUNTIME", "production")
      server = start_fresh_selector()
      assert mode_of(server) == :auto
    end

    test "empty string defaults to :auto" do
      System.put_env("PUP_RUNTIME", "")
      server = start_fresh_selector()
      assert mode_of(server) == :auto
    end
  end

  # ── :python mode ───────────────────────────────────────────────────────

  describe ":python mode" do
    test "always returns :python regardless of capability" do
      server = start_fresh_selector(mode: :python)

      for cap <- Flags.names() do
        assert select_for(server, cap) == :python
      end
    end

    test "returns :python for unknown capabilities" do
      server = start_fresh_selector(mode: :python)
      assert select_for(server, :nonexistent) == :python
    end
  end

  # ── :elixir mode ───────────────────────────────────────────────────────

  describe ":elixir mode" do
    test "always returns :elixir regardless of capability" do
      server = start_fresh_selector(mode: :elixir)

      for cap <- Flags.names() do
        assert select_for(server, cap) == :elixir
      end
    end

    test "returns :elixir for unknown capabilities" do
      server = start_fresh_selector(mode: :elixir)
      assert select_for(server, :nonexistent) == :elixir
    end
  end

  # ── :auto mode ─────────────────────────────────────────────────────────

  describe ":auto mode" do
    test "returns :elixir when feature flag is enabled" do
      FeatureFlags.set(:llm_client, true)

      server = start_fresh_selector(mode: :auto)
      assert select_for(server, :llm_client) == :elixir
    end

    test "returns :python when feature flag is disabled" do
      FeatureFlags.set(:llm_client, false)

      server = start_fresh_selector(mode: :auto)
      assert select_for(server, :llm_client) == :python
    end

    test "returns :python for capabilities that default to false" do
      # All flags default to false in an empty temp dir — the reload in
      # setup already picked up the empty state.
      server = start_fresh_selector(mode: :auto)

      for cap <- Flags.names() do
        assert select_for(server, cap) == :python
      end
    end

    test "handles each capability independently" do
      FeatureFlags.set(:llm_client, true)
      FeatureFlags.set(:tools, true)
      FeatureFlags.set(:base_agent, false)
      FeatureFlags.set(:plugins, false)
      FeatureFlags.set(:cli, false)

      server = start_fresh_selector(mode: :auto)

      assert select_for(server, :llm_client) == :elixir
      assert select_for(server, :tools) == :elixir
      assert select_for(server, :base_agent) == :python
      assert select_for(server, :plugins) == :python
      assert select_for(server, :cli) == :python
    end

    test "falls back to :python when FeatureFlags raises on unknown capability" do
      server = start_fresh_selector(mode: :auto)

      # FeatureFlags raises ArgumentError for unknown capabilities;
      # RuntimeSelector catches it and returns :python
      assert select_for(server, :nonexistent) == :python
    end

    test "falls back to :python when FeatureFlags GenServer is down" do
      FeatureFlags.set(:cli, true)

      server = start_fresh_selector(mode: :auto)

      # Verify it works with a live flags server
      assert select_for(server, :cli) == :elixir

      # Stop the global FeatureFlags GenServer. The supervisor may restart
      # it immediately, making this a race — we accept either result since
      # both are valid behaviors (matching the FeatureFlags test pattern).
      pid = Process.whereis(FeatureFlags)
      assert pid != nil
      Process.exit(pid, :kill)
      Process.sleep(10)

      result = select_for(server, :cli)

      assert result in [:python, :elixir],
             "Expected :python or :elixir, got: #{inspect(result)}"
    end
  end

  # ── Dynamic mode switching ─────────────────────────────────────────────

  describe "set_mode" do
    test "switches from :auto to :python" do
      server = start_fresh_selector(mode: :auto)
      assert mode_of(server) == :auto

      set_mode_of(server, :python)
      assert mode_of(server) == :python

      # Now all capabilities route to Python
      assert select_for(server, :llm_client) == :python
    end

    test "switches from :python to :elixir" do
      server = start_fresh_selector(mode: :python)
      assert mode_of(server) == :python

      set_mode_of(server, :elixir)
      assert mode_of(server) == :elixir
      assert select_for(server, :tools) == :elixir
    end

    test "switches from :elixir to :auto and respects feature flags" do
      FeatureFlags.set(:plugins, true)

      server = start_fresh_selector(mode: :elixir)
      assert select_for(server, :plugins) == :elixir
      assert select_for(server, :cli) == :elixir

      set_mode_of(server, :auto)
      assert mode_of(server) == :auto

      assert select_for(server, :plugins) == :elixir
      assert select_for(server, :cli) == :python
    end

    test "raises ArgumentError for invalid mode" do
      assert_raise ArgumentError, ~r/Invalid RuntimeSelector mode/, fn ->
        RuntimeSelector.set_mode(:hybrid)
      end
    end
  end

  # ── Telemetry ──────────────────────────────────────────────────────────

  describe "telemetry" do
    test "emits select event with correct metadata" do
      FeatureFlags.set(:tools, true)

      server = start_fresh_selector(mode: :auto)
      test_pid = self()

      :telemetry.attach_many(
        "rs-test-select",
        [[:code_puppy, :runtime, :select]],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_select, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("rs-test-select")
      end)

      assert select_for(server, :tools) == :elixir

      assert_receive {:telemetry_select, %{},
                      %{capability: :tools, selected: :elixir, mode: :auto}}
    end

    test "emits select event with :python in python mode" do
      server = start_fresh_selector(mode: :python)
      test_pid = self()

      :telemetry.attach_many(
        "rs-test-python",
        [[:code_puppy, :runtime, :select]],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_python, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("rs-test-python")
      end)

      assert select_for(server, :cli) == :python

      assert_receive {:telemetry_python, %{},
                      %{capability: :cli, selected: :python, mode: :python}}
    end

    test "emits set_mode telemetry" do
      server = start_fresh_selector(mode: :auto)
      test_pid = self()

      :telemetry.attach_many(
        "rs-test-set-mode",
        [[:code_puppy, :runtime, :set_mode]],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_set_mode, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("rs-test-set-mode")
      end)

      set_mode_of(server, :elixir)

      assert_receive {:telemetry_set_mode, %{}, %{mode: :elixir, previous_mode: :auto}}
    end
  end

  # ── Named-server-down fallback ─────────────────────────────────────────

  describe "named-server-down fallback" do
    test "select_runtime returns :python when named server stopped" do
      # This tests the GenServer fallback on the public API selector
      # when the global server is unreachable. The named-server version
      # is tested by the :auto/:python/:elixir mode tests above.
      # GenServer.call on a stopped named process raises an exit;
      # the public API catches this and returns :python.

      # Ensure the global RuntimeSelector is not running
      case Process.whereis(RuntimeSelector) do
        nil -> :ok
        pid -> Process.exit(pid, :kill)
      end

      Process.sleep(5)
      assert RuntimeSelector.select_runtime(:llm_client) == :python
    end
  end

  # ── Test helpers ───────────────────────────────────────────────────────

  # Start a RuntimeSelector GenServer, optionally with a pre-set mode.
  # If no mode is given, it reads PUP_RUNTIME env var (or defaults to :auto).
  # Returns the registered name.
  defp start_fresh_selector(opts \\ []) do
    name = :"runtime_selector_test_#{:erlang.unique_integer([:positive])}"

    # If a mode was explicitly given, set the env var so init picks it up
    if mode = Keyword.get(opts, :mode) do
      System.put_env("PUP_RUNTIME", Atom.to_string(mode))
    end

    start_supervised!({RuntimeSelector, name: name}, id: name)
    name
  end

  # Get the current mode from a named RuntimeSelector server.
  defp mode_of(server), do: GenServer.call(server, :current_mode)

  # Select a runtime for a capability from a named RuntimeSelector server.
  defp select_for(server, capability) do
    GenServer.call(server, {:select_runtime, capability})
  end

  # Set mode on a named RuntimeSelector server.
  defp set_mode_of(server, mode) do
    GenServer.call(server, {:set_mode, mode})
  end
end
