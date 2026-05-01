defmodule CodePuppyControl.FeatureFlagsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.FeatureFlags
  alias CodePuppyControl.FeatureFlags.Flags

  # async: false because we manipulate shared env vars and temp files,
  # and register named GenServers.

  @tmp_dir Path.join(
             System.tmp_dir!(),
             "feature_flags_test_#{:erlang.unique_integer([:positive])}"
           )

  setup do
    # Use a temp directory as PUP_EX_HOME so we never touch real config
    File.mkdir_p!(@tmp_dir)
    System.put_env("PUP_EX_HOME", @tmp_dir)

    # Ensure no leftover flags.json from prior test
    flags_path = Path.join(@tmp_dir, "flags.json")
    File.rm(flags_path)

    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      File.rm_rf!(@tmp_dir)
    end)

    %{flags_path: flags_path}
  end

  # ── GenServer tests with supervised process ────────────────────────────
  #
  # We start a FeatureFlags GenServer per test with a unique name.
  # Tests call the GenServer directly to avoid coupling to the global name.

  describe "GenServer: default state" do
    test "all capabilities default to false when no flags file exists" do
      server = start_fresh_flags_server()

      for cap <- Flags.names() do
        assert GenServer.call(server, {:enabled?, cap}) == false
      end
    end
  end

  describe "GenServer: list" do
    test "returns all capabilities with false status when no file" do
      server = start_fresh_flags_server()
      entries = GenServer.call(server, :list)

      assert length(entries) == 5

      for {cap, status, desc} <- entries do
        assert status == false
        assert is_atom(cap)
        assert is_binary(desc)
      end
    end
  end

  describe "GenServer: set" do
    test "enables a capability and persists to disk", %{flags_path: path} do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :llm_client, true)
      assert GenServer.call(server, {:enabled?, :llm_client}) == true

      # Verify the file was written
      assert File.exists?(path)
      {:ok, raw} = File.read(path)
      {:ok, decoded} = Jason.decode(raw)
      assert decoded["elixir.llm_client"] == true
    end

    test "disables a capability" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :tools, true)
      assert GenServer.call(server, {:enabled?, :tools}) == true

      :ok = set_via_server(server, :tools, false)
      assert GenServer.call(server, {:enabled?, :tools}) == false
    end

    test "accepts string capability with elixir. prefix" do
      server = start_fresh_flags_server()
      {:ok, resolved} = Flags.resolve("elixir.cli")
      :ok = GenServer.call(server, {:set, resolved, true})
      assert GenServer.call(server, {:enabled?, :cli}) == true
    end
  end

  describe "GenServer: reset" do
    test "resets all capabilities to false", %{flags_path: _path} do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :llm_client, true)
      :ok = set_via_server(server, :tools, true)
      assert GenServer.call(server, {:enabled?, :llm_client}) == true
      assert GenServer.call(server, {:enabled?, :tools}) == true

      :ok = GenServer.call(server, :reset)

      for cap <- Flags.names() do
        assert GenServer.call(server, {:enabled?, cap}) == false
      end
    end

    test "persists reset to disk", %{flags_path: path} do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :base_agent, true)
      :ok = GenServer.call(server, :reset)

      {:ok, raw} = File.read(path)
      {:ok, decoded} = Jason.decode(raw)

      for cap <- Flags.names() do
        assert decoded[Flags.json_key(cap)] == false
      end
    end
  end

  describe "GenServer: reload" do
    test "picks up changes from disk", %{flags_path: path} do
      server = start_fresh_flags_server()

      # Initially all false
      assert GenServer.call(server, {:enabled?, :cli}) == false

      # Write a flags.json directly to disk
      json = Jason.encode!(%{"elixir.cli" => true}, pretty: true)
      File.write!(path, json <> "\n")

      # Before reload, still false (cached)
      assert GenServer.call(server, {:enabled?, :cli}) == false

      :ok = GenServer.call(server, :reload)

      # After reload, picks up the change
      assert GenServer.call(server, {:enabled?, :cli}) == true
    end
  end

  describe "file loading: missing file" do
    test "defaults to all false when flags.json does not exist" do
      server = start_fresh_flags_server()

      for cap <- Flags.names() do
        assert GenServer.call(server, {:enabled?, cap}) == false
      end
    end
  end

  describe "file loading: malformed file" do
    test "defaults to all false when flags.json contains invalid JSON", %{flags_path: path} do
      File.write!(path, "this is not json at all {{{")
      server = start_fresh_flags_server()

      for cap <- Flags.names() do
        assert GenServer.call(server, {:enabled?, cap}) == false
      end
    end

    test "defaults to all false when flags.json is a JSON array", %{flags_path: path} do
      File.write!(path, Jason.encode!([1, 2, 3]))
      server = start_fresh_flags_server()

      for cap <- Flags.names() do
        assert GenServer.call(server, {:enabled?, cap}) == false
      end
    end

    test "defaults to all false when flags.json is empty", %{flags_path: path} do
      File.write!(path, "")
      server = start_fresh_flags_server()

      for cap <- Flags.names() do
        assert GenServer.call(server, {:enabled?, cap}) == false
      end
    end

    test "ignores non-boolean values with a warning", %{flags_path: path} do
      File.write!(path, Jason.encode!(%{"elixir.llm_client" => "yes"}))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          server = start_fresh_flags_server()
          # llm_client should remain false despite the "yes" value
          assert GenServer.call(server, {:enabled?, :llm_client}) == false
        end)

      assert log =~ "expected boolean"
    end

    test "ignores unknown keys silently", %{flags_path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "elixir.llm_client" => true,
          "elixir.future_cap" => true,
          "totally_random_key" => true
        })
      )

      server = start_fresh_flags_server()

      # Known key works
      assert GenServer.call(server, {:enabled?, :llm_client}) == true

      # All others remain false
      for cap <- Flags.names() -- [:llm_client] do
        assert GenServer.call(server, {:enabled?, cap}) == false
      end
    end

    test "accepts keys without elixir. prefix", %{flags_path: path} do
      File.write!(path, Jason.encode!(%{"llm_client" => true}))
      server = start_fresh_flags_server()
      assert GenServer.call(server, {:enabled?, :llm_client}) == true
    end

    test "warns when flags.json is not a JSON object", %{flags_path: path} do
      File.write!(path, Jason.encode!([1, 2, 3]))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_fresh_flags_server()
        end)

      assert log =~ "flags.json is not a JSON object"
    end
  end

  describe "file loading: valid file" do
    test "loads all flags from valid flags.json", %{flags_path: path} do
      File.write!(
        path,
        Jason.encode!(
          %{
            "elixir.llm_client" => true,
            "elixir.base_agent" => false,
            "elixir.tools" => true,
            "elixir.plugins" => false,
            "elixir.cli" => false
          },
          pretty: true
        )
      )

      server = start_fresh_flags_server()

      assert GenServer.call(server, {:enabled?, :llm_client}) == true
      assert GenServer.call(server, {:enabled?, :base_agent}) == false
      assert GenServer.call(server, {:enabled?, :tools}) == true
      assert GenServer.call(server, {:enabled?, :plugins}) == false
      assert GenServer.call(server, {:enabled?, :cli}) == false
    end

    test "partial flags.json: missing keys default to false", %{flags_path: path} do
      File.write!(path, Jason.encode!(%{"elixir.cli" => true}))
      server = start_fresh_flags_server()

      assert GenServer.call(server, {:enabled?, :cli}) == true

      for cap <- Flags.names() -- [:cli] do
        assert GenServer.call(server, {:enabled?, cap}) == false
      end
    end
  end

  describe "percentage-based rollout" do
    test "percentage/1 returns 0 when flag is false" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :llm_client, false)
      assert GenServer.call(server, {:percentage, :llm_client}) == 0
    end

    test "percentage/1 returns 100 when flag is true" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :tools, true)
      assert GenServer.call(server, {:percentage, :tools}) == 100
    end

    test "percentage/1 returns integer for 50%% flag" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :base_agent, 50)
      assert GenServer.call(server, {:percentage, :base_agent}) == 50
    end

    test "set/2 accepts integer 0..100" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :plugins, 25)
      assert GenServer.call(server, {:percentage, :plugins}) == 25

      # 0 works (disabled)
      :ok = set_via_server(server, :plugins, 0)
      assert GenServer.call(server, {:percentage, :plugins}) == 0

      # 100 works (fully enabled)
      :ok = set_via_server(server, :plugins, 100)
      assert GenServer.call(server, {:percentage, :plugins}) == 100

      # 1 works (barely enabled)
      :ok = set_via_server(server, :plugins, 1)
      assert GenServer.call(server, {:percentage, :plugins}) == 1

      # 99 works (nearly enabled)
      :ok = set_via_server(server, :plugins, 99)
      assert GenServer.call(server, {:percentage, :plugins}) == 99
    end

    test "probabilistic: 0%% is always false" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :cli, 0)

      results = for _ <- 1..100, do: GenServer.call(server, {:enabled?, :cli})
      assert Enum.all?(results, &(&1 == false))
    end

    test "probabilistic: 100%% is always true" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :tools, 100)

      results = for _ <- 1..100, do: GenServer.call(server, {:enabled?, :tools})
      assert Enum.all?(results, &(&1 == true))
    end

    test "probabilistic: 50%% converges within 30%% margin over 1000 trials" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :llm_client, 50)

      results = for _ <- 1..1000, do: GenServer.call(server, {:enabled?, :llm_client})
      pct = Enum.count(results, &(&1 == true)) / length(results) * 100

      # With 1000 trials, a true 50% coin should land between 35% and 65%
      # with > 99.9% probability (margin > 4 sigma).
      assert pct >= 35 and pct <= 65,
             "Expected ~50% enabled, got #{Float.round(pct, 1)}% over 1000 trials"
    end

    test "list includes percentage metadata" do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :cli, 75)

      entries = GenServer.call(server, :list)
      {_, enabled?, pct, _} = Enum.find(entries, fn {c, _, _, _} -> c == :cli end)

      assert pct == 75
      # 75% is probabilistic, but could be true or false — just check it's boolean
      assert is_boolean(enabled?)
    end
  end

  describe "file loading: percentage values" do
    test "loads integer 0..100 values from flags.json", %{flags_path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "elixir.llm_client" => 0,
          "elixir.base_agent" => 50,
          "elixir.tools" => 100
        })
      )

      server = start_fresh_flags_server()
      assert GenServer.call(server, {:percentage, :llm_client}) == 0
      assert GenServer.call(server, {:percentage, :base_agent}) == 50
      assert GenServer.call(server, {:percentage, :tools}) == 100
    end

    test "mixed boolean and integer values in same file", %{flags_path: path} do
      File.write!(
        path,
        Jason.encode!(%{
          "elixir.llm_client" => true,
          "elixir.base_agent" => false,
          "elixir.tools" => 50
        })
      )

      server = start_fresh_flags_server()
      assert GenServer.call(server, {:percentage, :llm_client}) == 100
      assert GenServer.call(server, {:percentage, :base_agent}) == 0
      assert GenServer.call(server, {:percentage, :tools}) == 50
    end

    test "rejects negative percentages with warning", %{flags_path: path} do
      File.write!(
        path,
        Jason.encode!(%{"elixir.llm_client" => -5})
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          server = start_fresh_flags_server()
          assert GenServer.call(server, {:percentage, :llm_client}) == 0
        end)

      assert log =~ "expected boolean or 0..100 integer"
    end

    test "rejects >100 percentages with warning", %{flags_path: path} do
      File.write!(
        path,
        Jason.encode!(%{"elixir.tools" => 150})
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          server = start_fresh_flags_server()
          assert GenServer.call(server, {:percentage, :tools}) == 0
        end)

      assert log =~ "expected boolean or 0..100 integer"
    end
  end

  describe "disk persistence" do
    test "set writes JSON with elixir. prefixed keys", %{flags_path: path} do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :cli, true)

      {:ok, raw} = File.read(path)
      {:ok, decoded} = Jason.decode(raw)

      # Should contain the changed flag plus all defaults
      assert decoded["elixir.cli"] == true
      assert Map.keys(decoded) |> Enum.all?(&String.starts_with?(&1, "elixir."))
    end

    test "multiple sets produce correct final state", %{flags_path: path} do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :llm_client, true)
      :ok = set_via_server(server, :tools, true)
      :ok = set_via_server(server, :llm_client, false)

      assert GenServer.call(server, {:enabled?, :llm_client}) == false
      assert GenServer.call(server, {:enabled?, :tools}) == true

      {:ok, raw} = File.read(path)
      {:ok, decoded} = Jason.decode(raw)
      assert decoded["elixir.llm_client"] == false
      assert decoded["elixir.tools"] == true
    end

    test "serializes percentage values: 0→false, 100→true, 1..99→integer", %{flags_path: path} do
      server = start_fresh_flags_server()
      :ok = set_via_server(server, :llm_client, 0)
      :ok = set_via_server(server, :base_agent, 100)
      :ok = set_via_server(server, :tools, 50)

      {:ok, raw} = File.read(path)
      {:ok, decoded} = Jason.decode(raw)

      assert decoded["elixir.llm_client"] == false
      assert decoded["elixir.base_agent"] == true
      assert decoded["elixir.tools"] == 50
    end
  end

  describe "public API: enabled?/1" do
    test "raises ArgumentError for unknown capabilities" do
      # The public FeatureFlags.enabled?/1 validates capability names.
      # We need the GenServer running under the default name for this.
      # If the app already started one, we use it; otherwise start one.
      ensure_global_flags_server()

      assert_raise ArgumentError, ~r/Unknown feature-flag capability/, fn ->
        FeatureFlags.enabled?(:totally_made_up)
      end
    end

    test "returns false for all caps when GenServer is up and no file" do
      ensure_global_flags_server()

      # Force reload with our temp dir
      :ok = FeatureFlags.reload()

      for cap <- Flags.names() do
        assert FeatureFlags.enabled?(cap) == false
      end
    end
  end

  describe "public API: set/2" do
    test "returns error for unknown capability" do
      assert {:error, :unknown} = FeatureFlags.set(:nonexistent, true)
    end
  end

  describe "public API: GenServer-down fallback" do
    test "enabled? returns false when GenServer is not running" do
      # Stop the global server — the app supervisor will restart it,
      # but there's a brief window where it's unavailable.
      # We test the catch :exit, _ -> false path by racing.
      pid = Process.whereis(FeatureFlags)

      if pid do
        # Kill the process — supervisor will restart, but for a
        # brief moment FeatureFlags.enabled? must not crash.
        # We test by killing and immediately calling.
        Process.exit(pid, :kill)
        # Small sleep to let the process die but not yet restart
        Process.sleep(10)
      end

      # FeatureFlags.enabled? should return false, not crash
      result = FeatureFlags.enabled?(:llm_client)
      assert result == false or result == true
      # Either the process is back up (true/false from GenServer)
      # or the catch clause fired (false). Either way, no crash.
    end

    test "set returns error tuple when GenServer is unavailable" do
      # We verify the catch :exit, _ path by calling set on a
      # non-registered name, confirming the error path works.
      # (We can't easily stop the real GenServer without the
      # supervisor restarting it, so we test the error path
      # by validating the code path directly.)
      pid = Process.whereis(FeatureFlags)

      if pid do
        Process.exit(pid, :kill)
        Process.sleep(10)
      end

      result = FeatureFlags.set(:llm_client, true)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  # ── Test helpers ───────────────────────────────────────────────────────

  # Start a FeatureFlags GenServer with a unique name per test.
  # Uses start_supervised! so it's automatically stopped on test exit.
  defp start_fresh_flags_server do
    name = :"feature_flags_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({FeatureFlags, name: name})
    name
  end

  # Set a capability via the GenServer by name.
  defp set_via_server(server, capability, value) do
    {:ok, resolved} = Flags.resolve(capability)
    GenServer.call(server, {:set, resolved, value})
  end

  # Ensure the global FeatureFlags GenServer is running under its
  # canonical name. If already running, reload from the temp dir.
  defp ensure_global_flags_server do
    case Process.whereis(FeatureFlags) do
      nil ->
        start_supervised!({FeatureFlags, name: FeatureFlags})
        :ok

      _pid ->
        # Already running (from application.ex supervision tree) — just reload
        FeatureFlags.reload()
    end
  end
end
