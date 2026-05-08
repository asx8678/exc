defmodule CodePuppyControl.PolicyEngine.PolicyRule do
  @moduledoc """
  PolicyRule struct and decision types for the PolicyEngine.

  Defines the Allow, Deny, and AskUser decision types, as well as
  the PolicyRule struct for configurable permission rules.

  ## Security

  Uses an allowlist for converting string decisions to atoms to prevent
  atom exhaustion attacks from untrusted JSON input.
  """

  require Logger

  # --------------------------------------------------------------------------
  # Permission Decision Types
  # --------------------------------------------------------------------------

  defmodule Allow do
    @moduledoc "The operation is permitted; proceed without further prompting."
    defstruct []

    @type t :: %__MODULE__{}
  end

  defmodule Deny do
    @moduledoc """
    The operation is denied.

    - `reason` - Machine-readable reason surfaced to the model
    - `user_feedback` - Optional human-readable feedback
    """
    defstruct [:reason, :user_feedback]

    @type t :: %__MODULE__{
            reason: String.t() | nil,
            user_feedback: String.t() | nil
          }
  end

  defmodule AskUser do
    @moduledoc """
    Defer the decision to an interactive user prompt.

    - `prompt` - Question / context to show the user
    """
    defstruct [:prompt]

    @type t :: %__MODULE__{prompt: String.t() | nil}
  end

  @typedoc "Possible decision atoms"
  @type decision :: :allow | :deny | :ask_user

  @typedoc "Permission decision union type"
  @type permission_decision :: Allow.t() | Deny.t() | AskUser.t()

  # --------------------------------------------------------------------------
  # Security: Allowlist for string-to-atom conversion
  # --------------------------------------------------------------------------

  @valid_decisions %{
    "allow" => :allow,
    "deny" => :deny,
    "ask_user" => :ask_user
  }

  @doc """
  Converts a decision string to a validated atom.

  Uses an allowlist to prevent atom exhaustion from untrusted input.
  Unknown values default to `:ask_user` (safe fallback).

  ## Examples

      iex> PolicyRule.safe_decision_atom("allow")
      :allow

      iex> PolicyRule.safe_decision_atom("deny")
      :deny

      iex> PolicyRule.safe_decision_atom("unknown")
      :ask_user

  """
  @spec safe_decision_atom(String.t()) :: decision()
  def safe_decision_atom(str) when is_binary(str) do
    Map.get(@valid_decisions, str, :ask_user)
  end

  # --------------------------------------------------------------------------
  # PolicyRule Struct
  # --------------------------------------------------------------------------

  defstruct [
    :tool_name,
    :decision,
    :priority,
    :command_pattern,
    :args_pattern,
    :source,
    :_compiled_command,
    :_compiled_args,
    :_command_pattern_valid,
    :_args_pattern_valid
  ]

  @type t :: %__MODULE__{
          tool_name: String.t(),
          decision: :allow | :deny | :ask_user,
          priority: integer(),
          command_pattern: String.t() | nil,
          args_pattern: String.t() | nil,
          source: String.t(),
          _compiled_command: Regex.t() | nil,
          _compiled_args: Regex.t() | nil,
          _command_pattern_valid: boolean() | nil,
          _args_pattern_valid: boolean() | nil
        }

  @doc """
  Creates a new PolicyRule with compiled regex patterns.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    rule = struct(__MODULE__, opts)
    compile_patterns(rule)
  end

  @doc false
  @spec compile_patterns(t()) :: t()
  defp compile_patterns(rule) do
    rule
    |> maybe_compile_command()
    |> maybe_compile_args()
  end

  defp maybe_compile_command(%{command_pattern: nil} = rule),
    do: %{rule | _command_pattern_valid: true}

  defp maybe_compile_command(%{command_pattern: pattern} = rule) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        %{rule | _compiled_command: regex, _command_pattern_valid: true}

      {:error, reason} ->
        Logger.warning("Invalid command_pattern regex: #{inspect(reason)}")
        %{rule | _command_pattern_valid: false}
    end
  end

  defp maybe_compile_args(%{args_pattern: nil} = rule), do: %{rule | _args_pattern_valid: true}

  defp maybe_compile_args(%{args_pattern: pattern} = rule) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} ->
        %{rule | _compiled_args: regex, _args_pattern_valid: true}

      {:error, reason} ->
        Logger.warning("Invalid args_pattern regex: #{inspect(reason)}")
        %{rule | _args_pattern_valid: false}
    end
  end
end
