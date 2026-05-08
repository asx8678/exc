defmodule CodePuppyControl.Evals do
  @moduledoc """
  Evaluation harness for testing agent behavior.

  This module provides the top-level namespace for the evals framework, which
  mirrors the Python `evals/eval_helpers.py` implementation so that both runtimes
  produce JSON logs with identical schema under `evals/logs/<name>.json`.

  ## Submodules

    * `Policy` — classifies how deterministic an eval is (`always_passes` / `usually_passes`)
    * `ToolCall` — captures a single tool invocation from an agent run
    * `Result` — the full result of running an eval prompt against an agent
    * `Logger` — persists `Result` structs to JSON for parity diffs with Python

  ## Quick start

      alias CodePuppyControl.Evals.{Result, ToolCall, Logger}

      result = Result.new(
        response_text: "I'll read the file for you.",
        tool_calls: [ToolCall.new("read_file", %{"path" => "README.md"}, "# Code Puppy...")],
        duration_seconds: 1.5,
        model_name: "mock-model"
      )

      Logger.log_eval("sample_eval_framework", result)
  """

  @doc """
  Convenience wrapper around `Logger.log_eval/2`.
  """
  @spec log_eval(String.t(), CodePuppyControl.Evals.Result.t()) :: :ok
  defdelegate log_eval(name, result), to: CodePuppyControl.Evals.Logger
end
