defmodule CodePuppyControl.Tools.FileModifications.FileLock do
  @moduledoc """
  Per-file locking for serializing concurrent mutations.

  Different files run concurrently; the same file (by realpath) is serialized.
  Uses `:global.trans/3` for lock acquisition — no Agent state to leak.

  ## Design

  - Uses `:global.trans/3` for distributed lock semantics in a cluster
  - Locks are per-realpath to handle symlinks correctly
  - No Agent process — `:global` handles all synchronization

  ## Usage

      FileLock.with_lock("/path/to/file.py", fn ->
        SafeWrite.safe_write("/path/to/file.py", content)
      end)
  """

  require Logger

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Execute a function while holding a lock on the given file path.

  Serializes concurrent access to the same file (by realpath).
  Different files run concurrently.

  Returns whatever the function returns. If the function raises,
  returns `{:error, exception}`.

  ## Examples

      iex> FileLock.with_lock("/tmp/test.txt", fn -> {:ok, :done} end)
      {:ok, :done}
  """
  @spec with_lock(Path.t(), (-> result)) :: result when result: var
  def with_lock(file_path, fun) when is_binary(file_path) and is_function(fun, 0) do
    key = resolve_key(file_path)
    lock_id = {__MODULE__, key}

    try do
      :global.trans(lock_id, fn ->
        try do
          fun.()
        rescue
          e -> {:error, e}
        end
      end)
    catch
      :exit, reason ->
        {:error, {:lock_timeout, reason}}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp resolve_key(file_path) do
    expanded = Path.expand(file_path)

    case File.stat(expanded) do
      {:ok, _} -> expanded
      {:error, _} -> expanded
    end
  end
end
