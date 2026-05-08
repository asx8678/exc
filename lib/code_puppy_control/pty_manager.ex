defmodule CodePuppyControl.PtyManager do
  @moduledoc """
  PTY session manager for interactive terminal emulation.

  Spawns and manages pseudo-terminal (PTY) sessions on Unix systems (macOS + Linux).
  Each session runs an interactive shell inside a true PTY allocated by `erlexec`,
  providing proper terminal semantics: line editing, escape sequences, signal
  handling, and window resizing.

  ## Why erlexec over Port.open?

  `Port.open/2` creates pipes for stdin/stdout/stderr — the child process does NOT
  see a controlling terminal. This breaks interactive shells (no readline, no
  colors, no $LINES/$COLUMNS). PTY allocation requires OS-level `openpty()` /
  `forkpty()` which the BEAM doesn't expose natively. `erlexec` wraps the C-level
  PTY calls and provides:

    - `:exec.run/2` with `:pty` option → real PTY allocation
    - `:exec.winsz/3` → terminal resize (TIOCSWINSZ ioctl)
    - `:exec.send/2` → stdin write
    - `:exec.stop/1` → graceful SIGTERM → SIGKILL shutdown
    - Process monitoring with `{'DOWN', OsPid, ...}` messages

  ## Architecture

  This GenServer tracks sessions in a map keyed by `session_id`. Each session
  holds the erlexec `OsPid` (OS process ID) and `Pid` (Erlang process managing
  the OS process). Output from the PTY is forwarded to a subscriber process
  (typically a Phoenix Channel) via `{:pty_output, session_id, data}` messages.

  ## Usage

      # Start a session (PtyManager must be in the supervision tree)
      {:ok, session} = PtyManager.create_session("my-term", cols: 120, rows: 40)

      # Subscribe to output
      PtyManager.subscribe("my-term")

      # Write to the terminal
      :ok = PtyManager.write("my-term", "ls -la\\n")

      # Resize
      :ok = PtyManager.resize("my-term", 200, 50)

      # Close
      :ok = PtyManager.close_session("my-term")

  ## Cross-platform notes

  Only Unix (macOS, Linux) is supported. The Python implementation also supports
  Windows via `pywinpty`, but the Elixir control plane targets Unix deployments.
  """

  use GenServer

  require Logger

  defstruct sessions: %{}, erlexec_started: false

  # ---------------------------------------------------------------------------
  # Session struct
  # ---------------------------------------------------------------------------

  defmodule Session do
    @moduledoc """
    State for a single PTY session.
    """

    @type t :: %__MODULE__{
            session_id: String.t(),
            os_pid: non_neg_integer(),
            pid: pid(),
            cols: pos_integer(),
            rows: pos_integer(),
            shell: String.t(),
            subscriber: pid() | nil,
            closing?: boolean()
          }

    defstruct [:session_id, :os_pid, :pid, :cols, :rows, :shell, :subscriber, closing?: false]
  end

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the PtyManager GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a new PTY session.

  ## Options

    * `:cols` - Terminal width in columns (default: 80)
    * `:rows` - Terminal height in rows (default: 24)
    * `:shell` - Shell executable path (default: `$SHELL` env → `bash` → `sh` → `/bin/sh`)
    * `:subscriber` - PID to receive `{:pty_output, session_id, data}` messages

  Returns `{:ok, %Session{}}` on success or `{:error, reason}` on failure.
  """
  @spec create_session(String.t(), keyword()) :: {:ok, Session.t()} | {:error, term()}
  def create_session(session_id, opts \\ []) do
    GenServer.call(__MODULE__, {:create_session, session_id, opts})
  end

  @doc """
  Writes data to a PTY session's stdin.
  """
  @spec write(String.t(), binary()) :: :ok | {:error, term()}
  def write(session_id, data) when is_binary(data) do
    GenServer.call(__MODULE__, {:write, session_id, data})
  end

  @doc """
  Resizes a PTY session's terminal window.
  """
  @spec resize(String.t(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def resize(session_id, cols, rows) when is_integer(cols) and is_integer(rows) do
    GenServer.call(__MODULE__, {:resize, session_id, cols, rows})
  end

  @doc """
  Closes a PTY session, terminating the shell process.
  """
  @spec close_session(String.t()) :: :ok | {:error, term()}
  def close_session(session_id) do
    GenServer.call(__MODULE__, {:close_session, session_id})
  end

  @doc """
  Closes all active PTY sessions.
  """
  @spec close_all() :: :ok
  def close_all do
    GenServer.call(__MODULE__, :close_all)
  end

  @doc """
  Returns the list of active session IDs.
  """
  @spec list_sessions() :: [String.t()]
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions)
  end

  @doc """
  Returns the session struct for a given session ID, or nil.
  """
  @spec get_session(String.t()) :: Session.t() | nil
  def get_session(session_id) do
    GenServer.call(__MODULE__, {:get_session, session_id})
  end

  @doc """
  Subscribes the calling process to PTY output for a session.

  The subscriber will receive `{:pty_output, session_id, binary}` messages
  when data is read from the PTY, and `{:pty_exit, session_id, status}` when
  the PTY process exits.
  """
  @spec subscribe(String.t()) :: :ok | {:error, :not_found}
  def subscribe(session_id) do
    GenServer.call(__MODULE__, {:subscribe, session_id, self()})
  end

  @doc """
  Unsubscribes the calling process from PTY output for a session.
  """
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(session_id) do
    GenServer.call(__MODULE__, {:unsubscribe, session_id, self()})
  end

  @doc """
  Returns the number of active sessions.
  """
  @spec count() :: non_neg_integer()
  def count do
    GenServer.call(__MODULE__, :count)
  end

  @doc """
  Returns whether erlexec is available for PTY session creation.

  Useful for callers that want to check PTY availability without
  attempting to create a session. Returns `true` if erlexec has
  been successfully started (either previously or just now),
  `false` otherwise.
  """
  @spec erlexec_available?() :: boolean()
  def erlexec_available? do
    GenServer.call(__MODULE__, :erlexec_available)
  end

  # ---------------------------------------------------------------------------
  # Server Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Do NOT call Application.ensure_all_started(:erlexec) at init time.
    # In escript/Burrito builds, erlexec looks for its `exec-port` binary under
    # a virtual/unusable priv_dir (e.g. `pup/erlexec/priv`), so startup fails.
    # PtyManager must not crash the application supervision tree when erlexec
    # is unavailable — PTY sessions are only needed for interactive terminal
    # emulation, not for the REPL or agent loop.
    #
    # Instead, we start in a degraded state (erlexec_started: false) and
    # lazily attempt erlexec startup on the first create_session/2 call.
    # If erlexec cannot start, create_session/2 returns a clear error so
    # ExecutorPty can fall back to standard execution.
    {:ok, %__MODULE__{sessions: %{}, erlexec_started: false}}
  end

  @impl true
  def handle_call({:create_session, session_id, opts}, _from, state) do
    # Lazily attempt erlexec startup on first create_session call.
    # If erlexec is unavailable (e.g. in escript where exec-port cannot be
    # found), return a clear error so ExecutorPty can fall back to standard
    # execution via System.cmd.
    case ensure_erlexec_started(state) do
      {:ok, state} ->
        do_create_session(session_id, opts, state)

      {:error, reason, state} ->
        Logger.error(
          "PtyManager: erlexec unavailable, cannot create session #{session_id}: #{inspect(reason)}"
        )

        {:reply, {:error, {:erlexec_unavailable, reason}}, state}
    end
  end

  @impl true
  def handle_call({:write, session_id, data}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        Logger.warning("PtyManager: write to unknown session #{session_id}")
        {:reply, {:error, :not_found}, state}

      session ->
        :exec.send(session.os_pid, data)
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:resize, session_id, cols, rows}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        Logger.warning("PtyManager: resize unknown session #{session_id}")
        {:reply, {:error, :not_found}, state}

      session ->
        case :exec.winsz(session.os_pid, rows, cols) do
          :ok ->
            updated = %{session | cols: cols, rows: rows}
            new_sessions = Map.put(state.sessions, session_id, updated)
            Logger.debug("PtyManager: resized session #{session_id} to #{cols}x#{rows}")
            {:reply, :ok, %{state | sessions: new_sessions}}

          {:error, reason} ->
            Logger.error("PtyManager: resize failed for #{session_id}: #{inspect(reason)}")
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:close_session, session_id}, _from, state) do
    case close_session_internal(session_id, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:close_all, _from, state) do
    new_state =
      Enum.reduce(state.sessions, state, fn {session_id, _session}, acc_state ->
        case close_session_internal(session_id, acc_state) do
          {:ok, s} -> s
          {:error, :not_found} -> acc_state
        end
      end)

    Logger.info("PtyManager: closed all sessions")
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    {:reply, Map.keys(state.sessions), state}
  end

  @impl true
  def handle_call({:get_session, session_id}, _from, state) do
    {:reply, Map.get(state.sessions, session_id), state}
  end

  @impl true
  def handle_call({:subscribe, session_id, subscriber_pid}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      session ->
        updated = %{session | subscriber: subscriber_pid}
        new_sessions = Map.put(state.sessions, session_id, updated)
        {:reply, :ok, %{state | sessions: new_sessions}}
    end
  end

  @impl true
  def handle_call({:unsubscribe, session_id, _subscriber_pid}, _from, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, :ok, state}

      session ->
        updated = %{session | subscriber: nil}
        new_sessions = Map.put(state.sessions, session_id, updated)
        {:reply, :ok, %{state | sessions: new_sessions}}
    end
  end

  @impl true
  def handle_call(:count, _from, state) do
    {:reply, map_size(state.sessions), state}
  end

  @impl true
  def handle_call(:erlexec_available, _from, state) do
    # Attempt lazy startup if not yet resolved
    case ensure_erlexec_started(state) do
      {:ok, state} -> {:reply, true, state}
      {:error, _reason, state} -> {:reply, false, state}
    end
  end

  # ---------------------------------------------------------------------------
  # Handle PTY output from erlexec
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:stdout, os_pid, data}, state) when is_binary(data) do
    forward_output(state, os_pid, data)
    {:noreply, state}
  end

  @impl true
  def handle_info({:stderr, os_pid, data}, state) when is_binary(data) do
    # stderr is also forwarded as output (terminals interleave them)
    forward_output(state, os_pid, data)
    {:noreply, state}
  end

  # Handle process exit from erlexec monitor
  @impl true
  def handle_info({:DOWN, os_pid, _process, _pid, reason}, state) do
    case find_session_by_os_pid(state, os_pid) do
      nil ->
        Logger.debug("PtyManager: received DOWN for unknown os_pid #{os_pid}")
        {:noreply, state}

      %{closing?: true} = session ->
        # Session was already closed via close_session_internal — notification
        # was sent there. Just clean up the session map.
        new_sessions = Map.delete(state.sessions, session.session_id)

        Logger.debug(
          "PtyManager: session #{session.session_id} DOWN after close (reason=#{inspect(reason)})"
        )

        {:noreply, %{state | sessions: new_sessions}}

      session ->
        # Unexpected exit — subscriber wasn't notified yet, so do it now
        if session.subscriber do
          send(session.subscriber, {:pty_exit, session.session_id, reason})
        end

        new_sessions = Map.delete(state.sessions, session.session_id)

        Logger.info(
          "PtyManager: session #{session.session_id} exited (reason=#{inspect(reason)})"
        )

        {:noreply, %{state | sessions: new_sessions}}
    end
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(msg, state) do
    Logger.debug("PtyManager: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Cleanup on terminate
  # ---------------------------------------------------------------------------

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.sessions, fn {_id, session} ->
      unless session.closing? do
        try do
          :exec.stop(session.os_pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp close_session_internal(session_id, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:error, :not_found}

      %{closing?: true} ->
        # Already closing — idempotent
        {:ok, state}

      session ->
        # Notify subscriber BEFORE stopping so the message is delivered
        # within this handle_call's reply cycle (no race with async DOWN)
        if session.subscriber do
          send(session.subscriber, {:pty_exit, session.session_id, :closed})
        end

        # erlexec stop sends SIGTERM then SIGKILL after kill_timeout
        try do
          :exec.stop(session.os_pid)
        catch
          :exit, _reason -> :ok
        end

        # Mark as closing; actual map deletion happens in handle_info({:DOWN, ...})
        # The DOWN handler sees closing?: true and skips the duplicate notification
        updated = %{session | closing?: true}
        new_sessions = Map.put(state.sessions, session_id, updated)
        Logger.info("PtyManager: closing session #{session_id}")
        {:ok, %{state | sessions: new_sessions}}
    end
  end

  defp forward_output(state, os_pid, data) do
    case find_session_by_os_pid(state, os_pid) do
      nil ->
        :ok

      session ->
        if session.subscriber do
          send(session.subscriber, {:pty_output, session.session_id, data})
        end
    end
  end

  defp find_session_by_os_pid(state, os_pid) do
    Enum.find_value(state.sessions, fn {_id, session} ->
      if session.os_pid == os_pid, do: session
    end)
  end

  # Lazy erlexec startup — attempted once on the first create_session call.
  # If erlexec is already started (or was started by another path), marks
  # the flag and returns {:ok, state}. If startup fails, caches the failure
  # in state so we don't retry on every create_session call.
  defp ensure_erlexec_started(%{erlexec_started: true} = state) do
    {:ok, state}
  end

  defp ensure_erlexec_started(state) do
    case Application.ensure_all_started(:erlexec) do
      {:ok, _} ->
        {:ok, %{state | erlexec_started: true}}

      {:error, {:already_started, :erlexec}} ->
        {:ok, %{state | erlexec_started: true}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp do_create_session(session_id, opts, state) do
    state =
      if Map.has_key?(state.sessions, session_id) do
        Logger.warning("PtyManager: session #{session_id} already exists, closing old one")

        case close_session_internal(session_id, state) do
          {:ok, new_state} -> new_state
          {:error, :not_found} -> state
        end
      else
        state
      end

    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    subscriber = Keyword.get(opts, :subscriber)

    shell =
      Keyword.get_lazy(opts, :shell, fn ->
        System.get_env("SHELL") ||
          System.find_executable("bash") ||
          System.find_executable("sh") ||
          "/bin/sh"
      end)

    erlexec_opts = [
      :pty,
      :stdin,
      :stdout,
      {:stderr, :stdout},
      {:winsz, {rows, cols}},
      :monitor,
      {:kill_timeout, 5},
      {:env, [{"TERM", System.get_env("TERM") || "xterm-256color"}]}
    ]

    case :exec.run(String.to_charlist(shell), erlexec_opts) do
      {:ok, pid, os_pid} ->
        session = %Session{
          session_id: session_id,
          os_pid: os_pid,
          pid: pid,
          cols: cols,
          rows: rows,
          shell: shell,
          subscriber: subscriber
        }

        new_sessions = Map.put(state.sessions, session_id, session)
        Logger.info("PtyManager: created session #{session_id} (os_pid=#{os_pid})")
        {:reply, {:ok, session}, %{state | sessions: new_sessions}}

      {:error, reason} ->
        Logger.error("PtyManager: failed to create session #{session_id}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end
end
