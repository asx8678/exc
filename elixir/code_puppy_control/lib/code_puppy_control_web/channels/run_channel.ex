defmodule CodePuppyControlWeb.RunChannel do
  @moduledoc """
  Phoenix Channel for real-time run-specific events.

  Clients join "run:<run_id>" to receive:
  - Live events for a specific run only
  - Run state updates
  - Tool execution results
  - Agent output chunks

  This channel is more focused than SessionChannel - it only broadcasts
  events for a single run. Use this when you want to isolate a specific
  run's events from other activity in the session.

  ## Join

      {:ok, socket} = socket("/socket", %{}) |> join("run:run-456", %{"replay" => true})

  ## Incoming Messages (from client)

  - `"cancel"` - Cancel this run
  - `"ping"` - Client heartbeat
  - `"subscribe_session"` - Also subscribe to session events

  ## Outgoing Messages (to client)

  - `"replay"` - Initial batch of recent run events
  - `"event"` - Live event from the run
  - `"status"` - Run status change
  - `"pong"` - Heartbeat response
  - `"completed"` - Run completion notification
  - `"failed"` - Run failure notification
  """

  use Phoenix.Channel

  require Logger

  alias CodePuppyControl.{EventBus, EventStore, Run}

  @heartbeat_timeout_ms 30_000

  # ============================================================================
  # Join
  # ============================================================================

  # Join a run channel.
  # Params: "replay" (bool), "since" (cursor), "include_session" (bool)
  @impl true
  def join("run:" <> run_id, params, socket) do
    Logger.info("RunChannel: client joining run #{run_id}")

    # First check if the run exists
    case Run.Manager.get_run(run_id) do
      {:ok, run_state} ->
        # Authorize: verify this socket owns the run's session
        verified_session_id = socket.assigns[:verified_session_id]

        if authorized_for_run?(verified_session_id, run_state.session_id) do
          do_join_run(run_id, run_state, params, socket)
        else
          Logger.warning(
            "RunChannel: unauthorized join attempt for run #{run_id} (session: #{run_state.session_id})"
          )

          {:error, %{reason: "unauthorized"}}
        end

      {:error, :not_found} ->
        Logger.warning("RunChannel: join attempted for non-existent run #{run_id}")
        {:error, %{reason: "run_not_found", run_id: run_id}}
    end
  end

  # Reject join attempts for invalid topics.
  @impl true
  def join(topic, _params, _socket) do
    Logger.warning("RunChannel: rejected join attempt for topic #{topic}")
    {:error, %{reason: "unauthorized"}}
  end

  # Authorize join if verified_session_id is nil (dev mode) or matches the run's session
  defp authorized_for_run?(nil, _run_session_id), do: true
  defp authorized_for_run?(verified_id, run_session_id), do: verified_id == run_session_id

  defp do_join_run(run_id, run_state, params, socket) do
    session_id = run_state.session_id

    # Subscribe to run events via PubSub
    case EventBus.subscribe_run(run_id) do
      :ok ->
        # Optionally subscribe to session events too
        include_session = Map.get(params, "include_session", false)

        if include_session && session_id do
          EventBus.subscribe_session(session_id)
        end

        # Get replay parameters
        replay = Map.get(params, "replay", true)
        since = Map.get(params, "since", 0)

        # Build socket assigns
        socket =
          socket
          |> assign(:run_id, run_id)
          |> assign(:session_id, session_id)
          |> assign(:joined_at, DateTime.utc_now())
          |> assign(:replay_cursor, since)
          |> assign(:include_session, include_session)
          |> assign(:run_state, run_state)

        # Schedule replay if requested
        if replay do
          send(self(), {:send_replay, run_id, since})
        end

        # Schedule heartbeat check
        schedule_heartbeat_check()

        {:ok,
         %{
           run_id: run_id,
           session_id: session_id,
           status: run_state.status,
           agent_name: run_state.agent_name
         }, socket}

      {:error, reason} ->
        Logger.error("RunChannel: failed to subscribe to run #{run_id}: #{inspect(reason)}")
        {:error, %{reason: "subscription_failed"}}
    end
  end

  # ============================================================================
  # Incoming Messages (from client)
  # ============================================================================

  # Handle run cancellation request.
  # No payload needed - cancels the run this channel is joined to.
  @impl true
  def handle_in("cancel", _payload, socket) do
    run_id = socket.assigns.run_id
    Logger.info("RunChannel: cancellation requested for run #{run_id}")

    case Run.Manager.cancel_run(run_id, "user_cancelled") do
      :ok ->
        {:reply, {:ok, %{"run_id" => run_id, "status" => "cancellation_requested"}}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "run_not_found", "run_id" => run_id}}, socket}
    end
  end

  # Handle client heartbeat.
  @impl true
  def handle_in("ping", payload, socket) do
    client_time = Map.get(payload, "client_time")
    server_time = DateTime.utc_now() |> DateTime.to_iso8601()

    socket = assign(socket, :last_ping, server_time)

    {:reply, {:ok, %{"pong" => server_time, "client_time" => client_time}}, socket}
  end

  # Handle request to also subscribe to session events.
  @impl true
  def handle_in("subscribe_session", _payload, socket) do
    session_id = socket.assigns.session_id

    if session_id && not socket.assigns.include_session do
      EventBus.subscribe_session(session_id)
      socket = assign(socket, :include_session, true)
      {:reply, {:ok, %{"session_id" => session_id, "subscribed" => true}}, socket}
    else
      {:reply, {:ok, %{"session_id" => session_id, "subscribed" => false}}, socket}
    end
  end

  # Handle request for event replay.
  # Payload: {"since": ..., "limit": 100, "event_types": [...]}
  @impl true
  def handle_in("replay", params, socket) do
    run_id = socket.assigns.run_id
    since = Map.get(params, "since", 0)
    limit = Map.get(params, "limit", 100)
    event_types = Map.get(params, "event_types")

    Logger.debug(
      "RunChannel: replay requested for #{run_id}, since: #{since}, limit: #{limit}, types: #{inspect(event_types)}"
    )

    # Get session events and filter for this run
    session_id = socket.assigns.session_id

    if session_id do
      events =
        EventStore.replay(
          session_id,
          since: since,
          limit: limit,
          event_types: event_types
        )
        |> Enum.filter(fn event ->
          (event[:run_id] || event["run_id"]) == run_id
        end)

      cursor = EventStore.get_cursor(session_id)

      push(socket, "replay", %{
        events: events,
        cursor: cursor,
        count: length(events)
      })
    end

    {:noreply, socket}
  end

  # Handle request for current run state.
  @impl true
  def handle_in("get_state", _payload, socket) do
    run_id = socket.assigns.run_id

    case Run.Manager.get_run(run_id) do
      {:ok, state} ->
        {:reply,
         {:ok,
          %{
            run_id: state.run_id,
            session_id: state.session_id,
            agent_name: state.agent_name,
            status: state.status,
            started_at: state.started_at,
            completed_at: state.completed_at,
            error: state.error,
            event_count: length(state.events)
          }}, socket}

      {:error, :not_found} ->
        {:reply, {:error, %{"reason" => "run_not_found", "run_id" => run_id}}, socket}
    end
  end

  # ============================================================================
  # Outgoing Messages (to client)
  # ============================================================================

  # Send replay events to the client.
  @impl true
  def handle_info({:send_replay, run_id, since}, socket) do
    handle_info({:send_replay, run_id, since, 1000}, socket)
  end

  def handle_info({:send_replay, run_id, since, limit}, socket) do
    session_id = socket.assigns.session_id

    if session_id do
      # Get events for this session filtered by run_id
      events =
        EventStore.replay(session_id, since: since, limit: limit)
        |> Enum.filter(fn event ->
          (event[:run_id] || event["run_id"]) == run_id
        end)

      cursor = EventStore.get_cursor(session_id)

      push(socket, "replay", %{
        events: events,
        cursor: cursor,
        count: length(events)
      })

      {:noreply, assign(socket, :replay_cursor, cursor)}
    else
      {:noreply, socket}
    end
  end

  # Forward PubSub run events to the client.
  @impl true
  def handle_info({:run_event, event}, socket) do
    run_id = socket.assigns.run_id
    event_run_id = event[:run_id] || event["run_id"]

    # Only forward events for this run (or session events if subscribed)
    if event_run_id == run_id do
      # Send appropriate message based on event type
      event_type = event[:type] || event["type"]

      case event_type do
        "completed" ->
          push(socket, "completed", event)

        "failed" ->
          push(socket, "failed", event)

        "status" ->
          push(socket, "status", event)

        _ ->
          push(socket, "event", event)
      end
    else
      # Session event (if subscribed to session)
      if socket.assigns.include_session do
        push(socket, "session_event", event)
      end
    end

    {:noreply, socket}
  end

  # Handle heartbeat timeout checks.
  @impl true
  def handle_info(:check_heartbeat, socket) do
    # Could track last client activity and disconnect stale connections
    schedule_heartbeat_check()
    {:noreply, socket}
  end

  # Handle other messages.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("RunChannel: unexpected message: #{inspect(msg)}")
    {:noreply, socket}
  end

  # ============================================================================
  # Termination
  # ============================================================================

  # Clean up on channel termination.
  @impl true
  def terminate(reason, socket) do
    run_id = socket.assigns[:run_id]
    session_id = socket.assigns[:session_id]
    include_session = socket.assigns[:include_session] || false

    Logger.info("RunChannel: client left run #{run_id}, reason: #{inspect(reason)}")

    # Unsubscribe from run events
    if run_id do
      EventBus.unsubscribe_run(run_id)
    end

    # Unsubscribe from session if we were subscribed
    if include_session && session_id do
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
