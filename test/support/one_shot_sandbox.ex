defmodule CodePuppyControl.TestSupport.OneShotSandbox do
  @moduledoc """
  Shared session-storage sandbox for one-shot CLI tests.

  Redirects `SessionStorage` writes to a fully temporary directory
  under `System.tmp_dir!/0`.  **Never touches real `~/.code_puppy_ex/`.**

  ## Strategy

  `SessionStorage.validate_storage_dir!/1` enforces that the session
  dir must be under `Path.expand("~/.code_puppy_ex")`.  Since
  `Path.expand("~")` reads from `:init.get_argument(:home)` (cached at
  BEAM VM startup), overriding `HOME` env var has no effect on it.

  Instead, we set `PUP_TEST_SESSION_ROOT` — a test-only env var that
  `validate_storage_dir!/1` accepts as an allowed prefix ONLY when the
  `:allow_test_session_root` Application env is true (set in test.exs).
  Combined with `PUP_SESSION_DIR` pointing into our temp dir, async saves
  write successfully to the sandbox and never touch the real
  `~/.code_puppy_ex/`.

  ## Usage

  Call from within a test `setup` callback (where `ExUnit.Callbacks.on_exit/1`
  is available):

      setup do
        OneShotSandbox.setup_sandbox(context)
        # ... other setup ...
      end

  The setup function calls `ExUnit.Callbacks.on_exit/1` internally
  for deterministic cleanup including async save draining and env
  var restoration.

  Refs: code_puppy-dku
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets up a fully temporary session-storage sandbox.

  Call from a `setup` callback.  Returns `{:ok, sandbox_dir: path}`
  where `sandbox_dir` is the temporary `.code_puppy_ex/sessions`
  directory.  Registers `on_exit` for deterministic cleanup.
  """
  @spec setup_sandbox(map()) :: {:ok, [{:sandbox_dir, String.t()}]}
  def setup_sandbox(_context) do
    uniq = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

    # Temp sandbox — never touches real ~/.code_puppy_ex
    tmp_root = Path.join(System.tmp_dir!(), "pup_oneshot_#{uniq}")
    sandbox_ex = Path.join(tmp_root, ".code_puppy_ex")
    sandbox_sessions = Path.join(sandbox_ex, "sessions")
    File.mkdir_p!(sandbox_sessions)

    # Snapshot current env before overriding
    prev_test_root = System.get_env("PUP_TEST_SESSION_ROOT")
    prev_session_dir = System.get_env("PUP_SESSION_DIR")

    prev_allow_test_root =
      Application.get_env(:code_puppy_control, :allow_test_session_root, false)

    # PUP_TEST_SESSION_ROOT: test-only root accepted by
    # validate_storage_dir!/1 as an alternative to ~/.code_puppy_ex.
    # Requires :allow_test_session_root Application env (set in test.exs).
    # (code_puppy-dku)
    System.put_env("PUP_TEST_SESSION_ROOT", sandbox_ex)

    # PUP_SESSION_DIR: explicit session dir for SessionStorage.base_dir/0
    System.put_env("PUP_SESSION_DIR", sandbox_sessions)

    # on_exit runs in LIFO order relative to other on_exit callbacks.
    # Since this is typically registered first (before mock-LLM cleanup),
    # it runs LAST — env vars stay set during test-specific cleanup.
    on_exit(fn ->
      # 1. Drain fire-and-forget async saves before touching env or dirs.
      #    save_session_async/3 uses Task.start/1 (unsupervised), so we
      #    poll briefly rather than tracking pids.
      drain_async_saves()

      # 2. Restore env vars deterministically
      restore_env("PUP_TEST_SESSION_ROOT", prev_test_root)
      restore_env("PUP_SESSION_DIR", prev_session_dir)

      # 3a. Restore :allow_test_session_root Application env
      #     (normally always true in test, but preserve whatever was there)
      restore_app_env(:code_puppy_control, :allow_test_session_root, prev_allow_test_root)

      # 3. Clean up sandbox dir (tolerate concurrent writes via rm_rf)
      {:ok, _} = File.rm_rf(tmp_root)
    end)

    {:ok, sandbox_dir: sandbox_sessions}
  end

  @doc """
  Drains pending `save_session_async/3` Tasks.

  `save_session_async/3` uses `Task.start/1` (fire-and-forget, unsupervised).
  We wait briefly for the Task to complete before restoring env vars or
  removing directories.  Without this drain, async Tasks may:
    - Write to a deleted directory
    - Read stale PUP_SESSION_DIR after env restoration
    - Crash on File.mkdir_p during teardown
  """
  @spec drain_async_saves() :: :ok
  def drain_async_saves do
    Process.sleep(200)
  end

  @doc """
  Restores an env var to its previous value (or deletes if it was unset).
  """
  @spec restore_env(String.t(), String.t() | nil) :: :ok
  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  @doc """
  Restores an Application env key to its previous value (or deletes if nil).
  """
  @spec restore_app_env(atom(), atom(), term()) :: :ok
  def restore_app_env(app, key, nil), do: Application.delete_env(app, key)
  def restore_app_env(app, key, value), do: Application.put_env(app, key, value)
end
