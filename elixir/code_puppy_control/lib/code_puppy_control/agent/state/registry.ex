defmodule CodePuppyControl.Agent.State.Registry do
  @moduledoc "Registry for per-{session,agent} Agent.State processes."

  def child_spec(_opts) do
    Registry.child_spec(
      keys: :unique,
      name: __MODULE__,
      partitions: System.schedulers_online()
    )
  end
end
