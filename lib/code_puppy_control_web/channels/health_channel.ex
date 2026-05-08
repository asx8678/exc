defmodule CodePuppyControlWeb.HealthChannel do
  @moduledoc """
  Phoenix Channel for health monitoring and diagnostics.

  Replaces the Python `/ws/health` WebSocket endpoint. Clients join
  `"health"` to receive periodic health status updates and send echo
  messages.

  ## Comparison with Python endpoint

  | Python `/ws/health` | HealthChannel |
  |---|---|
  | Echo any text back | `"echo"` message with `"echo: <text>"` |
  | No periodic pushes | Periodic `"status"` pushes with system health |
  | Simple text frames | Structured JSON messages |

  This channel goes beyond the simple Python echo endpoint by also
  providing periodic system health status pushes (memory, scheduler,
  process count, etc.).

  ## Join

      socket.channel("health", %{})

  ## Incoming messages (from client)

  - `"echo"` — `{"text": "hello"}` — Echo text back
  - `"ping"` — Client heartbeat
  - `"status"` — Request current health status

  ## Outgoing messages (to client)

  - `"echo"` — `{"text": "echo: hello"}` — Echoed text
  - `"status"` — System health status push (periodic)
  - `"pong"` — Heartbeat response
  """

  use Phoenix.Channel

  require Logger

  @health_interval_ms 15_000

  # ===========================================================================
  # Join
  # ===========================================================================

  @doc """
  Join the health channel.

  No session_id required — this is a global channel.
  Periodic health status updates begin on join.
  """
  @impl true
  def join("health", _params, socket) do
    Logger.info("HealthChannel: client connected")

    socket =
      socket
      |> assign(:joined_at, DateTime.utc_now())

    # Send initial status (the handler also schedules the next tick)
    send(self(), :send_health_status)

    {:ok, %{status: "connected"}, socket}
  end

  # Reject invalid topics
  @impl true
  def join(topic, _params, _socket) do
    Logger.warning("HealthChannel: rejected join for topic #{topic}")
    {:error, %{reason: "unauthorized"}}
  end

  # ===========================================================================
  # Incoming messages (from client)
  # ===========================================================================

  @impl true
  def handle_in("echo", %{"text" => text}, socket),
    do: {:reply, {:ok, %{"text" => "echo: #{text}"}}, socket}

  def handle_in("echo", payload, socket) do
    # Fallback: echo any payload as string (matches Python's `send_text(f"echo: {data}")`)
    text = inspect(payload)
    {:reply, {:ok, %{"text" => "echo: #{text}"}}, socket}
  end

  @doc "Handle client heartbeat."
  @impl true
  def handle_in("ping", payload, socket) do
    client_time = Map.get(payload, "client_time")
    server_time = DateTime.utc_now() |> DateTime.to_iso8601()

    {:reply, {:ok, %{"pong" => server_time, "client_time" => client_time}}, socket}
  end

  @impl true
  def handle_in("status", _payload, socket) do
    status = get_health_status()
    {:reply, {:ok, status}, socket}
  end

  # ===========================================================================
  # Outgoing messages (to client)
  # ===========================================================================

  # Periodic health status push
  @impl true
  def handle_info(:send_health_status, socket) do
    status = get_health_status()
    push(socket, "status", status)
    schedule_health()
    {:noreply, socket}
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("HealthChannel: unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ===========================================================================
  # Termination
  # ===========================================================================

  @impl true
  def terminate(reason, _socket) do
    Logger.info("HealthChannel: client disconnected, reason: #{inspect(reason)}")
    :ok
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp schedule_health do
    Process.send_after(self(), :send_health_status, @health_interval_ms)
  end

  defp get_health_status do
    # Gather BEAM VM health metrics
    _ = Process.info(self(), :memory)

    %{
      status: "ok",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      vm: %{
        process_count: Process.list() |> length(),
        memory_total_mb: Float.round(:erlang.memory(:total) / 1_048_576, 2),
        memory_process_mb: Float.round(:erlang.memory(:processes) / 1_048_576, 2),
        scheduler_count: :erlang.system_info(:schedulers),
        scheduler_online: :erlang.system_info(:schedulers_online),
        otp_version: :erlang.system_info(:otp_release) |> to_string(),
        uptime_ms: :erlang.statistics(:wall_clock) |> then(fn {ms, _} -> ms * 1000 end)
      }
    }
  end
end
