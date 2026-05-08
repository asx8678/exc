defmodule CodePuppyControl.Plugins.AgentMemory do
  @moduledoc """
  Agent Memory plugin — persistent fact storage per agent.

  Extracts facts from conversations, detects correction/reinforcement/
  preference signals, and injects relevant memories into system prompts.

  Configuration (puppy.cfg):
    memory_enabled = false          # OPT-IN, default off
    memory_debounce_seconds = 30    # Write debounce window
    memory_max_facts = 50           # Max facts per agent
    memory_token_budget = 500       # Token budget for injection

  Ported from `code_puppy/plugins/agent_memory/`.
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Plugins.AgentMemory.{Config, Storage, Signals, Prompts, Commands}

  require Logger

  @impl true
  def name, do: "agent_memory"

  @impl true
  def description, do: "Persistent per-agent fact storage with signal detection"

  @impl true
  def register do
    Callbacks.register(:startup, &__MODULE__.on_startup/0)
    Callbacks.register(:shutdown, &__MODULE__.on_shutdown/0)
    Callbacks.register(:agent_run_end, &__MODULE__.on_agent_run_end/7)
    Callbacks.register(:get_model_system_prompt, &Prompts.on_get_model_system_prompt/3)
    Callbacks.register(:custom_command, &Commands.handle_command/2)
    Callbacks.register(:custom_command_help, &Commands.help_entries/0)
    :ok
  end

  @impl true
  def startup do
    config = Config.load()

    if config.enabled do
      Logger.info(
        "Agent Memory plugin activated (max_facts=#{config.max_facts}, token_budget=#{config.token_budget})"
      )
    else
      Logger.debug(
        "Agent Memory plugin loaded but disabled (set memory_enabled=true to activate)"
      )
    end

    :ok
  end

  @impl true
  def shutdown, do: :ok

  # ── Callback Implementations ────────────────────────────────────

  @doc false
  @spec on_startup() :: :ok
  def on_startup, do: startup()

  @doc false
  @spec on_shutdown() :: :ok
  def on_shutdown, do: :ok

  @doc false
  @spec on_agent_run_end(
          String.t(),
          String.t(),
          String.t() | nil,
          boolean(),
          term(),
          term(),
          term()
        ) ::
          :ok
  def on_agent_run_end(
        agent_name,
        _model_name,
        session_id,
        success,
        _error,
        _response_text,
        metadata
      ) do
    config = Config.load()

    if config.enabled and success do
      messages = extract_messages(metadata)

      if messages != [] do
        _count = Signals.apply_confidence_updates(agent_name, messages, session_id)
      end
    end

    :ok
  end

  # ── Public API ──────────────────────────────────────────────────

  @doc "Add a fact for an agent."
  @spec add_fact(String.t(), map()) :: :ok
  def add_fact(agent_name, fact) do
    fact = Map.put_new(fact, "created_at", DateTime.utc_now() |> DateTime.to_iso8601())
    Storage.add_fact(agent_name, fact)
  end

  @doc "Get all facts for an agent."
  @spec get_facts(String.t(), float()) :: [map()]
  def get_facts(agent_name, min_confidence \\ 0.0) do
    Storage.get_facts(agent_name, min_confidence)
  end

  @doc "Clear all facts for an agent."
  @spec clear(String.t()) :: :ok
  def clear(agent_name), do: Storage.clear(agent_name)

  # ── Private ─────────────────────────────────────────────────────

  defp extract_messages(nil), do: []

  defp extract_messages(metadata) when is_map(metadata) do
    Map.get(metadata, "message_history", Map.get(metadata, :message_history, []))
  end

  defp extract_messages(_), do: []
end
