defmodule CodePuppyControlWeb.TerminalChannel do
  @moduledoc """
  Phoenix Channel for interactive terminal sessions.

  Replaces the Python `/ws/terminal` WebSocket endpoint. Clients join
  `"terminal:<session_id>"` to create a PTY session and exchange
  input/output/resize messages.

  ## Comparison with Python endpoint

  | Python `/ws/terminal` | TerminalChannel |
  |---|---|
  | `PTYManager.create_session()` | `PtyManager.create_session/2` (GenServer) |
  | Binary frames with coalescing | Channel `"output"` messages |
  | `base64` JSON fallback | Not needed — Phoenix channels handle binary |
  | `output_queue` + sender task | PtyManager subscriber → `handle_info` push |
  | `websocket.receive_json()` | `handle_in("input", …)` / `handle_in("resize", …)` |

  ## PTY Backend

  The actual PTY management is delegated to `CodePuppyControl.PtyManager`
  (a GenServer). The channel subscribes to PTY output and receives
  `{:pty_output, session_id, data}` messages from the manager.
  A stub implementation (`PtyManager.Stub`) is available for tests.

  ## Join

      socket.channel("terminal:my-session", %{"cols" => 120, "rows" => 40})

  ## Incoming messages (from client)

  - `"input"` — `{"data": "ls\\n"}` — Write to PTY stdin
  - `"resize"` — `{"cols": 120, "rows": 40}` — Resize terminal
  - `"ping"` — Client heartbeat

  ## Outgoing messages (to client)

  - `"session_started"` — `{"session_id": "…"}` — PTY session created
  - `"output"` — `{"data": "<base64>"}` — PTY stdout data
  - `"pong"` — Heartbeat response
  - `"error"` — `{"reason": "…"}` — Error notification
  """

  use Phoenix.Channel

  require Logger

  alias CodePuppyControl.PtyManager
  alias CodePuppyControl.SessionStorage.Store

  @default_cols 80
  @default_rows 24

  # ===========================================================================
  # Join
  # ===========================================================================

  @doc """
  Join a terminal channel and create a PTY session.

  ## Params

    * `"cols"` — Terminal width in columns (default: 80)
    * `"rows"` — Terminal height in rows (default: 24)
    * `"shell"` — Shell executable (optional)

  ## Socket assigns

    * `:session_id` — The PTY session identifier
    * `:joined_at` — UTC DateTime of join
    * `:pty_session_id` — ID of the PTY session (may differ from topic)
  """
  @impl true
  def join("terminal:" <> session_id, params, socket) do
    Logger.info("TerminalChannel: client joining terminal for session #{session_id}")

    verified_session_id = socket.assigns[:verified_session_id]

    if authorized_for_session?(verified_session_id, session_id) do
      do_join(session_id, params, socket)
    else
      Logger.warning(
        "TerminalChannel: unauthorized join for session #{session_id} (verified: #{inspect(verified_session_id)})"
      )

      {:error, %{reason: "unauthorized"}}
    end
  end

  # Reject invalid topics
  @impl true
  def join(topic, _params, _socket) do
    Logger.warning("TerminalChannel: rejected join for topic #{topic}")
    {:error, %{reason: "unauthorized"}}
  end

  defp authorized_for_session?(nil, _channel_session_id), do: true

  defp authorized_for_session?(verified_id, channel_session_id),
    do: verified_id == channel_session_id

  defp do_join(session_id, params, socket) do
    cols = Map.get(params, "cols", @default_cols)
    rows = Map.get(params, "rows", @default_rows)
    shell = Map.get(params, "shell")

    opts = [
      cols: cols,
      rows: rows,
      subscriber: self()
    ]

    opts = if shell, do: Keyword.put(opts, :shell, shell), else: opts

    case PtyManager.create_session(session_id, opts) do
      {:ok, pty_session} ->
        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:joined_at, DateTime.utc_now())
          |> assign(:pty_session_id, pty_session.session_id || session_id)

        # Notify client that the PTY session is ready (must be sent after join)
        send(self(), {:session_started, session_id})

        # (code_puppy-ctj.1) Register terminal with SessionStorage.Store
        # for crash recovery tracking. This ensures that on restart,
        # TerminalRecovery can attempt to recreate the PTY.
        # register_terminal now creates a minimal durable session row if
        # no session exists yet, so terminal metadata is never silently lost.
        # A later save_session will overwrite with full history.
        if Process.whereis(Store) do
          terminal_meta = %{
            session_id: session_id,
            cols: cols,
            rows: rows,
            shell: shell,
            attached_at: System.monotonic_time(:millisecond)
          }

          # (code_puppy-ctj.1 fix: register_terminal now creates a minimal
          # session row if absent, so this should rarely fail.  Log warning
          # visibly on error rather than silently discarding the result.
          case Store.register_terminal(session_id, terminal_meta) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "TerminalChannel: register_terminal failed for " <>
                  "#{session_id}: #{inspect(reason)}. " <>
                  "Terminal metadata will be persisted on next save_session."
              )
          end
        end

        {:ok, %{session_id: session_id, cols: cols, rows: rows}, socket}

      {:error, reason} ->
        Logger.error(
          "TerminalChannel: failed to create PTY session #{session_id}: #{inspect(reason)}"
        )

        {:error, %{reason: "pty_creation_failed", detail: inspect(reason)}}
    end
  end

  # ===========================================================================
  # Incoming messages (from client)
  # ===========================================================================

  @impl true
  def handle_in("input", %{"data" => data}, socket) do
    session_id = socket.assigns.pty_session_id

    # Support both string and base64-encoded binary input
    binary_data =
      case data do
        d when is_binary(d) -> d
        _ -> to_string(data)
      end

    case PtyManager.write(session_id, binary_data) do
      :ok ->
        {:reply, {:ok, %{}}, socket}

      {:error, reason} ->
        Logger.warning("TerminalChannel: write failed for #{session_id}: #{inspect(reason)}")
        {:reply, {:error, %{reason: "write_failed"}}, socket}
    end
  end

  @impl true
  def handle_in("input", _payload, socket) do
    {:reply, {:error, %{reason: "missing_data"}}, socket}
  end

  @impl true
  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    session_id = socket.assigns.pty_session_id

    case PtyManager.resize(session_id, cols, rows) do
      :ok ->
        {:reply, {:ok, %{cols: cols, rows: rows}}, socket}

      {:error, reason} ->
        Logger.warning("TerminalChannel: resize failed for #{session_id}: #{inspect(reason)}")
        {:reply, {:error, %{reason: "resize_failed"}}, socket}
    end
  end

  @impl true
  def handle_in("resize", _payload, socket) do
    {:reply, {:error, %{reason: "missing_cols_or_rows"}}, socket}
  end

  @doc "Handle client heartbeat."
  @impl true
  def handle_in("ping", payload, socket) do
    client_time = Map.get(payload, "client_time")
    server_time = DateTime.utc_now() |> DateTime.to_iso8601()

    {:reply, {:ok, %{"pong" => server_time, "client_time" => client_time}}, socket}
  end

  # ===========================================================================
  # Outgoing messages (to client)
  # ===========================================================================

  # Forward PTY output to the client
  @impl true
  def handle_info({:pty_output, _session_id, data}, socket) do
    # Send as base64-encoded output to match Python protocol compatibility
    encoded = Base.encode64(data)
    push(socket, "output", %{"data" => encoded})
    {:noreply, socket}
  end

  # PTY process exited
  @impl true
  def handle_info({:pty_exit, session_id, reason}, socket) do
    Logger.info("TerminalChannel: PTY session #{session_id} exited (reason: #{inspect(reason)})")

    push(socket, "error", %{"reason" => "pty_exit", "detail" => inspect(reason)})
    {:stop, {:shutdown, :pty_exit}, socket}
  end

  # Send session_started notification after successful join
  @impl true
  def handle_info({:session_started, session_id}, socket) do
    push(socket, "session_started", %{"session_id" => session_id})
    {:noreply, socket}
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("TerminalChannel: unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ===========================================================================
  # Termination
  # ===========================================================================

  @impl true
  def terminate(reason, socket) do
    pty_session_id = socket.assigns[:pty_session_id]

    Logger.info(
      "TerminalChannel: client left PTY session #{pty_session_id}, reason: #{inspect(reason)}"
    )

    if pty_session_id do
      # Unsubscribe before closing to prevent :pty_exit feedback loop.
      # close_session sends {:pty_exit, ...} to the subscriber, but we
      # are the subscriber and are already terminating — processing that
      # message would trigger handle_info/2's {:stop, ...} path, crashing
      # the process when terminate is called outside normal lifecycle.
      PtyManager.unsubscribe(pty_session_id)
      PtyManager.close_session(pty_session_id)

      # (code_puppy-ctj.1) Unregister terminal from SessionStorage.Store
      # since the PTY session is being closed gracefully (not a crash).
      # Log warning on error rather than silently discarding the result.
      if Process.whereis(Store) do
        case Store.unregister_terminal(pty_session_id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "TerminalChannel: unregister_terminal failed for #{pty_session_id}: #{inspect(reason)}"
            )
        end
      end
    end

    :ok
  end
end
