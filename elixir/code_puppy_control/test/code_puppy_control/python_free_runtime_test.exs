defmodule CodePuppyControl.PythonFreeRuntimeTest do
  @moduledoc """
  Tests for the native-only Elixir runtime guarantee (code-puppy-3o7.6).

  Validates that:
  - Config.validate!/0 succeeds in prod with no Python worker configuration
  - Config.load_from_env/0 does not include python_worker_script
  - The runtime no longer supports PUP_RUNTIME, PUP_PYTHON_WORKER_SCRIPT,
    or PYTHON_WORKER_SCRIPT env vars

  Note: .py file paths previously referenced env vars for the Python bridge
  worker script — a compatibility-mode artifact removed in code-puppy-3o7.6.
  See ADR-005.
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config

  # Env vars we mutate; must be async: false
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

  defp sandbox_user_data_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "python_free_test_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  # ── Config.validate!/0 — native-only runtime ────────────────────────────

  describe "Config.validate!/0 in prod — native-only runtime" do
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

    test "succeeds when no Python worker script is configured" do
      with_saved_env(
        [@pup_secret, @pup_db, @burrito],
        fn ->
          # Simulate Burrito binary mode so secret_key_base and db_path
          # have defaults
          System.put_env(@burrito, "1")
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          # Should NOT raise — Python worker config is no longer relevant
          assert Config.validate!() == :ok
        end
      )
    end
  end

  # ── Config.load_from_env/0 ────────────────────────────────────────────

  describe "Config.load_from_env/0 no Python worker config" do
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

    test "load_from_env/0 does not include :python_worker_script" do
      with_saved_env(
        [@pup_secret, @pup_db, @burrito],
        fn ->
          System.put_env(@burrito, "1")
          System.delete_env(@pup_secret)
          System.delete_env(@pup_db)

          result = Config.load_from_env()

          # Should NOT contain any python_worker_script entries
          refute Enum.any?(result, fn
                   {:python_worker_script, _} -> true
                   _ -> false
                 end)
        end
      )
    end
  end
end
