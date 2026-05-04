defmodule CodePuppyControl.PythonFreeRuntimeTest do
  @moduledoc """
  Tests for the Python-optional runtime guarantee (code-puppy-4ry).

  Validates that:
  - Default Elixir-first prod startup does NOT require PUP_PYTHON_WORKER_SCRIPT
  - Config.validate!/0 succeeds in prod with no Python worker script when
    PUP_RUNTIME is unset or set to elixir/auto
  - Config.validate!/0 still fails with a clear message when PUP_RUNTIME=python
    and Python worker script is missing
  - Config.python_worker_script/0 returns nil in prod when unset, and returns
    the configured value when set
  - PythonWorker.Port.init/1 returns clear error tuples when python3 is
    unavailable or script path is not configured
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config

  # Env vars we mutate; must be async: false
  @pup_runtime "PUP_RUNTIME"
  @pup_python_worker "PUP_PYTHON_WORKER_SCRIPT"
  @legacy_python_worker "PYTHON_WORKER_SCRIPT"
  @pup_secret "PUP_SECRET_KEY_BASE"
  @pup_db "PUP_DATABASE_PATH"
  @burrito "__BURRITO"

  # ── Helpers ────────────────────────────────────────────────────────────

  defp save_env(vars) do
    for var <- vars, into: %{} do
      {var, System.get_env(var)}
    end
  end

  defp restore_env(saved) do
    for {var, val} <- saved do
      case val do
        nil -> System.delete_env(var)
        v -> System.put_env(var, v)
      end
    end
  end

  defp with_saved_env(vars, fun) do
    saved = save_env(vars)

    try do
      fun.()
    after
      restore_env(saved)
    end
  end

  defp with_app_env(key, fun) do
    original = Application.get_env(:code_puppy_control, key)

    try do
      fun.()
    after
      case original do
        nil -> Application.delete_env(:code_puppy_control, key)
        _ -> Application.put_env(:code_puppy_control, key, original)
      end
    end
  end

  defp sandbox_user_data_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "python_free_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  # ── Config.python_worker_script/0 ─────────────────────────────────────

  describe "Config.python_worker_script/0" do
    test "returns nil when no script is configured via app env or env vars" do
      with_app_env(:python_worker_script, fn ->
        Application.delete_env(:code_puppy_control, :python_worker_script)

        with_saved_env([@pup_python_worker, @legacy_python_worker], fn ->
          System.delete_env(@pup_python_worker)
          System.delete_env(@legacy_python_worker)

          assert Config.python_worker_script() == nil
        end)
      end)
    end

    test "returns value from Application env when set" do
      with_app_env(:python_worker_script, fn ->
        Application.put_env(:code_puppy_control, :python_worker_script, "/app/worker.py")

        with_saved_env([@pup_python_worker, @legacy_python_worker], fn ->
          System.delete_env(@pup_python_worker)
          System.delete_env(@legacy_python_worker)

          assert Config.python_worker_script() == "/app/worker.py"
        end)
      end)
    end

    test "returns value from PUP_PYTHON_WORKER_SCRIPT env var when set" do
      with_app_env(:python_worker_script, fn ->
        Application.delete_env(:code_puppy_control, :python_worker_script)

        with_saved_env([@pup_python_worker, @legacy_python_worker], fn ->
          System.put_env(@pup_python_worker, "/env/worker.py")
          System.delete_env(@legacy_python_worker)

          assert Config.python_worker_script() == "/env/worker.py"
        end)
      end)
    end

    test "returns value from legacy PYTHON_WORKER_SCRIPT env var (with deprecation warning)" do
      with_app_env(:python_worker_script, fn ->
        Application.delete_env(:code_puppy_control, :python_worker_script)

        with_saved_env([@pup_python_worker, @legacy_python_worker], fn ->
          System.delete_env(@pup_python_worker)
          System.put_env(@legacy_python_worker, "/legacy/worker.py")

          # Should still return the legacy value
          assert Config.python_worker_script() == "/legacy/worker.py"
        end)
      end)
    end

    test "prefers app env over env vars" do
      with_app_env(:python_worker_script, fn ->
        Application.put_env(:code_puppy_control, :python_worker_script, "/app/first.py")

        with_saved_env([@pup_python_worker, @legacy_python_worker], fn ->
          System.put_env(@pup_python_worker, "/env/second.py")

          assert Config.python_worker_script() == "/app/first.py"
        end)
      end)
    end
  end

  # ── Config.python_runtime?/0 ──────────────────────────────────────────

  describe "Config.python_runtime?/0" do
    test "returns true when PUP_RUNTIME=python" do
      with_saved_env([@pup_runtime], fn ->
        System.put_env(@pup_runtime, "python")
        assert Config.python_runtime?() == true
      end)
    end

    test "returns false when PUP_RUNTIME=elixir" do
      with_saved_env([@pup_runtime], fn ->
        System.put_env(@pup_runtime, "elixir")
        assert Config.python_runtime?() == false
      end)
    end

    test "returns false when PUP_RUNTIME=auto" do
      with_saved_env([@pup_runtime], fn ->
        System.put_env(@pup_runtime, "auto")
        assert Config.python_runtime?() == false
      end)
    end

    test "returns false when PUP_RUNTIME is unset" do
      with_saved_env([@pup_runtime], fn ->
        System.delete_env(@pup_runtime)
        assert Config.python_runtime?() == false
      end)
    end
  end

  # ── Config.validate!/0 — Elixir-first runtime ─────────────────────────

  describe "Config.validate!/0 in prod — Elixir-first runtime" do
    setup do
      tmp_dir = sandbox_user_data_dir()

      previous_override =
        Application.get_env(:code_puppy_control, :user_data_dir_override)

      Application.put_env(:code_puppy_control, :user_data_dir_override, tmp_dir)
      Application.put_env(:code_puppy_control, :env, :prod)

      on_exit(fn ->
        case previous_override do
          nil -> Application.delete_env(:code_puppy_control, :user_data_dir_override)
          prev -> Application.put_env(:code_puppy_control, :user_data_dir_override, prev)
        end

        Application.delete_env(:code_puppy_control, :env)
        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "succeeds when no Python worker script is configured and PUP_RUNTIME is unset" do
      with_saved_env(
        [@pup_runtime, @pup_python_worker, @legacy_python_worker, @pup_secret, @pup_db, @burrito],
        fn ->
          # Simulate Burrito binary mode so secret_key_base and db_path
          # have defaults
          System.put_env(@burrito, "1")
          System.delete_env(@pup_runtime)
          System.delete_env(@pup_python_worker)
          System.delete_env(@legacy_python_worker)
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          with_app_env(:python_worker_script, fn ->
            Application.delete_env(:code_puppy_control, :python_worker_script)

            # Should NOT raise — Python worker script is optional in
            # Elixir-first runtime
            assert Config.validate!() == :ok
          end)
        end
      )
    end

    test "succeeds when PUP_RUNTIME=elixir and no Python worker script" do
      with_saved_env(
        [@pup_runtime, @pup_python_worker, @legacy_python_worker, @pup_secret, @pup_db, @burrito],
        fn ->
          System.put_env(@burrito, "1")
          System.put_env(@pup_runtime, "elixir")
          System.delete_env(@pup_python_worker)
          System.delete_env(@legacy_python_worker)
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          with_app_env(:python_worker_script, fn ->
            Application.delete_env(:code_puppy_control, :python_worker_script)

            assert Config.validate!() == :ok
          end)
        end
      )
    end

    test "succeeds when PUP_RUNTIME=auto and no Python worker script" do
      with_saved_env(
        [@pup_runtime, @pup_python_worker, @legacy_python_worker, @pup_secret, @pup_db, @burrito],
        fn ->
          System.put_env(@burrito, "1")
          System.put_env(@pup_runtime, "auto")
          System.delete_env(@pup_python_worker)
          System.delete_env(@legacy_python_worker)
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          with_app_env(:python_worker_script, fn ->
            Application.delete_env(:code_puppy_control, :python_worker_script)

            assert Config.validate!() == :ok
          end)
        end
      )
    end
  end

  # ── Config.validate!/0 — Python runtime requires script ────────────────

  describe "Config.validate!/0 in prod — Python runtime requires script" do
    setup do
      tmp_dir = sandbox_user_data_dir()

      previous_override =
        Application.get_env(:code_puppy_control, :user_data_dir_override)

      Application.put_env(:code_puppy_control, :user_data_dir_override, tmp_dir)
      Application.put_env(:code_puppy_control, :env, :prod)

      on_exit(fn ->
        case previous_override do
          nil -> Application.delete_env(:code_puppy_control, :user_data_dir_override)
          prev -> Application.put_env(:code_puppy_control, :user_data_dir_override, prev)
        end

        Application.delete_env(:code_puppy_control, :env)
        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "raises with clear message when PUP_RUNTIME=python and script is missing" do
      with_saved_env(
        [@pup_runtime, @pup_python_worker, @legacy_python_worker, @pup_secret, @pup_db, @burrito],
        fn ->
          System.put_env(@burrito, "1")
          System.put_env(@pup_runtime, "python")
          System.delete_env(@pup_python_worker)
          System.delete_env(@legacy_python_worker)
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          with_app_env(:python_worker_script, fn ->
            Application.delete_env(:code_puppy_control, :python_worker_script)

            assert_raise RuntimeError,
                         ~r/PUP_PYTHON_WORKER_SCRIPT.*missing.*PUP_RUNTIME=python/s,
                         fn ->
                           Config.validate!()
                         end
          end)
        end
      )
    end

    test "succeeds when PUP_RUNTIME=python and script is configured" do
      with_saved_env(
        [@pup_runtime, @pup_python_worker, @legacy_python_worker, @pup_secret, @pup_db, @burrito],
        fn ->
          System.put_env(@burrito, "1")
          System.put_env(@pup_runtime, "python")
          System.put_env(@pup_python_worker, "/path/to/worker.py")
          System.delete_env(@legacy_python_worker)
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          with_app_env(:python_worker_script, fn ->
            Application.delete_env(:code_puppy_control, :python_worker_script)

            assert Config.validate!() == :ok
          end)
        end
      )
    end
  end

  # ── PythonWorker.Port graceful error tuples ───────────────────────────

  describe "PythonWorker.Port init graceful errors" do
    test "returns {:stop, {:python_worker_script_not_configured, _}} when no script path" do
      # Clear all script path sources
      original_app = Application.get_env(:code_puppy_control, :python_worker_script)
      Application.delete_env(:code_puppy_control, :python_worker_script)

      saved = save_env([@pup_python_worker, @legacy_python_worker])
      System.delete_env(@pup_python_worker)
      System.delete_env(@legacy_python_worker)

      try do
        # Call init directly with minimal opts
        result =
          CodePuppyControl.PythonWorker.Port.init(
            run_id: "test-graceful-no-script",
            parent: self()
          )

        assert {:stop, {:python_worker_script_not_configured, msg}} = result
        assert is_binary(msg)
        assert msg =~ "not configured"
      after
        restore_env(saved)

        if original_app do
          Application.put_env(:code_puppy_control, :python_worker_script, original_app)
        else
          Application.delete_env(:code_puppy_control, :python_worker_script)
        end
      end
    end

    test "returns {:stop, {:python_unavailable, _}} when python3 is not on PATH" do
      # This test requires both:
      # 1. A script path to be configured (so we pass the script check)
      # 2. A sanitized PATH with no python3 (so we fail the exe check)
      #
      # We set a script path and temporarily set PATH to an empty dir.
      original_app = Application.get_env(:code_puppy_control, :python_worker_script)
      Application.put_env(:code_puppy_control, :python_worker_script, "/tmp/fake_worker.py")

      saved = save_env([@pup_python_worker, @legacy_python_worker, "PATH"])
      System.delete_env(@pup_python_worker)
      System.delete_env(@legacy_python_worker)

      # Create a temp dir with no python3 and set PATH to it
      empty_path =
        Path.join(System.tmp_dir!(), "no_python3_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(empty_path)
      System.put_env("PATH", empty_path)

      try do
        result =
          CodePuppyControl.PythonWorker.Port.init(
            run_id: "test-graceful-no-python3",
            parent: self()
          )

        assert {:stop, {:python_unavailable, msg}} = result
        assert is_binary(msg)
        assert msg =~ "python3"
        assert msg =~ "not found"
      after
        restore_env(saved)
        File.rm_rf(empty_path)

        if original_app do
          Application.put_env(:code_puppy_control, :python_worker_script, original_app)
        else
          Application.delete_env(:code_puppy_control, :python_worker_script)
        end
      end
    end
  end

  # ── Config.load_from_env/0 ────────────────────────────────────────────

  describe "Config.load_from_env/0 tolerates nil script path" do
    setup do
      tmp_dir = sandbox_user_data_dir()

      previous_override =
        Application.get_env(:code_puppy_control, :user_data_dir_override)

      Application.put_env(:code_puppy_control, :user_data_dir_override, tmp_dir)
      Application.put_env(:code_puppy_control, :env, :prod)

      on_exit(fn ->
        case previous_override do
          nil -> Application.delete_env(:code_puppy_control, :user_data_dir_override)
          prev -> Application.put_env(:code_puppy_control, :user_data_dir_override, prev)
        end

        Application.delete_env(:code_puppy_control, :env)
        File.rm_rf(tmp_dir)
      end)

      {:ok, tmp_dir: tmp_dir}
    end

    test "load_from_env/0 does not include :python_worker_script when nil" do
      with_saved_env(
        [@pup_runtime, @pup_python_worker, @legacy_python_worker, @pup_secret, @pup_db, @burrito],
        fn ->
          System.put_env(@burrito, "1")
          System.delete_env(@pup_runtime)
          System.delete_env(@pup_python_worker)
          System.delete_env(@legacy_python_worker)
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          with_app_env(:python_worker_script, fn ->
            Application.delete_env(:code_puppy_control, :python_worker_script)

            result = Config.load_from_env()

            # Should NOT contain {:python_worker_script, nil}
            refute Enum.any?(result, fn
                     {:python_worker_script, nil} -> true
                     {:python_worker_script, _} -> true
                     _ -> false
                   end)
          end)
        end
      )
    end

    test "load_from_env/0 includes :python_worker_script when configured" do
      with_saved_env(
        [@pup_runtime, @pup_python_worker, @legacy_python_worker, @pup_secret, @pup_db, @burrito],
        fn ->
          System.put_env(@burrito, "1")
          System.delete_env(@pup_runtime)
          System.put_env(@pup_python_worker, "/path/to/worker.py")
          System.delete_env(@legacy_python_worker)
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          with_app_env(:python_worker_script, fn ->
            Application.delete_env(:code_puppy_control, :python_worker_script)

            result = Config.load_from_env()

            # Should contain {:python_worker_script, "/path/to/worker.py"}
            assert {:python_worker_script, "/path/to/worker.py"} in result
          end)
        end
      )
    end
  end
end
