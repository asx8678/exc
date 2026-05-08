defmodule CodePuppyControl.RoundRobinModel do
  @moduledoc """
  Round-robin model rotation service for CodePuppy.

  This module manages the rotation of model names in a round-robin fashion,
  distributing requests across multiple candidate models to help overcome
  rate limits or distribute load.

  ## Purpose

  - Cycles through multiple models in a sequential round-robin pattern
  - Tracks rotation state (current index, request count)
  - Configurable rotation interval (requests before rotating)
  - Thread-safe concurrent access via ETS table

  ## Storage

  Uses ETS for fast concurrent reads and GenServer-coordinated writes.
  The ETS table is `:set` type storing the rotation state.

  ## API

  - `get_next_model/0` - Get the next model in the sequence, advancing rotation
  - `get_current_model/0` - Get the current model without advancing
  - `reset/0` - Reset rotation state to initial position
  - `get_state/0` - Get full rotation state for introspection
  - `configure/1` - Configure models list and rotation settings

  ## Configuration

  Initial models can be configured via application environment:

      config :code_puppy_control, :round_robin_models,
        models: ["claude-sonnet", "claude-haiku", "gpt-4"],
        rotate_every: 1

  ## RPC Methods

  The stdio service exposes these JSON-RPC methods:
  - `round_robin.get_next` - Get next model, advancing rotation
  - `round_robin.get_current` - Get current model without advancing
  - `round_robin.reset` - Reset rotation to initial position
  - `round_robin.get_state` - Get full rotation state
  - `round_robin.configure` - Configure models and rotation settings

  ## Examples

      iex> RoundRobinModel.configure(models: ["model-a", "model-b", "model-c"])
      :ok

      iex> RoundRobinModel.get_next_model()
      "model-a"

      iex> RoundRobinModel.get_next_model()
      "model-b"

      iex> RoundRobinModel.get_current_model()
      "model-b"

      iex> RoundRobinModel.reset()
      :ok

      iex> RoundRobinModel.get_next_model()
      "model-a"
  """

  use GenServer

  require Logger

  @table :round_robin_state

  @type model_name :: String.t()
  @type state :: %{
          models: [model_name()],
          current_index: non_neg_integer(),
          rotate_every: pos_integer(),
          request_count: non_neg_integer()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the RoundRobinModel GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Configures the round-robin model rotation.

  Options:
  - `:models` - List of model names to rotate through (required)
  - `:rotate_every` - Number of requests before rotating (default: 1)

  ## Examples

      iex> RoundRobinModel.configure(models: ["model-a", "model-b"])
      :ok

      iex> RoundRobinModel.configure(models: ["model-a", "model-b"], rotate_every: 3)
      :ok

      iex> RoundRobinModel.configure(models: [])
      {:error, :empty_models}
  """
  @spec configure(keyword()) :: :ok | {:error, atom()}
  def configure(opts) do
    models = Keyword.get(opts, :models, [])
    rotate_every = Keyword.get(opts, :rotate_every, 1)

    cond do
      models == [] ->
        {:error, :empty_models}

      rotate_every < 1 ->
        {:error, :invalid_rotate_every}

      not is_list(models) ->
        {:error, :invalid_models}

      true ->
        GenServer.call(__MODULE__, {:configure, models, rotate_every})
    end
  end

  @doc """
  Gets the next model in the round-robin sequence.

  This advances the rotation state according to the configured `rotate_every`
  setting. Returns `nil` if no models are configured.

  ## Examples

      iex> RoundRobinModel.configure(models: ["model-a", "model-b", "model-c"])
      iex> RoundRobinModel.get_next_model()
      "model-a"

      iex> RoundRobinModel.get_next_model()
      "model-b"
  """
  @spec get_next_model() :: model_name() | nil
  def get_next_model do
    case :ets.lookup(@table, :state) do
      [{:state, state}] ->
        case state.models do
          [] -> nil
          models -> Enum.at(models, state.current_index)
        end

      [] ->
        nil
    end
  end

  @doc """
  Advances the round-robin counter and returns the next model.

  This is similar to `get_next_model/0` but also increments the internal
  counter. After `rotate_every` calls, the current index advances.

  ## Examples

      iex> RoundRobinModel.configure(models: ["a", "b"], rotate_every: 1)
      iex> RoundRobinModel.advance_and_get()
      "a"
      iex> RoundRobinModel.advance_and_get()
      "b"
      iex> RoundRobinModel.advance_and_get()
      "a"
  """
  @spec advance_and_get() :: model_name() | nil
  def advance_and_get do
    GenServer.call(__MODULE__, :advance_and_get)
  end

  @doc """
  Gets the current model without advancing the rotation.

  Returns the model at the current index position, or `nil` if no models
  are configured.

  ## Examples

      iex> RoundRobinModel.configure(models: ["model-a", "model-b"])
      iex> RoundRobinModel.advance_and_get()
      "model-a"

      iex> RoundRobinModel.get_current_model()
      "model-a"

      iex> RoundRobinModel.get_current_model()
      "model-a"
  """
  @spec get_current_model() :: model_name() | nil
  def get_current_model do
    case :ets.lookup(@table, :state) do
      [{:state, state}] ->
        case state.models do
          [] -> nil
          models -> Enum.at(models, state.current_index)
        end

      [] ->
        nil
    end
  end

  @doc """
  Resets the round-robin state to initial position.

  Clears the request count and resets the current index to 0.

  ## Examples

      iex> RoundRobinModel.configure(models: ["model-a", "model-b"])
      iex> RoundRobinModel.advance_and_get()
      "model-a"
      iex> RoundRobinModel.advance_and_get()
      "model-b"
      iex> RoundRobinModel.reset()
      :ok
      iex> RoundRobinModel.get_current_model()
      "model-a"
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @doc """
  Returns the current round-robin state for introspection.

  ## Examples

      iex> RoundRobinModel.configure(models: ["a", "b"], rotate_every: 2)
      iex> RoundRobinModel.get_state()
      %{models: ["a", "b"], current_index: 0, rotate_every: 2, request_count: 0}
  """
  @spec get_state() :: state() | nil
  def get_state do
    case :ets.lookup(@table, :state) do
      [{:state, state}] -> state
      [] -> nil
    end
  end

  @doc """
  Returns the list of configured models.

  ## Examples

      iex> RoundRobinModel.configure(models: ["model-a", "model-b"])
      iex> RoundRobinModel.list_models()
      ["model-a", "model-b"]
  """
  @spec list_models() :: [model_name()]
  def list_models do
    case :ets.lookup(@table, :state) do
      [{:state, state}] -> state.models
      [] -> []
    end
  end

  @doc """
  Returns a human-readable name for the round-robin configuration.

  Format: `round_robin:m1,m2,m3` when `rotate_every=1`,
  or `round_robin:m1,m2,m3:rotate_every=N` when `rotate_every > 1`.

  This mirrors the Python `RoundRobinModel.model_name` property.

  ## Examples

      iex> RoundRobinModel.configure(models: ["m1", "m2", "m3"])
      iex> RoundRobinModel.model_name()
      "round_robin:m1,m2,m3"

      iex> RoundRobinModel.configure(models: ["m1", "m2"], rotate_every: 5)
      iex> RoundRobinModel.model_name()
      "round_robin:m1,m2:rotate_every=5"
  """
  @spec model_name() :: String.t()
  def model_name do
    case :ets.lookup(@table, :state) do
      [{:state, state}] ->
        names = Enum.join(state.models, ",")

        if state.rotate_every > 1 do
          "round_robin:#{names}:rotate_every=#{state.rotate_every}"
        else
          "round_robin:#{names}"
        end

      [] ->
        "round_robin:"
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    # Create public set table for concurrent reads
    table =
      :ets.new(@table, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Load initial configuration from application environment
    {models, rotate_every} = load_initial_config(opts)

    state = %{
      models: models,
      current_index: 0,
      rotate_every: rotate_every,
      request_count: 0
    }

    :ets.insert(table, {:state, state})

    Logger.info(
      "RoundRobinModel initialized with #{length(models)} models, rotate_every=#{rotate_every}"
    )

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:configure, models, rotate_every}, _from, state) do
    new_state = %{
      models: models,
      current_index: 0,
      rotate_every: rotate_every,
      request_count: 0
    }

    :ets.insert(state.table, {:state, new_state})

    Logger.info(
      "RoundRobinModel configured with #{length(models)} models, rotate_every=#{rotate_every}"
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:advance_and_get, _from, state) do
    case :ets.lookup(@table, :state) do
      [{:state, %{models: []}}] ->
        {:reply, nil, state}

      [{:state, rr_state}] ->
        # Get current model
        n = length(rr_state.models)
        current_model = Enum.at(rr_state.models, rr_state.current_index)

        # Advance counters
        new_request_count = rr_state.request_count + 1

        {new_index, new_request_count} =
          if new_request_count >= rr_state.rotate_every do
            # Time to rotate
            new_idx = rem(rr_state.current_index + 1, n)
            {new_idx, 0}
          else
            # Stay on current model
            {rr_state.current_index, new_request_count}
          end

        new_state = %{
          rr_state
          | current_index: new_index,
            request_count: new_request_count
        }

        :ets.insert(state.table, {:state, new_state})

        if new_index != rr_state.current_index do
          Logger.debug(
            "RoundRobinModel: rotated to index #{new_index} (#{Enum.at(rr_state.models, new_index)})"
          )
        end

        {:reply, current_model, state}

      [] ->
        {:reply, nil, state}
    end
  end

  @impl true
  def handle_call(:reset, _from, state) do
    case :ets.lookup(@table, :state) do
      [{:state, rr_state}] ->
        new_state = %{
          rr_state
          | current_index: 0,
            request_count: 0
        }

        :ets.insert(state.table, {:state, new_state})
        Logger.debug("RoundRobinModel: reset to index 0")
        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("RoundRobinModel received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_initial_config(opts) do
    # First check opts, then application environment
    models =
      Keyword.get(opts, :models) ||
        Application.get_env(:code_puppy_control, :round_robin_models, [])
        |> Keyword.get(:models, [])

    rotate_every =
      Keyword.get(opts, :rotate_every) ||
        Application.get_env(:code_puppy_control, :round_robin_models, [])
        |> Keyword.get(:rotate_every, 1)

    # Validate models list
    models = if is_list(models), do: models, else: []

    # Validate rotate_every
    rotate_every = if rotate_every >= 1, do: rotate_every, else: 1

    {models, rotate_every}
  end
end
