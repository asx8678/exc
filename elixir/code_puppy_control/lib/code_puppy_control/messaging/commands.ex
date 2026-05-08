defmodule CodePuppyControl.Messaging.Commands do
  @moduledoc """
  UI→Agent command schema and serialization.

  Defines command structs that flow FROM the UI TO the Agent, mirroring the
  Python `code_puppy.messaging.commands` models. Commands control agent
  execution (cancel, interrupt) and carry user responses to agent prompts
  (input, confirmation, selection).

      ┌─────────┐   Commands    ┌─────────┐
      │   UI    │ ────────────> │  Agent  │
      │ (User)  │               │         │
      │         │ <──────────── │         │
      └─────────┘   Messages    └─────────┘

  ## Wire Format

  All commands are serialized as JSON-safe string-keyed maps with a
  `"command_type"` discriminator for polymorphic deserialization:

      %{
        "command_type" => "cancel_agent",
        "id" => "a1b2c3d4...",
        "timestamp" => 1717000000000,
        "reason" => "user requested"
      }

  ## Command Types

  | command_type           | Struct                    | Description                        |
  |------------------------|---------------------------|------------------------------------|
  | `"cancel_agent"`       | `CancelAgentCommand`      | Soft-cancel running agent          |
  | `"interrupt_shell"`    | `InterruptShellCommand`   | SIGINT a running shell command     |
  | `"user_input_response"`| `UserInputResponse`      | Respond to a user input prompt     |
  | `"confirmation_response"`| `ConfirmationResponse` | Respond to a confirmation prompt    |
  | `"selection_response"` | `SelectionResponse`       | Respond to a selection prompt      |
  | `"ask_user_question_response"` | `AskUserQuestionResponse` | Respond to a batch question prompt |

  ## Validation

  - `from_wire/1` rejects unknown `command_type` values with `{:error, :unknown_command_type}`.
  - Extra/unknown fields are rejected with `{:error, :extra_fields_not_allowed}`.
  - `SelectionResponse.selected_index` must be a non-negative integer.
  - Malformed payloads (non-maps, missing required keys, wrong types) return
    `{:error, reason}` — never raises.

  ## ID & Timestamp Defaults

  When `id` or `timestamp` are absent in a wire map, defaults are generated:
  - `id`: 32-char lowercase hex from `:crypto.strong_rand_bytes(16)`.
  - `timestamp`: Integer Unix milliseconds from `System.system_time(:millisecond)`.
  """

  # ---------------------------------------------------------------------------
  # Struct Definitions
  # ---------------------------------------------------------------------------

  defstruct [:command_type, :id, :timestamp]

  @type command_type ::
          :cancel_agent
          | :interrupt_shell
          | :user_input_response
          | :confirmation_response
          | :selection_response
          | :ask_user_question_response

  @type t ::
          CancelAgentCommand.t()
          | InterruptShellCommand.t()
          | UserInputResponse.t()
          | ConfirmationResponse.t()
          | SelectionResponse.t()
          | AskUserQuestionResponse.t()

  # -- CancelAgentCommand ----------------------------------------------------

  defmodule CancelAgentCommand do
    @moduledoc "Signals the agent to stop current execution gracefully."

    @enforce_keys [:command_type, :id, :timestamp]
    defstruct [:command_type, :id, :timestamp, :reason]

    @type t :: %__MODULE__{
            command_type: :cancel_agent,
            id: String.t(),
            timestamp: integer(),
            reason: String.t() | nil
          }
  end

  # -- InterruptShellCommand -------------------------------------------------

  defmodule InterruptShellCommand do
    @moduledoc "Signals to interrupt a currently running shell command."

    @enforce_keys [:command_type, :id, :timestamp]
    defstruct [:command_type, :id, :timestamp, :command_id]

    @type t :: %__MODULE__{
            command_type: :interrupt_shell,
            id: String.t(),
            timestamp: integer(),
            command_id: String.t() | nil
          }
  end

  # -- UserInputResponse -----------------------------------------------------

  defmodule UserInputResponse do
    @moduledoc "Response to a UserInputRequest from the agent."

    @enforce_keys [:command_type, :id, :timestamp, :prompt_id, :value]
    defstruct [:command_type, :id, :timestamp, :prompt_id, :value]

    @type t :: %__MODULE__{
            command_type: :user_input_response,
            id: String.t(),
            timestamp: integer(),
            prompt_id: String.t(),
            value: String.t()
          }
  end

  # -- ConfirmationResponse --------------------------------------------------

  defmodule ConfirmationResponse do
    @moduledoc "Response to a ConfirmationRequest from the agent."

    @enforce_keys [:command_type, :id, :timestamp, :prompt_id, :confirmed]
    defstruct [:command_type, :id, :timestamp, :prompt_id, :confirmed, :feedback]

    @type t :: %__MODULE__{
            command_type: :confirmation_response,
            id: String.t(),
            timestamp: integer(),
            prompt_id: String.t(),
            confirmed: boolean(),
            feedback: String.t() | nil
          }
  end

  # -- SelectionResponse -----------------------------------------------------

  defmodule SelectionResponse do
    @moduledoc "Response to a SelectionRequest from the agent."

    @enforce_keys [:command_type, :id, :timestamp, :prompt_id, :selected_index, :selected_value]
    defstruct [:command_type, :id, :timestamp, :prompt_id, :selected_index, :selected_value]

    @type t :: %__MODULE__{
            command_type: :selection_response,
            id: String.t(),
            timestamp: integer(),
            prompt_id: String.t(),
            selected_index: non_neg_integer(),
            selected_value: String.t()
          }
  end

  # -- AskUserQuestionResponse -----------------------------------------------

  defmodule AskUserQuestionResponse do
    @moduledoc "Response to an AskUserQuestionRequest from the agent."

    @enforce_keys [:command_type, :id, :timestamp, :prompt_id]
    defstruct [
      :command_type,
      :id,
      :timestamp,
      :prompt_id,
      :answers,
      :cancelled,
      :timed_out,
      :error
    ]

    @type t :: %__MODULE__{
            command_type: :ask_user_question_response,
            id: String.t(),
            timestamp: integer(),
            prompt_id: String.t(),
            answers: [map()] | nil,
            cancelled: boolean() | nil,
            timed_out: boolean() | nil,
            error: String.t() | nil
          }
  end

  # ---------------------------------------------------------------------------
  # Command Type Mapping
  # ---------------------------------------------------------------------------

  @command_type_to_module %{
    "cancel_agent" => CancelAgentCommand,
    "interrupt_shell" => InterruptShellCommand,
    "user_input_response" => UserInputResponse,
    "confirmation_response" => ConfirmationResponse,
    "selection_response" => SelectionResponse,
    "ask_user_question_response" => AskUserQuestionResponse
  }

  # Build reverse mapping at compile time using full module names
  # so that pattern match in to_wire/1 (%module{} = cmd) resolves correctly.
  @module_to_command_type @command_type_to_module
                          |> Enum.map(fn {type_str, mod} -> {mod, type_str} end)
                          |> Map.new()

  # ---------------------------------------------------------------------------
  # Constructors
  # ---------------------------------------------------------------------------

  @doc "Builds a `CancelAgentCommand`. Omitting `id`/`timestamp` triggers auto-generation."
  @spec cancel_agent(keyword()) :: CancelAgentCommand.t()
  def cancel_agent(opts \\ []) do
    {id, ts} = fill_defaults(opts)

    %CancelAgentCommand{
      command_type: :cancel_agent,
      id: id,
      timestamp: ts,
      reason: Keyword.get(opts, :reason)
    }
  end

  @doc "Builds an `InterruptShellCommand`."
  @spec interrupt_shell(keyword()) :: InterruptShellCommand.t()
  def interrupt_shell(opts \\ []) do
    {id, ts} = fill_defaults(opts)

    %InterruptShellCommand{
      command_type: :interrupt_shell,
      id: id,
      timestamp: ts,
      command_id: Keyword.get(opts, :command_id)
    }
  end

  @doc "Builds a `UserInputResponse`. `prompt_id` and `value` are required."
  @spec user_input_response(String.t(), String.t(), keyword()) :: UserInputResponse.t()
  def user_input_response(prompt_id, value, opts \\ []) do
    {id, ts} = fill_defaults(opts)

    %UserInputResponse{
      command_type: :user_input_response,
      id: id,
      timestamp: ts,
      prompt_id: prompt_id,
      value: value
    }
  end

  @doc "Builds a `ConfirmationResponse`. `prompt_id` and `confirmed` are required."
  @spec confirmation_response(String.t(), boolean(), keyword()) :: ConfirmationResponse.t()
  def confirmation_response(prompt_id, confirmed, opts \\ []) do
    {id, ts} = fill_defaults(opts)

    %ConfirmationResponse{
      command_type: :confirmation_response,
      id: id,
      timestamp: ts,
      prompt_id: prompt_id,
      confirmed: confirmed,
      feedback: Keyword.get(opts, :feedback)
    }
  end

  @doc """
  Builds a `SelectionResponse`.

  `prompt_id`, `selected_index` (≥ 0), and `selected_value` are required.
  Returns `{:ok, %SelectionResponse{}}` on success or
  `{:error, {:invalid_selected_index, value}}` if `selected_index` is
  negative or non-integer.
  """
  @spec selection_response(String.t(), term(), String.t(), keyword()) ::
          {:ok, SelectionResponse.t()} | {:error, {:invalid_selected_index, term()}}
  def selection_response(prompt_id, selected_index, selected_value, opts \\ []) do
    case validate_selected_index(selected_index) do
      :ok ->
        {id, ts} = fill_defaults(opts)

        {:ok,
         %SelectionResponse{
           command_type: :selection_response,
           id: id,
           timestamp: ts,
           prompt_id: prompt_id,
           selected_index: selected_index,
           selected_value: selected_value
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Bang variant of `selection_response/4`.

  Returns the struct directly on success; raises `ArgumentError` on invalid
  `selected_index`.
  """
  @spec selection_response!(String.t(), non_neg_integer(), String.t(), keyword()) ::
          SelectionResponse.t()
  def selection_response!(prompt_id, selected_index, selected_value, opts \\ []) do
    case selection_response(prompt_id, selected_index, selected_value, opts) do
      {:ok, cmd} ->
        cmd

      {:error, {:invalid_selected_index, val}} ->
        raise ArgumentError, "selected_index must be a non-negative integer, got: #{inspect(val)}"
    end
  end

  @doc """
  Builds an `AskUserQuestionResponse`.

  `prompt_id` is required. `answers` is a list of answer maps.
  """
  @spec ask_user_question_response(String.t(), [map()], keyword()) ::
          AskUserQuestionResponse.t()
  def ask_user_question_response(prompt_id, answers, opts \\ []) do
    {id, ts} = fill_defaults(opts)

    %AskUserQuestionResponse{
      command_type: :ask_user_question_response,
      id: id,
      timestamp: ts,
      prompt_id: prompt_id,
      answers: answers,
      cancelled: Keyword.get(opts, :cancelled, false),
      timed_out: Keyword.get(opts, :timed_out, false),
      error: Keyword.get(opts, :error)
    }
  end

  # ---------------------------------------------------------------------------
  # Serialization: to_wire / from_wire
  # ---------------------------------------------------------------------------

  @doc """
  Converts a command struct to a JSON-safe string-keyed map (wire format).

  The `command_type` atom is converted to its string discriminator.
  `nil` optional fields are omitted from the wire map for compactness.
  """
  @spec to_wire(t()) :: map()
  def to_wire(%module{} = cmd) do
    type_str = @module_to_command_type[module]

    cmd
    |> Map.from_struct()
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.map(fn
      {:command_type, _atom} -> {"command_type", type_str}
      {k, v} -> {Atom.to_string(k), v}
    end)
    |> Map.new()
  end

  @doc """
  Parses a string-keyed wire map into a typed command struct.

  Returns `{:ok, command}` on success or `{:error, reason}` on failure.
  Never raises — all validation errors are returned as tagged tuples.

  Delegates to `Commands.Deserialization.from_wire/1`.

  ## Error Reasons

  | reason                       | meaning                                       |
  |------------------------------|-----------------------------------------------|
  | `:not_a_map`                 | Input is not a map                            |
  | `:unknown_command_type`      | `command_type` value is not recognized         |
  | `:missing_command_type`      | `command_type` key absent                      |
  | `:extra_fields_not_allowed`  | Unknown fields present (forbid extra)         |
  | `{:invalid_field_type, key}`  | A field has the wrong primitive type           |
  | `{:missing_required_field, key}` | A required field is absent                |
  """
  @spec from_wire(map()) :: {:ok, t()} | {:error, term()}
  defdelegate from_wire(wire), to: CodePuppyControl.Messaging.Commands.Deserialization

  defp fill_defaults(opts) do
    id = Keyword.get(opts, :id) || generate_id()
    ts = Keyword.get(opts, :timestamp) || System.system_time(:millisecond)
    {id, ts}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp validate_selected_index(idx) when is_integer(idx) and idx >= 0, do: :ok

  defp validate_selected_index(idx), do: {:error, {:invalid_selected_index, idx}}
end
