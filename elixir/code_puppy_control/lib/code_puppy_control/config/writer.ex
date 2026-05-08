defmodule CodePuppyControl.Config.Writer do
  @moduledoc """
  Atomic write-back for `puppy.cfg`.

  Writes are performed via a temporary file in the same directory as the
  target, then renamed over the original. On Unix this is a single atomic
  `mv(2)` — readers never see a half-written file.

  After each successful write, the loader cache is invalidated so the next
  read picks up fresh data.

  ## Usage

      # Set a single key
      Writer.set_value("model", "gpt-5")

      # Set multiple keys at once
      Writer.set_values(%{"model" => "gpt-5", "yolo_mode" => "true"})

      # Remove a key
      Writer.delete_value("old_key")

  ## Concurrency

  All write operations serialize through a single `GenServer` to prevent
  lost updates from concurrent writers. Reads remain lock-free via
  `:persistent_term`.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Config.{Isolation, Loader}

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Start the writer GenServer. Called by the supervision tree.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, [], name: name)
  end

  @doc """
  Set a single key in the default section and persist to disk.

  Returns `{:error, %IsolationViolation{}}` when ADR-003 blocks the write
  (target path is under the legacy home). The GenServer stays alive.
  """
  @spec set_value(String.t(), String.t()) :: :ok | {:error, Isolation.IsolationViolation.t()}
  def set_value(key, value) do
    GenServer.call(__MODULE__, {:set_value, key, value})
  end

  @doc """
  Bang variant of `set_value/2`. Raises `IsolationViolation` on ADR-003 denial.
  """
  @spec set_value!(String.t(), String.t()) :: :ok
  def set_value!(key, value) do
    case set_value(key, value) do
      :ok -> :ok
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Set multiple key-value pairs in the default section atomically.

  Returns `{:error, %IsolationViolation{}}` when ADR-003 blocks the write.
  """
  @spec set_values(%{String.t() => String.t()}) ::
          :ok | {:error, Isolation.IsolationViolation.t()}
  def set_values(kv_map) when is_map(kv_map) do
    GenServer.call(__MODULE__, {:set_values, kv_map})
  end

  @doc """
  Bang variant of `set_values/1`. Raises `IsolationViolation` on ADR-003 denial.
  """
  @spec set_values!(%{String.t() => String.t()}) :: :ok
  def set_values!(kv_map) do
    case set_values(kv_map) do
      :ok -> :ok
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Remove a key from the default section.

  Returns `{:error, %IsolationViolation{}}` when ADR-003 blocks the delete.
  """
  @spec delete_value(String.t()) :: :ok | {:error, Isolation.IsolationViolation.t()}
  def delete_value(key) do
    GenServer.call(__MODULE__, {:delete_value, key})
  end

  @doc """
  Bang variant of `delete_value/1`. Raises `IsolationViolation` on ADR-003 denial.
  """
  @spec delete_value!(String.t()) :: :ok
  def delete_value!(key) do
    case delete_value(key) do
      :ok -> :ok
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Write an entire config map to disk (used by migrations and bulk updates).

  Returns `{:error, %IsolationViolation{}}` when ADR-003 blocks the write.
  """
  @spec write_config(Loader.config()) :: :ok | {:error, Isolation.IsolationViolation.t()}
  def write_config(config) do
    GenServer.call(__MODULE__, {:write_config, config})
  end

  @doc """
  Bang variant of `write_config/1`. Raises `IsolationViolation` on ADR-003 denial.
  """
  @spec write_config!(Loader.config()) :: :ok
  def write_config!(config) do
    case write_config(config) do
      :ok -> :ok
      {:error, exception} -> raise exception
    end
  end

  @doc """
  Synchronous write: set a value without going through the GenServer.
  Useful during shutdown when the GenServer may not be available.

  **Warning**: not safe for concurrent callers — use only when you know
  there are no other writers.
  """
  @spec unsafe_set_value(String.t(), String.t()) ::
          :ok | {:error, Isolation.IsolationViolation.t()}
  def unsafe_set_value(key, value) do
    config = Loader.get_cached()
    section = Loader.default_section()
    section_map = Map.get(config, section, %{})
    updated = Map.put(config, section, Map.put(section_map, key, value))
    do_write(updated)
  end

  # ── GenServer Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:set_value, key, value}, _from, state) do
    config = Loader.get_cached()
    section = Loader.default_section()
    section_map = Map.get(config, section, %{})
    updated = Map.put(config, section, Map.put(section_map, key, value))
    {:reply, do_write(updated), state}
  end

  @impl true
  def handle_call({:set_values, kv_map}, _from, state) do
    config = Loader.get_cached()
    section = Loader.default_section()
    section_map = Map.get(config, section, %{})

    updated_section =
      Enum.reduce(kv_map, section_map, fn {k, v}, acc -> Map.put(acc, k, v) end)

    updated = Map.put(config, section, updated_section)
    {:reply, do_write(updated), state}
  end

  @impl true
  def handle_call({:delete_value, key}, _from, state) do
    config = Loader.get_cached()
    section = Loader.default_section()
    section_map = Map.get(config, section, %{})
    updated_section = Map.delete(section_map, key)
    updated = Map.put(config, section, updated_section)
    {:reply, do_write(updated), state}
  end

  @impl true
  def handle_call({:write_config, config}, _from, state) do
    {:reply, do_write(config), state}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @spec do_write(Loader.config()) :: :ok | {:error, Isolation.IsolationViolation.t()}
  defp do_write(config) do
    path = Loader.loaded_path()

    # ADR-003: Verify the write target is NOT under the legacy home.
    # Uses check_allowed/2 (non-raising) so the GenServer stays alive
    # on isolation violations. Bang API variants (set_value!, etc.)
    # re-raise at the caller level.
    case Isolation.check_allowed(path, :write) do
      :ok ->
        content = serialize(config)
        atomic_write(path, content)
        Loader.invalidate()
        :ok

      {:error, _} = err ->
        err
    end
  end

  @spec serialize(Loader.config()) :: String.t()
  defp serialize(config) do
    config
    |> Enum.sort_by(fn {section, _} -> section end)
    |> Enum.map_join("\n", fn {section, kv_map} ->
      section_header = "[#{section}]"

      pairs =
        kv_map
        |> Enum.sort_by(fn {k, _} -> k end)
        |> Enum.map_join("\n", fn {k, v} -> "#{k} = #{v}" end)

      "#{section_header}\n#{pairs}"
    end)
    |> then(&(&1 <> "\n"))
  end

  @spec atomic_write(String.t(), String.t()) :: :ok
  defp atomic_write(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    tmp_path = Path.join(dir, ".puppy.cfg.#{:erlang.unique_integer([:positive])}.tmp")

    case File.write(tmp_path, content, [:sync]) do
      :ok ->
        case File.rename(tmp_path, path) do
          :ok ->
            :ok

          {:error, reason} ->
            File.rm(tmp_path)
            Logger.error("Failed to rename #{tmp_path} -> #{path}: #{reason}")
            raise "Atomic write failed: rename error #{reason}"
        end

      {:error, reason} ->
        Logger.error("Failed to write temp file #{tmp_path}: #{reason}")
        raise "Atomic write failed: write error #{reason}"
    end
  end
end
