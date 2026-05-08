defmodule CodePuppyControl.Tools.CpAgentOps do
  @moduledoc """
  `:cp_`-prefixed Tool-behaviour wrappers for agent operations.

  These modules expose agent invocation and listing through the Tool
  behaviour so the CodePuppy agent can call `cp_invoke_agent` and
  `cp_list_agents` via the tool registry.

  Delegates to `CodePuppyControl.Tools.AgentInvocation` for core logic.
  Result shapes match Python's `AgentInvokeOutput` and `ListAgentsOutput`.

  Refs: code_puppy-mmk.4 (Phase E), code_puppy-4s8.7 (Phase C CI gate)
  """

  defmodule CpInvokeAgent do
    @moduledoc """
    Invokes a sub-agent for a specialized task.

    Delegates to `AgentInvocation.invoke/3` for the full invocation
    flow including session management, context filtering, and event emission.

    Returns `%{response: ..., agent_name: ..., session_id: ..., error: ...}`
    matching Python's `AgentInvokeOutput`.
    """

    use CodePuppyControl.Tool

    alias CodePuppyControl.Tools.AgentInvocation

    @impl true
    def name, do: :cp_invoke_agent

    @impl true
    def description do
      "Invoke a specialized sub-agent to handle a focused task. " <>
        "Use cp_list_agents to see available agents. " <>
        "Optionally provide a session_id to continue a previous conversation."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "agent_name" => %{
            "type" => "string",
            "description" => "Name of the agent to invoke"
          },
          "prompt" => %{
            "type" => "string",
            "description" => "Task description for the sub-agent"
          },
          "session_id" => %{
            "type" => "string",
            "description" =>
              "Optional session ID for continuing a conversation. " <>
                "Auto-generated with a unique hash suffix if omitted. " <>
                "Must be kebab-case (lowercase, hyphens only)."
          },
          "node" => %{
            "type" => "string",
            "description" =>
              "Optional target node for remote execution. " <>
                "Format: 'worker_name@hostname' (e.g., 'pup_builder@build-01'). " <>
                "Only used when distributed packs are enabled. " <>
                "If omitted, dispatches locally or auto-selects a worker."
          }
        },
        "required" => ["agent_name", "prompt"]
      }
    end

    @impl true
    def invoke(args, context) do
      agent_name = Map.get(args, "agent_name", "")
      prompt = Map.get(args, "prompt", "")
      session_id = Map.get(args, "session_id")

      # Extract node target for remote dispatch (distributed packs)
      node_target =
        case Map.get(args, "node") do
          nil -> nil
          "" -> nil
          node_str -> String.to_atom(node_str)
        end

      # Extract parent context from the tool invocation context
      # for sub-agent isolation filtering
      parent_context = extract_parent_context(context)

      result =
        AgentInvocation.invoke(agent_name, prompt,
          session_id: session_id,
          context: parent_context,
          node: node_target
        )

      # Convert to {:ok, ...} / {:error, ...} for Tool behaviour
      if result.error do
        {:error, result}
      else
        {:ok, result}
      end
    end

    # Extracts relevant context from the tool invocation context map.
    # The context map includes :run_id, :agent_module, :agent_session_id, etc.
    defp extract_parent_context(context) when is_map(context) do
      # Only pass string-keyed entries through the context filter
      context
      |> Enum.filter(fn
        {k, _} when is_binary(k) -> true
        _ -> false
      end)
      |> Map.new()
    end

    defp extract_parent_context(_), do: nil
  end

  defmodule CpListAgents do
    @moduledoc """
    Lists available sub-agents.

    Delegates to `AgentInvocation.list_agents/0`.
    Returns `%{agents: [...], error: nil}` matching Python's `ListAgentsOutput`.
    """

    use CodePuppyControl.Tool

    alias CodePuppyControl.Tools.AgentInvocation

    @impl true
    def name, do: :cp_list_agents

    @impl true
    def description do
      "List all available sub-agents that can be invoked " <>
        "for specialized tasks."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      }
    end

    @impl true
    def invoke(_args, _context) do
      result = AgentInvocation.list_agents()

      if result.error do
        {:error, result.error}
      else
        {:ok, result}
      end
    end
  end
end
