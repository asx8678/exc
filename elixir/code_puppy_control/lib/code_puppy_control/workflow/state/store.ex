defmodule CodePuppyControl.Workflow.State.Store do
  @moduledoc """
  Agent-backed storage for workflow state: flags, metadata, counters, introspection.

  All operations accept an optional `run_key` keyword argument so that async
  callbacks can target a specific run namespace without relying on the
  process dictionary.

  The Agent is registered under `CodePuppyControl.Workflow.State` (singleton).
  Internal state shape:

      %{
        "run-key-a" => %Workflow.State{flags: ..., metadata: ..., start_time: ...},
        "run-key-b" => %Workflow.State{flags: ..., metadata: ..., start_time: ...},
        :session_index => %{"session-id-1" => "run-key-a", ...}
      }
  """

  require Logger

  alias CodePuppyControl.Workflow.State
  alias CodePuppyControl.Workflow.State.Flags
  alias CodePuppyControl.Workflow.State.RunKey

  @agent_name State

  # ── Agent Lifecycle ──────────────────────────────────────────────────

  @doc """
  Starts the Workflow.State agent.

  The internal state is a map of `run_key => %State{}` plus a
  `:session_index` key for session_id → run_key lookups.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(
      fn -> %{RunKey.default_run_key() => State.new(), :session_index => %{}} end,
      opts
    )
  end

  @doc "Returns the current workflow state for the given run key."
  @spec get(keyword()) :: State.t()
  def get(opts \\ []) do
    run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())
    Agent.get(@agent_name, fn state -> Map.get(state, run_key, State.new()) end)
  end

  @doc """
  Resets the workflow state for the given run key.

  Only the state for the specified run key is reset; other runs are
  unaffected. Returns the fresh state struct.
  """
  @spec reset(keyword()) :: State.t()
  def reset(opts \\ []) do
    fresh = State.new()
    run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

    Agent.update(@agent_name, fn state ->
      Map.put(state, run_key, fresh)
    end)

    fresh
  end

  @doc "Returns all run keys currently stored in the Agent."
  @spec run_keys() :: [String.t()]
  def run_keys do
    Agent.get(@agent_name, fn state ->
      state
      |> Map.keys()
      |> Enum.reject(&(&1 == :session_index))
    end)
  end

  @doc """
  Deletes a specific run key's state from the Agent.

  Returns `:ok`. Does not affect the calling process's current run key.
  """
  @spec delete_run(String.t()) :: :ok
  def delete_run(key) when is_binary(key) do
    Agent.update(@agent_name, fn state -> Map.delete(state, key) end)
    :ok
  end

  # ── Flag Operations ─────────────────────────────────────────────────

  @doc """
  Sets a flag (adds it to the active set) for the given run key.

  Accepts both atoms and strings. Unknown flags are ignored with a warning.
  """
  @spec set_flag(atom() | String.t(), keyword()) :: :ok
  def set_flag(flag, opts \\ []) when is_atom(flag) or is_binary(flag) do
    case Flags.resolve_flag(flag) do
      {:ok, resolved} ->
        run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

        Agent.update(@agent_name, fn state ->
          run_state = Map.get(state, run_key, State.new())
          Map.put(state, run_key, %{run_state | flags: MapSet.put(run_state.flags, resolved)})
        end)

      {:error, :unknown_flag} ->
        Logger.warning("Unknown workflow flag: #{inspect(flag)}")
    end

    :ok
  end

  @doc """
  Sets a flag with explicit boolean value.

  When `value` is `true`, adds the flag. When `false`, removes it.
  """
  @spec set_flag(atom() | String.t(), boolean(), keyword()) :: :ok
  def set_flag(flag, true, opts) when is_atom(flag) or is_binary(flag) do
    set_flag(flag, opts)
  end

  def set_flag(flag, false, opts) when is_atom(flag) or is_binary(flag) do
    clear_flag(flag, opts)
  end

  @doc """
  Clears a flag (removes it from the active set). Unknown flags are ignored.
  """
  @spec clear_flag(atom() | String.t(), keyword()) :: :ok
  def clear_flag(flag, opts \\ []) when is_atom(flag) or is_binary(flag) do
    case Flags.resolve_flag(flag) do
      {:ok, resolved} ->
        run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

        Agent.update(@agent_name, fn state ->
          run_state = Map.get(state, run_key, State.new())
          Map.put(state, run_key, %{run_state | flags: MapSet.delete(run_state.flags, resolved)})
        end)

      {:error, :unknown_flag} ->
        # Silently ignore unknown flags on clear (matching Python behavior)
        :ok
    end

    :ok
  end

  @doc """
  Checks whether a flag is active for the given run key.

  Accepts both atoms and strings. Returns `false` for unknown flags.
  """
  @spec has_flag?(atom() | String.t(), keyword()) :: boolean()
  def has_flag?(flag, opts \\ []) when is_atom(flag) or is_binary(flag) do
    case Flags.resolve_flag(flag) do
      {:ok, resolved} ->
        run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

        Agent.get(@agent_name, fn state ->
          run_state = Map.get(state, run_key, State.new())
          MapSet.member?(run_state.flags, resolved)
        end)

      {:error, :unknown_flag} ->
        false
    end
  end

  # ── Metadata Operations ────────────────────────────────────────────

  @doc "Stores a metadata key/value pair for the given run key."
  @spec put_metadata(String.t(), any(), keyword()) :: :ok
  def put_metadata(key, value, opts \\ []) when is_binary(key) do
    run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

    Agent.update(@agent_name, fn state ->
      run_state = Map.get(state, run_key, State.new())
      Map.put(state, run_key, %{run_state | metadata: Map.put(run_state.metadata, key, value)})
    end)
  end

  @doc "Reads a metadata value for the given run key, defaulting to `default`."
  @spec get_metadata(String.t(), any(), keyword()) :: any()
  def get_metadata(key, default \\ nil, opts \\ []) when is_binary(key) do
    run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

    Agent.get(@agent_name, fn state ->
      run_state = Map.get(state, run_key, State.new())
      Map.get(run_state.metadata, key, default)
    end)
  end

  @doc "Returns a map of current metadata for the given run key."
  @spec metadata(keyword()) :: %{String.t() => any()}
  def metadata(opts \\ []) do
    run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

    Agent.get(@agent_name, fn state ->
      run_state = Map.get(state, run_key, State.new())
      run_state.metadata
    end)
  end

  @doc """
  Increments a counter in metadata for the given run key.

  If the key doesn't exist, it starts at 0 and is incremented by `amount`.
  Returns the new counter value.
  """
  @spec increment_counter(String.t(), integer(), keyword()) :: integer()
  def increment_counter(key, amount \\ 1, opts \\ [])
      when is_binary(key) and is_integer(amount) do
    run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

    Agent.get_and_update(@agent_name, fn state ->
      run_state = Map.get(state, run_key, State.new())
      current = Map.get(run_state.metadata, key, 0)
      new_value = current + amount
      updated = %{run_state | metadata: Map.put(run_state.metadata, key, new_value)}
      {{:ok, new_value}, Map.put(state, run_key, updated)}
    end)
    |> case do
      {:ok, value} -> value
    end
  end

  # ── Introspection ───────────────────────────────────────────────────

  @doc "Returns the count of active flags for the given run key."
  @spec active_count(keyword()) :: non_neg_integer()
  def active_count(opts \\ []) do
    run_key = Keyword.get(opts, :run_key, RunKey.get_run_key())

    Agent.get(@agent_name, fn state ->
      run_state = Map.get(state, run_key, State.new())
      MapSet.size(run_state.flags)
    end)
  end

  @doc "Generates a short human-readable summary of active flags for the given run key."
  @spec summary(keyword()) :: String.t()
  def summary(opts \\ []) do
    state = get(opts)

    if MapSet.size(state.flags) == 0 do
      "No actions recorded"
    else
      state.flags
      |> Enum.map(&Atom.to_string/1)
      |> Enum.map(&String.replace(&1, "_", " "))
      |> Enum.map(&String.capitalize/1)
      |> Enum.sort()
      |> Enum.join(", ")
    end
  end

  @doc "Converts the current state to a map for serialization."
  @spec to_map(keyword()) :: map()
  def to_map(opts \\ []) do
    state = get(opts)

    %{
      flags: state.flags |> MapSet.to_list() |> Enum.map(&Atom.to_string/1),
      metadata: state.metadata,
      start_time: state.start_time,
      summary: summary(opts)
    }
  end
end
