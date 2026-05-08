defmodule CodePuppyControl.SessionStorage.PubSub do
  @moduledoc """
  Per-session and global PubSub helpers for SessionStorage.

  ## Topic Taxonomy

  | Topic | Pattern | Event shape |
  |-------|---------|-------------|
  | Per-session | `"session:{name}"` | `{:session_event, %{type:, name:, timestamp:, payload:}}` |
  | Global | `"sessions:events"` | `{:session_saved, name, meta}` / `{:session_deleted, name}` / `{:sessions_cleaned, names}` |
  | Terminal | `"terminal:recovery"` | `{:terminal_registered, name}` / `{:terminal_unregistered, name}` etc. |

  ## Event Shape Asymmetry (by design)

  `subscribe/1` (per-session) and `subscribe_all/0` (global) emit **different
  event shapes**. This is intentional — the global topic predates per-session
  topics and existing subscribers depend on the `{:session_saved, ...}` tuple
  shape. Changing it would break LiveView channels and TUI subscribers.

  - **Per-session** (`subscribe/1`): `{:session_event, %{type: atom(), name: String.t(), timestamp: DateTime.t(), payload: map()}}`
  - **Global** (`subscribe_all/0`): `{:session_saved, name, meta}` | `{:session_deleted, name}` | `{:sessions_cleaned, [name]}`

  (code_puppy-ctj.1)
  """

  @pubsub CodePuppyControl.PubSub
  @session_topic_prefix "session:"

  # ---------------------------------------------------------------------------
  # Topic Constructors
  # ---------------------------------------------------------------------------

  @doc "Returns the per-session PubSub topic for a given session name."
  @spec session_topic(String.t()) :: String.t()
  def session_topic(name), do: "#{@session_topic_prefix}#{name}"

  @doc "Returns the global sessions PubSub topic."
  @spec sessions_topic() :: String.t()
  def sessions_topic, do: "sessions:events"

  @doc "Returns the terminal recovery PubSub topic."
  @spec terminal_topic() :: String.t()
  def terminal_topic, do: "terminal:recovery"

  # ---------------------------------------------------------------------------
  # Subscribe / Unsubscribe
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes the calling process to events for a specific session.

  Received events have shape: `{:session_event, %{type:, name:, timestamp:, payload:}}`

  Event types: `:saved`, `:updated`, `:deleted`, `:custom`.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(name) do
    Phoenix.PubSub.subscribe(@pubsub, session_topic(name))
  end

  @doc """
  Unsubscribes the calling process from events for a specific session.
  """
  @spec unsubscribe(String.t()) :: :ok | {:error, term()}
  def unsubscribe(name) do
    Phoenix.PubSub.unsubscribe(@pubsub, session_topic(name))
  end

  @doc """
  Subscribes the calling process to global session lifecycle events.

  Received events have shape:
  - `{:session_saved, name, meta}` — after a session is saved
  - `{:session_deleted, name}` — after a session is deleted
  - `{:sessions_cleaned, [name]}` — after cleanup removes sessions
  """
  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all do
    Phoenix.PubSub.subscribe(@pubsub, sessions_topic())
  end

  @doc """
  Unsubscribes the calling process from global session events.
  """
  @spec unsubscribe_all() :: :ok | {:error, term()}
  def unsubscribe_all do
    Phoenix.PubSub.unsubscribe(@pubsub, sessions_topic())
  end

  # ---------------------------------------------------------------------------
  # Broadcast Helpers (used by Store)
  # ---------------------------------------------------------------------------

  @doc """
  Broadcasts a per-session event to all subscribers on `"session:{name}"`.

  Returns `:ok` always (Phoenix.PubSub.broadcast returns :ok even on no subscribers).
  """
  @spec broadcast_event(String.t(), atom(), map()) :: :ok
  def broadcast_event(name, type, payload) do
    event = %{
      type: type,
      name: name,
      timestamp: DateTime.utc_now(),
      payload: payload
    }

    Phoenix.PubSub.broadcast(@pubsub, session_topic(name), {:session_event, event})
    :ok
  end

  @doc """
  Broadcasts a per-session event to the local node only.
  """
  @spec broadcast_local_event(String.t(), atom(), map()) :: :ok
  def broadcast_local_event(name, type, payload) do
    event = %{
      type: type,
      name: name,
      timestamp: DateTime.utc_now(),
      payload: payload
    }

    Phoenix.PubSub.local_broadcast(@pubsub, session_topic(name), {:session_event, event})
    :ok
  end
end
