defmodule CodePuppyControl.Evals.Result do
  @moduledoc """
  The full result of running an eval prompt against an agent.

  Mirrors Python `EvalResult` dataclass in `evals/eval_helpers.py`.

  JSON shape (via `CodePuppyControl.Evals.Logger`):

      %{
        "name" => "...",
        "timestamp" => "2026-04-20T...",
        "model" => "...",
        "duration_seconds" => 1.5,
        "response_text" => "...",
        "tool_calls" => [...]
      }
  """

  alias CodePuppyControl.Evals.ToolCall

  defstruct response_text: "",
            tool_calls: [],
            duration_seconds: 0.0,
            model_name: ""

  @type t :: %__MODULE__{
          response_text: String.t(),
          tool_calls: [ToolCall.t()],
          duration_seconds: float(),
          model_name: String.t()
        }

  @doc """
  Build a result struct with keyword args.

  ## Examples

      iex> CodePuppyControl.Evals.Result.new(response_text: "hi", model_name: "mock")
      %CodePuppyControl.Evals.Result{response_text: "hi", tool_calls: [], duration_seconds: 0.0, model_name: "mock"}

      iex> CodePuppyControl.Evals.Result.new(response_text: "ok", duration_seconds: 2.3, model_name: "gpt-4")
      %CodePuppyControl.Evals.Result{response_text: "ok", tool_calls: [], duration_seconds: 2.3, model_name: "gpt-4"}
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct!(__MODULE__, opts)
  end
end
