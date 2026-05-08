defmodule CodePuppyControl.Tools.SubagentContext do
  @moduledoc """
  Sub-agent context management with process-based state tracking.

  Provides context-aware tracking of sub-agent execution state using
  Elixir's process dictionary (Process.put/get) for process-isolated state.

  ## Why Process Dictionary?

  Unlike Python's contextvars, Elixir processes are inherently isolated:
  - Each process gets its own state
  - Process dictionary is naturally process-local
  - No async context leaking between tasks
  - Clean lifecycle tied to process lifetime

  ## Tools Provided

  - `get_subagent_context` — Returns current sub-agent depth, name, and parent chain
  - `push_subagent_context` — Enter a sub-agent context (sets name and increments depth)
  - `pop_subagent_context` — Exit a sub-agent context (restores parent state)

  ## Usage

      # From agent loop, before invoking a sub-agent:
      Tool.Runner.invoke(:push_subagent_context, %{"agent_name" => "retriever"}, %{})

      # After sub-agent completes:
      Tool.Runner.invoke(:pop_subagent_context, %{}, %{})

      # Query current state:
      Tool.Runner.invoke(:get_subagent_context, %{}, %{})
  """

  require Logger

  alias CodePuppyControl.Tool.Registry

  # Process dictionary keys
  @depth_key :subagent_depth
  @name_key :subagent_name
  @stack_key :subagent_stack

  defmodule GetContext do
    @moduledoc "Returns current sub-agent context information."

    use CodePuppyControl.Tool

    @impl true
    def name, do: :get_subagent_context

    @impl true
    def description do
      "Get the current sub-agent context: depth, name, and parent chain. " <>
        "Returns depth=0 for the main agent."
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
      {:ok,
       %{
         depth: CodePuppyControl.Tools.SubagentContext.get_depth(),
         name: CodePuppyControl.Tools.SubagentContext.get_name(),
         is_subagent: CodePuppyControl.Tools.SubagentContext.is_subagent?(),
         parent_chain: CodePuppyControl.Tools.SubagentContext.get_parent_chain()
       }}
    end
  end

  defmodule PushContext do
    @moduledoc "Enter a sub-agent context."

    use CodePuppyControl.Tool

    @impl true
    def name, do: :push_subagent_context

    @impl true
    def description do
      "Push a sub-agent context: sets the current agent name and increments nesting depth."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "agent_name" => %{
            "type" => "string",
            "description" => "Name of the sub-agent being entered (e.g., 'retriever', 'coder')"
          }
        },
        "required" => ["agent_name"]
      }
    end

    @impl true
    def invoke(args, _context) do
      agent_name = Map.get(args, "agent_name", "")
      CodePuppyControl.Tools.SubagentContext.push(agent_name)

      {:ok,
       %{
         depth: CodePuppyControl.Tools.SubagentContext.get_depth(),
         name: agent_name,
         is_subagent: CodePuppyControl.Tools.SubagentContext.is_subagent?()
       }}
    end
  end

  defmodule PopContext do
    @moduledoc "Exit the current sub-agent context."

    use CodePuppyControl.Tool

    @impl true
    def name, do: :pop_subagent_context

    @impl true
    def description do
      "Pop the current sub-agent context: decrements nesting depth and restores parent name."
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
      case CodePuppyControl.Tools.SubagentContext.pop() do
        {:ok, %{depth: depth, name: name}} ->
          {:ok,
           %{
             depth: depth,
             name: name,
             is_subagent: CodePuppyControl.Tools.SubagentContext.is_subagent?()
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── State Management Functions ────────────────────────────────────────

  @doc "Push a new sub-agent context onto the stack."
  @spec push(String.t()) :: :ok
  def push(agent_name) when is_binary(agent_name) do
    current_depth = get_depth()
    current_name = get_name()

    # Push current state onto stack
    stack = get_stack()
    Process.put(@stack_key, [{current_name, current_depth} | stack])

    # Set new state
    Process.put(@depth_key, current_depth + 1)
    Process.put(@name_key, agent_name)

    :ok
  end

  @doc "Pop the current sub-agent context from the stack."
  @spec pop() :: {:ok, map()} | {:error, String.t()}
  def pop do
    stack = get_stack()

    case stack do
      [{parent_name, parent_depth} | rest] ->
        Process.put(@stack_key, rest)
        Process.put(@depth_key, parent_depth)
        Process.put(@name_key, parent_name)

        {:ok, %{depth: parent_depth, name: parent_name}}

      [] ->
        if get_depth() > 0 do
          # Stack is empty but depth > 0 — reset
          Process.put(@depth_key, 0)
          Process.put(@name_key, nil)
          {:ok, %{depth: 0, name: nil}}
        else
          {:error, "No sub-agent context to pop (already at depth 0)"}
        end
    end
  end

  @doc "Get the current sub-agent nesting depth."
  @spec get_depth() :: non_neg_integer()
  def get_depth, do: Process.get(@depth_key, 0)

  @doc "Get the current sub-agent name."
  @spec get_name() :: String.t() | nil
  def get_name, do: Process.get(@name_key)

  @doc "Check if currently executing in a sub-agent context."
  @spec is_subagent?() :: boolean()
  def is_subagent?, do: get_depth() > 0

  @doc "Get the parent chain as a list of agent names (most recent first)."
  @spec get_parent_chain() :: [String.t()]
  def get_parent_chain do
    get_stack()
    |> Enum.map(fn {name, _depth} -> name end)
    |> Enum.reject(&is_nil/1)
  end

  defp get_stack, do: Process.get(@stack_key, [])

  @doc """
  Registers all subagent context tools with the Tool Registry.
  """
  @spec register_all() :: {:ok, non_neg_integer()}
  def register_all do
    modules = [GetContext, PushContext, PopContext]

    Enum.reduce(modules, {:ok, 0}, fn module, {:ok, acc} ->
      case Registry.register(module) do
        :ok -> {:ok, acc + 1}
        {:error, _} -> {:ok, acc}
      end
    end)
  end
end
