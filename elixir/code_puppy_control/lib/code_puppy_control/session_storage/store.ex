defmodule CodePuppyControl.SessionStorage.Store do
  @moduledoc """
  ETS-backed session cache with PubSub events and disk crash-survivability.

  Write path (crash-safe): SQLite → ETS → PubSub.
  Read path: ETS (O(1)) → SQLite (cache miss).
  Recovery: rebuilds ETS from SQLite on init; terminal sessions handed
  to `TerminalRecovery` for PTY recreation.

  ETS tables: `:session_store_ets` (sessions), `:session_terminal_ets` (terminals).
  PubSub topics: `"sessions:events"`, `"terminal:recovery"`.

  Replaces Python `session_storage_bridge.py` pattern with ETS + PubSub
  on top of the existing SQLite backend. (code_puppy-ctj.1)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Sessions
  alias CodePuppyControl.SessionStorage.StoreHelpers
  alias CodePuppyControl.SessionStorage.TerminalRecovery

  @pubsub CodePuppyControl.PubSub
  @sessions_topic "sessions:events"
  @terminal_topic "terminal:recovery"

  # ETS table names
  @session_table :session_store_ets
  @terminal_table :session_terminal_ets

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type session_name :: String.t()
  @type history :: [map()]
  @type compacted_hashes :: [String.t()]

  @type session_entry :: %{
          name: session_name(),
          history: history(),
          compacted_hashes: compacted_hashes(),
          total_tokens: non_neg_integer(),
          message_count: non_neg_integer(),
          auto_saved: boolean(),
          timestamp: String.t(),
          has_terminal: boolean(),
          terminal_meta: terminal_meta() | nil,
          updated_at: integer()
        }

  @type terminal_meta :: %{
          session_id: String.t(),
          cols: pos_integer(),
          rows: pos_integer(),
          shell: String.t() | nil,
          attached_at: integer()
        }

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the SessionStorage Store GenServer.

  ## Options

    * `:name` — registration name (default: `__MODULE__`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Saves a session with write-through: SQLite → ETS → PubSub.

  Crash-survivability: SQLite write must succeed before ETS/PubSub.
  Options: `:compacted_hashes`, `:total_tokens`, `:auto_saved`, `:timestamp`,
  `:has_terminal`, `:terminal_meta`.
  """
  @spec save_session(session_name(), history(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def save_session(name, history, opts \\ []) do
    GenServer.call(__MODULE__, {:save_session, name, history, opts})
  end

  @doc """
  Loads a session (cache-first: ETS → SQLite fallback).

  Returns `{:ok, %{history: list(), compacted_hashes: list()}}` or
  `{:error, reason}`.
  """
  @spec load_session(session_name()) ::
          {:ok, %{history: history(), compacted_hashes: compacted_hashes()}}
          | {:error, term()}
  def load_session(name) do
    # Fast path: ETS lookup (no GenServer call needed for reads)
    case :ets.lookup(@session_table, name) do
      [{^name, entry}] ->
        {:ok, %{history: entry.history, compacted_hashes: entry.compacted_hashes}}

      [] ->
        # Cache miss: read from SQLite, populate ETS
        case Sessions.load_session(name) do
          {:ok, data} ->
            entry = StoreHelpers.session_data_to_entry(name, data)
            :ets.insert(@session_table, {name, entry})
            {:ok, data}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Loads a session with full metadata (cache-first).

  Returns the full session entry map including terminal metadata.
  """
  @spec load_session_full(session_name()) ::
          {:ok, session_entry()} | {:error, term()}
  def load_session_full(name) do
    case :ets.lookup(@session_table, name) do
      [{^name, entry}] ->
        {:ok, entry}

      [] ->
        case Sessions.load_session_full(name) do
          {:ok, session} ->
            entry = StoreHelpers.chat_session_to_entry(session)
            :ets.insert(@session_table, {name, entry})
            {:ok, entry}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Deletes a session with write-through.

  1. Delete from SQLite (durable)
  2. Remove from ETS
  3. Remove terminal tracking if present
  4. Broadcast deletion via PubSub
  """
  @spec delete_session(session_name()) :: :ok | {:error, term()}
  def delete_session(name) do
    GenServer.call(__MODULE__, {:delete_session, name})
  end

  @doc """
  Lists all session names from ETS (no disk access needed after init).
  """
  @spec list_sessions() :: {:ok, [session_name()]}
  def list_sessions do
    names =
      @session_table
      |> :ets.match({:"$1", :_})
      |> List.flatten()
      |> Enum.sort()

    {:ok, names}
  end

  @doc """
  Lists sessions with metadata from ETS.
  """
  @spec list_sessions_with_metadata() :: {:ok, [session_entry()]}
  def list_sessions_with_metadata do
    entries =
      @session_table
      |> :ets.tab2list()
      |> Enum.map(fn {_name, entry} -> entry end)
      |> Enum.sort_by(& &1.timestamp, :desc)

    {:ok, entries}
  end

  @doc """
  Cleans up old sessions, keeping only the most recent N.

  Uses timestamp-based ordering from ETS metadata.
  """
  @spec cleanup_sessions(non_neg_integer()) :: {:ok, [session_name()]}
  def cleanup_sessions(max_sessions) do
    GenServer.call(__MODULE__, {:cleanup_sessions, max_sessions})
  end

  @doc """
  Checks if a session exists in ETS (fast, no disk access).
  """
  @spec session_exists?(session_name()) :: boolean()
  def session_exists?(name) do
    :ets.member(@session_table, name)
  end

  @doc """
  Returns the count of sessions from ETS.
  """
  @spec count_sessions() :: non_neg_integer()
  def count_sessions do
    :ets.info(@session_table, :size)
  end

  # ---------------------------------------------------------------------------
  # Terminal Session Tracking
  # ---------------------------------------------------------------------------

  @doc """
  Registers a terminal session for crash recovery.

  Records metadata (cols, rows, shell, attached_at) so TerminalRecovery
  can recreate the PTY on crash/restart. Durably persists to SQLite —
  terminal metadata survives node crashes.

  If no session row exists yet (common when TerminalChannel.join fires
  before any chat message has been saved), a minimal session row is
  created in SQLite and ETS so the terminal metadata is not silently
  lost.  A subsequent save_session call will overwrite this row with
  full history.  (code_puppy-ctj.1 fix)

  Returns `{:error, reason}` only if the SQLite write itself fails.
  """
  @spec register_terminal(session_name(), terminal_meta()) ::
          :ok | {:error, term()}
  def register_terminal(session_name, meta) do
    GenServer.call(__MODULE__, {:register_terminal, session_name, meta})
  end

  @doc """
  Unregisters a terminal session. Called on graceful close.

  Durably clears terminal metadata from SQLite. Returns
  `{:error, :session_not_found}` if the session does not exist.
  """
  @spec unregister_terminal(session_name()) ::
          :ok | {:error, :session_not_found | term()}
  def unregister_terminal(session_name) do
    GenServer.call(__MODULE__, {:unregister_terminal, session_name})
  end

  @doc """
  Lists all tracked terminal sessions (for crash recovery).
  """
  @spec list_terminal_sessions() :: [terminal_meta()]
  def list_terminal_sessions do
    @terminal_table
    |> :ets.tab2list()
    |> Enum.map(fn {_name, meta} -> meta end)
  end

  @doc """
  Returns the PubSub topic for session events.
  """
  @spec sessions_topic() :: String.t()
  def sessions_topic, do: @sessions_topic

  @doc """
  Returns the PubSub topic for terminal recovery events.
  """
  @spec terminal_topic() :: String.t()
  def terminal_topic, do: @terminal_topic

  @doc """
  Subscribes to session lifecycle events via PubSub.

  Events: `{:session_saved, name, meta}`, `{:session_deleted, name}`,
  `{:sessions_cleaned, deleted_names}`.
  """
  @spec subscribe_sessions() :: :ok | {:error, term()}
  def subscribe_sessions do
    Phoenix.PubSub.subscribe(@pubsub, @sessions_topic)
  end

  @doc """
  Subscribes to terminal recovery events via PubSub.

  Events: `{:terminal_recovered, id, meta}`, `{:terminal_recovery_failed, id, reason}`,
  `{:terminal_registered, id}`, `{:terminal_unregistered, id}`.
  """
  @spec subscribe_terminal() :: :ok | {:error, term()}
  def subscribe_terminal do
    Phoenix.PubSub.subscribe(@pubsub, @terminal_topic)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    # Create ETS tables (owner is this GenServer; tables survive as long as
    # the process lives and are automatically destroyed on termination)
    session_table =
      :ets.new(@session_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    terminal_table =
      :ets.new(@terminal_table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Recovery: rebuild ETS from SQLite
    recovered = recover_from_disk()

    # Identify sessions that had active terminals at crash time.
    # Terminal recovery is DEFERRED via :continue — PtyManager may not
    # be started yet since it appears later in the supervision tree.
    # (code_puppy-ctj.1 fix: recovery must run after PtyManager starts)
    terminal_count =
      @session_table
      |> :ets.tab2list()
      |> Enum.count(fn {_name, entry} -> entry.has_terminal end)

    Logger.info(
      "SessionStorage.Store initialized: #{recovered} sessions recovered, " <>
        "#{terminal_count} terminal sessions pending recovery (deferred)"
    )

    {:ok,
     %{
       session_table: session_table,
       terminal_table: terminal_table,
       opts: opts,
       pending_terminal_recovery: terminal_count > 0
     }, {:continue, :recover_terminals}}
  end

  @impl true
  def handle_call({:save_session, name, history, opts}, _from, state) do
    compacted_hashes = Keyword.get(opts, :compacted_hashes, [])
    total_tokens = Keyword.get(opts, :total_tokens, 0)
    auto_saved = Keyword.get(opts, :auto_saved, false)
    timestamp = Keyword.get(opts, :timestamp) || StoreHelpers.now_iso()

    # (code_puppy-ctj.1 fix) Preserve existing terminal metadata when opts
    # omit :has_terminal / :terminal_meta — previously defaulting to false/nil
    # would silently clear registered terminal recovery data.
    {has_terminal, terminal_meta, terminal_explicit?} =
      StoreHelpers.resolve_terminal_fields(name, opts, @session_table)

    # 1. Persist to SQLite (durable). Always pass resolved values so
    # Sessions.save_session/3 receives the correct terminal state.
    case Sessions.save_session(name, history,
           compacted_hashes: compacted_hashes,
           total_tokens: total_tokens,
           auto_saved: auto_saved,
           timestamp: timestamp,
           has_terminal: has_terminal,
           terminal_meta: terminal_meta
         ) do
      {:ok, session} ->
        # 2. Update ETS cache (only after durable write succeeds)
        entry =
          StoreHelpers.build_entry(
            name,
            history,
            compacted_hashes,
            total_tokens,
            auto_saved,
            timestamp,
            has_terminal,
            terminal_meta
          )

        :ets.insert(@session_table, {name, entry})

        # 3. Broadcast via PubSub
        Phoenix.PubSub.broadcast(
          @pubsub,
          @sessions_topic,
          {:session_saved, name, Map.drop(entry, [:history])}
        )

        # 4. Terminal ETS table consistency:
        #    - insert/update when has_terminal true + meta present
        #    - delete when caller explicitly clears has_terminal to false
        #    - preserve (no change) when opts omitted both fields
        cond do
          has_terminal && terminal_meta ->
            :ets.insert(@terminal_table, {name, terminal_meta})

          terminal_explicit? && !has_terminal ->
            :ets.delete(@terminal_table, name)

          true ->
            :ok
        end

        {:reply, {:ok, StoreHelpers.session_to_result(session)}, state}

      {:error, reason} ->
        # Durable write failed — no ETS update, no broadcast
        Logger.error("Session save failed for #{name}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:delete_session, name}, _from, state) do
    # Step 1: Delete from SQLite (durable)
    :ok = Sessions.delete_session(name)

    # Step 2: Remove from ETS
    :ets.delete(@session_table, name)
    # Remove terminal tracking
    had_terminal = match?([{^name, _}], :ets.lookup(@terminal_table, name))
    :ets.delete(@terminal_table, name)
    # Broadcast deletion
    Phoenix.PubSub.broadcast(@pubsub, @sessions_topic, {:session_deleted, name})

    if had_terminal do
      Phoenix.PubSub.broadcast(@pubsub, @terminal_topic, {:terminal_unregistered, name})
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:cleanup_sessions, max_sessions}, _from, state) do
    # Sort oldest-first by timestamp; delete the oldest entries that
    # exceed max_sessions. (code_puppy-ctj.1 fix: previously used
    # Enum.drop which incorrectly deleted NEWEST sessions)
    all_entries =
      @session_table
      |> :ets.tab2list()
      |> Enum.map(fn {_, e} -> e end)
      |> Enum.sort_by(& &1.timestamp, :asc)

    if length(all_entries) <= max_sessions do
      {:reply, {:ok, []}, state}
    else
      # Keep the newest max_sessions, delete the oldest excess
      to_delete_count = length(all_entries) - max_sessions
      to_delete = Enum.take(all_entries, to_delete_count)
      deleted = Enum.map(to_delete, & &1.name)
      Enum.each(deleted, &Sessions.delete_session/1)

      Enum.each(deleted, fn n ->
        :ets.delete(@session_table, n)
        :ets.delete(@terminal_table, n)
      end)

      Phoenix.PubSub.broadcast(@pubsub, @sessions_topic, {:sessions_cleaned, deleted})
      {:reply, {:ok, deleted}, state}
    end
  end

  @impl true
  def handle_call({:register_terminal, session_name, meta}, _from, state) do
    # (code_puppy-ctj.1 fix: durable persist + error on missing session)
    case :ets.lookup(@session_table, session_name) do
      [{^session_name, entry}] ->
        case Sessions.update_terminal_meta(session_name, true, meta) do
          {:ok, _session} ->
            :ets.insert(@terminal_table, {session_name, meta})
            updated = %{entry | has_terminal: true, terminal_meta: meta}
            :ets.insert(@session_table, {session_name, updated})

            Phoenix.PubSub.broadcast(
              @pubsub,
              @terminal_topic,
              {:terminal_registered, session_name}
            )

            {:reply, :ok, state}

          {:error, reason} ->
            Logger.error(
              "Store: durable register_terminal failed for #{session_name}: #{inspect(reason)}"
            )

            {:reply, {:error, reason}, state}
        end

      [] ->
        # (code_puppy-ctj.1 fix) No ETS entry — create a minimal durable session
        # row in SQLite + ETS so the terminal metadata is not silently lost.
        # This handles the common path where TerminalChannel.join fires before
        # any chat message has been saved.  The next save_session call will
        # update this row with full history.
        case Sessions.save_session(session_name, [], has_terminal: true, terminal_meta: meta) do
          {:ok, _session} ->
            entry =
              StoreHelpers.build_entry(
                session_name,
                [],
                [],
                0,
                false,
                StoreHelpers.now_iso(),
                true,
                meta
              )

            :ets.insert(@session_table, {session_name, entry})
            :ets.insert(@terminal_table, {session_name, meta})

            Phoenix.PubSub.broadcast(
              @pubsub,
              @terminal_topic,
              {:terminal_registered, session_name}
            )

            Logger.info(
              "Store: register_terminal created minimal session row for #{session_name}"
            )

            {:reply, :ok, state}

          {:error, reason} ->
            Logger.error(
              "Store: register_terminal failed to create session for #{session_name}: #{inspect(reason)}"
            )

            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:unregister_terminal, session_name}, _from, state) do
    # (code_puppy-ctj.1 fix: durable clear + error on missing session)
    case :ets.lookup(@session_table, session_name) do
      [{^session_name, entry}] ->
        case Sessions.update_terminal_meta(session_name, false, nil) do
          {:ok, _session} ->
            :ets.delete(@terminal_table, session_name)
            updated = %{entry | has_terminal: false, terminal_meta: nil}
            :ets.insert(@session_table, {session_name, updated})

            Phoenix.PubSub.broadcast(
              @pubsub,
              @terminal_topic,
              {:terminal_unregistered, session_name}
            )

            {:reply, :ok, state}

          {:error, reason} ->
            Logger.error(
              "Store: durable unregister_terminal failed for #{session_name}: #{inspect(reason)}"
            )

            {:reply, {:error, reason}, state}
        end

      [] ->
        Logger.warning("Store: unregister_terminal for unknown session #{session_name}")
        {:reply, {:error, :session_not_found}, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Deferred Terminal Recovery (code_puppy-ctj.1 fix)
  # ---------------------------------------------------------------------------

  @impl true
  def handle_continue(:recover_terminals, %{pending_terminal_recovery: false} = state),
    do: {:noreply, state}

  def handle_continue(:recover_terminals, state) do
    TerminalRecovery.deferred_recover_from_store()
    {:noreply, state}
  end

  @impl true
  def handle_info({:retry_terminal_recovery, attempt}, state) do
    TerminalRecovery.attempt_recovery_from_store(attempt)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  # Rebuild ETS cache from SQLite on startup.
  defp recover_from_disk do
    case Sessions.list_sessions_with_metadata() do
      {:ok, sessions} ->
        count =
          Enum.reduce(sessions, 0, fn session, acc ->
            entry = StoreHelpers.chat_session_to_entry(session)
            :ets.insert(@session_table, {session.name, entry})
            acc + 1
          end)

        Logger.info("SessionStorage.Store: recovered #{count} sessions from SQLite")
        count

      {:error, reason} ->
        Logger.warning("SessionStorage.Store: failed to recover from SQLite: #{inspect(reason)}")
        0
    end
  end

  # Terminal recovery deferred via handle_continue — see above.

  # ---------------------------------------------------------------------------
  # Child Spec
  # ---------------------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end
end
