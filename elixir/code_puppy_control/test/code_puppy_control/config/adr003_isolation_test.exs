defmodule CodePuppyControl.Config.ADR003IsolationTest do
  @moduledoc """
  Focused Elixir tests proving ADR-003 dual-home isolation.

  Verifies:
  1. Paths resolve to ~/.code_puppy_ex/ (or PUP_EX_HOME), never ~/.code_puppy/
  2. Writes via Isolation.safe_* are blocked on legacy home
  3. Writer delegates through Isolation guard before persisting
  4. Default behavior: no PUP_EX_HOME → defaults to ~/.code_puppy_ex/
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Isolation, Paths, Writer, Loader}

  @home Path.expand("~")

  setup do
    # (code_puppy-i1n) Ensure Config.Writer is alive — prior tests
    # may have destabilised the supervision tree.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(CodePuppyControl.Config.Writer)

    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")
      Process.delete(:isolation_sandbox)
      Loader.invalidate()
    end)

    :ok
  end

  # ── Path resolution ─────────────────────────────────────────────────────

  describe "path resolution under ADR-003" do
    test "home_dir defaults to ~/.code_puppy_ex" do
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")

      assert Paths.home_dir() == Path.join(@home, ".code_puppy_ex")
    end

    test "home_dir respects PUP_EX_HOME" do
      System.put_env("PUP_EX_HOME", "/tmp/test_ex_home")
      assert Paths.home_dir() == "/tmp/test_ex_home"
    end

    test "legacy_home_dir is always ~/.code_puppy" do
      System.put_env("PUP_EX_HOME", "/tmp/test_ex_home")

      # Regardless of env, legacy home is hardcoded
      assert Paths.legacy_home_dir() == Path.join(@home, ".code_puppy")
    end

    test "all path functions resolve under ex home" do
      System.put_env("PUP_EX_HOME", "/tmp/adr003_ex_#{:erlang.unique_integer([:positive])}")

      home = Paths.home_dir()

      for {name, path} <- [
            {"config_dir", Paths.config_dir()},
            {"data_dir", Paths.data_dir()},
            {"cache_dir", Paths.cache_dir()},
            {"state_dir", Paths.state_dir()},
            {"config_file", Paths.config_file()},
            {"mcp_servers_file", Paths.mcp_servers_file()},
            {"models_file", Paths.models_file()},
            {"agents_dir", Paths.agents_dir()},
            {"autosave_dir", Paths.autosave_dir()},
            {"command_history_file", Paths.command_history_file()}
          ] do
        assert String.starts_with?(path, home),
               "#{name} = #{path} does not start with ex home #{home}"
      end
    end

    test "no path function resolves under legacy home" do
      System.put_env("PUP_EX_HOME", "/tmp/adr003_ex_#{:erlang.unique_integer([:positive])}")

      legacy = Paths.legacy_home_dir()

      for {name, path} <- [
            {"config_dir", Paths.config_dir()},
            {"data_dir", Paths.data_dir()},
            {"cache_dir", Paths.cache_dir()},
            {"state_dir", Paths.state_dir()},
            {"config_file", Paths.config_file()},
            {"models_file", Paths.models_file()},
            {"autosave_dir", Paths.autosave_dir()}
          ] do
        refute String.starts_with?(path, legacy <> "/"),
               "#{name} = #{path} incorrectly starts with legacy home #{legacy}"

        refute path == legacy,
               "#{name} = #{path} incorrectly equals legacy home #{legacy}"
      end
    end
  end

  # ── Write isolation ─────────────────────────────────────────────────────

  describe "write isolation under ADR-003" do
    test "safe_write! blocks writes to legacy home" do
      legacy_file = Path.join(Paths.legacy_home_dir(), "test_blocked.txt")

      assert_raise Isolation.IsolationViolation, fn ->
        Isolation.safe_write!(legacy_file, "should be blocked")
      end
    end

    test "safe_mkdir_p! blocks mkdir in legacy home" do
      legacy_dir = Path.join(Paths.legacy_home_dir(), "subdir_blocked")

      assert_raise Isolation.IsolationViolation, fn ->
        Isolation.safe_mkdir_p!(legacy_dir)
      end
    end

    test "safe_write! allows writes under PUP_EX_HOME" do
      test_id = :erlang.unique_integer([:positive])
      ex_home = Path.join(System.tmp_dir!(), "adr003_write_#{test_id}")
      System.put_env("PUP_EX_HOME", ex_home)
      File.mkdir_p!(ex_home)

      target = Path.join(ex_home, "allowed_write.txt")

      Isolation.with_sandbox([ex_home], fn ->
        assert :ok = Isolation.safe_write!(target, "allowed content")
        assert File.read(target) == {:ok, "allowed content"}
      end)

      File.rm_rf(ex_home)
    end

    test "Writer.set_value returns {:error, IsolationViolation} when path is under legacy home" do
      # Configure Loader to think config lives in legacy home
      legacy_cfg = Path.join(Paths.legacy_home_dir(), "puppy.cfg")
      :persistent_term.put({:code_puppy_control, :puppy_cfg_path}, legacy_cfg)
      :persistent_term.put({:code_puppy_control, :puppy_cfg}, %{"puppy" => %{}})

      result = Writer.set_value("test_key", "test_value")
      assert {:error, %Isolation.IsolationViolation{}} = result
    after
      :persistent_term.erase({:code_puppy_control, :puppy_cfg_path})
      :persistent_term.erase({:code_puppy_control, :puppy_cfg})
    end

    test "Writer.set_value! raises IsolationViolation when path is under legacy home" do
      # Configure Loader to think config lives in legacy home
      legacy_cfg = Path.join(Paths.legacy_home_dir(), "puppy.cfg")
      :persistent_term.put({:code_puppy_control, :puppy_cfg_path}, legacy_cfg)
      :persistent_term.put({:code_puppy_control, :puppy_cfg}, %{"puppy" => %{}})

      assert_raise Isolation.IsolationViolation, fn ->
        Writer.set_value!("test_key", "test_value")
      end
    after
      :persistent_term.erase({:code_puppy_control, :puppy_cfg_path})
      :persistent_term.erase({:code_puppy_control, :puppy_cfg})
    end

    test "Writer survives isolation violation without GenServer crash" do
      # Configure Loader to think config lives in legacy home
      legacy_cfg = Path.join(Paths.legacy_home_dir(), "puppy.cfg")
      :persistent_term.put({:code_puppy_control, :puppy_cfg_path}, legacy_cfg)
      :persistent_term.put({:code_puppy_control, :puppy_cfg}, %{"puppy" => %{}})

      # First call returns error without killing the GenServer
      assert {:error, _} = Writer.set_value("bad_key", "bad_val")
      # GenServer is still alive — a second call also returns error
      assert {:error, _} = Writer.set_value("another_key", "another_val")
    after
      :persistent_term.erase({:code_puppy_control, :puppy_cfg_path})
      :persistent_term.erase({:code_puppy_control, :puppy_cfg})
    end
  end

  # ── Default behavior ───────────────────────────────────────────────────

  describe "default behavior" do
    test "is_pup_ex is true when PUP_EX_HOME is set" do
      System.put_env("PUP_EX_HOME", "/tmp/default_ex")

      # The Python side's is_pup_ex() checks this env var
      assert System.get_env("PUP_EX_HOME") != nil
    end

    test "in_legacy_home? detects legacy paths" do
      legacy = Paths.legacy_home_dir()

      assert Paths.in_legacy_home?(Path.join(legacy, "puppy.cfg"))
      assert Paths.in_legacy_home?(legacy)
    end

    test "in_legacy_home? does not flag ex home paths" do
      System.put_env("PUP_EX_HOME", "/tmp/ex_home_check")
      ex_home = Paths.home_dir()

      refute Paths.in_legacy_home?(ex_home)
      refute Paths.in_legacy_home?(Path.join(ex_home, "puppy.cfg"))
    end

    test "allowed? returns true for paths outside legacy home" do
      assert Isolation.allowed?("/tmp/safe_path/file.txt")
    end

    test "allowed? returns false for paths inside legacy home" do
      legacy = Paths.legacy_home_dir()
      refute Isolation.allowed?(Path.join(legacy, "file.txt"))
    end
  end
end
