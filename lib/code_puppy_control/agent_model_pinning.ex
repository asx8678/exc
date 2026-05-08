defmodule CodePuppyControl.AgentModelPinning do
  @moduledoc """
  Agent model pinning service for CodePuppy.

  Maps agent names to specific model names, allowing users to pin particular
  models to particular agents. This is the Elixir port of the Python
  `code_puppy/agent_model_pinning.py` module.

  ## Purpose

  - Provides a single source of truth for which model an agent should use
  - Enables runtime configuration of agent-to-model mappings
  - Integrates with the JSON-RPC transport for remote configuration

  ## Storage

  Uses ETS for fast concurrent reads and GenServer-coordinated writes.
  The ETS table is `:set` type with `{agent_name, model_name}` tuples.

  ## API

  - `get_pinned_model/1` - Get the pinned model for an agent (returns model or nil)
  - `set_pinned_model/2` - Pin a model to an agent
  - `clear_pinned_model/1` - Remove the pin for an agent
  - `list_pins/0` - List all agent-to-model mappings

  ## Configuration

  Initial pins can be configured via application environment:

      config :code_puppy_control, :agent_model_pins,
        "elixir-dev": "claude-code-elixir",
        "reviewer": "claude-sonnet"

  ## RPC Methods

  The stdio service exposes these JSON-RPC methods:
  - `agent_pinning.get` - Get pinned model for an agent
  - `agent_pinning.set` - Set pinned model
  - `agent_pinning.clear` - Clear pin
  - `agent_pinning.list` - List all pins

  ## Examples

      iex> AgentModelPinning.set_pinned_model("elixir-dev", "claude-code-elixir")
      :ok

      iex> AgentModelPinning.get_pinned_model("elixir-dev")
      "claude-code-elixir"

      iex> AgentModelPinning.clear_pinned_model("elixir-dev")
      :ok

      iex> AgentModelPinning.get_pinned_model("elixir-dev")
      nil
  """

  use GenServer

  require Logger

  @table :agent_model_pins
  @unpin_marker "(unpin)"

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the AgentModelPinning GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the pinned model for an agent.

  Returns the model name if pinned, or `nil` if no pin exists.

  ## Examples

      iex> AgentModelPinning.get_pinned_model("elixir-dev")
      "claude-code-elixir"

      iex> AgentModelPinning.get_pinned_model("unknown-agent")
      nil
  """
  @spec get_pinned_model(String.t()) :: String.t() | nil
  def get_pinned_model(agent_name) when is_binary(agent_name) do
    case :ets.lookup(@table, agent_name) do
      [{^agent_name, model}] -> model
      [] -> nil
    end
  end

  @doc """
  Sets the pinned model for an agent.

  If the model choice is "(unpin)", the pin is removed.

  ## Examples

      iex> AgentModelPinning.set_pinned_model("elixir-dev", "claude-code-elixir")
      :ok

      iex> AgentModelPinning.set_pinned_model("elixir-dev", "(unpin)")
      :ok  # Equivalent to clearing the pin
  """
  @spec set_pinned_model(String.t(), String.t()) :: :ok
  def set_pinned_model(agent_name, model_choice)
      when is_binary(agent_name) and is_binary(model_choice) do
    GenServer.call(__MODULE__, {:set, agent_name, model_choice})
  end

  @doc """
  Clears the pinned model for an agent.

  ## Examples

      iex> AgentModelPinning.clear_pinned_model("elixir-dev")
      :ok
  """
  @spec clear_pinned_model(String.t()) :: :ok
  def clear_pinned_model(agent_name) when is_binary(agent_name) do
    GenServer.call(__MODULE__, {:clear, agent_name})
  end

  @doc """
  Lists all agent-to-model pin mappings.

  Returns a map of agent names to their pinned models.

  ## Examples

      iex> AgentModelPinning.list_pins()
      %{"elixir-dev" => "claude-code-elixir", "reviewer" => "claude-sonnet"}
  """
  @spec list_pins() :: %{String.t() => String.t()}
  def list_pins do
    @table
    |> :ets.tab2list()
    |> Map.new(fn {agent, model} -> {agent, model} end)
  end

  @doc """
  Gets the effective model for an agent with optional fallback.

  Returns the pinned model if one exists, otherwise returns the fallback
  (which defaults to nil).

  ## Examples

      iex> AgentModelPinning.effective_model("elixir-dev", "claude-default")
      "claude-code-elixir"  # Returns pinned model if exists

      iex> AgentModelPinning.effective_model("unknown", "claude-default")
      "claude-default"  # Returns fallback when no pin
  """
  @spec effective_model(String.t(), String.t() | nil) :: String.t() | nil
  def effective_model(agent_name, fallback \\ nil) when is_binary(agent_name) do
    case get_pinned_model(agent_name) do
      nil -> fallback
      model -> model
    end
  end

  @doc """
  Applies a pinned model selection for an agent.

  This is the main entry point matching the Python `apply_agent_pinned_model`.

  - If `model_choice` is "(unpin)", removes any existing pin
  - Otherwise, sets the pin to the specified model

  Returns the pinned model name if pinned, or nil if unpinned.

  ## Examples

      iex> AgentModelPinning.apply_pinned_model("elixir-dev", "claude-code-elixir")
      "claude-code-elixir"

      iex> AgentModelPinning.apply_pinned_model("elixir-dev", "(unpin)")
      nil
  """
  @spec apply_pinned_model(String.t(), String.t()) :: String.t() | nil
  def apply_pinned_model(agent_name, model_choice)
      when is_binary(agent_name) and is_binary(model_choice) do
    if model_choice == @unpin_marker do
      :ok = clear_pinned_model(agent_name)
      nil
    else
      :ok = set_pinned_model(agent_name, model_choice)
      model_choice
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

    # Load initial pins from application environment
    initial_pins = Keyword.get(opts, :initial_pins, load_initial_pins())

    for {agent, model} <- initial_pins do
      agent_str = to_string(agent)
      model_str = to_string(model)
      :ets.insert(table, {agent_str, model_str})
    end

    Logger.info("AgentModelPinning initialized with #{length(initial_pins)} initial pins")

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:set, agent_name, model_choice}, _from, state)
      when model_choice == @unpin_marker do
    # Treat unpin marker as a clear operation
    :ets.delete(@table, agent_name)
    Logger.debug("AgentModelPinning: cleared pin for #{agent_name} via (unpin) marker")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:set, agent_name, model_name}, _from, state) do
    :ets.insert(@table, {agent_name, model_name})
    Logger.debug("AgentModelPinning: set pin for #{agent_name} -> #{model_name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear, agent_name}, _from, state) do
    :ets.delete(@table, agent_name)
    Logger.debug("AgentModelPinning: cleared pin for #{agent_name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("AgentModelPinning received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_initial_pins do
    Application.get_env(:code_puppy_control, :agent_model_pins, [])
    |> Enum.to_list()
  end
end
