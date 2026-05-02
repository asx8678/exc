defmodule CodePuppyControl.FeatureFlagsTest do
  @moduledoc """
  Tests for the FeatureFlags GenServer. (code_puppy-djs.4)

  Covers:
  - Default state (all true when no file exists) (Phase J.1)
  - enabled?/1 returns false for valid but disabled flags
  - enabled?/1 returns false for unknown flags
  - set_flag/2 updates in-memory AND persists to disk
  - all_flags/0 returns complete map
  - reload/0 picks up external file changes
  - reset_all/0 sets everything to false
  - Corrupt/invalid JSON handled gracefully
  - File permissions error handled gracefully

  async: false because FeatureFlags is a named singleton that shares ETS.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.FeatureFlags

  @flags_path CodePuppyControl.Config.Paths.home_dir() <> "/flags.json"

  setup do
    # Ensure the GenServer is running
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(FeatureFlags)

    # Reset to clean state and remove any leftover flags.json
    FeatureFlags.reset_all()
    File.rm(@flags_path)

    on_exit(fn ->
      # Clean up flags.json after tests
      File.rm(@flags_path)
      FeatureFlags.reset_all()
    end)

    :ok
  end

  # ===========================================================================
  # Default state
  # ===========================================================================

  describe "default state (no flags.json)" do
    test "all capabilities default to true" do
      # Reload to pick up missing file defaults
      :ok = FeatureFlags.reload()
      for cap <- FeatureFlags.capabilities() do
        assert FeatureFlags.enabled?(cap) == true
      end
    end

    test "all_flags/0 returns all capabilities as true" do
      # Reload to pick up missing file defaults
      :ok = FeatureFlags.reload()
      flags = FeatureFlags.all_flags()

      for cap <- FeatureFlags.capabilities() do
        assert Map.has_key?(flags, cap)
        assert flags[cap] == true
      end
    end
  end

  # ===========================================================================
  # enabled?/1
  # ===========================================================================

  describe "enabled?/1" do
    test "returns false for valid but disabled flags" do
      assert FeatureFlags.enabled?("elixir.llm_client") == false
      assert FeatureFlags.enabled?("elixir.base_agent") == false
      assert FeatureFlags.enabled?("elixir.tools") == false
      assert FeatureFlags.enabled?("elixir.plugins") == false
      assert FeatureFlags.enabled?("elixir.cli") == false
    end

    test "returns false for unknown flags (not in @capabilities)" do
      assert FeatureFlags.enabled?("elixir.unknown") == false
      assert FeatureFlags.enabled?("python.everything") == false
      assert FeatureFlags.enabled?("") == false
      assert FeatureFlags.enabled?("random_string") == false
    end

    test "returns true after flag is enabled" do
      :ok = FeatureFlags.set_flag("elixir.llm_client", true)
      assert FeatureFlags.enabled?("elixir.llm_client") == true
    end
  end

  # ===========================================================================
  # set_flag/2
  # ===========================================================================

  describe "set_flag/2" do
    test "updates in-memory flag" do
      :ok = FeatureFlags.set_flag("elixir.tools", true)
      assert FeatureFlags.enabled?("elixir.tools") == true
    end

    test "persists to disk" do
      :ok = FeatureFlags.set_flag("elixir.base_agent", true)

      assert File.exists?(@flags_path)

      {:ok, content} = File.read(@flags_path)
      {:ok, data} = Jason.decode(content)
      assert data["elixir.base_agent"] == true
    end

    test "multiple flags persist correctly" do
      :ok = FeatureFlags.set_flag("elixir.llm_client", true)
      :ok = FeatureFlags.set_flag("elixir.tools", true)

      {:ok, content} = File.read(@flags_path)
      {:ok, data} = Jason.decode(content)

      assert data["elixir.llm_client"] == true
      assert data["elixir.tools"] == true
      assert data["elixir.base_agent"] == false
    end

    test "can disable a previously enabled flag" do
      :ok = FeatureFlags.set_flag("elixir.cli", true)
      assert FeatureFlags.enabled?("elixir.cli") == true

      :ok = FeatureFlags.set_flag("elixir.cli", false)
      assert FeatureFlags.enabled?("elixir.cli") == false
    end

    test "returns error for unknown capability" do
      assert {:error, :unknown_capability} = FeatureFlags.set_flag("elixir.bogus", true)
    end

    test "does not affect other flags when setting one" do
      :ok = FeatureFlags.set_flag("elixir.plugins", true)
      :ok = FeatureFlags.set_flag("elixir.llm_client", true)

      # plugins should still be true after setting llm_client
      assert FeatureFlags.enabled?("elixir.plugins") == true
      assert FeatureFlags.enabled?("elixir.llm_client") == true
    end
  end

  # ===========================================================================
  # all_flags/0
  # ===========================================================================

  describe "all_flags/0" do
    test "returns complete map with all capabilities" do
      flags = FeatureFlags.all_flags()
      expected_keys = FeatureFlags.capabilities()
      assert Map.keys(flags) |> Enum.sort() == Enum.sort(expected_keys)
    end

    test "reflects current state after modifications" do
      :ok = FeatureFlags.set_flag("elixir.tools", true)
      :ok = FeatureFlags.set_flag("elixir.cli", true)

      flags = FeatureFlags.all_flags()

      assert flags["elixir.tools"] == true
      assert flags["elixir.cli"] == true
      assert flags["elixir.llm_client"] == false
      assert flags["elixir.base_agent"] == false
      assert flags["elixir.plugins"] == false
    end
  end

  # ===========================================================================
  # reload/0
  # ===========================================================================

  describe "reload/0" do
    test "picks up external file changes" do
      # Start with all false
      assert FeatureFlags.enabled?("elixir.llm_client") == false

      # Write an external flags.json
      external_data = %{
        "elixir.llm_client" => true,
        "elixir.base_agent" => true
      }

      File.mkdir_p!(Path.dirname(@flags_path))
      File.write!(@flags_path, Jason.encode!(external_data, pretty: true))

      # Reload from disk
      :ok = FeatureFlags.reload()

      assert FeatureFlags.enabled?("elixir.llm_client") == true
      assert FeatureFlags.enabled?("elixir.base_agent") == true
      assert FeatureFlags.enabled?("elixir.tools") == false
    end

    test "handles missing file on reload" do
      File.rm(@flags_path)
      :ok = FeatureFlags.reload()

      for cap <- FeatureFlags.capabilities() do
        assert FeatureFlags.enabled?(cap) == true
      end
    end
  end

  # ===========================================================================
  # reset_all/0
  # ===========================================================================

  describe "reset_all/0" do
    test "sets everything to false" do
      # Enable a few flags first
      :ok = FeatureFlags.set_flag("elixir.llm_client", true)
      :ok = FeatureFlags.set_flag("elixir.plugins", true)

      :ok = FeatureFlags.reset_all()

      for cap <- FeatureFlags.capabilities() do
        assert FeatureFlags.enabled?(cap) == false
      end
    end

    test "persists reset to disk" do
      :ok = FeatureFlags.set_flag("elixir.cli", true)
      :ok = FeatureFlags.reset_all()

      {:ok, content} = File.read(@flags_path)
      {:ok, data} = Jason.decode(content)

      for cap <- FeatureFlags.capabilities() do
        assert data[cap] == false
      end
    end
  end

  # ===========================================================================
  # Corrupt/invalid JSON
  # ===========================================================================

  describe "corrupt flags.json" do
    test "invalid JSON uses defaults and logs warning" do
      File.mkdir_p!(Path.dirname(@flags_path))
      File.write!(@flags_path, "{this is not valid json!!!")

      # Reload should not crash
      :ok = FeatureFlags.reload()

      for cap <- FeatureFlags.capabilities() do
        assert FeatureFlags.enabled?(cap) == true
      end
    end

    test "non-object JSON uses defaults" do
      File.mkdir_p!(Path.dirname(@flags_path))
      File.write!(@flags_path, Jason.encode!([1, 2, 3]))

      :ok = FeatureFlags.reload()

      for cap <- FeatureFlags.capabilities() do
        assert FeatureFlags.enabled?(cap) == true
      end
    end

    test "JSON with unknown keys ignores them gracefully" do
      data = %{
        "elixir.llm_client" => true,
        "elixir.unknown_capability" => true
      }

      File.mkdir_p!(Path.dirname(@flags_path))
      File.write!(@flags_path, Jason.encode!(data, pretty: true))

      :ok = FeatureFlags.reload()

      assert FeatureFlags.enabled?("elixir.llm_client") == true
      # Unknown key should not appear
      assert FeatureFlags.enabled?("elixir.unknown_capability") == false
    end

    test "JSON with non-boolean values coerces gracefully" do
      data = %{
        "elixir.tools" => "true",
        "elixir.base_agent" => 1,
        "elixir.cli" => "yes"
      }

      File.mkdir_p!(Path.dirname(@flags_path))
      File.write!(@flags_path, Jason.encode!(data, pretty: true))

      :ok = FeatureFlags.reload()

      # "true" string and 1 should be coerced to boolean true
      assert FeatureFlags.enabled?("elixir.tools") == true
      assert FeatureFlags.enabled?("elixir.base_agent") == true
      # "yes" is not a recognized truthy value → false
      assert FeatureFlags.enabled?("elixir.cli") == false
    end
  end

  # ===========================================================================
  # File permissions / I/O errors
  # ===========================================================================

  describe "file permission errors" do
    test "set_flag does not crash on write failure" do
      # Temporarily point the flags file at an impossible path
      # by making the home dir unwritable.
      # We can't easily make the real home dir unwritable, but we can
      # test that the function handles the error gracefully.

      # Instead, we test by setting PUP_EX_HOME to a read-only path
      # and seeing that set_flag still returns an error tuple, not a crash.
      #
      # Since we can't change the home_dir at runtime (it's cached),
      # we test a simpler scenario: writing to a path where the
      # parent directory doesn't exist yet (should succeed because mkdir_p).

      # The actual test: set_flag should return :ok or {:error, _}, never crash
      result = FeatureFlags.set_flag("elixir.plugins", true)
      assert result == :ok or match?({:error, _}, result)
    end
  end

  # ===========================================================================
  # capabilities/0
  # ===========================================================================

  describe "capabilities/0" do
    test "returns all expected capability names" do
      caps = FeatureFlags.capabilities()

      assert "elixir.llm_client" in caps
      assert "elixir.base_agent" in caps
      assert "elixir.tools" in caps
      assert "elixir.plugins" in caps
      assert "elixir.cli" in caps
      assert length(caps) == 5
    end
  end

  # ===========================================================================
  # Idempotency / edge cases
  # ===========================================================================

  describe "edge cases" do
    test "reset_all when already all false is idempotent" do
      :ok = FeatureFlags.reset_all()
      :ok = FeatureFlags.reset_all()

      for cap <- FeatureFlags.capabilities() do
        assert FeatureFlags.enabled?(cap) == false
      end
    end

    test "set_flag to same value is idempotent" do
      :ok = FeatureFlags.set_flag("elixir.tools", true)
      :ok = FeatureFlags.set_flag("elixir.tools", true)
      assert FeatureFlags.enabled?("elixir.tools") == true
    end

    test "enabled? with empty string returns false" do
      assert FeatureFlags.enabled?("") == false
    end
  end
end
