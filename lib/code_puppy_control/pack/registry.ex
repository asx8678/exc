defmodule CodePuppyControl.Pack.Registry do
  @moduledoc """
  Registry for distributed pack `:via` tuple routing.

  Used by Pack modules to register and look up processes:

      {:via, Registry, {CodePuppyControl.Pack.Registry, key}}

  Started as part of the Pack supervision subtree.

  (Phase I.1 — code_puppy-yge.2)
  """

  @doc """
  Returns the via-tuple for registering a process under a given key.

  ## Examples

      # In a child spec:
      name: CodePuppyControl.Pack.Registry.via(:distributed_supervisor)

      # Lookup:
      [{pid, _}] = Registry.lookup(CodePuppyControl.Pack.Registry, :distributed_supervisor)
  """
  @spec via(atom()) :: {:via, Registry, {__MODULE__, atom()}}
  def via(key) do
    {:via, Registry, {__MODULE__, key}}
  end
end
