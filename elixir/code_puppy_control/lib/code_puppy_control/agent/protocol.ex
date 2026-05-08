defprotocol CodePuppyControl.Agent.Protocol do
  @moduledoc """
  Runtime polymorphism protocol for agent dispatch.

  While `CodePuppyControl.Agent.Behaviour` defines a **compile-time contract**
  for agent *modules*, this protocol provides **runtime polymorphism** for
  any data type that can act as an agent.

  ## Built-in implementations

  - `Atom` — dispatches to module callbacks (`MyAgent.name()`)

  ## Extending the protocol

  You can implement the protocol for your own types:

      defimpl CodePuppyControl.Agent.Protocol, for: MyApp.AgentConfig do
        def name(%{name: n}), do: String.to_atom(n)
        def system_prompt(config, _context), do: config.prompt
        def allowed_tools(%{tools: t}), do: t
        def model_preference(%{model: m}), do: m
        def run(config, prompt, context) do
          # Custom execution logic
        end
      end
  """

  @fallback_to_any true

  @doc """
  Returns the agent name.
  """
  def name(agent)

  @doc """
  Returns the system prompt for the agent.
  """
  def system_prompt(agent, context)

  @doc """
  Returns the list of allowed tool names.
  """
  def allowed_tools(agent)

  @doc """
  Returns the preferred model name or pack tuple.
  """
  def model_preference(agent)

  @doc """
  Runs the agent with the given user prompt and context.
  """
  def run(agent, prompt, context)
end

# ── Atom implementation (module dispatch) ──────────────────────────────────────

defimpl CodePuppyControl.Agent.Protocol, for: Atom do
  def name(agent_module), do: agent_module.name()

  def system_prompt(agent_module, context),
    do: agent_module.system_prompt(context)

  def allowed_tools(agent_module), do: agent_module.allowed_tools()

  def model_preference(agent_module), do: agent_module.model_preference()

  def run(agent_module, prompt, context) do
    agent_module.run(prompt, context)
  end
end

# ── Any fallback ──────────────────────────────────────────────────────────────

defimpl CodePuppyControl.Agent.Protocol, for: Any do
  def name(value),
    do: raise(Protocol.UndefinedError, protocol: CodePuppyControl.Agent.Protocol, value: value)

  def system_prompt(value, _),
    do: raise(Protocol.UndefinedError, protocol: CodePuppyControl.Agent.Protocol, value: value)

  def allowed_tools(value),
    do: raise(Protocol.UndefinedError, protocol: CodePuppyControl.Agent.Protocol, value: value)

  def model_preference(value),
    do: raise(Protocol.UndefinedError, protocol: CodePuppyControl.Agent.Protocol, value: value)

  def run(value, _, _),
    do: raise(Protocol.UndefinedError, protocol: CodePuppyControl.Agent.Protocol, value: value)
end
