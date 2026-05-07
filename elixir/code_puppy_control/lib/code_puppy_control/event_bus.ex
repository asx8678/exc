defmodule CodePuppyControl.EventBus do
  @moduledoc """
  Event distribution via Phoenix.PubSub.

  Replaces the legacy MessageBus pattern with Elixir-native PubSub.
  Python emits events to Elixir, which broadcasts via PubSub to subscribers.

  ## Topics

  - `"session:<session_id>"` - All events for a session
  - `"run:<run_id>"` - Events for specific run
  - `"global:events"` - System-wide events

  ## Usage

      # Subscribe to events
      EventBus.subscribe_session("session-123")
      EventBus.subscribe_run("run-456")

      # Broadcast events from Python worker
      EventBus.broadcast_text("run-456", "session-123", "Hello from agent")
      EventBus.broadcast_tool_result("run-456", "session-123", "file_read", %{content: "..."})

  ## Event Format

  All events include:
  - `type` - Event type (text, tool_result, status, etc.)
  - `run_id` - Associated run identifier
  - `session_id` - Associated session identifier
  - `timestamp` - UTC DateTime
  - Event-specific fields
  """

  require Logger

  alias Phoenix.PubSub

  alias CodePuppyControl.Messaging.{WireEvent, Commands}

  @pubsub CodePuppyControl.PubSub
  @env Mix.env()

  # ============================================================================
  # Topic Helpers
  # ============================================================================

  @doc """
  Returns the topic name for a session.
  """
  @spec session_topic(String.t()) :: String.t()
  def session_topic(session_id), do: "session:#{session_id}"

  @doc """
  Returns the topic name for a run.
  """
  @spec run_topic(String.t()) :: String.t()
  def run_topic(run_id), do: "run:#{run_id}"

  @doc """
  Returns the global events topic name.
  """
  @spec global_topic() :: String.t()
  def global_topic, do: "global:events"

  # ============================================================================
  # Subscribe
  # ============================================================================

  @doc """
  Subscribe to events for a specific session.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec subscribe_session(String.t()) :: :ok | {:error, term()}
  def subscribe_session(session_id) do
    PubSub.subscribe(@pubsub, session_topic(session_id))
  end

  @doc """
  Subscribe to events for a specific run.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec subscribe_run(String.t()) :: :ok | {:error, term()}
  def subscribe_run(run_id) do
    PubSub.subscribe(@pubsub, run_topic(run_id))
  end

  @doc """
  Subscribe to global events.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec subscribe_global() :: :ok | {:error, term()}
  def subscribe_global do
    PubSub.subscribe(@pubsub, global_topic())
  end

  @doc """
  Unsubscribe from a session topic.
  """
  @spec unsubscribe_session(String.t()) :: :ok | {:error, term()}
  def unsubscribe_session(session_id) do
    PubSub.unsubscribe(@pubsub, session_topic(session_id))
  end

  @doc """
  Unsubscribe from a run topic.
  """
  @spec unsubscribe_run(String.t()) :: :ok | {:error, term()}
  def unsubscribe_run(run_id) do
    PubSub.unsubscribe(@pubsub, run_topic(run_id))
  end

  @doc """
  Unsubscribe from global events.
  """
  @spec unsubscribe_global() :: :ok | {:error, term()}
  def unsubscribe_global do
    PubSub.unsubscribe(@pubsub, global_topic())
  end

  # ============================================================================
  # Broadcast Events
  # ============================================================================

  @doc """
  Broadcast an event to all relevant topics.

  The event is broadcast to:
  - The run topic (if run_id is present)
  - The session topic (if session_id is present)
  - The global topic (always)

  ## Options

    * `:store` - Whether to store the event in EventStore. Default: true
  """
  @spec broadcast_event(map(), keyword()) :: :ok
  def broadcast_event(event, opts \\ []) do
    # Store event first if requested (default true)
    if Keyword.get(opts, :store, true) do
      CodePuppyControl.EventStore.store(event)
    end

    # Broadcast to run topic
    # (code_puppy-i1n) Guard against PubSub being unavailable (e.g.
    # during test suite shutdown or supervision tree restart).
    if run_id = event[:run_id] || event["run_id"] do
      safe_broadcast(run_topic(run_id), {:event, event})
    end

    # Broadcast to session topic
    if session_id = event[:session_id] || event["session_id"] do
      safe_broadcast(session_topic(session_id), {:event, event})
    end

    # Always broadcast to global
    safe_broadcast(global_topic(), {:event, event})

    :ok
  end

  @doc """
  Broadcast an event only to the local node (non-distributed).
  """
  @spec broadcast_local_event(map()) :: :ok
  def broadcast_local_event(event) do
    if run_id = event[:run_id] || event["run_id"] do
      safe_local_broadcast(run_topic(run_id), {:event, event})
    end

    if session_id = event[:session_id] || event["session_id"] do
      safe_local_broadcast(session_topic(session_id), {:event, event})
    end

    safe_local_broadcast(global_topic(), {:event, event})

    :ok
  end

  # ============================================================================
  # Event Type Helpers
  # ============================================================================

  @doc """
  Broadcast a text/content event from an agent.
  """
  @spec broadcast_text(String.t(), String.t() | nil, String.t(), keyword()) :: :ok
  def broadcast_text(run_id, session_id, content, opts \\ []) do
    event = %{
      type: "text",
      run_id: run_id,
      session_id: session_id,
      content: content,
      chunk: Keyword.get(opts, :chunk, false),
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast a status update event.
  """
  @spec broadcast_status(String.t(), String.t() | nil, atom() | String.t(), keyword()) :: :ok
  def broadcast_status(run_id, session_id, status, opts \\ []) do
    event = %{
      type: "status",
      run_id: run_id,
      session_id: session_id,
      status: to_string(status),
      metadata: Keyword.get(opts, :metadata, %{}),
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast a tool execution result.
  """
  @spec broadcast_tool_result(String.t(), String.t() | nil, String.t(), map(), keyword()) ::
          :ok
  def broadcast_tool_result(run_id, session_id, tool_name, result, opts \\ []) do
    event = %{
      type: "tool_result",
      run_id: run_id,
      session_id: session_id,
      tool_name: tool_name,
      result: result,
      tool_call_id: Keyword.get(opts, :tool_call_id),
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast a tool call (request to execute a tool).
  """
  @spec broadcast_tool_call(String.t(), String.t() | nil, String.t(), map(), keyword()) :: :ok
  def broadcast_tool_call(run_id, session_id, tool_name, arguments, opts \\ []) do
    event = %{
      type: "tool_call",
      run_id: run_id,
      session_id: session_id,
      tool_name: tool_name,
      arguments: arguments,
      tool_call_id: Keyword.get(opts, :tool_call_id),
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast a thinking/reasoning event.
  """
  @spec broadcast_thinking(String.t(), String.t() | nil, String.t(), keyword()) :: :ok
  def broadcast_thinking(run_id, session_id, content, opts \\ []) do
    event = %{
      type: "thinking",
      run_id: run_id,
      session_id: session_id,
      content: content,
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast an error event.
  """
  @spec broadcast_error(String.t(), String.t() | nil, String.t(), map(), keyword()) :: :ok
  def broadcast_error(run_id, session_id, message, details \\ %{}, opts \\ []) do
    event = %{
      type: "error",
      run_id: run_id,
      session_id: session_id,
      message: message,
      details: details,
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast a run completion event.
  """
  @spec broadcast_completed(String.t(), String.t() | nil, map(), keyword()) :: :ok
  def broadcast_completed(run_id, session_id, result \\ %{}, opts \\ []) do
    event = %{
      type: "completed",
      run_id: run_id,
      session_id: session_id,
      result: result,
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast a run failure event.
  """
  @spec broadcast_failed(String.t(), String.t() | nil, String.t(), map(), keyword()) :: :ok
  def broadcast_failed(run_id, session_id, error, details \\ %{}, opts \\ []) do
    event = %{
      type: "failed",
      run_id: run_id,
      session_id: session_id,
      error: error,
      details: details,
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast a prompt/request for user input.
  """
  @spec broadcast_prompt(String.t(), String.t() | nil, String.t(), map(), keyword()) :: :ok
  def broadcast_prompt(run_id, session_id, prompt_id, prompt_data, opts \\ []) do
    event = %{
      type: "prompt",
      run_id: run_id,
      session_id: session_id,
      prompt_id: prompt_id,
      data: prompt_data,
      timestamp: DateTime.utc_now()
    }

    broadcast_event(event, opts)
  end

  @doc """
  Broadcast a heartbeat/keepalive event.
  """
  @spec broadcast_heartbeat(String.t(), String.t() | nil, map()) :: :ok
  def broadcast_heartbeat(run_id, session_id, metrics \\ %{}) do
    event = %{
      type: "heartbeat",
      run_id: run_id,
      session_id: session_id,
      metrics: metrics,
      timestamp: DateTime.utc_now()
    }

    # Heartbeats are not stored to avoid flooding the event store
    broadcast_event(event, store: false)
  end

  # ============================================================================
  # Structured Messaging (Wire Events) - Agent→UI
  # ============================================================================

  @doc """
  Broadcast a structured message from an internal message map.

  Accepts an internal structured message map from Messaging.Messages constructors
  (string keys), injects/overrides "run_id" and "session_id" wrapper fields,
  serializes via WireEvent.to_wire/1, and broadcasts/stores the resulting
  wire envelope using existing routing semantics.

  ## Parameters

    * `run_id` - Execution run identifier (can be nil)
    * `session_id` - Session grouping (can be nil)
    * `internal_message` - Internal message map with string keys
    * `opts` - Options (see broadcast_event/2)

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on validation failure (no broadcast/store)

  ## Examples

      # Broadcast a text message
      {:ok, msg} = Messages.text_message(%{"level" => "info", "text" => "Hello"})
      EventBus.broadcast_message("run-1", "session-1", msg)
  """
  @spec broadcast_message(String.t() | nil, String.t() | nil, map(), keyword()) ::
          :ok | {:error, term()}
  def broadcast_message(run_id, session_id, internal_message, opts \\ [])

  def broadcast_message(_run_id, _session_id, internal_message, _opts)
      when not is_map(internal_message) do
    {:error, {:not_a_map, internal_message}}
  end

  def broadcast_message(run_id, session_id, internal_message, opts) do
    # Inject run_id and session_id into the internal message
    message_with_ids =
      internal_message
      |> Map.put("run_id", run_id)
      |> Map.put("session_id", session_id)

    # Serialize to wire format
    case WireEvent.to_wire(message_with_ids) do
      {:ok, wire_event} ->
        # Broadcast using existing routing semantics
        broadcast_event(wire_event, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Broadcast a validated wire event envelope.

  Validates the wire envelope using WireEvent.from_wire/1 before broadcasting.
  If invalid, returns error and does not broadcast/store.

  ## Parameters

    * `wire_event` - Wire envelope map (string-keyed)
    * `opts` - Options (see broadcast_event/2)

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on validation failure (no broadcast/store)

  ## Examples

      wire_event = %{
        "event_type" => "system",
        "run_id" => "run-1",
        "session_id" => "session-1",
        "timestamp" => 1717000000000,
        "payload" => %{"id" => "msg-1", "category" => "system", "level" => "info", "text" => "Hello"}
      }
      EventBus.broadcast_wire_event(wire_event)
  """
  @spec broadcast_wire_event(map(), keyword()) :: :ok | {:error, term()}
  def broadcast_wire_event(wire_event, opts \\ []) do
    # Validate the wire envelope
    case WireEvent.from_wire(wire_event) do
      {:ok, _internal} ->
        # Valid wire envelope, broadcast using existing routing semantics
        broadcast_event(wire_event, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Structured Messaging - UI→Agent Commands
  # ============================================================================

  @doc """
  Broadcast a UI→Agent command.

  Accepts either a Commands struct (using Commands.to_wire/1) or a string-keyed
  command wire map (validated by Commands.from_wire/1). Broadcasts a
  legacy-compatible event map with type "command" that preserves EventStore
  filtering and existing channel expectations.

  ## Parameters

    * `run_id` - Execution run identifier (can be nil)
    * `session_id` - Session grouping (can be nil)
    * `command_or_wire` - Commands struct or command wire map
    * `opts` - Options (see broadcast_event/2)

  ## Returns

    * `:ok` on success
    * `{:error, reason}` on validation failure (no broadcast/store)

  ## Examples

      # Broadcast a CancelAgentCommand struct
      cmd = Commands.cancel_agent(reason: "user requested")
      EventBus.broadcast_command("run-1", "session-1", cmd)

      # Broadcast a command wire map
      wire = %{"command_type" => "cancel_agent", "reason" => "user requested"}
      EventBus.broadcast_command("run-1", "session-1", wire)
  """
  # Known Commands struct modules — only these are accepted as valid command input.
  @known_command_structs [
    Commands.CancelAgentCommand,
    Commands.InterruptShellCommand,
    Commands.UserInputResponse,
    Commands.ConfirmationResponse,
    Commands.SelectionResponse,
    Commands.AskUserQuestionResponse
  ]

  @spec broadcast_command(String.t() | nil, String.t() | nil, term(), keyword()) ::
          :ok | {:error, term()}
  def broadcast_command(run_id, session_id, command_or_wire, opts \\ []) do
    # Convert to wire format
    wire_command =
      case command_or_wire do
        # Only accept known Commands structs (not arbitrary maps with :command_type)
        %module{} = cmd when module in @known_command_structs ->
          Commands.to_wire(cmd)

        # It's a wire map (string keys) — validate through from_wire
        wire when is_map(wire) ->
          case Commands.from_wire(wire) do
            {:ok, cmd_struct} ->
              Commands.to_wire(cmd_struct)

            {:error, reason} ->
              {:error, reason}
          end

        _ ->
          {:error, {:invalid_command_input, command_or_wire}}
      end

    case wire_command do
      {:error, reason} ->
        {:error, reason}

      wire when is_map(wire) ->
        # Build legacy-compatible event map
        event = %{
          type: "command",
          run_id: run_id,
          session_id: session_id,
          command: wire,
          timestamp: DateTime.utc_now()
        }

        broadcast_event(event, opts)
    end
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  # (code_puppy-i1n) Wraps PubSub.broadcast so that a dead PubSub registry
  # (ArgumentError) does not crash the caller. During test suite shutdown
  # or supervision tree restart, PubSub may be momentarily unavailable;
  # broadcasting is best-effort and should never kill the publishing process.
  # Outside tests, log the dropped event so a misconfigured PubSub is visible.
  defp safe_broadcast(topic, msg) do
    PubSub.broadcast(@pubsub, topic, msg)
  rescue
    e in ArgumentError -> handle_broadcast_error(topic, e)
  end

  defp safe_local_broadcast(topic, msg) do
    PubSub.local_broadcast(@pubsub, topic, msg)
  rescue
    e in ArgumentError -> handle_broadcast_error(topic, e)
  end

  defp handle_broadcast_error(topic, error) do
    unless @env == :test do
      Logger.warning("PubSub broadcast failed for #{inspect(topic)}: #{Exception.message(error)}")
    end

    :ok
  end
end
