defmodule CodePuppyControl.CLI.SlashCommands.Commands.AddModelPersistence do
  @moduledoc """
  Persistence layer for /add_model command.

  Handles reading and writing extra_models.json, including atomic writes,
  directory creation, and concurrency safety. Separated from the command
  module for testability.

  ## Concurrency

  Uses a dedicated GenServer (`__MODULE__.LockKeeper`) to serialise
  read-modify-write cycles, eliminating lost-update / read-modify-write
  races when two `/add_model` calls overlap.

  ## Isolation

  All filesystem writes route through `Config.Isolation.safe_*` wrappers
  per ADR-003.  Temp files are placed adjacent to the target file so that
  `File.rename/2` never crosses filesystem boundaries (avoids `:exdev`),
  and the same `tmp_path` is reused in error-handling to prevent orphan
  cleanup misses.
  """

  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Config.Paths

  # ── Lock Keeper GenServer ─────────────────────────────────────────────

  defmodule LockKeeper do
    @moduledoc false
    # Simple serialising GenServer.  Only one persist operation runs at a
    # time, preventing read-modify-write races on extra_models.json.
    use GenServer

    def start_link(opts \\ []) do
      name = Keyword.get(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    @impl true
    def init(_opts), do: {:ok, %{}}

    @doc "Execute `fun` under the serialisation lock. Returns the fun's result."
    @spec with_lock((-> result)) :: result when result: var
    def with_lock(fun) do
      GenServer.call(__MODULE__, {:run, fun}, 30_000)
    catch
      :exit, {:noproc, _} -> {:error, :not_running}
      :exit, {:shutdown, _} -> {:error, :not_running}
      :exit, {:timeout, _} -> {:error, :timeout}
    end

    @impl true
    def handle_call({:run, fun}, _from, state) do
      {:reply, fun.(), state}
    end
  end

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Persist a model config into extra_models.json.

  - Creates the file if it doesn't exist.
  - Merges into the existing dict (not a list).
  - Atomic write via temp file + rename.
  - Serialised through LockKeeper to prevent lost-update races.
  - All writes routed through Isolation-safe wrappers.

  Returns `{:ok, model_key}` on success.
  Returns `{:error, :already_exists}` if the key is already present.
  Returns `{:error, reason}` on other failures.
  """
  @spec persist(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def persist(model_key, config) when is_binary(model_key) and is_map(config) do
    lock_keeper().with_lock(fn ->
      path = Paths.extra_models_file()

      with {:ok, existing} <- read_existing(path),
           :ok <- check_duplicate(existing, model_key),
           updated <- Map.put(existing, model_key, config),
           {:ok, _} <- atomic_write_json(path, updated) do
        {:ok, model_key}
      end
    end)
  end

  @doc """
  Read the current extra_models.json as a map.
  Returns an empty map if the file doesn't exist.
  Returns an error if the file is not a valid JSON object.
  """
  @spec read_existing(String.t()) :: {:ok, map()} | {:error, term()}
  def read_existing(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} when is_map(data) ->
            {:ok, data}

          {:ok, _other} ->
            {:error, "extra_models.json must be a dictionary, not a list"}

          {:error, reason} ->
            {:error, "Error parsing extra_models.json: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, "Error reading extra_models.json: #{inspect(reason)}"}
    end
  end

  @doc """
  Check if a model_key already exists in the config map.
  """
  @spec check_duplicate(map(), String.t()) :: :ok | {:error, :already_exists}
  def check_duplicate(existing, model_key) do
    if Map.has_key?(existing, model_key) do
      {:error, :already_exists}
    else
      :ok
    end
  end

  @doc """
  Write a JSON map to a file atomically (temp file + rename).
  Creates parent directories if needed.  Routes all writes through
  Isolation-safe wrappers.

  The temp file is created in the same directory as the target so that
  `File.rename/2` never fails with `:exdev` (cross-device link).

  Exception-safe: `File.Error`, `Jason.EncodeError`, and
  `IsolationViolation` are all caught and converted to `{:error, _}`
  tuples.  The `File.rename/2` result is checked explicitly so that a
  rename failure returns `{:error, _}` instead of raising `MatchError`.
  The temp file is cleaned up in every error path (rename failure or
  rescued exception), preventing orphan temp files even when an
  unexpected exception crashes the LockKeeper call.
  """
  @spec atomic_write_json(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def atomic_write_json(path, data) do
    dir = Path.dirname(path)
    tmp_path = make_temp_path(path)

    try do
      :ok = safe_mkdir_p(dir)
      json = Jason.encode!(data, pretty: true)
      :ok = safe_write(tmp_path, json)

      case File.rename(tmp_path, path) do
        :ok ->
          {:ok, path}

        {:error, rename_reason} ->
          # Rename failed — clean up the orphaned temp file
          safe_remove_tmp(tmp_path)
          {:error, "rename failed: #{inspect(rename_reason)}"}
      end
    rescue
      e in File.Error ->
        safe_remove_tmp(tmp_path)
        {:error, Exception.message(e)}

      e in Jason.EncodeError ->
        safe_remove_tmp(tmp_path)
        {:error, Exception.message(e)}

      e in CodePuppyControl.Config.Isolation.IsolationViolation ->
        safe_remove_tmp(tmp_path)
        {:error, Exception.message(e)}
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  # Generates a unique temp path *adjacent to the target file* so that
  # File.rename never crosses filesystem boundaries (no :exdev risk).
  defp make_temp_path(target_path) do
    dir = Path.dirname(target_path)
    uniq = :erlang.unique_integer([:positive])
    Path.join(dir, ".cp_extra_models_#{uniq}.tmp")
  end

  # Isolation-safe directory creation.  Raises on failure so the outer
  # try/rescue in atomic_write_json/2 can catch and convert to {:error, _}.
  defp safe_mkdir_p(dir) do
    Isolation.safe_mkdir_p!(dir)
    :ok
  end

  # Isolation-safe file write.  Raises on failure so the outer
  # try/rescue in atomic_write_json/2 can catch and convert to {:error, _}.
  defp safe_write(path, content) do
    Isolation.safe_write!(path, content)
    :ok
  end

  # Best-effort removal of a temp file.  Never raises — if the file
  # doesn't exist or the remove fails, we silently ignore it since we're
  # already in an error path and the LockKeeper call must not crash.
  defp safe_remove_tmp(tmp_path) do
    File.rm(tmp_path)
    :ok
  rescue
    _ -> :ok
  end

  # Resolves the LockKeeper module (overridable in tests).
  defp lock_keeper, do: __MODULE__.LockKeeper
end
