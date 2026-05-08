defmodule CodePuppyControl.Evals.Policy do
  @moduledoc """
  Classifies how reliable an eval test is expected to be.

  Mirrors Python `EvalPolicy` enum in `evals/eval_helpers.py`.

  ## Values

    * `:always_passes` — fully deterministic (e.g. mock-backed), should never flake.
    * `:usually_passes` — depends on LLM output and may occasionally fail.
  """

  @type t :: :always_passes | :usually_passes

  @doc "Convert policy atom to the string form used in JSON logs (matches Python value)."
  @spec to_string(t()) :: String.t()
  def to_string(:always_passes), do: "always_passes"
  def to_string(:usually_passes), do: "usually_passes"

  @doc "Parse string form back into the atom."
  @spec from_string(String.t()) :: {:ok, t()} | {:error, :invalid_policy}
  def from_string("always_passes"), do: {:ok, :always_passes}
  def from_string("usually_passes"), do: {:ok, :usually_passes}
  def from_string(_), do: {:error, :invalid_policy}
end
