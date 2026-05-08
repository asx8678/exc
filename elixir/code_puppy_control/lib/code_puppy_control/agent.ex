defmodule CodePuppyControl.Agent do
  @moduledoc """
  Agent runtime for Code Puppy.

  This namespace contains the Elixir-native agent runtime that replaces
  pydantic-ai's Agent.run loop. The design is OTP-idiomatic:

  - **Agent.Behaviour** — The contract every agent module implements
  - **Agent.Turn** — Pure state machine for one LLM call + tool dispatch cycle
  - **Agent.Loop** — GenServer that drives turns until done
  - **Agent.Events** — Structured event types for UI/monitoring
  - **Agent.LLM** — Behaviour for LLM client (placeholder until )
  - **Agent.ToolCallTracker** — Tool call ID tracking and pruning
  - **Agent.MessageProcessor** — Message history filtering, dedup, truncation
  - **Agent.BudgetEnforcer** — Token budget and context window checks
  - **Agent.Lifecycle** — Model resolution, prompt assembly, MCP loading

  ## Quick Start

      defmodule MyApp.Agents.Echo do
        @behaviour CodePuppyControl.Agent.Behaviour

        @impl true
        def name, do: :echo

        @impl true
        def system_prompt(_ctx), do: "You are a helpful assistant."

        @impl true
        def allowed_tools, do: []

        @impl true
        def model_preference, do: "claude-sonnet-4-20250514"
      end

      # Start and run
      {:ok, pid} = Agent.Loop.start_link(MyApp.Agents.Echo, messages,
        run_id: "run-1",
        llm_module: MyMockLLM
      )

      :ok = Agent.Loop.run_until_done(pid)

  ## Supervision

  Agent loops are supervised under the existing `CodePuppyControl.Run.Supervisor`.
  No additional supervisor is needed — integration over duplication.
  """

  alias CodePuppyControl.Agent.Loop

  @doc """
  Starts an agent run and blocks until completion.

  This is the high-level API for running an agent. Internally starts a
  Loop GenServer under Run.Supervisor and calls `run_until_done/2`.

  ## Options

    * `:run_id` — Custom run ID (default: auto-generated)
    * `:session_id` — Session identifier for event routing
    * `:max_turns` — Maximum turns before stopping (default: 25)
    * `:llm_module` — LLM module to use (default: `Agent.LLM`)
    * `:metadata` — Additional metadata map
    * `:timeout` — Overall timeout in ms (default: `:infinity`)

  ## Returns

    * `:ok` — Run completed successfully
    * `{:error, reason}` — Run failed
  """
  @spec run(module(), [map()], keyword()) :: :ok | {:error, term()}
  def run(agent_module, messages, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, Loop.generate_run_id())
    timeout = Keyword.get(opts, :timeout, :infinity)
    loop_opts = Keyword.take(opts, [:session_id, :max_turns, :llm_module, :metadata, :run_id])

    child_spec = %{
      id: {Loop, run_id},
      start:
        {Loop, :start_link, [agent_module, messages, Keyword.put(loop_opts, :run_id, run_id)]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(CodePuppyControl.Run.Supervisor, child_spec) do
      {:ok, pid} ->
        result = Loop.run_until_done(pid, timeout)
        DynamicSupervisor.terminate_child(CodePuppyControl.Run.Supervisor, pid)
        result

      {:ok, pid, _info} ->
        result = Loop.run_until_done(pid, timeout)
        DynamicSupervisor.terminate_child(CodePuppyControl.Run.Supervisor, pid)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end
end
