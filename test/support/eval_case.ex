defmodule CodePuppyControl.Evals.Case do
  @moduledoc """
  ExUnit case template for eval tests.

  Tests using this case are tagged `:eval`, which means they are excluded by
  default and only run when `RUN_EVALS=1` is set in the environment (see
  `test/test_helper.exs`).

  ## Usage

      defmodule MyEvalTest do
        use CodePuppyControl.Evals.Case

        eval_test "greets correctly", policy: :always_passes do
          result = %Result{response_text: "hi", model_name: "mock"}
          assert result.response_text == "hi"
          log_eval("my_eval", result)
        end
      end

  ## Policy tagging

  Each test declares its `policy:` option — `:always_passes` (deterministic)
  or `:usually_passes` (LLM-dependent). This mirrors the Python `EvalPolicy`
  enum and is recorded on the test tags for reporting.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ExUnit.Case, async: false
      import CodePuppyControl.Evals.Case
      alias CodePuppyControl.Evals.{Policy, Result, ToolCall}
      import CodePuppyControl.Evals.Logger, only: [log_eval: 2]

      @moduletag :eval
    end
  end

  @doc """
  Define an eval test.

  Wraps `ExUnit.Case.test/2` but requires an explicit `:policy` option
  (either `:always_passes` or `:usually_passes`) and adds a per-test tag
  so downstream reporting can filter on policy.
  """
  defmacro eval_test(name, opts, do: block) do
    policy = Keyword.fetch!(opts, :policy)

    unless policy in [:always_passes, :usually_passes] do
      raise ArgumentError,
            "eval_test policy must be :always_passes or :usually_passes, got: #{inspect(policy)}"
    end

    quote do
      @tag eval_policy: unquote(policy)
      test unquote(name), _ctx do
        _policy = unquote(policy)
        # `Policy` alias is injected via `using` for suite-level use
        _ = Policy
        unquote(block)
      end
    end
  end
end
