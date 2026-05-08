defmodule CodePuppyControl.Agent.State do
  @moduledoc """
  GenServer for per-{session,agent} message history state.

  Ports Python's `BaseAgent._state.message_history` and
  `message_history_hashes` to Elixir as a supervised GenServer
  keyed by `{session_id, agent_name}`.

  Provides:
  - Ordered message list (append-order, newest-last)
  - MapSet of message hashes for O(1) dedup
  - Inactivity timeout (30 min) mirroring Run.State pattern
  - Injectable `time_fn` for deterministic testing
  """

  use GenServer

  @type session_id :: String.t()
  @type agent_name :: String.t()
  @type key :: {session_id(), agent_name()}
  @type message :: map()

  @inactivity_timeout :timer.minutes(30)

  defstruct [
    :session_id,
    :agent_name,
    :time_fn,
    messages: [],
    hashes: MapSet.new(),
    last_activity: nil
  ]

  @type t :: %__MODULE__{
          session_id: session_id(),
          agent_name: agent_name(),
          time_fn: (:millisecond -> integer()),
          messages: [message()],
          hashes: MapSet.t(binary()),
          last_activity: integer() | nil
        }

  # ── Client API ──────────────────────────────────────────────────────────

  @doc """
  Starts an Agent.State process linked to the current process.

  Required opts: `:session_id`, `:agent_name`
  Optional opts: `:time_fn` (defaults to `&System.monotonic_time/1`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_name = Keyword.fetch!(opts, :agent_name)
    key = {session_id, agent_name}

    GenServer.start_link(__MODULE__, opts, name: via_tuple(key))
  end

  @doc """
  Returns a via tuple for Registry lookup.
  """
  @spec via_tuple(key()) :: {:via, Registry, {module(), key()}}
  def via_tuple(key) do
    {:via, Registry, {CodePuppyControl.Agent.State.Registry, key}}
  end

  @doc """
  Auto-starts an Agent.State process via the DynamicSupervisor.

  Idempotent — if already running, returns `{:ok, existing_pid}`.
  """
  @spec start_agent_state(session_id(), agent_name(), keyword()) :: {:ok, pid()}
  def start_agent_state(session_id, agent_name, opts \\ []) do
    CodePuppyControl.Agent.State.Supervisor.start_agent_state(session_id, agent_name, opts)
  end

  @doc """
  Gets the message history for the given session/agent pair.

  Auto-starts the GenServer if not running.
  """
  @spec get_messages(session_id(), agent_name()) :: [message()]
  def get_messages(session_id, agent_name) do
    _ = start_agent_state(session_id, agent_name)
    GenServer.call(via_tuple({session_id, agent_name}), :get_messages)
  end

  @doc """
  Sets the message history for the given session/agent pair.

  Replaces both messages and hashes (rebuilds hash set from scratch).
  Auto-starts the GenServer if not running.
  """
  @spec set_messages(session_id(), agent_name(), [message()]) :: :ok
  def set_messages(session_id, agent_name, messages) do
    _ = start_agent_state(session_id, agent_name)
    GenServer.call(via_tuple({session_id, agent_name}), {:set_messages, messages})
  end

  @doc """
  Appends a single message if not a duplicate (by hash).

  Auto-starts the GenServer if not running.
  """
  @spec append_message(session_id(), agent_name(), message()) :: :ok
  def append_message(session_id, agent_name, message) do
    _ = start_agent_state(session_id, agent_name)
    GenServer.call(via_tuple({session_id, agent_name}), {:append_message, message})
  end

  @doc """
  Extends message history with multiple messages, filtering duplicates.

  Auto-starts the GenServer if not running.
  """
  @spec extend_messages(session_id(), agent_name(), [message()]) :: :ok
  def extend_messages(session_id, agent_name, messages) do
    _ = start_agent_state(session_id, agent_name)
    GenServer.call(via_tuple({session_id, agent_name}), {:extend_messages, messages})
  end

  @doc """
  Clears the message history and hashes for the given session/agent pair.

  Auto-starts the GenServer if not running.
  """
  @spec clear_messages(session_id(), agent_name()) :: :ok
  def clear_messages(session_id, agent_name) do
    _ = start_agent_state(session_id, agent_name)
    GenServer.call(via_tuple({session_id, agent_name}), :clear_messages)
  end

  @doc """
  Returns the number of unique messages for the given session/agent pair.

  Auto-starts the GenServer if not running.
  """
  @spec message_count(session_id(), agent_name()) :: non_neg_integer()
  def message_count(session_id, agent_name) do
    _ = start_agent_state(session_id, agent_name)
    GenServer.call(via_tuple({session_id, agent_name}), :message_count)
  end

  # ── Pure helper (stateless) ─────────────────────────────────────────────

  @doc """
  Creates a stable hash for a message that ignores timestamps.

  Mirrors Python's `BaseAgent.hash_message` (base_agent.py:473-493).
  SHA-256, hex-lowercase, first 16 chars.

  Canonical form: `"role=R||instructions=I||part1||part2||..."`
  Empty/missing fields are omitted. Parts are serialized via
  `:erlang.term_to_binary |> Base.encode16` for stable cross-process output.
  """
  @spec message_hash(message()) :: binary()
  def message_hash(message) when is_map(message) do
    header_bits = []

    header_bits =
      case Map.get(message, "role") do
        nil -> header_bits
        role -> ["role=#{role}" | header_bits]
      end

    header_bits =
      case Map.get(message, "instructions") do
        nil -> header_bits
        instructions -> ["instructions=#{instructions}" | header_bits]
      end

    # Reverse to maintain order: role first, then instructions
    header_bits = Enum.reverse(header_bits)

    parts = Map.get(message, "parts", [])
    part_strings = Enum.map(parts, &stringify_part/1)

    canonical = Enum.join(header_bits ++ part_strings, "||")

    :crypto.hash(:sha256, canonical)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp stringify_part(part) when is_map(part) do
    part
    |> :erlang.term_to_binary()
    |> Base.encode16(case: :lower)
  end

  defp stringify_part(part) do
    part
    |> :erlang.term_to_binary()
    |> Base.encode16(case: :lower)
  end

  # ── Server Callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    agent_name = Keyword.fetch!(opts, :agent_name)
    time_fn = Keyword.get(opts, :time_fn, &System.monotonic_time/1)

    state = %__MODULE__{
      session_id: session_id,
      agent_name: agent_name,
      time_fn: time_fn,
      messages: [],
      hashes: MapSet.new(),
      last_activity: time_fn.(:millisecond)
    }

    schedule_inactivity_check()

    {:ok, state}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, touch(state)}
  end

  @impl true
  def handle_call({:set_messages, messages}, _from, state) do
    # Rebuild hashes from scratch (mirrors Python's set_message_history)
    hashes =
      messages
      |> Enum.map(&message_hash/1)
      |> MapSet.new()

    new_state = %{state | messages: messages, hashes: hashes}
    {:reply, :ok, touch(new_state)}
  end

  @impl true
  def handle_call({:append_message, message}, _from, state) do
    hash = message_hash(message)

    new_state =
      if MapSet.member?(state.hashes, hash) do
        # Dedup — no-op
        state
      else
        %{state | messages: state.messages ++ [message], hashes: MapSet.put(state.hashes, hash)}
      end

    {:reply, :ok, touch(new_state)}
  end

  @impl true
  def handle_call({:extend_messages, messages}, _from, state) do
    {new_messages, new_hashes} =
      Enum.reduce(messages, {state.messages, state.hashes}, fn msg, {msgs, hashes} ->
        hash = message_hash(msg)

        if MapSet.member?(hashes, hash) do
          {msgs, hashes}
        else
          {msgs ++ [msg], MapSet.put(hashes, hash)}
        end
      end)

    new_state = %{state | messages: new_messages, hashes: new_hashes}
    {:reply, :ok, touch(new_state)}
  end

  @impl true
  def handle_call(:clear_messages, _from, state) do
    new_state = %{state | messages: [], hashes: MapSet.new()}
    {:reply, :ok, touch(new_state)}
  end

  @impl true
  def handle_call(:message_count, _from, state) do
    {:reply, length(state.messages), touch(state)}
  end

  @impl true
  def handle_info(:check_inactivity, state) do
    now = state.time_fn.(:millisecond)
    elapsed = now - state.last_activity

    if elapsed > @inactivity_timeout do
      {:stop, :normal, state}
    else
      schedule_inactivity_check()
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    require Logger
    Logger.debug("Agent.State received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp touch(state) do
    %{state | last_activity: state.time_fn.(:millisecond)}
  end

  defp schedule_inactivity_check do
    Process.send_after(self(), :check_inactivity, @inactivity_timeout)
  end
end
