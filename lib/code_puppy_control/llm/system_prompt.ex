defmodule CodePuppyControl.LLM.SystemPrompt do
  @moduledoc """
  Central system prompt normalization for LLM providers.

  Provides a unified interface for extracting, merging, and formatting
  system prompts across all LLM provider integrations. Each provider has
  different requirements for how system prompts are represented in request
  payloads — this module abstracts those differences.

  ## Provider Differences

  | Provider | System Prompt Location | Format |
  |----------|----------------------|--------|
  | OpenAI / Azure / Groq / Together | In `messages` array | `%{role: "system", content: "..."}` |
  | Anthropic | Top-level `system` field | String |
  | Gemini | Top-level `systemInstruction` field | `%{"parts" => [%{"text" => "..."}]}` |
  | ChatGPT Codex | Top-level `instructions` field | String |

  ## Usage

      # Extract system messages from a mixed messages list
      {system_text, chat_messages} = SystemPrompt.extract(messages)

      # Format for a specific provider
      SystemPrompt.format_for(:anthropic, system_text)  #=> "system text"
      SystemPrompt.format_for(:gemini, system_text)     #=> %{"parts" => [%{"text" => "system text"}]}

      # Merge system prompt from opts with system messages from messages
      merged = SystemPrompt.merge_opts_and_messages(opts_prompt, messages_prompt)

      # Ensure system prompt is in messages for OpenAI-compatible providers
      messages = SystemPrompt.ensure_in_messages(messages, opts_prompt)
  """

  @type provider_type :: :openai | :anthropic | :gemini | :chatgpt_codex

  # ── Extraction ─────────────────────────────────────────────────────────────

  @doc """
  Extract system messages from a messages list.

  Returns a tuple of `{system_text, chat_messages}` where `system_text` is
  the concatenated text of all system messages (joined with double newlines),
  and `chat_messages` is the remaining non-system messages in original order.

  Returns `nil` for `system_text` when no system messages are present.

  ## Examples

      iex> SystemPrompt.extract([%{role: "system", content: "You are helpful."}, %{role: "user", content: "Hi"}])
      {"You are helpful.", [%{role: "user", content: "Hi"}]}

      iex> SystemPrompt.extract([%{role: "user", content: "Hi"}])
      {nil, [%{role: "user", content: "Hi"}]}
  """
  @spec extract([map()]) :: {String.t() | nil, [map()]}
  def extract(messages) when is_list(messages) do
    {system_msgs, chat_msgs} =
      Enum.split_with(messages, fn
        %{role: "system"} -> true
        %{role: :system} -> true
        %{"role" => "system"} -> true
        _ -> false
      end)

    system_text =
      system_msgs
      |> Enum.map_join("\n\n", fn
        %{content: content} -> content || ""
        %{"content" => content} -> content || ""
      end)

    if system_text == "", do: {nil, chat_msgs}, else: {system_text, chat_msgs}
  end

  # ── Formatting ─────────────────────────────────────────────────────────────

  @doc """
  Format a system prompt for a specific provider type.

  Returns the provider-specific representation of the system prompt,
  or `nil` if no system prompt text is provided.

  ## Examples

      iex> SystemPrompt.format_for(:anthropic, "Be helpful")
      "Be helpful"

      iex> SystemPrompt.format_for(:gemini, "Be helpful")
      %{"parts" => [%{"text" => "Be helpful"}]}

      iex> SystemPrompt.format_for(:chatgpt_codex, "Be helpful")
      "Be helpful"

      iex> SystemPrompt.format_for(:openai, "Be helpful")
      %{role: "system", content: "Be helpful"}

      iex> SystemPrompt.format_for(:anthropic, nil)
      nil
  """
  @spec format_for(provider_type(), String.t() | nil) :: term() | nil
  def format_for(:openai, nil), do: nil
  def format_for(:openai, system_text), do: %{role: "system", content: system_text}

  def format_for(:anthropic, nil), do: nil
  def format_for(:anthropic, system_text), do: system_text

  def format_for(:gemini, nil), do: nil

  def format_for(:gemini, system_text) do
    %{"parts" => [%{"text" => system_text}]}
  end

  def format_for(:chatgpt_codex, nil), do: nil
  def format_for(:chatgpt_codex, system_text), do: system_text

  # ── Merging ───────────────────────────────────────────────────────────────

  @doc """
  Merge system prompt from opts with system text extracted from messages.

  When both sources are present, concatenates them with the opts prompt first.
  When only one source exists, returns that. When neither exists, returns nil.

  This handles the case where a system prompt is supplied via the `:system_prompt`
  option AND system messages exist in the messages list (e.g., when the agent
  loop assembles a prompt and also passes it as an opt for ChatGPT Codex).

  ## Examples

      iex> SystemPrompt.merge_opts_and_messages("From opts", "From messages")
      "From opts\\n\\nFrom messages"

      iex> SystemPrompt.merge_opts_and_messages("From opts", nil)
      "From opts"

      iex> SystemPrompt.merge_opts_and_messages(nil, nil)
      nil
  """
  @spec merge_opts_and_messages(String.t() | nil, String.t() | nil) :: String.t() | nil
  def merge_opts_and_messages(nil, nil), do: nil
  def merge_opts_and_messages(opts_prompt, nil), do: opts_prompt
  def merge_opts_and_messages(nil, messages_prompt), do: messages_prompt

  def merge_opts_and_messages(opts_prompt, messages_prompt) do
    "#{opts_prompt}\n\n#{messages_prompt}"
  end

  # ── OpenAI-Compatible Helpers ─────────────────────────────────────────────

  @doc """
  Ensure a system prompt message is present in the messages list.

  For OpenAI-compatible providers, system prompts belong in the messages
  array as `%{role: "system", content: "..."}`. If the `system_prompt_opt`
  is provided and no system messages already exist in the messages list,
  prepends a system message. If system messages already exist or no
  opt is provided, returns messages unchanged.

  ## Examples

      iex> SystemPrompt.ensure_in_messages([%{role: "user", content: "Hi"}], "Be helpful")
      [%{role: "system", content: "Be helpful"}, %{role: "user", content: "Hi"}]

      iex> SystemPrompt.ensure_in_messages([%{role: "system", content: "Existing"}, %{role: "user", content: "Hi"}], "New")
      [%{role: "system", content: "Existing"}, %{role: "user", content: "Hi"}]

      iex> SystemPrompt.ensure_in_messages([%{role: "user", content: "Hi"}], nil)
      [%{role: "user", content: "Hi"}]
  """
  @spec ensure_in_messages([map()], String.t() | nil) :: [map()]
  def ensure_in_messages(messages, nil), do: messages
  def ensure_in_messages(messages, ""), do: messages

  def ensure_in_messages(messages, system_prompt_opt) when is_binary(system_prompt_opt) do
    has_system? =
      Enum.any?(messages, fn
        %{role: "system"} -> true
        %{"role" => "system"} -> true
        _ -> false
      end)

    if has_system? do
      messages
    else
      [%{role: "system", content: system_prompt_opt} | messages]
    end
  end

  # ── Model-Specific Prompt Overrides ────────────────────────────────────────

  @doc """
  Apply model-specific system prompt overrides via the `:get_model_system_prompt` hook.

  Calls `Triggers.on_get_model_system_prompt/3` and extracts the `instructions`
  field from callback results. If callbacks return an updated instructions value,
  it replaces the original system prompt text. Otherwise returns the original
  prompt unchanged.

  Handles both string-keyed (`%{"instructions" => ...}`) and atom-keyed
  (`%{instructions: ...}`) result maps for compatibility with different plugin
  implementations.
  """
  @spec apply_model_overrides(String.t(), String.t() | nil, String.t() | nil) ::
          String.t() | nil
  def apply_model_overrides(_model_name, nil, _user_prompt), do: nil
  def apply_model_overrides(_model_name, "", _user_prompt), do: ""

  def apply_model_overrides(model_name, system_prompt_text, user_prompt)
      when is_binary(system_prompt_text) do
    result =
      CodePuppyControl.Callbacks.Triggers.on_get_model_system_prompt(
        model_name,
        system_prompt_text,
        user_prompt || ""
      )

    cond do
      # Single map result with instructions
      is_map(result) and not is_struct(result) and
          (is_binary(Map.get(result, :instructions)) or
             is_binary(Map.get(result, "instructions"))) ->
        Map.get(result, :instructions) || Map.get(result, "instructions")

      # List of results (multiple callbacks): take the last non-nil map with instructions
      is_list(result) ->
        last =
          result
          |> Enum.reverse()
          |> Enum.find(fn
            v when is_map(v) and not is_struct(v) ->
              is_binary(Map.get(v, :instructions)) or is_binary(Map.get(v, "instructions"))

            _ ->
              false
          end)

        if last != nil do
          Map.get(last, :instructions) || Map.get(last, "instructions")
        else
          system_prompt_text
        end

      # No useful result — return original
      true ->
        system_prompt_text
    end
  end

  # ── Provider Dispatch ─────────────────────────────────────────────────────

  @doc """
  Normalize messages and build provider-specific system prompt fields.

  This is the main entry point for providers. It:
  1. Extracts system messages from the messages list
  2. Merges with system_prompt from opts (if present)
  3. Returns `{system_field_value, chat_messages}` where
     `system_field_value` is formatted for the provider type

  For OpenAI-compatible providers, returns `{nil, messages_with_system_prepended}`
  since system prompts stay in the messages array.

  For Anthropic/Gemini/ChatGPT Codex, returns `{formatted_system, chat_messages}`
  where chat_messages have system messages removed.

  ## Examples

      iex> messages = [%{role: "system", content: "Be helpful"}, %{role: "user", content: "Hi"}]
      iex> SystemPrompt.normalize(:anthropic, messages, nil)
      {"Be helpful", [%{role: "user", content: "Hi"}]}

      iex> SystemPrompt.normalize(:openai, [%{role: "user", content: "Hi"}], "Be helpful")
      {nil, [%{role: "system", content: "Be helpful"}, %{role: "user", content: "Hi"}]}
  """
  @spec normalize(provider_type(), [map()], String.t() | nil) :: {term() | nil, [map()]}
  def normalize(:openai, messages, system_prompt_opt) do
    # OpenAI-compatible: system messages stay in messages array.
    # Just ensure the opt is also present if no system messages exist.
    messages = ensure_in_messages(messages, system_prompt_opt)
    {nil, messages}
  end

  def normalize(provider_type, messages, system_prompt_opt) do
    # Extract system messages from messages
    {messages_system_text, chat_messages} = extract(messages)

    # Merge with opts
    merged = merge_opts_and_messages(system_prompt_opt, messages_system_text)

    # Format for provider
    formatted = format_for(provider_type, merged)

    {formatted, chat_messages}
  end

  @doc """
  Normalize messages for a specific model, applying model-specific prompt overrides.

  Like `normalize/3`, but also applies the `:get_model_system_prompt` hook
  with the given `model_name` before formatting for the provider. This ensures
  plugin-provided model-specific prompt overrides are applied.

  ## Examples

      iex> messages = [%{role: "system", content: "Be helpful"}, %{role: "user", content: "Hi"}]
      iex> SystemPrompt.normalize(:anthropic, "claude-3", messages, nil)
      {"Be helpful", [%{role: "user", content: "Hi"}]}
  """
  @spec normalize(provider_type(), String.t(), [map()], String.t() | nil) ::
          {term() | nil, [map()]}
  def normalize(:openai, model_name, messages, system_prompt_opt) do
    prompt_opt =
      if system_prompt_opt do
        apply_model_overrides(model_name, system_prompt_opt, "")
      else
        nil
      end

    messages = ensure_in_messages(messages, prompt_opt)
    {nil, messages}
  end

  def normalize(provider_type, model_name, messages, system_prompt_opt) do
    {messages_system_text, chat_messages} = extract(messages)
    merged = merge_opts_and_messages(system_prompt_opt, messages_system_text)

    merged =
      if merged do
        apply_model_overrides(model_name, merged, "")
      else
        nil
      end

    formatted = format_for(provider_type, merged)
    {formatted, chat_messages}
  end
end
