defmodule CodePuppyControl.Plugins.AgentMemory.Prompts do
  @moduledoc """
  Prompt injection and memory formatting for agent memory.

  Formats facts into a memory section and injects them into
  system prompts via the :get_model_system_prompt hook.
  """

  alias CodePuppyControl.Plugins.AgentMemory.{Config, Storage}

  @doc """
  Format facts into a memory section for prompt injection.

  Sorts by confidence (highest first), respects max_facts and token_budget.
  Returns nil if no facts fit within budget.
  """
  @spec format_memory_section([map()], pos_integer(), pos_integer()) :: String.t() | nil
  def format_memory_section([], _max_facts, _token_budget), do: nil

  def format_memory_section(facts, max_facts, token_budget) do
    sorted = Enum.sort_by(facts, &Map.get(&1, "confidence", 0.0), :desc)
    chars_per_token = 4
    max_chars = token_budget * chars_per_token
    lines = ["## Memory"]
    current_chars = byte_size(hd(lines)) + 1

    {lines, _} =
      Enum.reduce_while(Enum.take(sorted, max_facts), {lines, current_chars}, fn fact,
                                                                                 {acc, chars} ->
        text = String.trim(Map.get(fact, "text", ""))
        confidence = Map.get(fact, "confidence", 0.5)

        if text == "" do
          {:cont, {acc, chars}}
        else
          line = "- #{text} (confidence: #{:erlang.float_to_binary(confidence, decimals: 1)})"
          line_chars = byte_size(line) + 1

          if chars + line_chars > max_chars do
            {:halt, {acc, chars}}
          else
            {:cont, {acc ++ [line], chars + line_chars}}
          end
        end
      end)

    if length(lines) == 1, do: nil, else: Enum.join(lines, "\n")
  end

  @doc """
  Callback for :get_model_system_prompt hook.

  Injects relevant memories into the system prompt if memory is enabled.
  """
  @spec on_get_model_system_prompt(String.t(), String.t(), String.t()) :: map() | nil
  def on_get_model_system_prompt(_model_name, default_prompt, user_prompt) do
    config = Config.load()

    if not config.enabled do
      nil
    else
      agent_name =
        Process.get(:current_agent_name) ||
          Application.get_env(:code_puppy_control, :current_agent_name)

      if agent_name == nil do
        nil
      else
        facts = Storage.get_facts(agent_name, config.min_confidence)

        if facts == [] do
          nil
        else
          section = format_memory_section(facts, config.max_facts, config.token_budget)

          if section == nil do
            nil
          else
            %{
              "instructions" => "#{default_prompt}\n\n#{section}",
              "user_prompt" => user_prompt,
              "handled" => false
            }
          end
        end
      end
    end
  end
end
