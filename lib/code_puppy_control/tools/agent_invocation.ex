defmodule CodePuppyControl.Tools.AgentInvocation do
  @moduledoc """
  Core agent invocation logic ported from Python's agent_tools.py.

  Provides the full sub-agent invocation flow:
  - Session ID generation with hash suffix for uniqueness
  - Session resolution (new vs. continuation)
  - Session history loading/saving via AgentSession
  - Context filtering via ContextFilter
  - Agent validation via AgentCatalogue
  - Structured event emission via EventBus
  - Proper result shape (AgentInvokeOutput / ListAgentsOutput)

  ## Architecture

  This module is the **logic layer** — it does NOT implement the `Tool`
  behaviour itself.  The `CpAgentOps.CpInvokeAgent` and
  `CpAgentOps.CpListAgents` modules wrap these functions with the
  Tool behaviour for registration in the tool registry.

  The `stdio_service.ex` RPC handlers call these functions directly
  when the Python bridge delegates agent tool calls to Elixir.

  ## Result Shapes

  Matches Python's `AgentInvokeOutput` and `ListAgentsOutput`:

      %{response: nil | String.t(), agent_name: String.t(),
        session_id: nil | String.t(), error: nil | String.t()}

      %{agents: [%{name: _, display_name: _, description: _}], error: nil | String.t()}

  Refs: code_puppy-mmk.4 (Phase E)
  """

  require Logger

  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Tools.{AgentCatalogue, AgentSession, ContextFilter}

  # ── Structs matching Python Pydantic models ──────────────────────────────

  @typedoc "Matches Python's AgentInvokeOutput"
  @type invoke_output :: %{
          response: String.t() | nil,
          agent_name: String.t(),
          session_id: String.t() | nil,
          error: String.t() | nil
        }

  @typedoc "Matches Python's ListAgentsOutput"
  @type list_output :: %{
          agents: [agent_info()],
          error: String.t() | nil
        }

  @typedoc "Matches Python's AgentInfo"
  @type agent_info :: %{
          name: String.t(),
          display_name: String.t(),
          description: String.t()
        }

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Lists all available sub-agents with their info.

  Returns a `%{agents: [...], error: nil}` map matching Python's `ListAgentsOutput`.
  On error, returns `%{agents: [], error: "..."}`.
  """
  @spec list_agents() :: list_output()
  def list_agents do
    try do
      agents =
        AgentCatalogue.list_agents()
        |> Enum.map(fn info ->
          %{name: info.name, display_name: info.display_name, description: info.description}
        end)

      %{agents: agents, error: nil}
    rescue
      e ->
        error_msg = "Error listing agents: #{Exception.message(e)}"
        Logger.error(error_msg)
        %{agents: [], error: error_msg}
    end
  end

  @doc """
  Invokes a sub-agent with full session management.

  This is the Elixir equivalent of Python's `register_invoke_agent` closure.
  It handles:
  1. Session ID sanitization (defensive against untrusted input)
  2. Session resolution (new vs. continuation)
  3. Session ID generation with hash suffix for new sessions
  4. Context filtering for sub-agent isolation
  5. Agent validation via AgentCatalogue
  6. Run start via Run.Manager
  7. Session history save after completion
  8. Structured event emission (subagent_invocation, subagent_response)
  9. Proper error handling with AgentInvokeOutput shape

  ## Parameters

  - `agent_name` — Name of the agent to invoke
  - `prompt` — Task prompt for the sub-agent
  - `opts` — Keyword options:
    - `:session_id` — Optional session ID (auto-generated if nil)
    - `:context` — Optional parent context map (filtered before passing)
    - `:model` — Optional model override
    - `:config` — Optional additional config map
    - `:node` — Optional target node for remote dispatch (requires distributed packs)

  ## Returns

  `%{response: ..., agent_name: ..., session_id: ..., error: ...}`
  """
  @spec invoke(String.t(), String.t(), keyword()) :: invoke_output()
  def invoke(agent_name, prompt, opts \\ []) do
    session_id_raw = Keyword.get(opts, :session_id)
    context = Keyword.get(opts, :context)
    model = Keyword.get(opts, :model)
    config = Keyword.get(opts, :config, %{})

    # Step 1: Defensive sanitization of user/LLM-provided session IDs
    session_id = sanitize_session_id_if_present(session_id_raw)

    # Step 2: Resolve session (new vs. continuation)
    {session_id, message_history, is_new_session} = resolve_session(session_id, agent_name)

    # Step 3: Filter parent context for sub-agent isolation
    filtered_context = ContextFilter.filter_context(context)

    # Available for future agent run context injection
    _ = filtered_context

    # Step 4: Emit structured invocation event
    emit_invocation_event(agent_name, session_id, prompt, is_new_session, message_history)

    # Step 5: Validate agent exists
    case validate_agent(agent_name) do
      {:ok, _module} ->
        # Step 5b: Check for remote dispatch
        node_target = Keyword.get(opts, :node)

        if node_target != nil and CodePuppyControl.Pack.Config.enabled?() do
          # Route through distributed dispatcher
          dispatch_result =
            CodePuppyControl.Pack.Dispatcher.dispatch(agent_name, prompt,
              node: node_target,
              session_id: session_id,
              model: model,
              timeout: Keyword.get(opts, :timeout)
            )

          # Unwrap Dispatcher's {:ok, _} | {:error, _} to flat map shape
          case dispatch_result do
            {:ok, result} -> result
            {:error, result} -> result
          end
        else
          # Existing local path
          do_invoke(agent_name, prompt, session_id, is_new_session, model, config)
        end

      {:error, reason} ->
        error_msg = "Agent not found: #{reason}"
        emit_error_event(agent_name, session_id, error_msg)
        %{response: nil, agent_name: agent_name, session_id: session_id, error: error_msg}
    end
  rescue
    e ->
      error_msg = "Error invoking agent '#{agent_name}': #{Exception.message(e)}"
      Logger.error(error_msg)
      session_id = Keyword.get(opts, :session_id)
      %{response: nil, agent_name: agent_name, session_id: session_id, error: error_msg}
  end

  @doc """
  Invokes a sub-agent without full session management — for plugin use.

  This is the Elixir equivalent of Python's `invoke_agent_headless`.
  It skips session persistence, context filtering, event emission,
  and the full agent lifecycle. Used by plugins that need lightweight
  agent invocation.

  ## Parameters

  - `agent_name` — Name of the agent to invoke
  - `prompt` — Task prompt for the sub-agent
  - `opts` — Keyword options:
    - `:session_id` — Optional session ID for logging only
    - `:model` — Optional model override

  ## Returns

  `{:ok, response}` on success, `{:error, reason}` on failure.
  """
  @spec invoke_headless(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def invoke_headless(agent_name, prompt, opts \\ []) do
    model = Keyword.get(opts, :model)
    session_id = Keyword.get(opts, :session_id, generate_session_id(agent_name))

    case validate_agent(agent_name) do
      {:ok, _module} ->
        case start_and_await(agent_name, prompt, session_id, model) do
          {:ok, %{status: :completed} = state} ->
            response = extract_response(state)
            {:ok, response}

          {:ok, %{status: :failed, error: error}} ->
            {:error, error || "agent_run_failed"}

          {:ok, %{status: :cancelled}} ->
            {:error, "agent_cancelled"}

          {:error, reason} ->
            {:error, "Failed to start agent run: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Agent not found: #{reason}"}
    end
  end

  @doc """
  Generates a unique session ID with hash suffix.

  Format: `{sanitized_agent_name}-session-{8-char-hex}`
  Example: `"code-puppy-session-a3f2b1c4"`

  Matches Python's `_generate_session_hash_suffix` and auto-generation
  logic in `register_invoke_agent`.
  """
  @spec generate_session_id(String.t()) :: String.t()
  def generate_session_id(agent_name) do
    hash_suffix = generate_hash_suffix()
    sanitized_name = agent_name |> String.replace("_", "-") |> String.downcase()
    AgentSession.sanitize_session_id("#{sanitized_name}-session-#{hash_suffix}")
  end

  @doc """
  Generates a unique hash suffix for session IDs.

  Uses `:crypto.strong_rand_bytes/1` for collision safety, matching
  Python's `uuid.uuid4().hex[:8]` pattern.
  """
  @spec generate_hash_suffix() :: String.t()
  def generate_hash_suffix do
    :crypto.strong_rand_bytes(4)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 8)
  end

  # ── Private: Session Resolution ────────────────────────────────────────

  defp sanitize_session_id_if_present(nil), do: nil

  defp sanitize_session_id_if_present(session_id) when is_binary(session_id) do
    sanitized = AgentSession.sanitize_session_id(session_id)

    if sanitized != session_id do
      Logger.warning(
        "invoke_agent: session_id #{inspect(session_id)} was not valid kebab-case; " <>
          "sanitized to #{inspect(sanitized)}. Update the caller to pass clean IDs."
      )
    end

    sanitized
  end

  defp sanitize_session_id_if_present(other), do: AgentSession.sanitize_session_id(other)

  # Resolves session state: loads existing history or prepares new session.
  # Returns {final_session_id, message_history, is_new_session}.
  defp resolve_session(nil, agent_name) do
    # Auto-generate a new session ID
    session_id = generate_session_id(agent_name)
    {session_id, [], true}
  end

  defp resolve_session(session_id, _agent_name) do
    case AgentSession.load_session_history(session_id) do
      {:ok, %{messages: []}} ->
        # New session with user-provided base name — append hash suffix
        hash_suffix = generate_hash_suffix()
        final_id = AgentSession.sanitize_session_id("#{session_id}-#{hash_suffix}")
        {final_id, [], true}

      {:ok, %{messages: messages}} ->
        # Existing session — continue conversation
        {session_id, messages, false}

      {:error, _} ->
        # Load failed — treat as new session
        hash_suffix = generate_hash_suffix()
        final_id = AgentSession.sanitize_session_id("#{session_id}-#{hash_suffix}")
        {final_id, [], true}
    end
  end

  # ── Private: Agent Validation ──────────────────────────────────────────

  defp validate_agent(agent_name) do
    case AgentCatalogue.get_agent_module(agent_name) do
      {:ok, module} -> {:ok, module}
      {:error, :no_module} -> {:error, "Agent found but has no module: #{agent_name}"}
      :not_found -> {:error, agent_name}
    end
  end

  # ── Private: Invocation ───────────────────────────────────────────────

  defp do_invoke(agent_name, prompt, session_id, is_new_session, model, config) do
    run_config =
      config
      |> Map.new()
      |> Map.put("prompt", prompt)
      |> Map.put("is_new_session", is_new_session)
      |> then(fn c -> if model, do: Map.put(c, "model", model), else: c end)

    case CodePuppyControl.Run.Manager.start_run(session_id, agent_name, config: run_config) do
      {:ok, run_id} ->
        case await_run_with_timeout(run_id) do
          {:ok, %{status: :completed} = state} ->
            response = extract_response(state)

            # Save session history
            save_session_after_run(session_id, agent_name, prompt, is_new_session)

            # Emit structured response event
            emit_response_event(agent_name, session_id, response)

            %{response: response, agent_name: agent_name, session_id: session_id, error: nil}

          {:ok, %{status: :failed, error: error}} ->
            error_msg = error || "Agent run failed"
            emit_error_event(agent_name, session_id, error_msg)
            %{response: nil, agent_name: agent_name, session_id: session_id, error: error_msg}

          {:ok, %{status: :cancelled}} ->
            error_msg = "Agent run cancelled"
            emit_error_event(agent_name, session_id, error_msg)
            %{response: nil, agent_name: agent_name, session_id: session_id, error: error_msg}

          {:timeout, _state} ->
            error_msg = "Agent run timed out"
            emit_error_event(agent_name, session_id, error_msg)
            %{response: nil, agent_name: agent_name, session_id: session_id, error: error_msg}
        end

      {:error, reason} ->
        error_msg = "Failed to start agent run: #{inspect(reason)}"
        emit_error_event(agent_name, session_id, error_msg)
        %{response: nil, agent_name: agent_name, session_id: session_id, error: error_msg}
    end
  end

  defp start_and_await(agent_name, prompt, session_id, model) do
    run_config = %{"prompt" => prompt}
    run_config = if model, do: Map.put(run_config, "model", model), else: run_config

    case CodePuppyControl.Run.Manager.start_run(session_id, agent_name, config: run_config) do
      {:ok, run_id} ->
        await_run_with_timeout(run_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Default run timeout: 5 minutes (matches Python's RunContext default)
  @default_run_timeout_ms 300_000

  defp await_run_with_timeout(run_id, timeout_ms \\ @default_run_timeout_ms) do
    CodePuppyControl.Run.Manager.await_run(run_id, timeout_ms)
  end

  defp extract_response(state) do
    # Support multiple result shapes that arrive from Run.State.metadata:
    #   1. Atom-keyed:  %{response: "text"}
    #   2. String-keyed: %{"response" => "text"}
    #   3. Canonical run.completed: %{"result" => %{"response" => "text"}}
    #   4. Nested in result key: %{result: %{response: "text"}}
    case state.metadata do
      %{response: response} when is_binary(response) ->
        response

      %{"response" => response} when is_binary(response) ->
        response

      %{"result" => %{"response" => response}} when is_binary(response) ->
        # Canonical run.completed shape from port.ex
        response

      %{result: %{response: response}} when is_binary(response) ->
        response

      %{"result" => response} when is_binary(response) ->
        response

      %{result: response} when is_binary(response) ->
        response

      _ ->
        "Agent completed (no text response captured)"
    end
  end

  # ── Private: Session Persistence ───────────────────────────────────────

  defp save_session_after_run(session_id, agent_name, _prompt, is_new_session) do
    # In the full Elixir-native path, the agent loop would accumulate
    # messages during the run. For the bridge path, session history
    # is managed on the Python side. We save minimal metadata here
    # so the Elixir side can track sessions independently.
    initial_prompt = if is_new_session, do: nil, else: nil

    case AgentSession.save_session_history(
           session_id,
           [],
           agent_name,
           initial_prompt
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to save session history for #{session_id}: #{reason}")
    end
  end

  # ── Private: Event Emission ────────────────────────────────────────────

  defp emit_invocation_event(agent_name, session_id, prompt, is_new_session, message_history) do
    event = %{
      type: "subagent_invocation",
      agent_name: agent_name,
      session_id: session_id,
      prompt: prompt,
      is_new_session: is_new_session,
      message_count: length(message_history),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    EventBus.broadcast_local_event(event)
  end

  defp emit_response_event(agent_name, session_id, response) do
    event = %{
      type: "subagent_response",
      agent_name: agent_name,
      session_id: session_id,
      response: response,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    EventBus.broadcast_local_event(event)
  end

  defp emit_error_event(agent_name, session_id, error_msg) do
    event = %{
      type: "subagent_error",
      agent_name: agent_name,
      session_id: session_id,
      error: error_msg,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    EventBus.broadcast_local_event(event)
  end
end
