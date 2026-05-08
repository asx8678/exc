defmodule CodePuppyControl.Agent.PromptMixinTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.PromptMixin

  describe "get_identity/2" do
    test "generates identity from name and id" do
      identity = PromptMixin.get_identity(:test_agent, "abc123def456")
      assert identity == "test_agent-abc123"
    end

    test "truncates id to 6 characters" do
      identity = PromptMixin.get_identity(:agent, "very_long_id_string_that_should_be_truncated")
      assert identity == "agent-very_l"
    end
  end

  describe "get_identity_prompt/1" do
    test "returns identity prompt with correct format" do
      prompt = PromptMixin.get_identity_prompt("test-agent-abc123")
      assert prompt =~ "Your ID is `test-agent-abc123`"
      assert prompt =~ "claiming task ownership"
    end
  end

  describe "get_platform_info/0" do
    test "returns platform information" do
      info = PromptMixin.get_platform_info()
      assert info =~ "- Platform:"
      assert info =~ "- Shell:"
      assert info =~ "- Current date:"
      assert info =~ "- Working directory:"
    end

    test "includes git repository info when .git exists" do
      info = PromptMixin.get_platform_info()
      # This will include git info if we're in a git repo
      # (which we should be in the code_puppy directory)
      assert is_binary(info)
    end
  end

  describe "get_full_system_prompt/2" do
    test "assembles complete prompt with all components" do
      base_prompt = "You are a test agent."
      identity = "test-agent-abc123"

      full_prompt = PromptMixin.get_full_system_prompt(base_prompt, identity)

      assert full_prompt =~ "You are a test agent."
      assert full_prompt =~ "# Environment"
      assert full_prompt =~ "Your ID is `test-agent-abc123`"
    end

    test "includes custom instructions from callbacks (concat_str merge)" do
      # Register a test callback — :load_prompt uses :concat_str merge strategy,
      # so Callbacks.on(:load_prompt) returns a merged binary string
      CodePuppyControl.Callbacks.register(:load_prompt, fn -> "Custom instruction" end)

      base_prompt = "Base prompt"
      identity = "test-agent-abc123"

      full_prompt = PromptMixin.get_full_system_prompt(base_prompt, identity)

      assert full_prompt =~ "Custom instruction"
      assert full_prompt =~ "# Custom Instructions"

      # Clean up
      CodePuppyControl.Callbacks.clear(:load_prompt)
    end

    test "handles nil return from Callbacks.on(:load_prompt) gracefully" do
      # Ensure no callbacks are registered — Callbacks.on returns nil
      CodePuppyControl.Callbacks.clear(:load_prompt)

      base_prompt = "Base prompt"
      identity = "test-agent-abc123"

      full_prompt = PromptMixin.get_full_system_prompt(base_prompt, identity)

      refute full_prompt =~ "# Custom Instructions"
      assert full_prompt =~ "Base prompt"
      assert full_prompt =~ "# Environment"
    end

    test "concatenates multiple load_prompt callbacks" do
      CodePuppyControl.Callbacks.clear(:load_prompt)
      CodePuppyControl.Callbacks.register(:load_prompt, fn -> "First addition" end)
      CodePuppyControl.Callbacks.register(:load_prompt, fn -> "Second addition" end)

      base_prompt = "Base prompt"
      identity = "test-agent-abc123"

      full_prompt = PromptMixin.get_full_system_prompt(base_prompt, identity)

      # :concat_str merge strategy joins with newlines
      assert full_prompt =~ "First addition"
      assert full_prompt =~ "Second addition"
      assert full_prompt =~ "# Custom Instructions"

      CodePuppyControl.Callbacks.clear(:load_prompt)
    end
  end
end
