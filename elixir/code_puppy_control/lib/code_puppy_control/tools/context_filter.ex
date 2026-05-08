defmodule CodePuppyControl.Tools.ContextFilter do
  @moduledoc """
  Context filtering for sub-agent invocations.

  This module removes parent-specific state keys before passing context
  to a sub-agent. Prevents accidental state leakage from parent to sub-agent.

  ## Excluded Keys

  The following keys are filtered out:
  - Session-specific keys:
    - `parent_session_id`
    - `agent_session_id`
    - `session_history`
  - Previous tool results:
    - `previous_tool_results`
    - `tool_call_history`
    - `tool_outputs`
  - Internal state keys:
    - `_private_state`
    - `_internal_metadata`
  - Callback/plugin state:
    - `callback_registry`
    - `hook_state`
  - UI/rendering state:
    - `render_context`
    - `console_state`

  ## Usage

  Call `filter_context/1` before passing context to a sub-agent:

      parent_context = %{"session_id" => "abc", "tool_outputs" => [...], "user_prompt" => "hi"}
      child_context = ContextFilter.filter_context(parent_context)
      # child_context has "tool_outputs" removed but "user_prompt" preserved

  Based on deepagents' _EXCLUDED_STATE_KEYS pattern.
  """

  @typedoc "Context dictionary"
  @type context :: map() | nil

  # Keys that should NOT propagate from parent agent to sub-agent
  # These are either session-specific, parent-private, or would confuse the sub-agent
  @excluded_keys MapSet.new([
                   # Session-specific keys that only make sense for the parent
                   "parent_session_id",
                   "agent_session_id",
                   "session_history",
                   # Previous tool results that would clutter the sub-agent's view
                   "previous_tool_results",
                   "tool_call_history",
                   "tool_outputs",
                   # Internal state keys
                   "_private_state",
                   "_internal_metadata",
                   # Callback/plugin state that shouldn't leak
                   "callback_registry",
                   "hook_state",
                   # UI/rendering state
                   "render_context",
                   "console_state"
                 ])

  @doc """
  Filters parent-specific state keys from a context before passing to sub-agent.

  ## Parameters
  - `context`: The parent agent context dict, or nil

  ## Returns
  - A new map with excluded keys removed
  - Empty map if context is nil

  ## Examples
      iex> parent = %{"session_id" => "abc", "tool_outputs" => [...], "user_prompt" => "hi"}
      iex> child = ContextFilter.filter_context(parent)
      iex> Map.has_key?(child, "tool_outputs")
      false
      iex> Map.get(child, "user_prompt")
      "hi"

      iex> ContextFilter.filter_context(nil)
      %{}
  """
  @spec filter_context(context()) :: map()
  def filter_context(nil), do: %{}

  def filter_context(context) when is_map(context) do
    Enum.reject(context, fn {key, _value} ->
      MapSet.member?(@excluded_keys, to_string(key))
    end)
    |> Map.new()
  end

  def filter_context(_), do: %{}

  @doc """
  Returns the set of excluded keys.

  Useful for debugging or introspection.
  """
  @spec excluded_keys() :: MapSet.t(String.t())
  def excluded_keys do
    @excluded_keys
  end

  @doc """
  Checks if a specific key would be excluded.

  ## Parameters
  - `key`: The key to check

  ## Returns
  - `true` if the key is in the exclusion list
  - `false` otherwise
  """
  @spec excluded?(String.t() | atom()) :: boolean()
  def excluded?(key) when is_binary(key) do
    MapSet.member?(@excluded_keys, key)
  end

  def excluded?(key) when is_atom(key) do
    MapSet.member?(@excluded_keys, Atom.to_string(key))
  end

  @doc """
  Filters with custom excluded keys.

  ## Parameters
  - `context`: The context to filter
  - `custom_excluded`: Additional keys to exclude (besides defaults)

  ## Returns
  - Filtered context map
  """
  @spec filter_context_with_custom(context(), list(String.t() | atom())) :: map()
  def filter_context_with_custom(context, custom_excluded) when is_list(custom_excluded) do
    custom_set = MapSet.new(custom_excluded, &to_string/1)

    context
    |> filter_context()
    |> Enum.reject(fn {key, _value} ->
      MapSet.member?(custom_set, to_string(key))
    end)
    |> Map.new()
  end
end
