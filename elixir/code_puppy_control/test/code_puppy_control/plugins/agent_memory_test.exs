defmodule CodePuppyControl.Plugins.AgentMemoryTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Plugins.AgentMemory.Prompts
  alias CodePuppyControl.Plugins.AgentMemory.Storage
  alias CodePuppyControl.LLM.SystemPrompt

  # ── Helpers ───────────────────────────────────────────────────────

  defp temp_data_dir! do
    dir =
      Path.join([
        System.tmp_dir!(),
        "agent_memory_test",
        System.unique_integer([:positive]) |> Integer.to_string()
      ])

    File.mkdir_p!(dir)
    dir
  end

  # ── format_memory_section/3 (pure, no side effects) ───────────────

  describe "format_memory_section/3" do
    test "returns nil for empty facts" do
      assert Prompts.format_memory_section([], 50, 500) == nil
    end

    test "formats facts sorted by confidence descending" do
      facts = [
        %{"text" => "low confidence fact", "confidence" => 0.3},
        %{"text" => "high confidence fact", "confidence" => 0.9},
        %{"text" => "medium confidence fact", "confidence" => 0.6}
      ]

      result = Prompts.format_memory_section(facts, 50, 500)
      assert result != nil

      lines = String.split(result, "\n")
      assert hd(lines) == "## Memory"

      # Extract confidence values from lines
      confidences =
        lines
        |> Enum.drop(1)
        |> Enum.map(fn line ->
          [_, conf_str] = Regex.run(~r/confidence: ([\d.]+)\)/, line)
          String.to_float(conf_str)
        end)

      assert confidences == [0.9, 0.6, 0.3]
    end

    test "respects max_facts limit" do
      facts = for _i <- 1..100, do: %{"text" => "fact", "confidence" => 1.0}

      result = Prompts.format_memory_section(facts, 5, 5000)
      lines = String.split(result, "\n") |> Enum.drop(1)
      assert length(lines) == 5
    end

    test "respects token_budget with very small budget" do
      facts = for _i <- 1..10, do: %{"text" => String.duplicate("x", 100), "confidence" => 1.0}

      result = Prompts.format_memory_section(facts, 50, 10)
      assert result == nil
    end

    test "returns nil when only header fits" do
      facts = [%{"text" => String.duplicate("x", 1000), "confidence" => 1.0}]

      result = Prompts.format_memory_section(facts, 50, 2)
      assert result == nil
    end

    test "skips empty text facts" do
      facts = [
        %{"text" => "", "confidence" => 0.9},
        %{"text" => "valid fact", "confidence" => 0.5}
      ]

      result = Prompts.format_memory_section(facts, 50, 500)
      assert result != nil
      refute result =~ "confidence: 0.9"
      assert result =~ "valid fact"
    end
  end

  # ── Full prompt-to-provider-payload acceptance flow ───────────────
  #
  # Tests the boundary: fact storage → prompt injection →
  # system prompt normalization for provider payloads.

  describe "on_get_model_system_prompt/3 — prompt injection" do
    setup do
      dir = temp_data_dir!()
      Application.put_env(:code_puppy_control, :memory_enabled, true)
      System.put_env("PUP_EX_HOME", dir)

      on_exit(fn ->
        Application.delete_env(:code_puppy_control, :memory_enabled)
        System.delete_env("PUP_EX_HOME")
      end)

      %{tmp_dir: dir, agent_name: "test_agent_a4"}
    end

    test "injects memory into system prompt when facts exist", %{agent_name: agent} do
      # Store a fact. Use 0.95 → rounds to "1.0" with decimals:1, so we
      # assert against "1.0" instead.
      Storage.add_fact(agent, %{
        "text" => "user prefers Elixir for backend services",
        "confidence" => 0.95
      })

      Process.put(:current_agent_name, agent)

      base_prompt = "You are a coding assistant."
      user_prompt = "Build me a service"

      result = Prompts.on_get_model_system_prompt("gpt-4", base_prompt, user_prompt)

      assert is_map(result)
      assert result["handled"] == false
      assert result["user_prompt"] == user_prompt

      instructions = result["instructions"]
      assert String.contains?(instructions, base_prompt)
      assert String.contains?(instructions, "user prefers Elixir")
      assert String.contains?(instructions, "confidence: 1.0")
      assert String.contains?(instructions, "## Memory")
    end

    test "returns nil when memory disabled", %{agent_name: agent} do
      Application.put_env(:code_puppy_control, :memory_enabled, false)

      Storage.add_fact(agent, %{"text" => "user fact", "confidence" => 0.9})
      Process.put(:current_agent_name, agent)

      result = Prompts.on_get_model_system_prompt("gpt-4", "prompt", "user msg")
      assert result == nil
    end

    test "returns nil when no facts exist", %{agent_name: agent} do
      Process.put(:current_agent_name, agent)

      result = Prompts.on_get_model_system_prompt("gpt-4", "prompt", "user msg")
      assert result == nil
    end

    test "returns nil when no agent name set" do
      Process.delete(:current_agent_name)

      result = Prompts.on_get_model_system_prompt("gpt-4", "prompt", "user msg")
      assert result == nil
    end

    test "filters facts below minimum confidence", %{agent_name: agent} do
      Storage.add_fact(agent, %{"text" => "low confidence fact", "confidence" => 0.3})
      Storage.add_fact(agent, %{"text" => "high confidence fact", "confidence" => 0.9})

      Process.put(:current_agent_name, agent)

      result = Prompts.on_get_model_system_prompt("gpt-4", "prompt", "user msg")

      instructions = result["instructions"]
      assert String.contains?(instructions, "high confidence fact")
      refute String.contains?(instructions, "low confidence fact")
    end
  end

  # ── SystemPrompt normalization integration ───────────────────────
  #
  # Verify that memory-enhanced prompts correctly flow through
  # SystemPrompt.normalize/3 into provider-specific payload formats.

  describe "memory prompt → provider payload normalization" do
    setup do
      dir = temp_data_dir!()
      agent = "a4_provider_test"

      System.put_env("PUP_EX_HOME", dir)
      Application.put_env(:code_puppy_control, :memory_enabled, true)

      Process.put(:current_agent_name, agent)

      Storage.add_fact(agent, %{
        "text" => "user prefers Python for data science",
        "confidence" => 0.9
      })

      %{"instructions" => enhanced_prompt} =
        Prompts.on_get_model_system_prompt("gpt-4", "You are an expert.", "Help me")

      on_exit(fn ->
        System.delete_env("PUP_EX_HOME")
        Application.delete_env(:code_puppy_control, :memory_enabled)
        Process.delete(:current_agent_name)
      end)

      %{enhanced_prompt: enhanced_prompt, agent: agent}
    end

    test "memory flows into :anthropic system field", %{enhanced_prompt: prompt} do
      messages = [%{role: "user", content: "Write a script"}]

      {system_field, _chat_msgs} = SystemPrompt.normalize(:anthropic, messages, prompt)

      assert is_binary(system_field)
      assert String.contains?(system_field, "user prefers Python")
      assert String.contains?(system_field, "## Memory")
      refute Enum.any?(_chat_msgs, &(&1[:role] == "system"))
    end

    test "memory flows into :gemini systemInstruction parts", %{enhanced_prompt: prompt} do
      messages = [%{role: "user", content: "Write a script"}]

      {system_field, _chat_msgs} = SystemPrompt.normalize(:gemini, messages, prompt)

      assert is_map(system_field)
      assert %{"parts" => [%{"text" => text}]} = system_field
      assert String.contains?(text, "user prefers Python")
      assert String.contains?(text, "## Memory")
    end

    test "memory flows into :chatgpt_codex instructions field", %{enhanced_prompt: prompt} do
      messages = [%{role: "user", content: "Write a script"}]

      {system_field, _chat_msgs} = SystemPrompt.normalize(:chatgpt_codex, messages, prompt)

      assert is_binary(system_field)
      assert String.contains?(system_field, "user prefers Python")
      assert String.contains?(system_field, "## Memory")
    end

    test "memory flows into :openai messages array as system message", %{
      enhanced_prompt: prompt
    } do
      messages = [%{role: "user", content: "Write a script"}]

      {system_field, normalized_msgs} = SystemPrompt.normalize(:openai, messages, prompt)

      assert system_field == nil

      first_msg = hd(normalized_msgs)
      assert first_msg.role == "system"
      assert String.contains?(first_msg.content, "user prefers Python")
      assert String.contains?(first_msg.content, "## Memory")
    end

    test "memory merges with existing system messages in :anthropic", %{
      enhanced_prompt: prompt
    } do
      messages = [
        %{role: "system", content: "Be concise."},
        %{role: "user", content: "Write a script"}
      ]

      {system_field, _chat_msgs} = SystemPrompt.normalize(:anthropic, messages, prompt)

      assert is_binary(system_field)
      assert String.contains?(system_field, "user prefers Python")
      assert String.contains?(system_field, "Be concise.")
      assert String.contains?(system_field, "## Memory")
    end
  end
end
