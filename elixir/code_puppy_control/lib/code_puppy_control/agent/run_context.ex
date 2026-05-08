defmodule CodePuppyControl.Agent.RunContext do
  @moduledoc """
  Tool dependency injection context, porting pydantic-ai's `RunContext` to Elixir.

  `RunContext` is the single struct passed to every tool invocation via the
  `CodePuppyControl.Tool` behaviour's `invoke/2` callback (as the second
  argument). It carries everything a tool needs to know about the current
  run: session identity, model, accumulated usage, dependency injection,
  retry state, and arbitrary metadata.

  ## Design Notes

  * **Struct, not GenServer** — RunContext is a pure data container. It is
    built by the agent loop on each turn and threaded through tool
    invocations. No process overhead; no mailbox risk.
  * **Map-compatible** — Implements `Access` so tools that currently
    receive a plain map (`context[:run_id]`) continue to work during
    migration.
  * **`deps` field** — Carries the generic "agent dependencies" (the
    Elixir equivalent of pydantic-ai's `RunContext.deps`). This is where
    you inject API clients, config, or any service a tool needs without
    coupling the tool to the application supervisor tree.

  ## Usage (from tool modules)

      defmodule MyApp.Tools.Greeter do
        use CodePuppyControl.Tool

        @impl true
        def name, do: :greeter

        @impl true
        def description, do: "Greets a user"

        @impl true
        def parameters, do: %{"type" => "object", "properties" => %{}}

        @impl true
        def invoke(_args, %RunContext{deps: %{greeting: greeting}}) do
          {:ok, greeting}
        end
      end

  ## Migration from pydantic-ai

  | Python (`pydantic_ai.RunContext`) | Elixir (`Agent.RunContext`)          |
  |-------------------------------------|-------------------------------------|
  | `ctx.deps`                         | `ctx.deps`                          |
  | `ctx.model`                        | `ctx.model`                         |
  | `ctx.usage`                        | `ctx.usage` (%RunUsage)             |
  | `ctx.retries`                      | `ctx.retries` (%{tool => count})    |
  | `ctx.retry`                        | `ctx.retry`                         |
  | `ctx.max_retries`                  | `ctx.max_retries`                   |
  | `ctx.last_attempt`                 | `RunContext.last_attempt?(ctx)`     |
  | `ctx.run_step`                     | `ctx.run_step`                      |
  | `ctx.tool_name`                    | `ctx.tool_name`                     |
  | `ctx.tool_call_id`                 | `ctx.tool_call_id`                  |
  | `ctx.metadata`                     | `ctx.metadata`                      |
  """

  @behaviour Access

  alias CodePuppyControl.Agent.RunUsage

  @type t :: %__MODULE__{
          agent_session_id: String.t() | nil,
          run_id: String.t() | nil,
          model: String.t() | nil,
          usage: RunUsage.t(),
          deps: term(),
          tools: [module()],
          retries: %{String.t() => non_neg_integer()},
          retry: non_neg_integer(),
          max_retries: non_neg_integer(),
          run_step: non_neg_integer(),
          tool_name: String.t() | nil,
          tool_call_id: String.t() | nil,
          tool_call_approved: boolean(),
          metadata: map()
        }

  defstruct [
    :agent_session_id,
    :run_id,
    :model,
    :deps,
    :tool_name,
    :tool_call_id,
    usage: %RunUsage{},
    tools: [],
    retries: %{},
    retry: 0,
    max_retries: 0,
    run_step: 0,
    tool_call_approved: false,
    metadata: %{}
  ]

  # ── Access Behaviour ──────────────────────────────────────────────────
  # Allows RunContext structs to be used as drop-in replacements for the
  # plain maps that tools currently receive via Tool.Runner.build_context/1.

  @impl true
  def fetch(%__MODULE__{} = ctx, key) when is_atom(key) do
    Map.fetch(ctx, key)
  end

  @impl true
  def pop(%__MODULE__{} = ctx, key) when is_atom(key) do
    {value, rest} = Map.pop(ctx, key)
    {value, struct(__MODULE__, rest)}
  end

  @impl true
  def get_and_update(%__MODULE__{} = ctx, key, fun) when is_atom(key) do
    {current, new_map} = Map.get_and_update(ctx, key, fun)
    {current, struct(__MODULE__, new_map)}
  end

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Returns `true` if this is the last retry attempt before an error is raised.

  Equivalent to pydantic-ai's `RunContext.last_attempt` property.

  ## Examples

      iex> RunContext.last_attempt?(%RunContext{retry: 2, max_retries: 2})
      true

      iex> RunContext.last_attempt?(%RunContext{retry: 0, max_retries: 2})
      false

      iex> RunContext.last_attempt?(%RunContext{retry: 0, max_retries: 0})
      true
  """
  @spec last_attempt?(t()) :: boolean()
  def last_attempt?(%__MODULE__{retry: retry, max_retries: max_retries}) do
    retry >= max_retries
  end

  @doc """
  Creates a new RunContext from a keyword list or map of options.

  All fields default to the struct defaults. Useful in the agent loop
  to construct the context before each turn.

  ## Examples

      iex> ctx = RunContext.new(run_id: "run-1", model: "claude-sonnet-4-20250514")
      iex> ctx.run_id
      "run-1"
      iex> ctx.model
      "claude-sonnet-4-20250514"
      iex> ctx.retry
      0
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts), do: opts |> Enum.into(%{}) |> new()
  def new(opts) when is_map(opts), do: struct(__MODULE__, opts)

  @doc """
  Merges additional metadata into the context.

  Returns a new RunContext with the metadata maps deep-merged.
  Existing keys in `ctx.metadata` are overridden by `extra_metadata`.

  ## Examples

      iex> ctx = %RunContext{metadata: %{foo: 1}}
      iex> RunContext.with_metadata(ctx, %{bar: 2})
      %RunContext{metadata: %{foo: 1, bar: 2}}
  """
  @spec with_metadata(t(), map()) :: t()
  def with_metadata(%__MODULE__{} = ctx, extra_metadata) when is_map(extra_metadata) do
    %{ctx | metadata: Map.merge(ctx.metadata, extra_metadata)}
  end

  @doc """
  Increments the retry counter for a specific tool.

  Returns a new RunContext with the tool's retry count incremented
  and the `retry` and `tool_name` fields set for the current invocation.

  ## Examples

      iex> ctx = %RunContext{retries: %{}, tool_name: nil, retry: 0}
      iex> ctx = RunContext.increment_retry(ctx, "read_file")
      iex> ctx.retries
      %{"read_file" => 1}
      iex> ctx.retry
      1
      iex> ctx.tool_name
      "read_file"
  """
  @spec increment_retry(t(), String.t()) :: t()
  def increment_retry(%__MODULE__{retries: retries} = ctx, tool_name)
      when is_binary(tool_name) do
    new_count = Map.get(retries, tool_name, 0) + 1

    %{
      ctx
      | retries: Map.put(retries, tool_name, new_count),
        retry: new_count,
        tool_name: tool_name
    }
  end

  @doc """
  Advances the run step counter.

  Called by the agent loop after each turn completes.

  ## Examples

      iex> ctx = %RunContext{run_step: 0}
      iex> RunContext.next_step(ctx).run_step
      1
  """
  @spec next_step(t()) :: t()
  def next_step(%__MODULE__{run_step: step} = ctx) do
    %{ctx | run_step: step + 1}
  end

  @doc """
  Converts the RunContext to a plain map for serialization or logging.

  Strips the `__struct__` key and converts the `usage` struct recursively.

  ## Examples

      iex> ctx = RunContext.new(run_id: "r1")
      iex> map = RunContext.to_map(ctx)
      iex> is_map(map)
      true
      iex> map[:run_id]
      "r1"
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = ctx) do
    ctx
    |> Map.from_struct()
    |> Map.update!(:usage, &RunUsage.to_map/1)
  end
end
