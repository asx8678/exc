defmodule CodePuppyControl.Evals.SampleEvalTest do
  @moduledoc """
  Sample eval demonstrating the eval framework (Elixir port of
  the legacy evals/test_sample_eval.py).

  Marked `:always_passes` because it uses mock data rather than a real LLM —
  it is the smoke-test of the harness itself and must never flake.

  Run with:
      RUN_EVALS=1 mix test test/evals/sample_eval_test.exs

  See `CodePuppyControl.Evals.Case` for the shared case template.
  """

  use CodePuppyControl.Evals.Case

  eval_test "eval framework captures tool calls correctly", policy: :always_passes do
    # Simulate what a real eval would produce after running an agent
    result = %Result{
      response_text: "I'll read the file for you.",
      tool_calls: [
        ToolCall.new("read_file", %{"path" => "README.md"}, "# Code Puppy...")
      ],
      duration_seconds: 1.5,
      model_name: "mock-model"
    }

    # Assert on the captured tool calls
    assert length(result.tool_calls) == 1
    [first | _] = result.tool_calls
    assert first.name == "read_file"
    assert first.args["path"] =~ "README.md"

    # Persist for debugging / inspection (writes to evals/logs/sample_eval_framework.json)
    log_eval("sample_eval_framework", result)
  end
end
