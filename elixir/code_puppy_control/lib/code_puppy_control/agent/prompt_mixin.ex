defmodule CodePuppyControl.Agent.PromptMixin do
  @moduledoc """
  Agent prompt utilities mixin.

  This module provides functions for generating agent identity strings,
  gathering platform context, and assembling complete system prompts.

  Expected to be used by agent modules that implement
  `CodePuppyControl.Agent.Behaviour`.

  ## Usage

      defmodule MyApp.Agents.MyAgent do
        use CodePuppyControl.Agent.PromptMixin

        @impl true
        def name, do: :my_agent

        @impl true
        def system_prompt(_context) do
          "You are an expert..."
        end
      end
  """

  @doc """
  Generate a unique identity for an agent instance.

  Returns a string like 'my_agent-a3f2b1' combining name + short UUID.
  """
  @spec get_identity(atom(), String.t()) :: String.t()
  def get_identity(name, id) when is_atom(name) and is_binary(id) do
    "#{name}-#{String.slice(id, 0..5)}"
  end

  @doc """
  Generate the identity prompt suffix to embed in system prompts.

  Returns a string instructing the agent about its identity for task ownership.
  """
  @spec get_identity_prompt(String.t()) :: String.t()
  def get_identity_prompt(identity) when is_binary(identity) do
    """

    Your ID is `#{identity}`. Use this for any tasks which require identifying yourself
    such as claiming task ownership or coordination with other agents.
    """
  end

  @doc """
  Return runtime platform context for the system prompt.

  Includes OS, shell, date, language locale, git repo detection,
  and current working directory.
  """
  @spec get_platform_info() :: String.t()
  def get_platform_info do
    lines = []

    # OS / architecture
    lines =
      case :os.type() do
        {:win32, _} ->
          ["- Platform: Windows" | lines]

        {:unix, :darwin} ->
          ["- Platform: macOS" | lines]

        {:unix, :linux} ->
          ["- Platform: Linux" | lines]

        {:unix, _} ->
          ["- Platform: Unix" | lines]

        _ ->
          ["- Platform: unknown" | lines]
      end

    # Shell
    shell_var =
      case :os.type() do
        {:win32, _} -> "COMSPEC"
        _ -> "SHELL"
      end

    shell_val = System.get_env(shell_var, "unknown")
    lines = ["- Shell: #{shell_var}=#{shell_val}" | lines]

    # Current date
    dt = Date.utc_today() |> Date.to_iso8601()
    lines = ["- Current date: #{dt}" | lines]

    # Working directory
    cwd =
      try do
        File.cwd!()
      rescue
        _ -> "<unknown>"
      end

    lines = ["- Working directory: #{cwd}" | lines]

    # Git repo detection
    lines =
      if File.dir?(".git") do
        ["- The user is working inside a git repository" | lines]
      else
        lines
      end

    lines
    |> Enum.reverse()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Assemble the complete system prompt with platform info and identity.

  Assembles: base prompt + plugin additions + platform context + agent identity.

  Returns the full system prompt including platform and identity information.
  """
  @spec get_full_system_prompt(String.t(), String.t()) :: String.t()
  def get_full_system_prompt(base_prompt, identity)
      when is_binary(base_prompt) and is_binary(identity) do
    prompt = base_prompt

    # Add plugin prompt additions (e.g., from prompt_store, file_mentions)
    # Callbacks.on(:load_prompt) uses :concat_str merge strategy, so
    # the result is a merged binary string (or nil if no callbacks registered).
    prompt_additions = CodePuppyControl.Callbacks.on(:load_prompt)

    prompt =
      if is_binary(prompt_additions) and prompt_additions != "" do
        prompt <> "\n\n# Custom Instructions\n" <> prompt_additions
      else
        prompt
      end

    prompt <> "\n\n# Environment\n" <> get_platform_info() <> get_identity_prompt(identity)
  end
end
