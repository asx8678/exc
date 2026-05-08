defmodule CodePuppyControl.Tools.CommandRunner.Validator do
  @moduledoc """
  Security validation for shell commands.

  This module provides defense-in-depth security validation for shell commands
  before execution. Even though upstream security (policy engine) validates
  commands, this adds an additional layer of protection at the execution point.

  ## Validation Layers

  1. **Command length** - Prevents DoS via massive input
  2. **Forbidden characters** - Blocks control characters
  3. **Dangerous patterns** - Detects potential command injection
  4. **Shell parse validation** - Verifies command can be tokenized

  ## Examples

      iex> Validator.validate("echo hello")
      {:ok, "echo hello"}

      iex> Validator.validate("")
      {:error, "Command cannot be empty or whitespace only"}

      iex> Validator.validate(String.duplicate("a", 9000))
      {:error, "Command exceeds maximum length..."}
  """

  # Maximum command length to prevent DoS via massive input
  @max_command_length 8192

  # Dangerous patterns that should be blocked even if upstream checks pass
  # These patterns could indicate command injection attempts
  @dangerous_patterns [
    # Process substitution (bash-specific, can be dangerous)
    # Input process substitution: <(command)
    ~r/<\s*\(/,
    # Output process substitution: >(command)
    ~r/>\s*\(/,
    # Multiple redirections that could be abused
    # Multiple fd redirections
    ~r/\d*>&\d*\s*\d*>&/,
    # Null byte injection
    ~r/\x00/
  ]

  # ASCII control characters that are forbidden (0x00-0x08, 0x0B-0x0C, 0x0E-0x1F, 0x7F)
  @forbidden_chars_pattern ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/

  @doc """
  Validates a shell command for security issues before execution.

  This is a defense-in-depth measure. Commands are also validated upstream
  by the policy engine, but we add an additional layer of protection here.

  ## Returns

  - `{:ok, command}` - The validated command (unchanged if valid)
  - `{:error, reason}` - The command failed security validation

  ## Validation Steps

  1. Empty/whitespace check
  2. Length limit check
  3. Forbidden character check (control chars)
  4. Dangerous pattern check (process substitution, etc.)
  5. Shell parse validation
  """
  @spec validate(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate(command) when is_binary(command) do
    with :ok <- validate_not_empty(command),
         :ok <- validate_length(command),
         :ok <- validate_forbidden_chars(command),
         :ok <- validate_dangerous_patterns(command),
         :ok <- validate_shell_parsable(command) do
      {:ok, command}
    end
  end

  def validate(_), do: {:error, "Command must be a string"}

  @doc """
  Validates that the command is not empty or whitespace only.
  """
  @spec validate_not_empty(String.t()) :: :ok | {:error, String.t()}
  def validate_not_empty(command) do
    trimmed = String.trim(command)

    if trimmed == "" do
      {:error, "Command cannot be empty or whitespace only"}
    else
      :ok
    end
  end

  @doc """
  Validates command length is within acceptable limits.
  """
  @spec validate_length(String.t()) :: :ok | {:error, String.t()}
  def validate_length(command) do
    len = String.length(command)

    if len > @max_command_length do
      {:error,
       "Command exceeds maximum length of #{@max_command_length} characters " <>
         "(got #{len} characters)"}
    else
      :ok
    end
  end

  @doc """
  Checks for forbidden control characters in command.

  Matches ASCII 0x00-0x08, 0x0B-0x0C, 0x0E-0x1F, and 0x7F (DEL).
  """
  @spec validate_forbidden_chars(String.t()) :: :ok | {:error, String.t()}
  def validate_forbidden_chars(command) do
    case Regex.run(@forbidden_chars_pattern, command, return: :index) do
      nil ->
        :ok

      matches ->
        # Format first few matches for error message
        char_info =
          matches
          |> Enum.take(5)
          |> Enum.map(fn {pos, _} ->
            char = String.at(command, pos)
            codepoint = :binary.at(char, 0)

            "0x#{Integer.to_string(codepoint, 16) |> String.pad_leading(2, "0")} at position #{pos}"
          end)
          |> Enum.join(", ")

        suffix = if length(matches) > 5, do: " (and more...)", else: ""

        {:error, "Command contains forbidden control characters: #{char_info}#{suffix}"}
    end
  end

  @doc """
  Checks for dangerous shell patterns that could indicate injection.

  Includes process substitution patterns and suspicious redirections.
  """
  @spec validate_dangerous_patterns(String.t()) :: :ok | {:error, String.t()}
  def validate_dangerous_patterns(command) do
    Enum.reduce_while(@dangerous_patterns, :ok, fn pattern, _acc ->
      case Regex.run(pattern, command, return: :index) do
        nil ->
          {:cont, :ok}

        [{start, len} | _] ->
          # Show context around the match
          context_start = max(0, start - 20)
          context_end = min(String.length(command), start + len + 20)
          context = String.slice(command, context_start, context_end - context_start)

          {:halt, {:error, "Command contains dangerous pattern near: '...#{context}...'"}}
      end
    end)
  end

  @doc """
  Validates command can be parsed/tokenized as a shell command.

  This verifies the command string can be properly parsed. It catches
  malformed quoting like unbalanced quotes, empty commands, etc.

  Note: This does NOT catch injection attempts like "echo hi; rm -rf /" -
  those are valid shell commands. This only validates proper quoting and
  tokenization.
  """
  @spec validate_shell_parsable(String.t()) :: :ok | {:error, String.t()}
  def validate_shell_parsable(command) do
    # Simulate shell tokenization by checking for basic structural issues
    # This is a simplified check - the actual shell will handle the full parsing

    # Check for balanced quotes (single and double)
    case check_balanced_quotes(command) do
      :ok ->
        # Check that the command has at least some non-whitespace content
        # after removing quotes
        cleaned =
          command
          |> String.replace(~r/'[^']*'/, "")
          |> String.replace(~r/"[^"]*"/, "")
          |> String.trim()

        if cleaned == "" do
          {:error, "Command contains no valid tokens after parsing"}
        else
          :ok
        end

      {:error, reason} ->
        {:error, "Command parsing failed (possible malformed input): #{reason}"}
    end
  end

  # Check for balanced single and double quotes
  # Handles backslash-escaped quotes properly
  defp check_balanced_quotes(command) do
    command
    |> String.graphemes()
    |> Enum.reduce({:normal, false}, fn
      "\\", {mode, false} -> {mode, true}
      _, {mode, true} -> {mode, false}
      "'", {:normal, false} -> {:single, false}
      "'", {:single, false} -> {:normal, false}
      "\"", {:normal, false} -> {:double, false}
      "\"", {:double, false} -> {:normal, false}
      _, {mode, _} -> {mode, false}
    end)
    |> case do
      {:normal, _} -> :ok
      {:single, _} -> {:error, "unbalanced single quotes"}
      {:double, _} -> {:error, "unbalanced double quotes"}
    end
  end

  @doc """
  Returns the maximum allowed command length.
  """
  @spec max_command_length() :: non_neg_integer()
  def max_command_length, do: @max_command_length
end
