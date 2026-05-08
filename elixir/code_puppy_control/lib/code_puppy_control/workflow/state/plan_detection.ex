defmodule CodePuppyControl.Workflow.State.PlanDetection do
  @moduledoc """
  Heuristic plan detection for workflow state.

  Parse response text; if it contains a plan (ordered list items with
  enough entries), set the `:did_create_plan` flag.

  This mirrors the Python `detect_and_mark_plan_from_response` which
  delegates to `code_puppy.utils.subtask_parser.has_plan`.

  TODO(code-puppy-ctj.3): Replace with proper Elixir subtask parser when ported
  """

  alias CodePuppyControl.Workflow.State.Store

  @doc """
  Parse the given response text; if it contains a plan, set DID_CREATE_PLAN.

  Returns `true` iff `:did_create_plan` was set as a result of this call.

  Uses a heuristic: looks for ordered list items (numbered or bulleted)
  with at least `min_tasks` entries.

  ## Options

    * `:min_tasks` — Minimum items to consider a plan (default: 2)
    * `:run_key` — Explicit run key (safe for async callbacks)
  """
  @spec detect_and_mark_plan_from_response(String.t(), keyword()) :: boolean()
  def detect_and_mark_plan_from_response(response_text, opts \\ [])
      when is_binary(response_text) do
    min_tasks = Keyword.get(opts, :min_tasks, 2)

    if has_plan?(response_text, min_tasks) do
      Store.set_flag(:did_create_plan, opts)
      true
    else
      false
    end
  end

  # Heuristic plan detection: counts numbered list items.
  # Matches patterns like "1. task", "2) task", "- task", "* task"
  # across multiple lines. Returns true if count >= min_tasks.
  defp has_plan?(text, min_tasks) do
    # Count numbered items (e.g. "1. Do X", "2) Do Y")
    numbered_count =
      Regex.scan(~r/(?:^|\n)\s*(\d+)[.)]\s+\S/, text)
      |> length()

    # Count bullet items (e.g. "- Do X", "* Do Y")
    bullet_count =
      Regex.scan(~r/(?:^|\n)\s*[-*]\s+\S/, text)
      |> length()

    # A plan is detected if there are enough items of either type
    numbered_count >= min_tasks or bullet_count >= min_tasks
  end
end
