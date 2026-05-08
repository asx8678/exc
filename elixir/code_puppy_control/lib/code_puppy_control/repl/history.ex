defmodule CodePuppyControl.REPL.History do
  @moduledoc """
  In-memory command history for the REPL, persisted to disk.

  GenServer that maintains a most-recent-first list of input entries,
  capped at `@max_entries`. Supports navigation (previous/next),
  prefix search, and file persistence via `Config.Paths`.

  ## Storage

  - In-memory: list of strings, newest first
  - On disk: `~/.code_puppy_ex/history` (one entry per line)

  ## Usage

      History.add("explain this module")
      History.previous()   #=> "explain this module"
      History.search("exp") #=> ["explain this module"]
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Config.Paths

  @max_entries 1000
  @history_file "history"

  # ── State ──────────────────────────────────────────────────────────────────

  defstruct entries: [], cursor: 0

  @type t :: %__MODULE__{
          entries: [String.t()],
          cursor: non_neg_integer()
        }

  # ── Client API ─────────────────────────────────────────────────────────────

  @doc "Starts the History GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Adds an entry to history. Duplicates of the most recent entry are ignored."
  @spec add(String.t()) :: :ok
  def add(entry) when is_binary(entry) do
    GenServer.cast(__MODULE__, {:add, entry})
  end

  @doc "Returns the previous (older) entry relative to the current cursor, or `nil`."
  @spec previous() :: String.t() | nil
  def previous do
    GenServer.call(__MODULE__, :previous)
  end

  @doc "Returns the next (newer) entry relative to the current cursor, or `nil`."
  @spec next() :: String.t() | nil
  def next do
    GenServer.call(__MODULE__, :next)
  end

  @doc "Returns all entries matching the given prefix, newest first."
  @spec search(String.t()) :: [String.t()]
  def search(prefix) when is_binary(prefix) do
    GenServer.call(__MODULE__, {:search, prefix})
  end

  @doc "Returns all entries, newest first."
  @spec all() :: [String.t()]
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Resets the navigation cursor to 0 (most recent)."
  @spec reset_cursor() :: :ok
  def reset_cursor do
    GenServer.cast(__MODULE__, :reset_cursor)
  end

  @doc "Persists the current history to disk."
  @spec save() :: :ok
  def save do
    GenServer.cast(__MODULE__, :save)
  end

  @doc "Loads history from disk, replacing in-memory entries."
  @spec load() :: :ok
  def load do
    GenServer.cast(__MODULE__, :load)
  end

  @doc "Sync version of save — blocks until written to disk."
  @spec save_sync() :: :ok | {:error, term()}
  def save_sync do
    GenServer.call(__MODULE__, :save_sync)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %__MODULE__{entries: [], cursor: 0}

    case read_history_file() do
      {:ok, entries} ->
        {:ok, %{state | entries: entries}}

      {:error, reason} ->
        Logger.debug("History: no saved history (#{inspect(reason)})")
        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:add, entry}, state) do
    # Skip blank or duplicate-of-most-recent
    new_entries =
      if entry == "" or (state.entries != [] and hd(state.entries) == entry) do
        state.entries
      else
        [entry | state.entries] |> Enum.take(@max_entries)
      end

    {:noreply, %{state | entries: new_entries, cursor: 0}}
  end

  def handle_cast(:reset_cursor, state) do
    {:noreply, %{state | cursor: 0}}
  end

  def handle_cast(:save, state) do
    write_history_file(state.entries)
    {:noreply, state}
  end

  def handle_cast(:load, state) do
    case read_history_file() do
      {:ok, entries} ->
        {:noreply, %{state | entries: entries, cursor: 0}}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:previous, _from, state) do
    # Cursor 0 = before first navigation, 1 = most recent, etc.
    next_cursor = state.cursor + 1

    case Enum.at(state.entries, next_cursor - 1) do
      nil ->
        # Already at oldest — stay put
        {:reply, nil, state}

      entry ->
        {:reply, entry, %{state | cursor: next_cursor}}
    end
  end

  def handle_call(:next, _from, state) do
    if state.cursor <= 1 do
      # At or before most recent — reset
      {:reply, nil, %{state | cursor: 0}}
    else
      next_cursor = state.cursor - 1
      entry = Enum.at(state.entries, next_cursor - 1)
      {:reply, entry, %{state | cursor: next_cursor}}
    end
  end

  def handle_call({:search, prefix}, _from, state) do
    results =
      Enum.filter(state.entries, fn entry ->
        String.starts_with?(entry, prefix)
      end)

    {:reply, results, state}
  end

  def handle_call(:all, _from, state) do
    {:reply, state.entries, state}
  end

  def handle_call(:save_sync, _from, state) do
    result = write_history_file(state.entries)
    {:reply, result, state}
  end

  # ── File I/O ───────────────────────────────────────────────────────────────

  @doc "Returns the path to the history file on disk."
  @spec history_path() :: String.t()
  def history_path do
    Path.join(Paths.home_dir(), @history_file)
  end

  defp read_history_file do
    path = history_path()

    case File.read(path) do
      {:ok, content} ->
        entries =
          content
          |> String.split("\n", trim: true)
          # Reverse so newest is last → we reverse on read to get newest-first
          |> Enum.reverse()

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_history_file(entries) do
    path = history_path()

    # Ensure parent directory exists
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    # Write oldest-first (one per line) so append makes sense
    content =
      entries
      |> Enum.reverse()
      |> Enum.join("\n")

    case File.write(path, content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("History: failed to save (#{inspect(reason)})")
        :ok
    end
  end
end
