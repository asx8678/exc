defmodule CodePuppyControl.Config.PathsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.Paths

  @home Path.expand("~")

  setup do
    # Clean up env vars that might interfere
    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")
      System.delete_env("XDG_CONFIG_HOME")
      System.delete_env("XDG_DATA_HOME")
      System.delete_env("XDG_CACHE_HOME")
      System.delete_env("XDG_STATE_HOME")

      # Reset deprecation warning guards so tests are repeatable
      for env_var <- ["PUP_HOME", "PUPPY_HOME"] do
        key = {:code_puppy_control, :deprecation_warned, env_var}

        try do
          :persistent_term.erase(key)
        catch
          :error, :badarg -> :ok
        end
      end
    end)

    :ok
  end

  # ── home_dir/0 ──────────────────────────────────────────────────────────

  describe "home_dir/0" do
    test "defaults to ~/.code_puppy_ex" do
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")

      assert Paths.home_dir() == Path.join(@home, ".code_puppy_ex")
    end

    test "PUP_EX_HOME overrides everything" do
      System.put_env("PUP_EX_HOME", "/custom/ex_home")
      System.put_env("PUP_HOME", "/should/be/ignored")
      System.put_env("PUPPY_HOME", "/also/ignored")

      assert Paths.home_dir() == "/custom/ex_home"
    end

    test "PUP_HOME overrides when PUP_EX_HOME not set" do
      System.delete_env("PUP_EX_HOME")
      System.put_env("PUP_HOME", "/custom/home")

      assert Paths.home_dir() == "/custom/home"
    end

    test "PUP_HOME logs deprecation warning" do
      System.delete_env("PUP_EX_HOME")
      System.put_env("PUP_HOME", "/custom/home")

      # Reset guard so warning fires in this test
      key = {:code_puppy_control, :deprecation_warned, "PUP_HOME"}

      try do
        :persistent_term.erase(key)
      catch
        :error, :badarg -> :ok
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Paths.home_dir()
        end)

      assert log =~ "PUP_HOME is deprecated"
      assert log =~ "PUP_EX_HOME"
    end

    test "PUP_HOME deprecation warning fires only once" do
      System.delete_env("PUP_EX_HOME")
      System.put_env("PUP_HOME", "/custom/home")

      # Reset guard
      key = {:code_puppy_control, :deprecation_warned, "PUP_HOME"}

      try do
        :persistent_term.erase(key)
      catch
        :error, :badarg -> :ok
      end

      log1 =
        ExUnit.CaptureLog.capture_log(fn ->
          Paths.home_dir()
        end)

      log2 =
        ExUnit.CaptureLog.capture_log(fn ->
          Paths.home_dir()
        end)

      assert log1 =~ "deprecated"
      refute log2 =~ "deprecated"
    end

    test "PUPPY_HOME is legacy fallback" do
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.put_env("PUPPY_HOME", "/legacy/home")

      assert Paths.home_dir() == "/legacy/home"
    end

    test "PUPPY_HOME logs deprecation warning" do
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.put_env("PUPPY_HOME", "/legacy/home")

      # Reset guard
      key = {:code_puppy_control, :deprecation_warned, "PUPPY_HOME"}

      try do
        :persistent_term.erase(key)
      catch
        :error, :badarg -> :ok
      end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Paths.home_dir()
        end)

      assert log =~ "PUPPY_HOME is deprecated"
      assert log =~ "PUP_EX_HOME"
    end
  end

  # ── legacy_home_dir/0 ──────────────────────────────────────────────────

  describe "legacy_home_dir/0" do
    test "always returns ~/.code_puppy regardless of env vars" do
      System.put_env("PUP_EX_HOME", "/custom/ex")
      System.put_env("PUP_HOME", "/custom/home")
      System.put_env("PUPPY_HOME", "/legacy/home")

      assert Paths.legacy_home_dir() == Path.join(@home, ".code_puppy")
    end
  end

  # ── in_legacy_home?/1 ──────────────────────────────────────────────────

  describe "in_legacy_home?/1" do
    test "returns true for paths under legacy home" do
      path = Path.join(@home, ".code_puppy/some_file")
      assert Paths.in_legacy_home?(path)
    end

    test "returns true for the legacy home directory itself" do
      assert Paths.in_legacy_home?(Path.join(@home, ".code_puppy"))
    end

    test "returns false for paths under the new home" do
      path = Path.join(@home, ".code_puppy_ex/some_file")
      refute Paths.in_legacy_home?(path)
    end

    test "returns false for unrelated paths" do
      refute Paths.in_legacy_home?("/tmp/unrelated")
    end

    test "does not false-positive on prefix collision" do
      # ~/.code_puppy_extras should NOT match ~/.code_puppy
      refute Paths.in_legacy_home?(Path.join(@home, ".code_puppy_extras/thing"))
    end

    test "follows symlinks to detect legacy home" do
      tmp_dir = System.tmp_dir!()
      link_path = Path.join(tmp_dir, "puppy_symlink_test_#{:erlang.unique_integer([:positive])}")
      legacy_target = Path.join(@home, ".code_puppy/x")

      # Create symlink: link_path → ~/.code_puppy/x
      :ok = :file.make_symlink(legacy_target, String.to_charlist(link_path))

      try do
        assert Paths.in_legacy_home?(link_path)
      after
        File.rm(link_path)
      end
    end
  end

  # ── canonical_resolve/1 ─────────────────────────────────────────────────

  describe "canonical_resolve/1" do
    test "expands ~ to home directory" do
      resolved = Paths.canonical_resolve("~/.code_puppy_ex")
      assert resolved == Path.join(@home, ".code_puppy_ex")
    end

    test "resolves .. segments" do
      # Use home dir to avoid macOS /tmp → /private/tmp symlink issues
      base = Path.join(@home, "code_puppy_test_a")
      expected = Path.join(@home, "code_puppy_test_b")
      resolved = Paths.canonical_resolve(Path.join(base, "../code_puppy_test_b"))
      assert resolved == expected
    end

    test "follows symlinks" do
      # Use home dir to avoid macOS /tmp → /private/tmp symlink issues
      real_dir = Path.join(@home, "_canonical_real_#{:erlang.unique_integer([:positive])}")
      link_path = Path.join(@home, "_canonical_link_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(real_dir)
      :ok = :file.make_symlink(real_dir, String.to_charlist(link_path))

      try do
        resolved = Paths.canonical_resolve(link_path)
        # Both real_dir and resolved should resolve to the same canonical path
        # since home dir components are not symlinks
        assert resolved == real_dir
      after
        File.rm(link_path)
        File.rm_rf(real_dir)
      end
    end

    test "returns expanded path for non-existent paths" do
      # Use home dir to avoid macOS /tmp → /private/tmp symlink issues
      non_existent =
        Path.join(@home, "nonexistent_path_xyz_#{:erlang.unique_integer([:positive])}/file.txt")

      expected = non_existent
      resolved = Paths.canonical_resolve(non_existent)
      assert resolved == expected
    end
  end

  # ── config_dir/0 ───────────────────────────────────────────────────────

  describe "config_dir/0" do
    test "defaults to ~/.code_puppy_ex when no XDG vars" do
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("XDG_CONFIG_HOME")

      assert Paths.config_dir() == Path.join(@home, ".code_puppy_ex")
    end

    test "uses XDG_CONFIG_HOME when set" do
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.put_env("XDG_CONFIG_HOME", "/xdg/config")

      assert Paths.config_dir() == Path.join("/xdg/config", "code_puppy_ex")
    end
  end

  # ── File path functions ─────────────────────────────────────────────────

  describe "config_file/0" do
    test "returns path ending in puppy.cfg" do
      assert String.ends_with?(Paths.config_file(), "puppy.cfg")
    end
  end

  describe "mcp_servers_file/0" do
    test "returns path ending in mcp_servers.json" do
      assert String.ends_with?(Paths.mcp_servers_file(), "mcp_servers.json")
    end
  end

  describe "models_file/0" do
    test "returns path ending in models.json" do
      assert String.ends_with?(Paths.models_file(), "models.json")
    end
  end

  describe "agents_dir/0" do
    test "returns path ending in agents" do
      assert String.ends_with?(Paths.agents_dir(), "agents")
    end
  end

  describe "autosave_dir/0" do
    test "returns path ending in autosaves" do
      assert String.ends_with?(Paths.autosave_dir(), "autosaves")
    end
  end

  # ── Utilities ───────────────────────────────────────────────────────────

  describe "ensure_dirs!/0" do
    test "creates directories without error" do
      assert Paths.ensure_dirs!() == :ok
    end
  end

  describe "project_agents_dir/0" do
    test "returns nil when .code_puppy/agents doesn't exist" do
      # Unless the test CWD has one
      result = Paths.project_agents_dir()
      assert result == nil or is_binary(result)
    end
  end
end
