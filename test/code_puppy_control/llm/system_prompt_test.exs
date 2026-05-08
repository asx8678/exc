defmodule CodePuppyControl.LLM.SystemPromptTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.LLM.SystemPrompt

  describe "extract/1" do
    test "extracts system messages and returns chat messages" do
      messages = [
        %{role: "system", content: "You are helpful."},
        %{role: "user", content: "Hi"}
      ]

      {system_text, chat_messages} = SystemPrompt.extract(messages)

      assert system_text == "You are helpful."
      assert chat_messages == [%{role: "user", content: "Hi"}]
    end

    test "handles string-keyed messages" do
      messages = [
        %{"role" => "system", "content" => "Be concise."},
        %{"role" => "user", "content" => "Hello"}
      ]

      {system_text, chat_messages} = SystemPrompt.extract(messages)

      assert system_text == "Be concise."
      assert chat_messages == [%{"role" => "user", "content" => "Hello"}]
    end

    test "concatenates multiple system messages with double newlines" do
      messages = [
        %{role: "system", content: "Rule 1."},
        %{role: "system", content: "Rule 2."},
        %{role: "user", content: "Hi"}
      ]

      {system_text, chat_messages} = SystemPrompt.extract(messages)

      assert system_text == "Rule 1.\n\nRule 2."
      assert chat_messages == [%{role: "user", content: "Hi"}]
    end

    test "returns nil when no system messages" do
      messages = [%{role: "user", content: "Hi"}]

      {system_text, chat_messages} = SystemPrompt.extract(messages)

      assert system_text == nil
      assert chat_messages == messages
    end

    test "handles empty messages list" do
      {system_text, chat_messages} = SystemPrompt.extract([])

      assert system_text == nil
      assert chat_messages == []
    end

    test "handles nil content in system messages" do
      messages = [
        %{role: "system", content: nil},
        %{role: "user", content: "Hi"}
      ]

      {system_text, _chat_messages} = SystemPrompt.extract(messages)

      # nil content becomes "" in join, and since it's "", system_text is nil
      assert system_text == nil
    end
  end

  describe "format_for/2" do
    test "formats for :openai provider" do
      assert SystemPrompt.format_for(:openai, "Be helpful") == %{
               role: "system",
               content: "Be helpful"
             }

      assert SystemPrompt.format_for(:openai, nil) == nil
    end

    test "formats for :anthropic provider" do
      assert SystemPrompt.format_for(:anthropic, "Be helpful") == "Be helpful"
      assert SystemPrompt.format_for(:anthropic, nil) == nil
    end

    test "formats for :gemini provider" do
      assert SystemPrompt.format_for(:gemini, "Be helpful") == %{
               "parts" => [%{"text" => "Be helpful"}]
             }

      assert SystemPrompt.format_for(:gemini, nil) == nil
    end

    test "formats for :chatgpt_codex provider" do
      assert SystemPrompt.format_for(:chatgpt_codex, "Be helpful") == "Be helpful"
      assert SystemPrompt.format_for(:chatgpt_codex, nil) == nil
    end
  end

  describe "merge_opts_and_messages/2" do
    test "returns nil when both are nil" do
      assert SystemPrompt.merge_opts_and_messages(nil, nil) == nil
    end

    test "returns opts prompt when messages prompt is nil" do
      assert SystemPrompt.merge_opts_and_messages("From opts", nil) == "From opts"
    end

    test "returns messages prompt when opts prompt is nil" do
      assert SystemPrompt.merge_opts_and_messages(nil, "From messages") == "From messages"
    end

    test "concatenates both prompts with double newlines, opts first" do
      result = SystemPrompt.merge_opts_and_messages("From opts", "From messages")
      assert result == "From opts\n\nFrom messages"
    end
  end

  describe "ensure_in_messages/2" do
    test "prepends system message when no system messages exist" do
      messages = [%{role: "user", content: "Hi"}]

      result = SystemPrompt.ensure_in_messages(messages, "Be helpful")

      assert result == [
               %{role: "system", content: "Be helpful"},
               %{role: "user", content: "Hi"}
             ]
    end

    test "does not prepend when system messages already exist" do
      messages = [
        %{role: "system", content: "Existing"},
        %{role: "user", content: "Hi"}
      ]

      result = SystemPrompt.ensure_in_messages(messages, "New")

      assert result == messages
    end

    test "handles string-keyed system messages" do
      messages = [
        %{"role" => "system", "content" => "Existing"},
        %{"role" => "user", "content" => "Hi"}
      ]

      result = SystemPrompt.ensure_in_messages(messages, "New")

      assert result == messages
    end

    test "returns messages unchanged when system_prompt_opt is nil" do
      messages = [%{role: "user", content: "Hi"}]

      result = SystemPrompt.ensure_in_messages(messages, nil)

      assert result == messages
    end

    test "returns messages unchanged when system_prompt_opt is empty string" do
      messages = [%{role: "user", content: "Hi"}]

      result = SystemPrompt.ensure_in_messages(messages, "")

      assert result == messages
    end
  end

  describe "normalize/3" do
    test "for :openai, keeps system in messages and prepends opt if needed" do
      messages = [%{role: "user", content: "Hi"}]

      {system_field, normalized_messages} =
        SystemPrompt.normalize(:openai, messages, "Be helpful")

      assert system_field == nil

      assert normalized_messages == [
               %{role: "system", content: "Be helpful"},
               %{role: "user", content: "Hi"}
             ]
    end

    test "for :openai, does not prepend when system messages already exist" do
      messages = [
        %{role: "system", content: "Existing"},
        %{role: "user", content: "Hi"}
      ]

      {system_field, normalized_messages} = SystemPrompt.normalize(:openai, messages, "New")

      assert system_field == nil
      assert normalized_messages == messages
    end

    test "for :anthropic, extracts system from messages" do
      messages = [
        %{role: "system", content: "Be helpful"},
        %{role: "user", content: "Hi"}
      ]

      {system_field, chat_messages} = SystemPrompt.normalize(:anthropic, messages, nil)

      assert system_field == "Be helpful"
      assert chat_messages == [%{role: "user", content: "Hi"}]
    end

    test "for :anthropic, merges opts and messages system prompts" do
      messages = [
        %{role: "system", content: "From messages"},
        %{role: "user", content: "Hi"}
      ]

      {system_field, chat_messages} = SystemPrompt.normalize(:anthropic, messages, "From opts")

      assert system_field == "From opts\n\nFrom messages"
      assert chat_messages == [%{role: "user", content: "Hi"}]
    end

    test "for :anthropic, uses opts when no system messages" do
      messages = [%{role: "user", content: "Hi"}]

      {system_field, chat_messages} = SystemPrompt.normalize(:anthropic, messages, "From opts")

      assert system_field == "From opts"
      assert chat_messages == [%{role: "user", content: "Hi"}]
    end

    test "for :gemini, formats system instruction" do
      messages = [
        %{role: "system", content: "Be helpful"},
        %{role: "user", content: "Hi"}
      ]

      {system_field, chat_messages} = SystemPrompt.normalize(:gemini, messages, nil)

      assert system_field == %{"parts" => [%{"text" => "Be helpful"}]}
      assert chat_messages == [%{role: "user", content: "Hi"}]
    end

    test "for :chatgpt_codex, extracts system from messages" do
      messages = [
        %{role: "system", content: "Be helpful"},
        %{role: "user", content: "Hi"}
      ]

      {system_field, chat_messages} = SystemPrompt.normalize(:chatgpt_codex, messages, nil)

      assert system_field == "Be helpful"
      assert chat_messages == [%{role: "user", content: "Hi"}]
    end

    test "for :chatgpt_codex, merges opts and messages" do
      messages = [
        %{role: "system", content: "From messages"},
        %{role: "user", content: "Hi"}
      ]

      {system_field, chat_messages} =
        SystemPrompt.normalize(:chatgpt_codex, messages, "From opts")

      assert system_field == "From opts\n\nFrom messages"
      assert chat_messages == [%{role: "user", content: "Hi"}]
    end

    test "returns nil system field when no system prompt from any source" do
      messages = [%{role: "user", content: "Hi"}]

      {system_field, chat_messages} = SystemPrompt.normalize(:anthropic, messages, nil)

      assert system_field == nil
      assert chat_messages == messages
    end
  end
end
