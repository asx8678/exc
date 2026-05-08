defmodule CodePuppyControlWeb.EventsChannel do
  @moduledoc """
  Phoenix Channel for real-time event streaming.

  Replaces the Python `/ws/events` WebSocket endpoint. Clients join
  `"events:<session_id>"` to receive live events and optional session
  history replay.

  ## Comparison with Python endpoint

  | Python `/ws/events` | EventsChannel |
  |---|---|
  | `subscribe(session_id=…)` queue | `EventBus.subscribe_session/1` PubSub |
  | `history_buffer.get_history(session_id)` | `EventStore.replay/2` |
  | 30s timeout → ping | Phoenix heartbeat (built-in) + `:keepalive` ping |
  | `unsubscribe(event_queue)` | `EventBus.unsubscribe_session/1` |

  ## Join

      socket.channel("events:session-123", %{"replay" => true, "since" => 42})

  ## Incoming messages (from client)

  - `"ping"` — client heartbeat, replies with `"pong"`
  - `"replay"` — request event replay since cursor

  ## Outgoing messages (to client)

  - `"event"` — live event from the event bus
  - `"replay"` — batch of historical events on join/replay request
  - `"pong"` — heartbeat response
  - `"error"` — error notification
  """

  use Phoenix.Channel

  require Logger

  alias CodePuppyControl.{EventBus, EventStore}

  @keepalive_interval_ms 30_000

  # ===========================================================================
  # Join
  # ===========================================================================

  @doc """
  Join an events channel for a session.

  ## Params

    * `"replay"` — If true, replay session events on join (default: true)
    * `"since"` — Cursor for replay; only events after this cursor (default: 0)

  ## Authorization

  The socket's `verified_session_id` must match the channel topic's
  session_id, unless in dev mode (verified_session_id is nil).
  """
  @impl true
  def join("events:" <> session_id, params, socket) do
    Logger.info("EventsChannel: client joining events for session #{session_id}")

    verified_session_id = socket.assigns[:verified_session_id]

    if authorized_for_session?(verified_session_id, session_id) do
      do_join(session_id, params, socket)
    else
      Logger.warning(
        "EventsChannel: unauthorized join for session #{session_id} (verified: #{inspect(verified_session_id)})"
      )

      {:error, %{reason: "unauthorized"}}
    end
  end

  # Reject invalid topics
  @impl true
  def join(topic, _params, _socket) do
    Logger.warning("EventsChannel: rejected join for topic #{topic}")
    {:error, %{reason: "unauthorized"}}
  end

  defp authorized_for_session?(nil, _channel_session_id), do: true

  defp authorized_for_session?(verified_id, channel_session_id),
    do: verified_id == channel_session_id

  defp do_join(session_id, params, socket) do
    case EventBus.subscribe_session(session_id) do
      :ok ->
        replay = Map.get(params, "replay", true)
        since = Map.get(params, "since", 0)

        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:joined_at, DateTime.utc_now())
          |> assign(:replay_cursor, since)

        # Schedule replay if requested
        if replay do
          send(self(), {:send_replay, session_id, since})
        end

        # Schedule keepalive pings
        schedule_keepalive()

        {:ok, %{session_id: session_id, status: "joined"}, socket}

      {:error, reason} ->
        Logger.error(
          "EventsChannel: subscription failed for session #{session_id}: #{inspect(reason)}"
        )

        {:error, %{reason: "subscription_failed"}}
    end
  end

  # ===========================================================================
  # Incoming messages (from client)
  # ===========================================================================

  @doc "Handle client heartbeat ping."
  @impl true
  def handle_in("ping", payload, socket) do
    client_time = Map.get(payload, "client_time")
    server_time = DateTime.utc_now() |> DateTime.to_iso8601()

    {:reply, {:ok, %{"pong" => server_time, "client_time" => client_time}}, socket}
  end

  @impl true
  def handle_in("replay", params, socket) do
    session_id = socket.assigns.session_id
    since = Map.get(params, "since", 0)
    limit = Map.get(params, "limit", 100)

    Logger.debug("EventsChannel: replay requested for #{session_id}, since: #{since}")

    send(self(), {:send_replay, session_id, since, limit})
    {:noreply, socket}
  end

  # ===========================================================================
  # Outgoing messages (to client)
  # ===========================================================================

  # Send replay events
  @impl true
  def handle_info({:send_replay, session_id, since}, socket) do
    handle_info({:send_replay, session_id, since, 1000}, socket)
  end

  def handle_info({:send_replay, session_id, since, limit}, socket) do
    events = EventStore.replay(session_id, since: since, limit: limit)
    cursor = EventStore.get_cursor(session_id)

    push(socket, "replay", %{
      events: events,
      cursor: cursor,
      count: length(events)
    })

    {:noreply, assign(socket, :replay_cursor, cursor)}
  end

  # Forward PubSub events to the client
  @impl true
  def handle_info({:event, event}, socket) do
    push(socket, "event", event)
    {:noreply, socket}
  end

  # Handle backward-compat PubSub message format from EventBus
  @impl true
  def handle_info({:run_event, event}, socket) do
    push(socket, "event", event)
    {:noreply, socket}
  end

  # Keepalive ping
  @impl true
  def handle_info(:keepalive, socket) do
    push(socket, "event", %{type: "ping", timestamp: DateTime.utc_now()})
    schedule_keepalive()
    {:noreply, socket}
  end

  # Catch-all for unexpected messages
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("EventsChannel: unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ===========================================================================
  # Termination
  # ===========================================================================

  @impl true
  def terminate(reason, socket) do
    session_id = socket.assigns[:session_id]
    Logger.info("EventsChannel: client left session #{session_id}, reason: #{inspect(reason)}")

    if session_id do
      EventBus.unsubscribe_session(session_id)
    end

    :ok
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp schedule_keepalive do
    Process.send_after(self(), :keepalive, @keepalive_interval_ms)
  end
end
