defmodule CodePuppyControl.ModelUtilsTest do
  @moduledoc """
  Tests for ModelUtils module.

  Ported from Python `code_puppy/model_utils.py` tests.
  """

  use ExUnit.Case

  alias CodePuppyControl.ModelUtils
  alias CodePuppyControl.ModelUtils.PreparedPrompt

  # ============================================================================
  # is_claude_code_model/1 tests
  # ============================================================================

  describe "is_claude_code_model/1" do
    test "returns true for 'claude-code'" do
      assert ModelUtils.is_claude_code_model("claude-code") == true
    end

    test "returns true for 'claude-code-latest'" do
      assert ModelUtils.is_claude_code_model("claude-code-latest") == true
    end

    test "returns true for 'claude-code-20240229'" do
      assert ModelUtils.is_claude_code_model("claude-code-20240229") == true
    end

    test "returns false for 'claude-sonnet-4'" do
      assert ModelUtils.is_claude_code_model("claude-sonnet-4") == false
    end

    test "returns false for 'gpt-4o'" do
      assert ModelUtils.is_claude_code_model("gpt-4o") == false
    end

    test "returns false for empty string" do
      assert ModelUtils.is_claude_code_model("") == false
    end

    test "returns false for nil" do
      assert ModelUtils.is_claude_code_model(nil) == false
    end

    test "returns false for models starting with 'claude' but not 'claude-code'" do
      assert ModelUtils.is_claude_code_model("claude-opus-4") == false
      assert ModelUtils.is_claude_code_model("claude-3-sonnet") == false
      assert ModelUtils.is_claude_code_model("claude") == false
    end

    test "returns false for non-string inputs" do
      assert ModelUtils.is_claude_code_model(123) == false
      assert ModelUtils.is_claude_code_model(:claude_code) == false
    end
  end

  # ============================================================================
  # prepare_prompt_for_model/4 tests
  # ============================================================================

  describe "prepare_prompt_for_model/4" do
    test "claude-code model with prepend_system_to_user=true (default)" do
      result = ModelUtils.prepare_prompt_for_model("claude-code", "System prompt", "User prompt")

      assert %PreparedPrompt{} = result
      assert result.instructions == "You are Claude Code, Anthropic's official CLI for Claude."
      assert result.user_prompt == "System prompt\n\nUser prompt"
      assert result.is_claude_code == true
    end

    test "claude-code model with prepend_system_to_user=false" do
      result =
        ModelUtils.prepare_prompt_for_model("claude-code", "System prompt", "User prompt",
          prepend_system_to_user: false
        )

      assert %PreparedPrompt{} = result
      assert result.instructions == "You are Claude Code, Anthropic's official CLI for Claude."
      assert result.user_prompt == "User prompt"
      assert result.is_claude_code == true
    end

    test "claude-code-latest model" do
      result = ModelUtils.prepare_prompt_for_model("claude-code-latest", "System", "User")

      assert result.instructions == "You are Claude Code, Anthropic's official CLI for Claude."
      assert result.is_claude_code == true
    end

    test "non-claude-code model returns passthrough" do
      result = ModelUtils.prepare_prompt_for_model("gpt-4o", "System prompt", "User prompt")

      assert %PreparedPrompt{} = result
      assert result.instructions == "System prompt"
      assert result.user_prompt == "User prompt"
      assert result.is_claude_code == false
    end

    test "non-claude-code model ignores prepend_system_to_user option" do
      result =
        ModelUtils.prepare_prompt_for_model("gpt-4o", "System", "User",
          prepend_system_to_user: true
        )

      assert result.instructions == "System"
      assert result.user_prompt == "User"
      assert result.is_claude_code == false
    end

    test "handles empty system prompt with prepend enabled" do
      result = ModelUtils.prepare_prompt_for_model("claude-code", "", "User prompt")

      # With empty system prompt, should not prepend anything
      assert result.user_prompt == "User prompt"
    end

    test "handles empty strings for non-claude-code model" do
      result = ModelUtils.prepare_prompt_for_model("gpt-4o", "", "")

      assert result.instructions == ""
      assert result.user_prompt == ""
      assert result.is_claude_code == false
    end

    test "handles multi-line system prompts" do
      system = "Line 1\nLine 2\nLine 3"
      result = ModelUtils.prepare_prompt_for_model("claude-code", system, "User prompt")

      assert result.user_prompt == "Line 1\nLine 2\nLine 3\n\nUser prompt"
    end

    test "handles complex user prompts" do
      user = "Question:\nWhat is the meaning of life?"
      result = ModelUtils.prepare_prompt_for_model("claude-code", "System", user)

      assert result.user_prompt == "System\n\nQuestion:\nWhat is the meaning of life?"
    end
  end

  # ============================================================================
  # get_claude_code_instructions/0 tests
  # ============================================================================

  describe "get_claude_code_instructions/0" do
    test "returns expected instruction string" do
      result = ModelUtils.get_claude_code_instructions()

      assert result == "You are Claude Code, Anthropic's official CLI for Claude."
    end

    test "returns consistent value across multiple calls" do
      result1 = ModelUtils.get_claude_code_instructions()
      result2 = ModelUtils.get_claude_code_instructions()

      assert result1 == result2
    end
  end

  # ============================================================================
  # get_default_extended_thinking/1 tests
  # ============================================================================

  describe "get_default_extended_thinking/1" do
    test "returns 'adaptive' for opus-4-6 models" do
      assert ModelUtils.get_default_extended_thinking("claude-opus-4-6") == "adaptive"
      assert ModelUtils.get_default_extended_thinking("anthropic-opus-4-6-latest") == "adaptive"
    end

    test "returns 'adaptive' for 4-6-opus variant" do
      assert ModelUtils.get_default_extended_thinking("anthropic-4-6-opus") == "adaptive"
      assert ModelUtils.get_default_extended_thinking("claude-4-6-opus-beta") == "adaptive"
    end

    test "returns 'enabled' for claude-code models" do
      assert ModelUtils.get_default_extended_thinking("claude-code") == "enabled"
      assert ModelUtils.get_default_extended_thinking("claude-code-latest") == "enabled"
    end

    test "returns 'enabled' for non-opus models" do
      assert ModelUtils.get_default_extended_thinking("claude-sonnet-4") == "enabled"
      assert ModelUtils.get_default_extended_thinking("claude-haiku") == "enabled"
      assert ModelUtils.get_default_extended_thinking("gpt-4o") == "enabled"
    end

    test "returns 'enabled' for opus models without 4-6" do
      assert ModelUtils.get_default_extended_thinking("claude-opus") == "enabled"
      assert ModelUtils.get_default_extended_thinking("claude-opus-4") == "enabled"
    end

    test "is case-insensitive" do
      assert ModelUtils.get_default_extended_thinking("CLAUDE-OPUS-4-6") == "adaptive"
      assert ModelUtils.get_default_extended_thinking("Claude-Opus-4-6") == "adaptive"
    end

    test "returns 'enabled' for empty string" do
      assert ModelUtils.get_default_extended_thinking("") == "enabled"
    end

    test "returns 'enabled' for non-string inputs" do
      assert ModelUtils.get_default_extended_thinking(nil) == "enabled"
      assert ModelUtils.get_default_extended_thinking(123) == "enabled"
    end
  end

  # ============================================================================
  # Integration/pipeline tests
  # ============================================================================

  describe "integration: prepare_prompt_for_model pipeline" do
    test "full pipeline for claude-code model" do
      model = "claude-code"
      system = "You are a helpful assistant."
      user = "Hello, can you help me?"

      # Step 1: Check if claude-code model
      is_claude = ModelUtils.is_claude_code_model(model)
      assert is_claude == true

      # Step 2: Get instructions
      instructions = ModelUtils.get_claude_code_instructions()
      assert instructions == "You are Claude Code, Anthropic's official CLI for Claude."

      # Step 3: Prepare prompt
      result = ModelUtils.prepare_prompt_for_model(model, system, user)
      assert result.instructions == instructions
      assert result.is_claude_code == true
      assert result.user_prompt == "#{system}\n\n#{user}"

      # Step 4: Check extended thinking default
      thinking = ModelUtils.get_default_extended_thinking(model)
      assert thinking == "enabled"
    end

    test "full pipeline for standard model" do
      model = "gpt-4o"
      system = "You are a helpful assistant."
      user = "Hello, can you help me?"

      # Step 1: Check if claude-code model
      is_claude = ModelUtils.is_claude_code_model(model)
      assert is_claude == false

      # Step 2: Prepare prompt (passthrough)
      result = ModelUtils.prepare_prompt_for_model(model, system, user)
      assert result.instructions == system
      assert result.user_prompt == user
      assert result.is_claude_code == false

      # Step 3: Check extended thinking default
      thinking = ModelUtils.get_default_extended_thinking(model)
      assert thinking == "enabled"
    end

    test "opus-4-6 model extended thinking" do
      # Note: opus-4-6 is not a claude-code model name, but has adaptive thinking
      model = "claude-opus-4-6"

      is_claude = ModelUtils.is_claude_code_model(model)
      assert is_claude == false

      thinking = ModelUtils.get_default_extended_thinking(model)
      assert thinking == "adaptive"
    end
  end

  # ============================================================================
  # Edge cases and invariants
  # ============================================================================

  describe "edge cases and invariants" do
    test "struct fields are accessible" do
      result = %PreparedPrompt{
        instructions: "test",
        user_prompt: "user",
        is_claude_code: true
      }

      assert result.instructions == "test"
      assert result.user_prompt == "user"
      assert result.is_claude_code == true
    end

    test "struct can be pattern matched" do
      result = ModelUtils.prepare_prompt_for_model("claude-code", "System", "User")

      assert %PreparedPrompt{instructions: instructions, is_claude_code: true} = result
      assert instructions == "You are Claude Code, Anthropic's official CLI for Claude."
    end

    test "prepare_prompt_for_model is deterministic" do
      result1 = ModelUtils.prepare_prompt_for_model("claude-code", "S", "U")
      result2 = ModelUtils.prepare_prompt_for_model("claude-code", "S", "U")

      assert result1 == result2
    end

    test "whitespace in system prompt is preserved when prepending" do
      system = "  Padded system  "
      result = ModelUtils.prepare_prompt_for_model("claude-code", system, "User")

      assert result.user_prompt == "  Padded system  \n\nUser"
    end
  end
end
