defmodule CodePuppyControl.TokenLedger.CostTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TokenLedger.Cost

  describe "compute_cost/4" do
    test "computes cost for Claude Sonnet 4" do
      # Claude Sonnet 4: $3/1M input, $15/1M output → 300 cents, 1500 cents
      cost = Cost.compute_cost("claude-sonnet-4-20250514", 1_000_000, 0, 0)
      assert cost == 300

      cost = Cost.compute_cost("claude-sonnet-4-20250514", 0, 1_000_000, 0)
      assert cost == 1500
    end

    test "applies cached token discount" do
      # Claude Sonnet 4 cached: $0.30/1M → 30 cents
      cost = Cost.compute_cost("claude-sonnet-4-20250514", 1_000_000, 0, 1_000_000)
      assert cost == 30
    end

    test "computes mixed cached and non-cached" do
      # 500k non-cached + 500k cached input + 200k output
      # Non-cached: 500k * 300 / 1M = 150
      # Cached: 500k * 30 / 1M = 15
      # Output: 200k * 1500 / 1M = 300
      # Total: 465
      cost = Cost.compute_cost("claude-sonnet-4-20250514", 1_000_000, 200_000, 500_000)
      assert cost == 465
    end

    test "computes cost for GPT-4o" do
      # GPT-4o: $2.50/1M input, $10/1M output → 250 cents, 1000 cents
      cost = Cost.compute_cost("gpt-4o-2024-11-20", 1_000_000, 0, 0)
      assert cost == 250

      cost = Cost.compute_cost("gpt-4o-2024-11-20", 0, 1_000_000, 0)
      assert cost == 1000
    end

    test "computes cost for GPT-4o-mini (cheap model)" do
      # GPT-4o-mini: $0.15/1M input, $0.60/1M output
      # 1M * 15 / 1M = 15 cents
      cost = Cost.compute_cost("gpt-4o-mini-2024-07-18", 1_000_000, 0, 0)
      assert cost == 15
    end

    test "returns 0 for unknown model" do
      cost = Cost.compute_cost("totally-unknown-model", 1_000_000, 1_000_000, 0)
      assert cost == 0
    end

    test "handles zero tokens" do
      cost = Cost.compute_cost("gpt-4o", 0, 0, 0)
      assert cost == 0
    end

    test "handles small token counts" do
      # 100 tokens of GPT-4o: 100 * 250 = 25000, div(25000 + 500000, 1M) = 0
      cost = Cost.compute_cost("gpt-4o", 100, 0, 0)
      assert cost == 0
    end

    test "rounds to nearest cent" do
      # 100,000 tokens at $2.50/1M: 100k * 250 = 25M
      # div(25M + 500k, 1M) = div(25.5M, 1M) = 25
      cost = Cost.compute_cost("gpt-4o", 100_000, 0, 0)
      assert cost == 25

      # 10,000 tokens at $2.50/1M: 10k * 250 = 2.5M
      # div(2.5M + 500k, 1M) = div(3M, 1M) = 3
      cost = Cost.compute_cost("gpt-4o", 10_000, 0, 0)
      assert cost == 3
    end
  end

  describe "cost_for_model/1" do
    test "returns positive costs for known Anthropic models" do
      for model <- [
            "claude-sonnet-4-20250514",
            "claude-3-5-sonnet-20241022",
            "claude-3-5-haiku-20241022",
            "claude-3-opus-20240229",
            "claude-3-haiku-20240307"
          ] do
        {input, output, cached} = Cost.cost_for_model(model)
        assert input > 0, "Expected positive input cost for #{model}"
        assert output > 0, "Expected positive output cost for #{model}"
        assert cached >= 0, "Expected non-negative cached cost for #{model}"
        assert cached < input, "Expected cached < input for #{model}"
      end
    end

    test "returns positive costs for known OpenAI models" do
      for model <- [
            "gpt-4o-2024-11-20",
            "gpt-4o-mini-2024-07-18",
            "gpt-4-turbo-2024-04-09",
            "gpt-3.5-turbo-0125",
            "o1-2024-12-17",
            "o3-mini-2025-01-31"
          ] do
        {input, output, _cached} = Cost.cost_for_model(model)
        assert input > 0, "Expected positive input cost for #{model}"
        assert output > 0, "Expected positive output cost for #{model}"
      end
    end

    test "returns positive costs for known Google models" do
      for model <- ["gemini-1.5-pro", "gemini-1.5-flash", "gemini-2.0-flash"] do
        {input, output, _cached} = Cost.cost_for_model(model)
        assert input > 0, "Expected positive input cost for #{model}"
        assert output > 0, "Expected positive output cost for #{model}"
      end
    end

    # (code_puppy-be7) ChatGPT Codex OAuth models must return zero-cost
    # placeholders instead of logging unknown-pricing warnings.
    test "returns zero-cost for chatgpt-gpt-5 models (OAuth placeholder)" do
      assert Cost.cost_for_model("chatgpt-gpt-5.5") == {0, 0, 0}
      assert Cost.cost_for_model("chatgpt-gpt-5.4") == {0, 0, 0}
      assert Cost.cost_for_model("chatgpt-gpt-5") == {0, 0, 0}
    end

    test "returns zero-cost for chatgpt-4o models (OAuth placeholder)" do
      assert Cost.cost_for_model("chatgpt-4o") == {0, 0, 0}
    end

    test "returns zero for unknown model" do
      assert Cost.cost_for_model("unknown-model") == {0, 0, 0}
    end

    test "prefix matching works for Anthropic" do
      {input, output, _} = Cost.cost_for_model("claude-sonnet-future-version")
      assert input > 0
      assert output > 0
    end

    test "prefix matching works for OpenAI" do
      {input, _, _} = Cost.cost_for_model("gpt-4o-new-variant")
      assert input > 0
    end

    test "output is more expensive than input for all priced models" do
      # (code_puppy-be7) ChatGPT Codex OAuth models have zero-cost placeholders,
      # so we only assert output > input for models with positive pricing.
      for model <- Cost.known_models() do
        {input, output, _} = Cost.cost_for_model(model)

        if input > 0 do
          assert output > input,
                 "Expected output > input for #{model}, got input=#{input} output=#{output}"
        end
      end
    end
  end

  describe "known_models/0" do
    test "returns a non-empty list" do
      models = Cost.known_models()
      assert is_list(models)
      assert length(models) > 0
    end

    test "includes major providers" do
      models = Cost.known_models()
      joined = Enum.join(models, ",")

      assert joined =~ "claude"
      assert joined =~ "gpt"
      assert joined =~ "gemini"
    end
  end
end
