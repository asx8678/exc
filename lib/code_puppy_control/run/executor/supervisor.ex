defmodule CodePuppyControl.Run.Executor.Supervisor do
  @moduledoc """
  DynamicSupervisor for Elixir executor processes.

  Separates executor supervision from `Run.Supervisor` (which owns
  `Run.State` processes) so that each logical run consumes exactly one
  `max_children` slot in each supervisor.  Before this split, a single
  Elixir run consumed *two* slots under `Run.Supervisor` (State +
  Executor), halving the effective capacity advertised by `PUP_MAX_RUNS`.

  Both supervisors share the same `max_children` cap via
  `Runtime.Limits.max_runs/0`, so the logical run capacity is enforced
  independently on each dimension (state tracking vs. execution).

  Refs: code-puppy-6sj
  """

  use DynamicSupervisor

  require Logger

  @doc """
  Starts the DynamicSupervisor.
  """
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Returns the count of active executor processes.
  """
  @spec executor_count() :: non_neg_integer()
  def executor_count do
    case Process.whereis(__MODULE__) do
      nil -> 0
      _ -> DynamicSupervisor.count_children(__MODULE__).workers
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 100,
      max_seconds: 60,
      max_children: CodePuppyControl.Runtime.Limits.max_runs()
    )
  end
end
