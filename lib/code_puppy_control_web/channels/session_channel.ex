defmodule CodePuppyControlWeb.SessionChannel do
  @moduledoc """
  Phoenix Channel for real-time session events.

  Clients join "session:<session_id>" to receive:
  - Live run events (text, tool results, status updates)
  - Replay of recent events for late-joining clients
  - Heartbeat confirmation

  ## Join

      {:ok, socket} = socket("/socket", %{}) |> join("session:session-123", %{"replay" => true})

  ## Incoming Messages (from client)

  - `"provide_response"` - Send response to a prompt
  - `"cancel_run"` - Cancel a running agent
  - `"ping"` - Client heartbeat

  ## Outgoing Messages (to client)

  - `"replay"` - Initial batch of recent events
  - `"event"` - Live event from agent run
  - `"pong"` - Heartbeat response
  - `"error"` - Error notification
  """

  use Phoenix.Channel

  require Logger

  alias CodePuppyControl.{EventBus, EventStore}

  @heartbeat_timeout_ms 30_000

  # ============================================================================
  # Join
  # ============================================================================

  @doc """
  Join a session channel.

  ## Params

    * `"replay"` - If true, sends recent events on join (default: true)
    * `"since"` - Timestamp cursor for replay (default: 0, meaning all)

  ## Socket Assigns

    * `:session_id` - The session identifier
    * `:joined_at` - UTC DateTime of join
    * `:replay_cursor` - The cursor value used for replay

  ## Authorization

  The socket's `verified_session_id` must match the channel's session_id,
  unless the socket is in dev mode (verified_session_id is nil).
  """
  @impl true
  def join("session:" <> session_id, params, socket) do
    Logger.info("SessionChannel: client joining session #{session_id}")

    # Authorize: verify this socket owns the session
    verified_session_id = socket.assigns[:verified_session_id]

    if authorized_for_session?(verified_session_id, session_id) do
      do_join_session(session_id, params, socket)
    else
      Logger.warning(
        "SessionChannel: unauthorized join attempt for session #{session_id} (verified: #{verified_session_id})"
      )

      {:error, %{reason: "unauthorized"}}
    end
  end

  # Reject join attempts for invalid topics.
  @impl true
  def join(topic, _params, _socket) do
    Logger.warning("SessionChannel: rejected join attempt for topic #{topic}")
    {:error, %{reason: "unauthorized"}}
  end

  # Authorize join if verified_session_id is nil (dev mode) or matches the session
  defp authorized_for_session?(nil, _channel_session_id), do: true

  defp authorized_for_session?(verified_id, channel_session_id),
    do: verified_id == channel_session_id

  defp do_join_session(session_id, params, socket) do
    # Subscribe to session events via PubSub
    case EventBus.subscribe_session(session_id) do
      :ok ->
        # Get replay parameters
        replay = Map.get(params, "replay", true)
        since = Map.get(params, "since", 0)

        # Build socket assigns
        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:joined_at, DateTime.utc_now())
          |> assign(:replay_cursor, since)

        # Schedule replay if requested
        if replay do
          send(self(), {:send_replay, session_id, since})
        end

        # Schedule heartbeat check
        schedule_heartbeat_check()

        {:ok, %{session_id: session_id, status: "joined"}, socket}

      {:error, reason} ->
        Logger.error(
          "SessionChannel: failed to subscribe to session #{session_id}: #{inspect(reason)}"
        )

        {:error, %{reason: "subscription_failed"}}
    end
  end

  # ============================================================================
  # Incoming Messages (from client)
  # ============================================================================

  # Handle user response to a prompt.
  # Payload: {"prompt_id": "...", "response": "..."}
  @impl true
  def handle_in("provide_response", %{"prompt_id" => prompt_id, "response" => response}, socket) do
    Logger.debug("SessionChannel: providing response for prompt #{prompt_id}")

    case CodePuppyControl.RequestTracker.provide_response(prompt_id, response) do
      :ok ->
        {:reply, {:ok, %{"prompt_id" => prompt_id, "status" => "delivered"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "prompt_not_found", "prompt_id" => prompt_id}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => inspect(reason), "prompt_id" => prompt_id}}, socket}
    end
  end

  @impl true
  def handle_in("provide_response", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_prompt_id_or_response"}}, socket}
  end

  # Handle run cancellation request.
  # Payload: {"run_id": "..."}
  @impl true
  def handle_in("cancel_run", %{"run_id" => run_id}, socket) do
    Logger.info("SessionChannel: cancelling run #{run_id}")

    # Also subscribe to this run's events for the duration
    EventBus.subscribe_run(run_id)

    case CodePuppyControl.Run.Manager.cancel_run(run_id, "user_cancelled") do
      :ok ->
        {:reply, {:ok, %{"run_id" => run_id, "status" => "cancellation_requested"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "run_not_found", "run_id" => run_id}}, socket}
    end
  end

  @impl true
  def handle_in("cancel_run", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_run_id"}}, socket}
  end

  # Handle run start request from client.
  # Payload: {"agent_name": "...", "config": {...}}
  @impl true
  def handle_in("start_run", %{"agent_name" => agent_name} = params, socket) do
    session_id = socket.assigns.session_id
    config = Map.get(params, "config", %{})

    Logger.info("SessionChannel: starting run for agent #{agent_name} in session #{session_id}")

    case CodePuppyControl.Run.Manager.start_run(session_id, agent_name, config: config) do
      {:ok, run_id} ->
        # Subscribe to the run's events
        EventBus.subscribe_run(run_id)

        {:reply, {:ok, %{"run_id" => run_id, "status" => "starting"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => inspect(reason)}}, socket}
    end
  end

  @impl true
  def handle_in("start_run", _payload, socket) do
    {:reply, {:error, %{"reason" => "missing_agent_name"}}, socket}
  end

  # Handle client heartbeat.
  @impl true
  def handle_in("ping", payload, socket) do
    client_time = Map.get(payload, "client_time")
    server_time = DateTime.utc_now() |> DateTime.to_iso8601()

    # Update last activity
    socket = assign(socket, :last_ping, server_time)

    {:reply, {:ok, %{"pong" => server_time, "client_time" => client_time}}, socket}
  end

  # Handle request for event replay.
  # Payload: {"since": ..., "limit": 100}
  @impl true
  def handle_in("replay", params, socket) do
    session_id = socket.assigns.session_id
    since = Map.get(params, "since", 0)
    limit = Map.get(params, "limit", 100)

    Logger.debug(
      "SessionChannel: replay requested for #{session_id}, since: #{since}, limit: #{limit}"
    )

    # Send replay asynchronously
    send(self(), {:send_replay, session_id, since, limit})

    {:noreply, socket}
  end

  # ============================================================================
  # Outgoing Messages (to client)
  # ============================================================================

  # Send replay events to the client.
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

    # Update socket with new cursor
    {:noreply, assign(socket, :replay_cursor, cursor)}
  end

  # Forward PubSub events to the client.
  @impl true
  def handle_info({:run_event, event}, socket) do
    # Transform internal event format to client format if needed
    push(socket, "event", event)

    # Update cursor if this event is for our session
    if event[:session_id] == socket.assigns.session_id ||
         event["session_id"] == socket.assigns.session_id do
      # Note: We don't have the timestamp in the event, but cursor is tracked separately
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Handle heartbeat timeout checks.
  @impl true
  def handle_info(:check_heartbeat, socket) do
    # In a real implementation, we might track last client activity
    # and disconnect stale connections
    schedule_heartbeat_check()
    {:noreply, socket}
  end

  # Handle other messages (PubSub, etc).
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("SessionChannel: unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Termination
  # ============================================================================

  # Clean up on channel termination.
  @impl true
  def terminate(reason, socket) do
    session_id = socket.assigns[:session_id]
    Logger.info("SessionChannel: client left session #{session_id}, reason: #{inspect(reason)}")

    # Unsubscribe from session events
    if session_id do
      EventBus.unsubscribe_session(session_id)
    end

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_heartbeat_check do
    Process.send_after(self(), :check_heartbeat, @heartbeat_timeout_ms)
  end
end
