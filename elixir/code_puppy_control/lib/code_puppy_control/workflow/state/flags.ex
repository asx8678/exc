defmodule CodePuppyControl.Workflow.State.Flags do
  @moduledoc """
  Workflow flag definitions and resolution.

  All workflow flags with descriptions. Mirrors Python's WorkflowFlag enum.
  NOTE: :did_make_api_call was missing from the original Elixir WorkflowState
  but is present in the Python source — added here for full parity.

  TODO(code-puppy-ctj.3): Keep in sync with Python WorkflowFlag enum
  """

  @all_flags [
    {:did_generate_code, "Code was generated/modified"},
    {:did_execute_shell, "Shell command executed"},
    {:did_load_context, "Context/files loaded"},
    {:did_create_plan, "Plan created"},
    {:did_encounter_error, "Error occurred"},
    {:needs_user_confirmation, "User confirmation pending"},
    {:did_save_session, "Session saved"},
    {:did_use_fallback_model, "Fallback model used"},
    {:did_trigger_compaction, "Context compacted"},
    {:did_make_api_call, "API call made to model"},
    {:did_edit_file, "File edited"},
    {:did_create_file, "File created"},
    {:did_delete_file, "File deleted"},
    {:did_run_tests, "Tests run"},
    {:did_check_lint, "Linting performed"}
  ]

  @flag_names Enum.map(@all_flags, fn {name, _desc} -> name end)

  @flag_by_string @all_flags
                  |> Enum.map(fn {name, _desc} -> {Atom.to_string(name), name} end)
                  |> Enum.into(%{})
                  |> Map.merge(
                    # Also support uppercase snake_case (Python enum name format)
                    @all_flags
                    |> Enum.map(fn {name, _desc} ->
                      {name |> Atom.to_string() |> String.upcase(), name}
                    end)
                    |> Enum.into(%{})
                  )

  @doc "Returns all known flag definitions as `[{atom, description}]`."
  @spec all_flags() :: [{atom(), String.t()}]
  def all_flags, do: @all_flags

  @doc "Returns all known flag name atoms."
  @spec flag_names() :: [atom()]
  def flag_names, do: @flag_names

  @doc "Checks whether `name` is a known flag atom."
  @spec known_flag?(atom()) :: boolean()
  def known_flag?(name) when is_atom(name), do: name in @flag_names
  def known_flag?(_), do: false

  @doc """
  Resolves a flag from atom or string to its canonical atom form.

  Supports both atom and string inputs. Strings are matched case-insensitively
  against known flag names (e.g. `"did_generate_code"`, `"DID_GENERATE_CODE"`
  all resolve to `:did_generate_code`).

  Returns `{:ok, atom}` if the flag is known, `{:error, :unknown_flag}` otherwise.
  """
  @spec resolve_flag(atom() | String.t()) :: {:ok, atom()} | {:error, :unknown_flag}
  def resolve_flag(name) when is_atom(name) do
    if known_flag?(name), do: {:ok, name}, else: {:error, :unknown_flag}
  end

  def resolve_flag(name) when is_binary(name) do
    case Map.get(@flag_by_string, name) do
      nil ->
        # Try case-insensitive lookup
        name_lower = String.downcase(name)

        Enum.find_value(@all_flags, {:error, :unknown_flag}, fn {atom, _desc} ->
          if Atom.to_string(atom) == name_lower, do: {:ok, atom}
        end)

      atom ->
        {:ok, atom}
    end
  end
end
