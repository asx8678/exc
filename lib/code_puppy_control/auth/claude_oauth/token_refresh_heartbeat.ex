defmodule CodePuppyControl.Auth.ClaudeOAuth.TokenRefreshHeartbeat do
  @moduledoc """
  Background GenServer that periodically checks and refreshes Claude Code
  OAuth tokens during long-running agent operations.

  Ported from `code_puppy/plugins/claude_code_oauth/token_refresh_heartbeat.py`.

  Ensures tokens don't expire during extended streaming responses or tool
  processing by proactively refreshing within the expiry buffer window.

  ## Lifecycle

  - Started via `start_heartbeat/1` when an agent run begins with a Claude Code model
  - Periodically calls `ClaudeOAuth.get_valid_access_token/0` which internally
    handles refresh logic (including the proactive buffer)
  - Stopped via `stop_heartbeat/1` when the agent run ends

  ## Concurrency

  Multiple heartbeats may exist concurrently (one per session). Each is
  tracked in an ETS table keyed by session_id for safe coordination.
  """

  use GenServer

  require Logger

  alias CodePuppyControl.Auth.ClaudeOAuth

  # Check token every 2 minutes — frequent enough to catch expiring tokens
  # before they cause issues but not so frequent as to spam the token endpoint
  @default_interval_ms 120_000

  # Minimum time between actual refresh attempts to avoid hammering the endpoint
  @min_refresh_interval_s 60

  # ETS table for tracking active heartbeats by session_id
  @table :claude_oauth_heartbeat_registry

  ## ── Public API ──────────────────────────────────────────────────

  @doc """
  Start a heartbeat GenServer for the given session.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start_heartbeat(keyword()) :: GenServer.on_start()
  def start_heartbeat(opts \\ []) do
    session_id = Keyword.get(opts, :session_id, "default")
    interval = Keyword.get(opts, :interval, @default_interval_ms)
    ensure_table()

    if heartbeat_alive?(session_id) do
      {:error, :already_running}
    else
      case GenServer.start(__MODULE__, {session_id, interval, self()}) do
        {:ok, pid} ->
          :ets.insert(@table, {session_id, pid, self()})
          {:ok, pid}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Stop a heartbeat for the given session.
  """
  @spec stop_heartbeat(String.t()) :: :ok
  def stop_heartbeat(session_id \\ "default") do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, pid, _owner}] ->
        if Process.alive?(pid) do
          GenServer.cast(pid, :stop)
        end

        :ets.delete(@table, session_id)
        :ok

      [] ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Check if a heartbeat is running for the given session.

  Cleans up stale ETS entries when the heartbeat pid is dead.
  """
  @spec heartbeat_alive?(String.t()) :: boolean()
  def heartbeat_alive?(session_id \\ "default") do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, pid, _owner}] ->
        if Process.alive?(pid) do
          true
        else
          # Cleanup stale ETS entry when pid is dead
          :ets.delete(@table, session_id)
          false
        end

      [] ->
        false
    end
  rescue
    _ -> false
  end

  @doc """
  Get the number of successful refreshes performed by the heartbeat for a session.
  """
  @spec refresh_count(String.t()) :: non_neg_integer()
  def refresh_count(session_id \\ "default") do
    ensure_table()

    case :ets.lookup(@table, session_id) do
      [{^session_id, pid, _owner}] ->
        try do
          GenServer.call(pid, :refresh_count, 5_000)
        catch
          :exit, _ -> 0
        end

      [] ->
        0
    end
  rescue
    _ -> 0
  end

  ## ── GenServer Callbacks ──────────────────────────────────────────

  @impl true
  def init({session_id, interval, _owner}) do
    state = %{
      session_id: session_id,
      interval: interval,
      last_refresh: 0,
      refresh_count: 0,
      timer_ref: nil
    }

    # Schedule the first check
    {:ok, schedule_next(state)}
  end

  @impl true
  def handle_cast(:stop, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    Logger.debug(
      "TokenRefreshHeartbeat stopped for session=#{state.session_id} (refreshed #{state.refresh_count} times)"
    )

    {:stop, :normal, state}
  end

  @impl true
  def handle_call(:refresh_count, _from, state) do
    {:reply, state.refresh_count, state}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.system_time(:second)

    # Respect minimum refresh interval to avoid hammering the endpoint
    if now - state.last_refresh >= @min_refresh_interval_s do
      new_state = attempt_refresh(state, now)
      {:noreply, schedule_next(new_state)}
    else
      Logger.debug(
        "TokenRefreshHeartbeat: skipping refresh — last refresh was #{now - state.last_refresh}s ago"
      )

      {:noreply, schedule_next(state)}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## ── Private ──────────────────────────────────────────────────────

  defp attempt_refresh(state, now) do
    case ClaudeOAuth.load_tokens() do
      {:ok, tokens} when is_map_key(tokens, "access_token") ->
        if ClaudeOAuth.token_expired?(tokens) do
          Logger.info("TokenRefreshHeartbeat: token expiring soon, refreshing proactively")

          case ClaudeOAuth.get_valid_access_token() do
            {:ok, _new_token} ->
              %{state | last_refresh: now, refresh_count: state.refresh_count + 1}

            {:error, reason} ->
              Logger.debug("TokenRefreshHeartbeat: refresh failed: #{inspect(reason)}")
              state
          end
        else
          Logger.debug("TokenRefreshHeartbeat: token not yet expired, skipping refresh")
          state
        end

      _ ->
        Logger.debug("TokenRefreshHeartbeat: no stored tokens found")
        state
    end
  rescue
    e ->
      Logger.debug("TokenRefreshHeartbeat: error during refresh: #{inspect(e)}")
      state
  end

  defp schedule_next(state) do
    ref = Process.send_after(self(), :tick, state.interval)
    %{state | timer_ref: ref}
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end
end
