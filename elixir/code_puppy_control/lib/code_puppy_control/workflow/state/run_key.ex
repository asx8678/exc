defmodule CodePuppyControl.Workflow.State.RunKey do
  @moduledoc """
  Run key management for per-run isolation.

  Provides two mechanisms for identifying which run namespace a callback
  should target inside the shared Agent:

  1. **Process dictionary** — `set_run_key/1`, `get_run_key/0`, `clear_run_key/0`.
     Suitable for synchronous, single-process callers. NOT safe for async
     callbacks (Tasks don't inherit the process dictionary).

  2. **Explicit run key** — `derive_run_key/1` derives a run key from callback
     args (session_id, context map, etc.). This is the **safe** mechanism
     for async callbacks.

  3. **Session index** — the Agent maintains a `%{session_id => run_key}` index
     so that callbacks with a `session_id` can look up their run namespace
     without relying on the process dictionary.

  ## Migration note (code-puppy-ctj.3)

  Callback handlers now use `derive_run_key/1` instead of `set_run_key/1`.
  The process dictionary API is retained for direct callers but is deprecated
  for use inside callback handlers.
  """

  @default_run_key "default"

  @doc "Returns the default run key constant."
  @spec default_run_key() :: String.t()
  def default_run_key, do: @default_run_key

  # ── Process Dictionary API (legacy, for direct callers) ─────────────

  @doc """
  Returns the current run key for the calling process.

  Defaults to `"default"` if not set via `set_run_key/1`.
  """
  @spec get_run_key() :: String.t()
  def get_run_key do
    Process.get(:workflow_state_run_key, @default_run_key)
  end

  @doc """
  Sets the run key for the calling process.

  All subsequent calls from this process will target the given run's
  namespace. This is per-process (process dictionary) and does not
  affect other processes.
  """
  @spec set_run_key(String.t()) :: :ok
  def set_run_key(key) when is_binary(key) do
    Process.put(:workflow_state_run_key, key)
    :ok
  end

  @doc """
  Clears the run key for the calling process, reverting to `"default"`.
  """
  @spec clear_run_key() :: :ok
  def clear_run_key do
    Process.delete(:workflow_state_run_key)
    :ok
  end

  # ── Explicit Run Key Derivation (safe for async callbacks) ──────────

  @doc """
  Derives a run key from callback arguments without relying on the process
  dictionary.

  This is the safe way for async callback handlers to determine which
  run namespace they should target. The derivation strategy is:

  1. If `session_id` is a non-nil binary, use it directly as the run key.
  2. If `context` is a map containing `"session_id"` or `:session_id`,
     use that value as the run key.
  3. Otherwise, fall back to `"default"`.

  ## Examples

      iex> derive_run_key(session_id: "sess-123")
      "sess-123"

      iex> derive_run_key(context: %{"session_id" => "sess-abc"})
      "sess-abc"

      iex> derive_run_key([])
      "default"
  """
  @spec derive_run_key(keyword()) :: String.t()
  def derive_run_key(opts) when is_list(opts) do
    case Keyword.get(opts, :session_id) do
      sid when is_binary(sid) and sid != "" ->
        sid

      nil ->
        case Keyword.get(opts, :context) do
          %{session_id: sid} when is_binary(sid) -> sid
          %{"session_id" => sid} when is_binary(sid) -> sid
          _ -> @default_run_key
        end
    end
  end

  # ── Session Index (Agent-stored mapping) ─────────────────────────────

  @doc """
  Registers a session_id → run_key mapping in the Agent's session index.

  Called by `_on_agent_run_start` so that later callbacks (e.g.
  `_on_agent_run_end`) can look up the run key from the session_id alone.
  """
  @spec register_session(String.t(), String.t()) :: :ok
  def register_session(session_id, run_key) when is_binary(session_id) and is_binary(run_key) do
    agent_name = CodePuppyControl.Workflow.State

    Agent.update(agent_name, fn state ->
      index = Map.get(state, :session_index, %{})
      Map.put(state, :session_index, Map.put(index, session_id, run_key))
    end)
  end

  @doc """
  Looks up the run key for a session_id from the Agent's session index.

  Returns `{:ok, run_key}` if found, `:error` otherwise.
  """
  @spec lookup_session(String.t()) :: {:ok, String.t()} | :error
  def lookup_session(session_id) when is_binary(session_id) do
    agent_name = CodePuppyControl.Workflow.State

    Agent.get(agent_name, fn state ->
      index = Map.get(state, :session_index, %{})
      Map.fetch(index, session_id)
    end)
  end

  @doc """
  Removes a session_id from the Agent's session index.

  Called by `_on_agent_run_end` for cleanup.
  """
  @spec unregister_session(String.t()) :: :ok
  def unregister_session(session_id) when is_binary(session_id) do
    agent_name = CodePuppyControl.Workflow.State

    Agent.update(agent_name, fn state ->
      index = Map.get(state, :session_index, %{})
      Map.put(state, :session_index, Map.delete(index, session_id))
    end)
  end
end
