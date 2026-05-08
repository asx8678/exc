defmodule CodePuppyControl.Run.Registry do
  @moduledoc """
  Registry for tracking run-related processes.

  Uses a partitioned Registry for concurrent access.
  Keys are tuples like `{:run_executor, run_id}`
  or `{:run_state, run_id}`.
  """

  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__,
      partitions: System.schedulers_online()
    )
  end

  @doc """
  Returns the via tuple for a run's state process.
  """
  @spec run_state(String.t()) :: {:via, module(), {module(), term()}}
  def run_state(run_id) do
    {:via, Registry, {__MODULE__, {:run_state, run_id}}}
  end

  @doc """
  Looks up a process by key.
  """
  @spec lookup(term()) :: list({pid(), term()})
  def lookup(key) do
    Registry.lookup(__MODULE__, key)
  end
end
