defmodule CodePuppyControl.SessionStorage.TerminalRecovery do
  @moduledoc """
  Terminal session crash recovery for CodePuppyControl.SessionStorage.

  When the OTP node crashes or restarts, active PTY sessions are lost because
  they are backed by OS processes that may have exited. This module handles
  the recovery semantics:

  ## Recovery Strategy

  1. **Identify** sessions that had active terminals at crash time (from ETS
     entries with `has_terminal: true`).
  2. **Attempt reconnection** — check if the OS process is still alive.
     If the PTY process survived (unlikely but possible in supervised
     restart scenarios), reconnect.
  3. **Recreate** — if the PTY process is gone, create a new PTY session
     with the saved terminal metadata (cols, rows, shell).
  4. **Notify** — broadcast recovery events via PubSub so that Phoenix
     Channels and other subscribers can re-establish their connections.

  ## Terminal Session Lifecycle

      ┌───────────┐  register   ┌───────────┐  crash   ┌───────────┐
      │  Created  │────────────▶│  Tracked  │────────▶│  Lost     │
      └───────────┘             └───────────┘         └─────┬─────┘
                                                       │
                                            recovery   │
                                                       ▼
                                              ┌───────────┐
                                              │ Recovered │
                                              └───────────┘

  ## Events (via `terminal:recovery` PubSub topic)

    * `{:terminal_recovered, session_id, meta}` — session successfully reconnected
    * `{:terminal_recovery_failed, session_id, reason}` — recovery failed
    * `{:terminal_recovery_skipped, session_id}` — session no longer has terminal

  ## Parity with Python

  Python's `session_storage.py` tracked terminal sessions via in-memory
  globals with no crash recovery — terminal state was lost on Ctrl+C or
  crash. This Elixir implementation adds the missing crash-survivability
  by persisting terminal metadata alongside session data in SQLite/ETS.
  """

  require Logger

  alias CodePuppyControl.PtyManager
  alias CodePuppyControl.SessionStorage.Store

  @pubsub CodePuppyControl.PubSub
  @terminal_topic "terminal:recovery"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Attempts to recover terminal sessions that were active at crash time.

  Called by `SessionStorage.Store` during initialization. For each session
  with `has_terminal: true`, attempts to recreate the PTY session.

  Returns the list of recovery results: `{:ok, session_id}` or
  `{:error, session_id, reason}`.
  """
  @spec recover_sessions([Store.session_entry()]) :: [
          {:ok, String.t()} | {:error, String.t(), term()}
        ]
  def recover_sessions(entries) when is_list(entries) do
    Logger.info("TerminalRecovery: starting recovery for #{length(entries)} terminal sessions")

    results =
      entries
      |> Enum.map(&recover_single/1)
      |> Enum.filter(&(&1 != nil))

    recovered = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _, _}, &1))

    Logger.info("TerminalRecovery: complete — #{recovered} recovered, #{failed} failed")

    results
  end

  @doc """
  Recovers a single terminal session.

  Returns:
    * `{:ok, session_id}` — session successfully recovered
    * `{:error, session_id, reason}` — recovery failed
    * `nil` — session has no terminal metadata (skipped)
  """
  @spec recover_single(Store.session_entry()) ::
          {:ok, String.t()} | {:error, String.t(), term()} | nil
  def recover_single(%{has_terminal: false}), do: nil

  def recover_single(%{has_terminal: true, terminal_meta: nil, name: name}) do
    Logger.warning("TerminalRecovery: session #{name} marked as terminal but has no metadata")
    broadcast_recovery_failed(name, "no_terminal_metadata")
    {:error, name, :no_terminal_metadata}
  end

  def recover_single(%{has_terminal: true, terminal_meta: meta, name: name}) do
    Logger.info("TerminalRecovery: attempting to recover terminal for session #{name}")

    # Check if the PTY process is still alive (unlikely after crash, but
    # possible in supervised restart where PtyManager restarts but the
    # OS process survives)
    case check_existing_pty(name) do
      {:ok, _session} ->
        Logger.info("TerminalRecovery: session #{name} PTY still alive, reconnecting")
        broadcast_recovered(name, meta)
        {:ok, name}

      :not_found ->
        # PTY process is gone — recreate it
        recreate_terminal(name, meta)
    end
  end

  def recover_single(_), do: nil

  @doc """
  Returns a summary of terminal recovery state.

  Useful for diagnostics and `/doctor` command.
  """
  @spec recovery_status() :: map()
  def recovery_status do
    terminal_sessions = Store.list_terminal_sessions()

    %{
      active_terminals: length(terminal_sessions),
      sessions: terminal_sessions,
      pty_manager_alive: Process.whereis(PtyManager) != nil
    }
  end

  # ---------------------------------------------------------------------------
  # Deferred Recovery with Retry (code_puppy-ctj.1 fix)
  # ---------------------------------------------------------------------------

  # PtyManager starts AFTER Store in the supervision tree, so recovery
  # cannot run during Store.init. These functions implement the retry
  # orchestration: check if PtyManager is up, recover if so, or schedule
  # a retry with exponential backoff.

  @max_recovery_retries 5
  @recovery_base_delay_ms 200

  @doc """
  Starts deferred terminal recovery from the Store's ETS tables.

  Checks if PtyManager is running. If yes, recovers immediately.
  If not, schedules a retry with exponential backoff.

  Called by Store's `handle_continue(:recover_terminals, _)`.
  """
  @spec deferred_recover_from_store() :: :ok
  def deferred_recover_from_store do
    attempt_recovery_from_store(1)
    :ok
  end

  @doc """
  Attempts terminal recovery from ETS tables, with retry scheduling.

  Called by Store's `handle_info({:retry_terminal_recovery, attempt}, _)`.
  """
  @spec attempt_recovery_from_store(pos_integer()) :: :ok
  def attempt_recovery_from_store(attempt) when attempt > @max_recovery_retries do
    Logger.warning(
      "TerminalRecovery: gave up after #{@max_recovery_retries} attempts — PtyManager unavailable"
    )

    :ok
  end

  def attempt_recovery_from_store(attempt) do
    if Process.whereis(PtyManager) != nil do
      # PtyManager is up — recover from ETS
      terminal_entries =
        :session_store_ets
        |> :ets.tab2list()
        |> Enum.filter(fn {_name, entry} -> entry.has_terminal end)
        |> Enum.map(fn {_name, entry} -> entry end)

      if length(terminal_entries) > 0 do
        Logger.info(
          "TerminalRecovery: starting deferred recovery for #{length(terminal_entries)} sessions"
        )

        recover_sessions(terminal_entries)
      end
    else
      # PtyManager not up yet — schedule retry with exponential backoff
      delay = (@recovery_base_delay_ms * :math.pow(2, attempt - 1)) |> round()

      Logger.debug(
        "TerminalRecovery: PtyManager not up, retry #{attempt}/#{@max_recovery_retries} in #{delay}ms"
      )

      store_pid = Process.whereis(Store)

      if store_pid do
        Process.send_after(store_pid, {:retry_terminal_recovery, attempt + 1}, delay)
      else
        Logger.warning("TerminalRecovery: Store not running, cannot schedule retry")
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  # Check if a PTY session with the given name already exists.
  defp check_existing_pty(name) do
    case Process.whereis(PtyManager) do
      nil ->
        :not_found

      _pid ->
        try do
          PtyManager.get_session(name)
        rescue
          _ -> :not_found
        else
          nil -> :not_found
          session -> {:ok, session}
        end
    end
  end

  # Attempt to recreate a PTY session from saved metadata.
  # (code_puppy-ctj.1 fix: use Map.put instead of map update syntax
  # to avoid crash when terminal_meta has string keys from SQLite.)
  defp recreate_terminal(name, meta) do
    cols = Map.get(meta, :cols, Map.get(meta, "cols", 80))
    rows = Map.get(meta, :rows, Map.get(meta, "rows", 24))
    shell = Map.get(meta, :shell, Map.get(meta, "shell"))

    opts = [cols: cols, rows: rows]

    opts = if shell, do: Keyword.put(opts, :shell, shell), else: opts

    case Process.whereis(PtyManager) do
      nil ->
        Logger.warning(
          "TerminalRecovery: PtyManager not running, cannot recreate terminal for #{name}"
        )

        broadcast_recovery_failed(name, :pty_manager_unavailable)
        {:error, name, :pty_manager_unavailable}

      _pid ->
        try do
          case PtyManager.create_session(name, opts) do
            {:ok, _session} ->
              Logger.info("TerminalRecovery: recreated PTY for session #{name}")

              # Re-register the terminal with the Store.
              # Use Map.put (not map update) — meta may have string keys
              # from SQLite deserialization.
              new_meta = Map.put(meta, :attached_at, System.monotonic_time(:millisecond))
              Store.register_terminal(name, new_meta)

              broadcast_recovered(name, new_meta)
              {:ok, name}

            {:error, reason} ->
              Logger.warning(
                "TerminalRecovery: failed to recreate PTY for #{name}: #{inspect(reason)}"
              )

              broadcast_recovery_failed(name, reason)
              {:error, name, reason}
          end
        rescue
          e ->
            Logger.warning(
              "TerminalRecovery: exception recreating PTY for #{name}: #{inspect(e)}"
            )

            broadcast_recovery_failed(name, e)
            {:error, name, e}
        end
    end
  end

  defp broadcast_recovered(name, meta) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      @terminal_topic,
      {:terminal_recovered, name, meta}
    )
  end

  defp broadcast_recovery_failed(name, reason) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      @terminal_topic,
      {:terminal_recovery_failed, name, reason}
    )
  end
end
