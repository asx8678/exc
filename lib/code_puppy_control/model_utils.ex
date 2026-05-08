defmodule CodePuppyControl.ModelUtils do
  @moduledoc """
  Model-related utilities for prompt preparation and model type detection.

  Pure functions module - no GenServer needed.
  Ports Python's `code_puppy/model_utils.py`.

  This module centralizes logic for handling model-specific behaviors,
  particularly for claude-code models which require special prompt handling.
  """

  # The instruction override used for claude-code models
  @claude_code_instructions "You are Claude Code, Anthropic's official CLI for Claude."

  defmodule PreparedPrompt do
    @moduledoc """
    Result of preparing a prompt for a specific model.

    Fields:
    - `instructions`: The system instructions to use for the agent
    - `user_prompt`: The user prompt (possibly modified)
    - `is_claude_code`: Whether this is a claude-code model
    """

    @enforce_keys [:instructions, :user_prompt, :is_claude_code]

    defstruct [
      :instructions,
      :user_prompt,
      :is_claude_code
    ]

    @type t :: %__MODULE__{
            instructions: String.t(),
            user_prompt: String.t(),
            is_claude_code: boolean()
          }
  end

  @doc """
  Check if a model is a claude-code model.

  ## Examples

      iex> ModelUtils.is_claude_code_model("claude-code")
      true

      iex> ModelUtils.is_claude_code_model("claude-code-latest")
      true

      iex> ModelUtils.is_claude_code_model("claude-sonnet-4")
      false

      iex> ModelUtils.is_claude_code_model("gpt-4o")
      false
  """
  @spec is_claude_code_model(String.t()) :: boolean()
  def is_claude_code_model(model_name) when is_binary(model_name) do
    String.starts_with?(model_name, "claude-code")
  end

  def is_claude_code_model(_), do: false

  @doc """
  Prepare instructions and prompt for a specific model.

  This function handles model-specific system prompt requirements.
  For claude-code models, it replaces the system instructions with
  the standard Claude Code instructions and optionally prepends the
  original system prompt to the user prompt.

  ## Options

  - `:prepend_system_to_user` - Whether to prepend system prompt to user prompt
    for claude-code models (default: `true`)

  ## Examples

      # Claude-code model with prepend (default)
      iex> ModelUtils.prepare_prompt_for_model("claude-code", "System prompt", "User prompt")
      %ModelUtils.PreparedPrompt{
        instructions: "You are Claude Code, Anthropic's official CLI for Claude.",
        user_prompt: "System prompt\\n\\nUser prompt",
        is_claude_code: true
      }

      # Claude-code model without prepend
      iex> ModelUtils.prepare_prompt_for_model("claude-code", "System", "User", prepend_system_to_user: false)
      %ModelUtils.PreparedPrompt{
        instructions: "You are Claude Code, Anthropic's official CLI for Claude.",
        user_prompt: "User",
        is_claude_code: true
      }

      # Non-claude-code model (passthrough)
      iex> ModelUtils.prepare_prompt_for_model("gpt-4o", "System", "User")
      %ModelUtils.PreparedPrompt{
        instructions: "System",
        user_prompt: "User",
        is_claude_code: false
      }
  """
  @spec prepare_prompt_for_model(String.t(), String.t(), String.t(), keyword()) ::
          PreparedPrompt.t()
  def prepare_prompt_for_model(model_name, system_prompt, user_prompt, opts \\ []) do
    prepend_system_to_user = Keyword.get(opts, :prepend_system_to_user, true)

    if is_claude_code_model(model_name) do
      build_claude_code_prompt(system_prompt, user_prompt, prepend_system_to_user)
    else
      %PreparedPrompt{
        instructions: system_prompt,
        user_prompt: user_prompt,
        is_claude_code: false
      }
    end
  end

  @doc """
  Get the standard claude-code instructions string.

  ## Examples

      iex> ModelUtils.get_claude_code_instructions()
      "You are Claude Code, Anthropic's official CLI for Claude."
  """
  @spec get_claude_code_instructions() :: String.t()
  def get_claude_code_instructions do
    @claude_code_instructions
  end

  @doc """
  Return the default extended_thinking mode for an Anthropic model.

  Opus 4-6 models default to `"adaptive"` thinking; all other
  Anthropic models default to `"enabled"`.

  ## Examples

      iex> ModelUtils.get_default_extended_thinking("claude-opus-4-6")
      "adaptive"

      iex> ModelUtils.get_default_extended_thinking("anthropic-4-6-opus")
      "adaptive"

      iex> ModelUtils.get_default_extended_thinking("claude-sonnet-4")
      "enabled"

      iex> ModelUtils.get_default_extended_thinking("claude-code")
      "enabled"
  """
  @spec get_default_extended_thinking(String.t()) :: String.t()
  def get_default_extended_thinking(model_name) when is_binary(model_name) do
    lower = String.downcase(model_name)

    if String.contains?(lower, "opus-4-6") or String.contains?(lower, "4-6-opus") do
      "adaptive"
    else
      "enabled"
    end
  end

  def get_default_extended_thinking(_), do: "enabled"

  # Private functions

  defp build_claude_code_prompt(system_prompt, user_prompt, prepend_system_to_user) do
    modified_prompt =
      if prepend_system_to_user and system_prompt != "" do
        "#{system_prompt}\n\n#{user_prompt}"
      else
        user_prompt
      end

    %PreparedPrompt{
      instructions: @claude_code_instructions,
      user_prompt: modified_prompt,
      is_claude_code: true
    }
  end
end
