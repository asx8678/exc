defmodule CodePuppyControl.Workflow.State do
  @moduledoc """
  Structured workflow-state tracking for agent runs.

  Full port of Python `code_puppy/workflow_state.py`. Stores a set of
  active flags and optional metadata in an Agent so that multiple
  processes in the same BEAM node can query/mutate the state concurrently.

  ## Per-Run Isolation

  State is **keyed by run key** to prevent concurrent agent runs from
  clobbering each other's flags. Each run gets its own isolated namespace
  inside the Agent.

  There are two ways to specify the run key:

  1. **Process dictionary** — `set_run_key/1` sets the key for the current
     process. Suitable for synchronous callers. NOT safe for async callbacks
     because `Callbacks.trigger_async/2` spawns Tasks that don't inherit
     the process dictionary.

  2. **Explicit `run_key:` option** — All flag/metadata/counter operations
     accept an optional `run_key: key` keyword argument. This is the safe
     mechanism for async callbacks.

  The **default run key** is `"default"`. Legacy callers that do not set a
  run key continue to work against `"default"`, preserving backward compat.

  ## Architecture

  This module is a **public facade** that delegates to submodules:

  | Submodule | Responsibility |
  |-----------|---------------|
  | `Flags` | Flag definitions, resolution |
  | `RunKey` | Run key management, session index |
  | `Store` | Agent-backed flag/metadata/counter operations |
  | `PlanDetection` | Heuristic plan detection |
  | `CallbackHandlers` | Auto-set flags from callbacks |

  ## Quick start

      # Start in supervision tree
      {CodePuppyControl.Workflow.State, name: CodePuppyControl.Workflow.State}

      # Use the API (default run key)
      Workflow.State.set_flag(:did_generate_code)
      Workflow.State.has_flag?(:did_generate_code)  #=> true

      # Use with explicit run key (async-safe)
      Workflow.State.set_flag(:did_generate_code, run_key: "sess-123")
      Workflow.State.has_flag?(:did_generate_code, run_key: "sess-123")  #=> true

  ## Migration from Python `workflow_state.py`

  | Python Feature | Elixir Equivalent |
  |----------------|-------------------|
  | `WorkflowFlag` enum | `Flags.all_flags/0` |
  | `ContextVar` storage | Agent (named `__MODULE__`) + per-run key |
  | `set_flag(str)` | `resolve_flag/1` via `Flags` module |
  | `increment_counter/2` | `increment_counter/2` |
  | `detect_and_mark_plan_from_response/2` | `PlanDetection.detect_and_mark_plan_from_response/2` |
  | `register_callback_handlers()` | `CallbackHandlers.register_callback_handlers/0` |
  | `unregister_callback_handlers()` | `CallbackHandlers.unregister_callback_handlers/0` |
  | `did_make_api_call` flag | Added (was missing in old WorkflowState) |
  """

  alias CodePuppyControl.Workflow.State.{CallbackHandlers, Flags, PlanDetection, RunKey, Store}

  # ── Child Spec (supervision tree compatibility) ─────────────────────

  # We define child_spec explicitly so supervision trees can start the Store
  # process under this module's name.
  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Store, :start_link, [Keyword.put_new(opts, :name, __MODULE__)]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  # ── Re-export: Flag Definitions ─────────────────────────────────────

  @doc "Returns all known flag definitions as `[{atom, description}]`."
  @spec all_flags() :: [{atom(), String.t()}]
  defdelegate all_flags, to: Flags

  @doc "Returns all known flag name atoms."
  @spec flag_names() :: [atom()]
  defdelegate flag_names, to: Flags

  @doc "Checks whether `name` is a known flag atom."
  @spec known_flag?(atom()) :: boolean()
  defdelegate known_flag?(name), to: Flags

  @doc "Resolves a flag from atom or string to its canonical atom form."
  @spec resolve_flag(atom() | String.t()) :: {:ok, atom()} | {:error, :unknown_flag}
  defdelegate resolve_flag(name), to: Flags

  # ── Re-export: Run Key Management ───────────────────────────────────

  @doc "Returns the current run key for the calling process."
  @spec get_run_key() :: String.t()
  defdelegate get_run_key, to: RunKey

  @doc "Sets the run key for the calling process."
  @spec set_run_key(String.t()) :: :ok
  defdelegate set_run_key(key), to: RunKey

  @doc "Clears the run key for the calling process, reverting to `\"default\"`."
  @spec clear_run_key() :: :ok
  defdelegate clear_run_key, to: RunKey

  @doc "Returns all run keys currently stored in the Agent."
  @spec run_keys() :: [String.t()]
  defdelegate run_keys, to: Store

  @doc "Deletes a specific run key's state from the Agent."
  @spec delete_run(String.t()) :: :ok
  defdelegate delete_run(key), to: Store

  # ── Re-export: Agent Lifecycle ──────────────────────────────────────

  @doc "Starts the Workflow.State agent."
  @spec start_link(keyword()) :: Agent.on_start()
  defdelegate start_link(opts), to: Store

  # ── Re-export: State Access ─────────────────────────────────────────

  @doc "Returns the current workflow state for the calling process's run key."
  @spec get() :: map()
  def get, do: Store.get()

  @doc "Resets the workflow state for the calling process's run key."
  @spec reset() :: map()
  def reset, do: Store.reset()

  # ── Re-export: Flag Operations ──────────────────────────────────────

  @doc """
  Sets a flag (adds it to the active set).

  Accepts both atoms and strings. Unknown flags are ignored with a warning.

  ## Options

    * `:run_key` — Explicit run key (safe for async callbacks)
  """
  @spec set_flag(atom() | String.t()) :: :ok
  def set_flag(flag), do: Store.set_flag(flag)

  @spec set_flag(atom() | String.t(), keyword()) :: :ok
  def set_flag(flag, opts) when is_list(opts), do: Store.set_flag(flag, opts)

  @spec set_flag(atom() | String.t(), boolean()) :: :ok
  def set_flag(flag, true) when is_atom(flag) or is_binary(flag), do: Store.set_flag(flag, [])

  def set_flag(flag, false) when is_atom(flag) or is_binary(flag),
    do: Store.clear_flag(flag, [])

  @doc """
  Clears a flag (removes it from the active set). Unknown flags are ignored.
  """
  @spec clear_flag(atom() | String.t()) :: :ok
  def clear_flag(flag), do: Store.clear_flag(flag)

  @doc """
  Checks whether a flag is active.

  Accepts both atoms and strings. Returns `false` for unknown flags.
  """
  @spec has_flag?(atom() | String.t()) :: boolean()
  def has_flag?(flag), do: Store.has_flag?(flag)

  @spec has_flag?(atom() | String.t(), keyword()) :: boolean()
  def has_flag?(flag, opts) when is_list(opts), do: Store.has_flag?(flag, opts)

  # ── Re-export: Metadata Operations ──────────────────────────────────

  @doc "Stores a metadata key/value pair."
  @spec put_metadata(String.t(), any()) :: :ok
  def put_metadata(key, value), do: Store.put_metadata(key, value)

  @doc "Reads a metadata value, defaulting to `nil`."
  @spec get_metadata(String.t()) :: any()
  def get_metadata(key), do: Store.get_metadata(key, nil)

  @doc "Reads a metadata value, defaulting to `default`."
  @spec get_metadata(String.t(), any()) :: any()
  def get_metadata(key, default), do: Store.get_metadata(key, default)

  @doc "Returns a map of current metadata."
  @spec metadata() :: %{String.t() => any()}
  def metadata, do: Store.metadata()

  @doc "Increments a counter in metadata. Returns the new counter value."
  @spec increment_counter(String.t(), integer()) :: integer()
  def increment_counter(key, amount \\ 1), do: Store.increment_counter(key, amount)

  # ── Re-export: Introspection ───────────────────────────────────────

  @doc "Returns the count of active flags."
  @spec active_count() :: non_neg_integer()
  def active_count, do: Store.active_count()

  @doc "Generates a short human-readable summary of active flags."
  @spec summary() :: String.t()
  def summary, do: Store.summary()

  @doc "Converts the current state to a map for serialization."
  @spec to_map() :: map()
  def to_map, do: Store.to_map()

  # ── Re-export: Plan Detection ───────────────────────────────────────

  @doc "Detect plan in response text and set DID_CREATE_PLAN flag if found."
  @spec detect_and_mark_plan_from_response(String.t(), keyword()) :: boolean()
  def detect_and_mark_plan_from_response(response_text, opts \\ []) do
    PlanDetection.detect_and_mark_plan_from_response(response_text, opts)
  end

  # ── Re-export: Callback Handlers ───────────────────────────────────

  # Keep legacy handler function names for backward compat (tests call
  # these directly). These delegate to the new CallbackHandlers module.

  @doc false
  def _on_delete_file(context), do: CallbackHandlers.on_delete_file(context)

  @doc false
  def _on_run_shell_command(context, command, cwd),
    do: CallbackHandlers.on_run_shell_command(context, command, cwd)

  @doc false
  def _on_agent_run_start(agent_name, model_name, session_id \\ nil),
    do: CallbackHandlers.on_agent_run_start(agent_name, model_name, session_id)

  @doc false
  def _on_agent_run_end(
        agent_name,
        model_name,
        session_id \\ nil,
        success \\ true,
        error \\ nil,
        response_text \\ nil,
        metadata \\ nil
      ),
      do:
        CallbackHandlers.on_agent_run_end(
          agent_name,
          model_name,
          session_id,
          success,
          error,
          response_text,
          metadata
        )

  @doc false
  def _on_pre_tool_call(tool_name, tool_args, context \\ nil),
    do: CallbackHandlers.on_pre_tool_call(tool_name, tool_args, context)

  @doc "Register workflow state callback handlers."
  @spec register_callback_handlers() :: :ok
  defdelegate register_callback_handlers, to: CallbackHandlers

  @doc "Unregister workflow state callback handlers."
  @spec unregister_callback_handlers() :: :ok
  defdelegate unregister_callback_handlers, to: CallbackHandlers

  # ── State Struct ────

  defstruct flags: MapSet.new(), metadata: %{}, start_time: nil

  @type t :: %__MODULE__{
          flags: MapSet.t(atom()),
          metadata: %{String.t() => any()},
          start_time: integer() | nil
        }

  @doc "Creates a fresh workflow state struct."
  @spec new() :: t()
  def new do
    %__MODULE__{start_time: System.system_time(:second)}
  end
end
