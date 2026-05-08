defmodule CodePuppyControl.Plugins.CostEstimatorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.{Callbacks, Plugins}
  alias CodePuppyControl.Plugins.CostEstimator

  setup do
    Callbacks.clear()
    CostEstimator.reset_session()
    :ok
  end

  describe "name/0" do
    test "returns string identifier" do
      assert CostEstimator.name() == "cost_estimator"
    end
  end

  describe "description/0" do
    test "returns a non-empty description" do
      assert is_binary(CostEstimator.description())
      assert CostEstimator.description() != ""
    end
  end

  describe "register/0" do
    test "registers all required callbacks" do
      assert :ok = CostEstimator.register()
      assert Callbacks.count_callbacks(:custom_command) >= 1
      assert Callbacks.count_callbacks(:custom_command_help) >= 1
      assert Callbacks.count_callbacks(:pre_tool_call) >= 1
      assert Callbacks.count_callbacks(:shutdown) >= 1
    end
  end

  describe "command_help/0" do
    test "returns help entries for cost and estimate commands" do
      help = CostEstimator.command_help()
      assert is_list(help)
      assert length(help) == 2
      commands = Enum.map(help, fn {cmd, _desc} -> cmd end)
      assert "/cost" in commands
      assert "/estimate <text>" in commands
    end
  end

  describe "handle_command/2" do
    test "returns nil for unknown command name" do
      assert CostEstimator.handle_command("/foo", "foo") == nil
    end

    test "returns no-tracked message for /cost with empty session" do
      result = CostEstimator.handle_command("/cost", "cost")
      assert result =~ "No token usage tracked"
    end

    test "returns usage message for /estimate without text" do
      result = CostEstimator.handle_command("/estimate", "estimate")
      assert result =~ "Usage"
    end

    test "returns estimate for /estimate with text" do
      result = CostEstimator.handle_command("/estimate hello world", "estimate")
      assert result =~ "Token Estimate"
      assert result =~ "heuristic"
    end
  end

  describe "estimate_cost/2" do
    test "estimates tokens and cost for a prompt" do
      est = CostEstimator.estimate_cost("Hello, world!")
      assert est.input_tokens > 0
      assert est.estimated_cost_usd >= 0.0
      assert est.method == "heuristic"
      assert est.model == "gpt-4o"
    end

    test "allows custom model" do
      est = CostEstimator.estimate_cost("test", model: "claude-sonnet-4-20250514")
      assert est.model == "claude-sonnet-4-20250514"
    end
  end

  describe "session tracking" do
    test "tracks and summarizes token usage per model" do
      CostEstimator.track_session_tokens("gpt-4o", 1000)
      CostEstimator.track_session_tokens("gpt-4o", 500)
      CostEstimator.track_session_tokens("claude-sonnet-4", 2000)

      summary = CostEstimator.get_session_summary()
      assert length(summary.models) == 2

      gpt_model = Enum.find(summary.models, fn m -> m.model == "gpt-4o" end)
      assert gpt_model.total_tokens == 1500

      claude_model = Enum.find(summary.models, fn m -> m.model == "claude-sonnet-4" end)
      assert claude_model.total_tokens == 2000

      assert summary.total_estimated_cost_usd > 0
    end

    test "resets session tracking" do
      CostEstimator.track_session_tokens("gpt-4o", 1000)
      assert CostEstimator.get_session_summary().models != []

      CostEstimator.reset_session()
      assert CostEstimator.get_session_summary().models == []
    end
  end

  describe "formatting" do
    test "formats cost with /cost command after tracking" do
      CostEstimator.track_session_tokens("gpt-4o", 5000)
      result = CostEstimator.handle_command("/cost", "cost")
      assert result =~ "Session Cost Summary"
      assert result =~ "gpt-4o"
    end
  end

  describe "loading via Plugins API" do
    test "can be loaded through the plugin system" do
      Plugins.load_plugin(CostEstimator)
      assert Callbacks.count_callbacks(:custom_command) >= 1
    end
  end
end
