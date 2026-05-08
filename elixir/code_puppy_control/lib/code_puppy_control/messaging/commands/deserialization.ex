defmodule CodePuppyControl.Messaging.Commands.Deserialization do
  @moduledoc """
  Wire-format deserialization for UI→Agent commands.

  Handles `from_wire/1` and all associated validation/field-extraction
  helpers. Extracted from `Commands` to keep the parent module under
  the 600-line hard cap.
  """

  alias CodePuppyControl.Messaging.Commands

  # Compile-time copies of the type-to-module and allowed-fields maps.
  # These are kept in sync with the parent Commands module by referencing
  # the same source of truth — the struct definitions themselves.
  @command_type_to_module %{
    "cancel_agent" => Commands.CancelAgentCommand,
    "interrupt_shell" => Commands.InterruptShellCommand,
    "user_input_response" => Commands.UserInputResponse,
    "confirmation_response" => Commands.ConfirmationResponse,
    "selection_response" => Commands.SelectionResponse,
    "ask_user_question_response" => Commands.AskUserQuestionResponse
  }

  @allowed_fields (
                    fields_by_type = %{
                      "cancel_agent" => ~w(command_type id timestamp reason),
                      "interrupt_shell" => ~w(command_type id timestamp command_id),
                      "user_input_response" => ~w(command_type id timestamp prompt_id value),
                      "confirmation_response" =>
                        ~w(command_type id timestamp prompt_id confirmed feedback),
                      "selection_response" =>
                        ~w(command_type id timestamp prompt_id selected_index selected_value),
                      "ask_user_question_response" =>
                        ~w(command_type id timestamp prompt_id answers cancelled timed_out error)
                    }

                    for {type_str, fields} <- fields_by_type,
                        into: %{} do
                      {@command_type_to_module[type_str], MapSet.new(fields)}
                    end
                  )

  @doc """
  Parses a string-keyed wire map into a typed command struct.

  Returns `{:ok, command}` on success or `{:error, reason}` on failure.
  Never raises — all validation errors are returned as tagged tuples.

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
  @spec from_wire(map()) :: {:ok, Commands.t()} | {:error, term()}
  def from_wire(wire) when is_map(wire) do
    with {:ok, type_str} <- fetch_command_type(wire),
         {:ok, module} <- resolve_module(type_str),
         :ok <- check_extra_fields(wire, module),
         {:ok, cmd} <- build_struct(wire, module) do
      {:ok, cmd}
    end
  end

  def from_wire(_), do: {:error, :not_a_map}

  # ── Private Helpers ──────────────────────────────────────────────────────

  defp fetch_command_type(wire) do
    case Map.fetch(wire, "command_type") do
      {:ok, type} when is_binary(type) -> {:ok, type}
      {:ok, _} -> {:error, :missing_command_type}
      :error -> {:error, :missing_command_type}
    end
  end

  defp resolve_module(type_str) do
    case Map.fetch(@command_type_to_module, type_str) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_command_type}
    end
  end

  defp check_extra_fields(wire, module) do
    allowed = @allowed_fields[module]
    extra = Map.keys(wire) |> MapSet.new() |> MapSet.difference(allowed)

    if MapSet.size(extra) == 0 do
      :ok
    else
      {:error, :extra_fields_not_allowed}
    end
  end

  defp build_struct(wire, module) do
    with {:ok, id} <- resolve_id(wire),
         {:ok, ts} <- resolve_timestamp(wire),
         {:ok, extra} <- extract_extra_fields(wire, module),
         {:ok, struct} <- construct_module(module, id, ts, extra),
         :ok <- validate_struct_fields(struct) do
      {:ok, struct}
    end
  end

  defp resolve_id(wire) do
    case Map.fetch(wire, "id") do
      {:ok, id} when is_binary(id) -> {:ok, id}
      {:ok, _} -> {:error, {:invalid_field_type, "id"}}
      :error -> {:ok, generate_id()}
    end
  end

  defp resolve_timestamp(wire) do
    case Map.fetch(wire, "timestamp") do
      {:ok, ts} when is_integer(ts) and ts >= 0 -> {:ok, ts}
      {:ok, _} -> {:error, {:invalid_field_type, "timestamp"}}
      :error -> {:ok, System.system_time(:millisecond)}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # -- extract_extra_fields per command type ---------------------------------

  defp extract_extra_fields(wire, Commands.CancelAgentCommand) do
    case Map.fetch(wire, "reason") do
      {:ok, r} when is_binary(r) or is_nil(r) -> {:ok, %{reason: r}}
      {:ok, _} -> {:error, {:invalid_field_type, "reason"}}
      :error -> {:ok, %{reason: nil}}
    end
  end

  defp extract_extra_fields(wire, Commands.InterruptShellCommand) do
    case Map.fetch(wire, "command_id") do
      {:ok, c} when is_binary(c) or is_nil(c) -> {:ok, %{command_id: c}}
      {:ok, _} -> {:error, {:invalid_field_type, "command_id"}}
      :error -> {:ok, %{command_id: nil}}
    end
  end

  defp extract_extra_fields(wire, Commands.UserInputResponse) do
    with {:ok, pid} <- require_string(wire, "prompt_id"),
         {:ok, val} <- require_string(wire, "value") do
      {:ok, %{prompt_id: pid, value: val}}
    end
  end

  defp extract_extra_fields(wire, Commands.ConfirmationResponse) do
    with {:ok, pid} <- require_string(wire, "prompt_id"),
         {:ok, confirmed} <- require_bool(wire, "confirmed"),
         {:ok, feedback} <- optional_string(wire, "feedback") do
      {:ok, %{prompt_id: pid, confirmed: confirmed, feedback: feedback}}
    end
  end

  defp extract_extra_fields(wire, Commands.SelectionResponse) do
    with {:ok, pid} <- require_string(wire, "prompt_id"),
         {:ok, idx} <- require_non_neg_int(wire, "selected_index"),
         {:ok, val} <- require_string(wire, "selected_value") do
      {:ok, %{prompt_id: pid, selected_index: idx, selected_value: val}}
    end
  end

  defp extract_extra_fields(wire, Commands.AskUserQuestionResponse) do
    with {:ok, pid} <- require_string(wire, "prompt_id"),
         {:ok, raw_answers} <- extract_list_or_empty(wire, "answers"),
         {:ok, answers} <- validate_answer_entries(raw_answers),
         {:ok, cancelled} <- extract_optional_bool(wire, "cancelled"),
         {:ok, timed_out} <- extract_optional_bool(wire, "timed_out"),
         {:ok, error} <- optional_string(wire, "error") do
      {:ok,
       %{
         prompt_id: pid,
         answers: answers,
         cancelled: cancelled,
         timed_out: timed_out,
         error: error
       }}
    end
  end

  # Validates each answer entry through Entries.question_answer_entry/1.
  # Returns {:ok, validated_list} or {:error, reason} on the first invalid entry.
  defp validate_answer_entries(answers) when is_list(answers) do
    CodePuppyControl.Messaging.Validation.validate_list(
      %{"answers" => answers},
      "answers",
      &CodePuppyControl.Messaging.Entries.question_answer_entry/1
    )
  end

  defp extract_list_or_empty(wire, key) do
    case Map.fetch(wire, key) do
      :error -> {:ok, []}
      {:ok, l} when is_list(l) -> {:ok, l}
      {:ok, o} -> {:error, {:invalid_field_type, key, o}}
    end
  end

  defp extract_optional_bool(wire, key) do
    case Map.fetch(wire, key) do
      :error -> {:ok, false}
      {:ok, v} when is_boolean(v) -> {:ok, v}
      {:ok, o} -> {:error, {:invalid_field_type, key, o}}
    end
  end

  # -- construct_module per command type -------------------------------------

  defp construct_module(Commands.CancelAgentCommand, id, ts, %{reason: reason}) do
    {:ok,
     %Commands.CancelAgentCommand{
       command_type: :cancel_agent,
       id: id,
       timestamp: ts,
       reason: reason
     }}
  end

  defp construct_module(Commands.InterruptShellCommand, id, ts, %{command_id: cid}) do
    {:ok,
     %Commands.InterruptShellCommand{
       command_type: :interrupt_shell,
       id: id,
       timestamp: ts,
       command_id: cid
     }}
  end

  defp construct_module(Commands.UserInputResponse, id, ts, %{prompt_id: pid, value: val}) do
    {:ok,
     %Commands.UserInputResponse{
       command_type: :user_input_response,
       id: id,
       timestamp: ts,
       prompt_id: pid,
       value: val
     }}
  end

  defp construct_module(Commands.ConfirmationResponse, id, ts, %{
         prompt_id: pid,
         confirmed: c,
         feedback: f
       }) do
    {:ok,
     %Commands.ConfirmationResponse{
       command_type: :confirmation_response,
       id: id,
       timestamp: ts,
       prompt_id: pid,
       confirmed: c,
       feedback: f
     }}
  end

  defp construct_module(Commands.SelectionResponse, id, ts, %{
         prompt_id: pid,
         selected_index: idx,
         selected_value: val
       }) do
    {:ok,
     %Commands.SelectionResponse{
       command_type: :selection_response,
       id: id,
       timestamp: ts,
       prompt_id: pid,
       selected_index: idx,
       selected_value: val
     }}
  end

  defp construct_module(Commands.AskUserQuestionResponse, id, ts, extra) do
    {:ok,
     %Commands.AskUserQuestionResponse{
       command_type: :ask_user_question_response,
       id: id,
       timestamp: ts,
       prompt_id: extra.prompt_id,
       answers: extra.answers,
       cancelled: extra.cancelled,
       timed_out: extra.timed_out,
       error: extra.error
     }}
  end

  # Final validation pass on the constructed struct.
  defp validate_struct_fields(%Commands.SelectionResponse{selected_index: idx}) do
    if is_integer(idx) and idx >= 0, do: :ok, else: {:error, :invalid_selected_index}
  end

  defp validate_struct_fields(_), do: :ok

  # -- Field type helpers ----------------------------------------------------

  defp require_string(wire, key) do
    case Map.fetch(wire, key) do
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, _} -> {:error, {:invalid_field_type, key}}
      :error -> {:error, {:missing_required_field, key}}
    end
  end

  defp require_bool(wire, key) do
    case Map.fetch(wire, key) do
      {:ok, v} when is_boolean(v) -> {:ok, v}
      {:ok, _} -> {:error, {:invalid_field_type, key}}
      :error -> {:error, {:missing_required_field, key}}
    end
  end

  defp require_non_neg_int(wire, key) do
    case Map.fetch(wire, key) do
      {:ok, v} when is_integer(v) and v >= 0 -> {:ok, v}
      {:ok, v} when is_integer(v) -> {:error, :invalid_selected_index}
      {:ok, _} -> {:error, :invalid_selected_index}
      :error -> {:error, {:missing_required_field, key}}
    end
  end

  defp optional_string(wire, key) do
    case Map.fetch(wire, key) do
      {:ok, v} when is_binary(v) or is_nil(v) -> {:ok, v}
      {:ok, _} -> {:error, {:invalid_field_type, key}}
      :error -> {:ok, nil}
    end
  end
end
