defmodule CodePuppyControl.Agent.BudgetEnforcerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.{BudgetEnforcer, RunUsage, UsageLimits}

  # ═══════════════════════════════════════════════════════════════════════
  # check_token_budgets/3
  # ═══════════════════════════════════════════════════════════════════════

  describe "check_token_budgets/3" do
    test "passes when no budgets are set" do
      usage = %RunUsage{}

      assert BudgetEnforcer.check_token_budgets(
               1000,
               %{max_session_tokens: 0, max_run_tokens: 0},
               usage
             ) ==
               {:ok, :checked}
    end

    test "passes when budgets are nil" do
      usage = %RunUsage{}

      assert BudgetEnforcer.check_token_budgets(
               1000,
               %{max_session_tokens: nil, max_run_tokens: nil},
               usage
             ) ==
               {:ok, :checked}
    end

    test "fails when session budget exceeded" do
      usage = %RunUsage{input_tokens: 1000, output_tokens: 500}

      assert {:error, :session_budget_exceeded, msg} =
               BudgetEnforcer.check_token_budgets(
                 100,
                 %{max_session_tokens: 1500, max_run_tokens: 0},
                 usage
               )

      assert is_binary(msg)
      assert String.contains?(msg, "Session token budget exceeded")
    end

    test "fails when run budget exceeded" do
      usage = %RunUsage{}

      assert {:error, :run_budget_exceeded, msg} =
               BudgetEnforcer.check_token_budgets(
                 5000,
                 %{max_session_tokens: 0, max_run_tokens: 1000},
                 usage
               )

      assert String.contains?(msg, "Run token budget exceeded")
    end

    test "passes when within both budgets" do
      usage = %RunUsage{input_tokens: 500, output_tokens: 200}

      assert BudgetEnforcer.check_token_budgets(
               100,
               %{max_session_tokens: 1000, max_run_tokens: 500},
               usage
             ) ==
               {:ok, :checked}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # check_context_budget/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "check_context_budget/2" do
    test "passes when max_output_tokens is nil" do
      budget = %{model_context_length: 128_000, max_output_tokens: nil}
      assert BudgetEnforcer.check_context_budget(200_000, budget) == {:ok, :checked}
    end

    test "passes when within context budget" do
      budget = %{
        model_context_length: 128_000,
        max_output_tokens: 4096,
        safety_margin_fraction: 0.9
      }

      assert BudgetEnforcer.check_context_budget(50_000, budget) == {:ok, :checked}
    end

    test "fails when context budget exceeded" do
      budget = %{
        model_context_length: 128_000,
        max_output_tokens: 4096,
        safety_margin_fraction: 0.9
      }

      assert {:error, :context_budget_exceeded, msg} =
               BudgetEnforcer.check_context_budget(200_000, budget)

      assert String.contains?(msg, "Context budget exceeded")
    end

    test "uses configurable safety margin" do
      # With 90% safety margin: safe_limit = 128000 * 0.9 = 115200
      # 100000 + 4096 = 104096 < 115200 → should pass
      budget = %{
        model_context_length: 128_000,
        max_output_tokens: 4096,
        safety_margin_fraction: 0.9
      }

      assert BudgetEnforcer.check_context_budget(100_000, budget) == {:ok, :checked}

      # With 50% safety margin: safe_limit = 128000 * 0.5 = 64000
      # 100000 + 4096 = 104096 > 64000 → should fail
      budget_strict = %{
        model_context_length: 128_000,
        max_output_tokens: 4096,
        safety_margin_fraction: 0.5
      }

      assert {:error, :context_budget_exceeded, _} =
               BudgetEnforcer.check_context_budget(100_000, budget_strict)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # check_before_send/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "check_before_send/2" do
    test "passes all checks when within budgets" do
      opts = %{
        token_budgets: %{max_session_tokens: 0, max_run_tokens: 0},
        context_budget: %{model_context_length: 128_000, max_output_tokens: 4096},
        usage_limits: nil,
        session_usage: %RunUsage{}
      }

      assert BudgetEnforcer.check_before_send(5000, opts) == {:ok, :checked}
    end

    test "fails on first error encountered" do
      opts = %{
        token_budgets: %{max_session_tokens: 100, max_run_tokens: 0},
        context_budget: %{model_context_length: 128_000, max_output_tokens: 4096},
        usage_limits: nil,
        session_usage: %RunUsage{input_tokens: 100, output_tokens: 50}
      }

      assert {:error, :session_budget_exceeded, _} =
               BudgetEnforcer.check_before_send(5000, opts)
    end

    test "checks usage limits when provided" do
      limits = UsageLimits.new(request_limit: 1)
      usage = %RunUsage{requests: 1}

      opts = %{
        token_budgets: %{max_session_tokens: 0, max_run_tokens: 0},
        context_budget: %{model_context_length: 128_000, max_output_tokens: nil},
        usage_limits: limits,
        session_usage: usage
      }

      assert {:error, :limit_exceeded, :request_limit} =
               BudgetEnforcer.check_before_send(100, opts)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # estimate_context_overhead/3
  # ═══════════════════════════════════════════════════════════════════════

  describe "estimate_context_overhead/3" do
    test "returns 0 for empty prompt and no tools" do
      assert BudgetEnforcer.estimate_context_overhead("", []) == 0
    end

    test "estimates tokens for system prompt" do
      prompt = "You are a helpful coding assistant."
      tokens = BudgetEnforcer.estimate_context_overhead(prompt, [])
      assert tokens > 0
      # "You are a helpful coding assistant." ≈ 36 chars / 2.5 ≈ 15 tokens
      assert tokens >= 10
    end

    test "estimates tokens for system prompt + tools" do
      prompt = "You are helpful."
      tokens_no_tools = BudgetEnforcer.estimate_context_overhead(prompt, [])
      tokens_with_tools = BudgetEnforcer.estimate_context_overhead(prompt, [:cp_read_file])
      # Tool overhead should add tokens
      assert tokens_with_tools >= tokens_no_tools
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # estimate_tokens/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "estimate_tokens/1" do
    test "returns 0 for empty string" do
      assert BudgetEnforcer.estimate_tokens("") == 0
    end

    test "uses length/2.5 heuristic" do
      # "hello" = 5 chars, 5/2.5 = 2
      assert BudgetEnforcer.estimate_tokens("hello") == 2
    end

    test "rounds up with ceil" do
      # "hi" = 2 chars, 2/2.5 = 0.8 → ceil = 1
      assert BudgetEnforcer.estimate_tokens("hi") == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # model_context_length/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "model_context_length/1" do
    test "returns 200k for Claude Sonnet" do
      assert BudgetEnforcer.model_context_length("claude-sonnet-4-20250514") == 200_000
    end

    test "returns 200k for Claude Opus" do
      assert BudgetEnforcer.model_context_length("claude-opus-4-20250514") == 200_000
    end

    test "returns 128k for GPT-4o" do
      assert BudgetEnforcer.model_context_length("gpt-4o") == 128_000
    end

    test "returns 128k default for unknown model" do
      assert BudgetEnforcer.model_context_length("some-random-model") == 128_000
    end
  end
end
