defmodule CodePuppyControl.Config.FirstRunTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{FirstRun, Isolation, Paths}

  @home Path.expand("~")

  setup do
    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")
      Process.delete(:isolation_sandbox)
    end)

    :ok
  end

  # ── initialize/0 ────────────────────────────────────────────────────────

  describe "initialize/0" do
    test "returns {:ok, :fresh_install} when Elixir home is missing" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)

      # Ensure the temp home doesn't exist
      File.rm_rf(tmp_home)
      refute File.dir?(tmp_home)

      # Use sandbox so safe_write! for the .initialized marker succeeds
      Isolation.with_sandbox([tmp_home], fn ->
        assert {:ok, :fresh_install} = FirstRun.initialize()
      end)

      # Clean up
      File.rm_rf(tmp_home)
    end

    test "creates the directory tree on fresh install" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.rm_rf(tmp_home)

      Isolation.with_sandbox([tmp_home], fn ->
        assert {:ok, :fresh_install} = FirstRun.initialize()
      end)

      # Verify key directories were created
      assert File.dir?(Paths.config_dir())
      assert File.dir?(Paths.data_dir())
      assert File.dir?(Paths.cache_dir())
      assert File.dir?(Paths.state_dir())

      File.rm_rf(tmp_home)
    end

    test "does NOT touch legacy home" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.rm_rf(tmp_home)

      # Create a marker file in legacy home to prove we don't touch it
      legacy_marker =
        Path.join(
          @home,
          ".code_puppy/_first_run_test_marker_#{:erlang.unique_integer([:positive])}"
        )

      legacy_marker_dir = Path.dirname(legacy_marker)

      File.mkdir_p!(legacy_marker_dir)
      File.write!(legacy_marker, "untouched")

      Isolation.with_sandbox([tmp_home], fn ->
        assert {:ok, _} = FirstRun.initialize()
      end)

      # Legacy marker should still be untouched
      assert File.read!(legacy_marker) == "untouched"

      File.rm(legacy_marker)
      File.rm_rf(tmp_home)
    end

    test "returns {:ok, :existing} on subsequent calls when home is present" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.rm_rf(tmp_home)

      # First run
      Isolation.with_sandbox([tmp_home], fn ->
        assert {:ok, :fresh_install} = FirstRun.initialize()
      end)

      # Second run — home now exists
      assert {:ok, :existing} = FirstRun.initialize()

      File.rm_rf(tmp_home)
    end

    test "emits guidance banner to stderr only when legacy home present AND fresh install" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.rm_rf(tmp_home)

      # Ensure legacy home exists for this test
      legacy_dir = Path.join(@home, ".code_puppy")
      legacy_existed = File.dir?(legacy_dir)

      if not legacy_existed do
        File.mkdir_p!(legacy_dir)
      end

      try do
        output =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            Isolation.with_sandbox([tmp_home], fn ->
              assert {:ok, :fresh_install} = FirstRun.initialize()
            end)
          end)

        assert output =~ "Welcome to pup-ex"
        assert output =~ "mix pup_ex.import"
      after
        if not legacy_existed do
          # Only remove if we created it — but .code_puppy is the real Python
          # pup home so we won't delete it. It's fine to leave the dir.
          :ok
        end
      end

      File.rm_rf(tmp_home)
    end

    test "guidance banner suppressed when .initialized marker file exists" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.rm_rf(tmp_home)

      # First run — creates home and writes marker
      Isolation.with_sandbox([tmp_home], fn ->
        assert {:ok, :fresh_install} = FirstRun.initialize()
      end)

      # Now the home exists with the .initialized marker.
      # Calling initialize again should NOT emit the banner
      # because it returns {:ok, :existing} immediately.
      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, :existing} = FirstRun.initialize()
        end)

      refute output =~ "Welcome to pup-ex"

      File.rm_rf(tmp_home)
    end

    test "returns {:error, _} when directory creation fails" do
      # Point PUP_EX_HOME at a path that cannot be created
      # (e.g., under /proc on Linux, or a deeply nested impossible path)
      # On macOS, trying to create under a non-existent parent that we can't
      # mkdir is tricky. Instead, test with a path that's a file, not a dir.
      tmp_home = Path.join(System.tmp_dir!(), "fr_file_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)

      # Create a FILE at that path (so mkdir_p will fail)
      File.write!(tmp_home, "i am a file, not a directory")

      try do
        result = FirstRun.initialize()
        # Should return error since we can't create dirs under a file
        assert match?({:error, _}, result)
      after
        File.rm(tmp_home)
      end
    end
  end

  # ── Predicate tests ────────────────────────────────────────────────────

  describe "elixir_home_present?/0" do
    test "returns true when Elixir home directory exists" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.mkdir_p!(tmp_home)

      assert FirstRun.elixir_home_present?()

      File.rm_rf(tmp_home)
    end

    test "returns false when Elixir home directory does not exist" do
      tmp_home =
        Path.join(System.tmp_dir!(), "fr_nonexistent_#{:erlang.unique_integer([:positive])}")

      System.put_env("PUP_EX_HOME", tmp_home)
      File.rm_rf(tmp_home)

      refute FirstRun.elixir_home_present?()
    end
  end

  describe "first_run?/0" do
    test "returns true when Elixir home is missing" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_missing_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.rm_rf(tmp_home)

      assert FirstRun.first_run?()
    end

    test "returns false when Elixir home exists" do
      tmp_home = Path.join(System.tmp_dir!(), "fr_exists_#{:erlang.unique_integer([:positive])}")
      System.put_env("PUP_EX_HOME", tmp_home)
      File.mkdir_p!(tmp_home)

      refute FirstRun.first_run?()

      File.rm_rf(tmp_home)
    end
  end
end
