defmodule CodePuppyControl.Callbacks.Hooks do
  @moduledoc """
  Declares all known callback hooks with their signatures and merge semantics.

  Each hook is defined with:
  - `arity` — expected number of arguments (excluding the hook name itself)
  - `merge` — how multiple callback results are combined:
    - `:noop` — results are collected as-is (no merging)
    - `:concat_str` — string results concatenated with newlines
    - `:extend_list` — list results flattened into one list
    - `:update_map` — map results deep-merged (later wins on conflict)
    - `:or_bool` — boolean results OR'd together (any true wins)
  - `async` — whether the hook supports concurrent execution
  - `description` — human-readable purpose

  Hooks are ported from the Python `code_puppy/callbacks.py` PhaseType definitions.
  """

  @type hook_config :: %{
          arity: non_neg_integer(),
          merge: :noop | :concat_str | :extend_list | :update_map | :or_bool,
          async: boolean(),
          description: String.t()
        }

  @hooks %{
    startup: %{
      arity: 0,
      merge: :noop,
      async: false,
      description: "Called once at application boot"
    },
    shutdown: %{
      arity: 0,
      merge: :noop,
      async: false,
      description: "Called on graceful application shutdown"
    },
    invoke_agent: %{
      arity: 1,
      merge: :noop,
      async: true,
      description: "Triggered when a sub-agent is invoked"
    },
    agent_exception: %{
      arity: 2,
      merge: :noop,
      async: true,
      description: "Triggered on unhandled agent error"
    },
    version_check: %{
      arity: 1,
      merge: :noop,
      async: true,
      description: "Check for version updates"
    },
    edit_file: %{
      arity: 1,
      merge: :noop,
      async: false,
      description: "Observer for file edit operations"
    },
    create_file: %{
      arity: 1,
      merge: :noop,
      async: false,
      description: "Observer for file creation operations"
    },
    replace_in_file: %{
      arity: 1,
      merge: :noop,
      async: false,
      description: "Observer for file content replacement"
    },
    delete_snippet: %{
      arity: 1,
      merge: :noop,
      async: false,
      description: "Observer for snippet deletion"
    },
    delete_file: %{
      arity: 1,
      merge: :noop,
      async: false,
      description: "Observer for file deletion"
    },
    run_shell_command: %{
      arity: 3,
      merge: :noop,
      async: true,
      description: "Security hook for shell command execution (fail-closed)"
    },
    load_model_config: %{
      arity: 2,
      merge: :update_map,
      async: false,
      description: "Plugin-provided model config patches"
    },
    load_models_config: %{
      arity: 0,
      merge: :update_map,
      async: false,
      description: "Plugin-provided model configurations (maps deep-merged, later wins)"
    },
    load_prompt: %{
      arity: 0,
      merge: :concat_str,
      async: false,
      description: "Additional system prompt content"
    },
    agent_reload: %{
      arity: 1,
      merge: :noop,
      async: false,
      description: "Agent hot-reload trigger"
    },
    custom_command: %{
      arity: 2,
      merge: :noop,
      async: false,
      description: "Handle custom slash commands"
    },
    custom_command_help: %{
      arity: 0,
      merge: :extend_list,
      async: false,
      description: "Collect custom command help entries"
    },
    file_permission: %{
      arity: 6,
      merge: :or_bool,
      async: true,
      description: "Security hook for file operations (fail-closed)"
    },
    pre_tool_call: %{
      arity: 3,
      merge: :noop,
      async: true,
      description: "Inspect/modify tool calls before execution"
    },
    post_tool_call: %{
      arity: 5,
      merge: :noop,
      async: true,
      description: "Inspect tool results after execution"
    },
    stream_event: %{
      arity: 3,
      merge: :noop,
      async: true,
      description: "React to streaming events in real-time"
    },
    register_tools: %{
      arity: 0,
      merge: :extend_list,
      async: false,
      description: "Collect custom tool registrations"
    },
    register_agents: %{
      arity: 0,
      merge: :extend_list,
      async: false,
      description: "Collect custom agent registrations"
    },
    register_model_type: %{
      arity: 0,
      merge: :extend_list,
      async: false,
      description: "Collect custom model type registrations"
    },
    get_model_system_prompt: %{
      arity: 3,
      merge: :noop,
      async: false,
      description: "Custom system prompts for specific model types (chained)"
    },
    agent_run_start: %{
      arity: 3,
      merge: :noop,
      async: true,
      description: "Triggered when an agent run starts"
    },
    agent_run_end: %{
      arity: 7,
      merge: :noop,
      async: true,
      description: "Triggered when an agent run ends"
    },
    register_mcp_catalog_servers: %{
      arity: 0,
      merge: :extend_list,
      async: false,
      description: "Register additional MCP catalog servers"
    },
    register_browser_types: %{
      arity: 0,
      merge: :extend_list,
      async: false,
      description: "Register custom browser type providers"
    },
    get_motd: %{
      arity: 0,
      merge: :noop,
      async: false,
      description: "Get custom MOTD content (returns tuple {msg, version} or nil)"
    },
    register_model_providers: %{
      arity: 0,
      merge: :extend_list,
      async: false,
      description: "Register custom model providers"
    },
    message_history_processor_start: %{
      arity: 4,
      merge: :noop,
      async: true,
      description: "Before message history processing"
    },
    message_history_processor_end: %{
      arity: 5,
      merge: :noop,
      async: true,
      description: "After message history processing"
    }
  }

  @doc """
  Returns the full hooks configuration map.
  """
  @spec all() :: %{atom() => hook_config()}
  def all, do: @hooks

  @doc """
  Returns the configuration for a specific hook, or `:error` if not found.
  """
  @spec get(atom()) :: {:ok, hook_config()} | :error
  def get(hook_name) when is_atom(hook_name) do
    case Map.fetch(@hooks, hook_name) do
      {:ok, config} -> {:ok, config}
      :error -> :error
    end
  end

  @doc """
  Returns all registered hook names as a sorted list.
  """
  @spec names() :: [atom()]
  def names do
    @hooks |> Map.keys() |> Enum.sort()
  end

  @doc """
  Returns the merge strategy for a hook.
  """
  @spec merge_type(atom()) :: :noop | :concat_str | :extend_list | :update_map | :or_bool
  def merge_type(hook_name) when is_atom(hook_name) do
    case Map.fetch(@hooks, hook_name) do
      {:ok, config} -> config.merge
      :error -> :noop
    end
  end

  @doc """
  Returns true if the hook supports async/concurrent execution.
  """
  @spec async?(atom()) :: boolean()
  def async?(hook_name) when is_atom(hook_name) do
    case Map.fetch(@hooks, hook_name) do
      {:ok, config} -> config.async
      :error -> false
    end
  end

  @doc """
  Returns the expected arity for a hook.
  """
  @spec arity(atom()) :: non_neg_integer()
  def arity(hook_name) when is_atom(hook_name) do
    case Map.fetch(@hooks, hook_name) do
      {:ok, config} -> config.arity
      :error -> 0
    end
  end

  @doc """
  Validates that a hook name is known.
  """
  @spec valid?(atom()) :: boolean()
  def valid?(hook_name) when is_atom(hook_name) do
    Map.has_key?(@hooks, hook_name)
  end
end
