defmodule CodePuppyControl.RuntimeState.Cache do
  @moduledoc """
  Cache getter/setter API for RuntimeState GenServer.

  These provide GenServer-mediated access to the ephemeral cache fields.
  They mirror the per-instance cache properties on Python's AgentRuntimeState
  but are stored globally in the RuntimeState singleton GenServer.

  All functions delegate to `CodePuppyControl.RuntimeState` GenServer calls/casts.

  ## Parity with Python

  The cache fields correspond to Python's `AgentRuntimeState` attributes:
  - `cached_system_prompt`    → `AgentRuntimeState.cached_system_prompt`
  - `cached_tool_defs`        → `AgentRuntimeState.cached_tool_defs`
  - `model_name_cache`        → `AgentRuntimeState.model_name_cache`
  - `delayed_compaction_requested` → `AgentRuntimeState.delayed_compaction_requested`
  - `tool_ids_cache`          → `AgentRuntimeState.tool_ids_cache`
  - `cached_context_overhead` → `AgentRuntimeState.cached_context_overhead`
  - `resolved_model_components_cache` → `AgentRuntimeState.resolved_model_components_cache`
  - `puppy_rules_cache`      → `AgentRuntimeState.puppy_rules`
  """

  alias CodePuppyControl.RuntimeState

  # ---------------------------------------------------------------------------
  # System Prompt Cache
  # ---------------------------------------------------------------------------

  @doc "Get the cached system prompt string, or nil if not yet computed."
  @spec get_cached_system_prompt() :: String.t() | nil
  def get_cached_system_prompt do
    GenServer.call(RuntimeState, :get_cached_system_prompt)
  end

  @doc "Set the cached system prompt string."
  @spec set_cached_system_prompt(String.t() | nil) :: :ok
  def set_cached_system_prompt(prompt) do
    GenServer.cast(RuntimeState, {:set_cached_system_prompt, prompt})
  end

  # ---------------------------------------------------------------------------
  # Tool Definitions Cache
  # ---------------------------------------------------------------------------

  @doc "Get the cached tool definitions list, or nil if not yet computed."
  @spec get_cached_tool_defs() :: list(map()) | nil
  def get_cached_tool_defs do
    GenServer.call(RuntimeState, :get_cached_tool_defs)
  end

  @doc "Set the cached tool definitions list."
  @spec set_cached_tool_defs(list(map()) | nil) :: :ok
  def set_cached_tool_defs(defs) do
    GenServer.cast(RuntimeState, {:set_cached_tool_defs, defs})
  end

  # ---------------------------------------------------------------------------
  # Model Name Cache
  # ---------------------------------------------------------------------------

  @doc "Get the cached model name, or nil if not yet resolved."
  @spec get_model_name_cache() :: String.t() | nil
  def get_model_name_cache do
    GenServer.call(RuntimeState, :get_model_name_cache)
  end

  @doc "Set the cached model name."
  @spec set_model_name_cache(String.t() | nil) :: :ok
  def set_model_name_cache(name) do
    GenServer.cast(RuntimeState, {:set_model_name_cache, name})
  end

  # ---------------------------------------------------------------------------
  # Delayed Compaction Flag
  # ---------------------------------------------------------------------------

  @doc "Get whether delayed compaction has been requested."
  @spec get_delayed_compaction_requested() :: boolean()
  def get_delayed_compaction_requested do
    GenServer.call(RuntimeState, :get_delayed_compaction_requested)
  end

  @doc "Set the delayed compaction requested flag."
  @spec set_delayed_compaction_requested(boolean()) :: :ok
  def set_delayed_compaction_requested(value) do
    GenServer.cast(RuntimeState, {:set_delayed_compaction_requested, value})
  end

  # ---------------------------------------------------------------------------
  # Tool IDs Cache
  # ---------------------------------------------------------------------------

  @doc "Get the per-invocation tool IDs cache."
  @spec get_tool_ids_cache() :: any()
  def get_tool_ids_cache do
    GenServer.call(RuntimeState, :get_tool_ids_cache)
  end

  @doc "Set the per-invocation tool IDs cache."
  @spec set_tool_ids_cache(any()) :: :ok
  def set_tool_ids_cache(cache) do
    GenServer.cast(RuntimeState, {:set_tool_ids_cache, cache})
  end

  # ---------------------------------------------------------------------------
  # Context Overhead Cache
  # ---------------------------------------------------------------------------

  @doc "Get the cached context overhead estimate, or nil if not yet computed."
  @spec get_cached_context_overhead() :: integer() | nil
  def get_cached_context_overhead do
    GenServer.call(RuntimeState, :get_cached_context_overhead)
  end

  @doc "Set the cached context overhead estimate."
  @spec set_cached_context_overhead(integer() | nil) :: :ok
  def set_cached_context_overhead(value) do
    GenServer.cast(RuntimeState, {:set_cached_context_overhead, value})
  end

  # ---------------------------------------------------------------------------
  # Resolved Model Components Cache
  # ---------------------------------------------------------------------------

  @doc "Get the resolved model components cache map, or nil if not yet computed."
  @spec get_resolved_model_components_cache() :: map() | nil
  def get_resolved_model_components_cache do
    GenServer.call(RuntimeState, :get_resolved_model_components_cache)
  end

  @doc "Set the resolved model components cache map."
  @spec set_resolved_model_components_cache(map() | nil) :: :ok
  def set_resolved_model_components_cache(cache) do
    GenServer.cast(RuntimeState, {:set_resolved_model_components_cache, cache})
  end

  # ---------------------------------------------------------------------------
  # Puppy Rules Cache (parity with Python AgentRuntimeState.puppy_rules)
  # ---------------------------------------------------------------------------

  @doc """
  Get the cached puppy rules content, or nil if not yet loaded.

  Mirrors Python's `AgentRuntimeState.puppy_rules` — the lazy-loaded
  content of AGENTS.md / puppy rules file, cached to avoid re-reading
  from disk on every token budget computation.
  """
  @spec get_puppy_rules_cache() :: String.t() | nil
  def get_puppy_rules_cache do
    GenServer.call(RuntimeState, :get_puppy_rules_cache)
  end

  @doc """
  Set the cached puppy rules content.

  Mirrors Python's `AgentRuntimeState.puppy_rules` setter.
  """
  @spec set_puppy_rules_cache(String.t() | nil) :: :ok
  def set_puppy_rules_cache(rules) do
    GenServer.cast(RuntimeState, {:set_puppy_rules_cache, rules})
  end
end
