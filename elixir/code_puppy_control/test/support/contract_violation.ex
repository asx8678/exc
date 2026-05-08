defmodule CodePuppyControl.Test.ContractViolation do
  @moduledoc """
  Exception raised when a provider contract is violated.

  Ported from Python's `tests.contracts.ContractViolation`. Carries the
  same three attributes — `component`, `issue`, and `details` — so that
  contract-error reporting stays consistent across the polyglot codebase.
  """

  @enforce_keys [:component, :issue]
  defexception component: nil, issue: nil, details: %{}

  @impl true
  def message(%__MODULE__{component: component, issue: issue}) do
    "Contract violation in #{component}: #{issue}"
  end
end
