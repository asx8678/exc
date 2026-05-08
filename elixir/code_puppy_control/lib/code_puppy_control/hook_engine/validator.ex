defmodule CodePuppyControl.HookEngine.Validator do
  @moduledoc """
  Configuration validation for hooks.

  Validates hook configuration maps and provides actionable error messages.
  Ported from `code_puppy/hook_engine/validator.py`.
  """

  alias CodePuppyControl.HookEngine.Models

  @valid_event_types Models.supported_event_types()
  @valid_hook_type_strings ~w(command prompt)

  @doc """
  Validates a hooks configuration map.

  Returns `{:ok, config}` if valid, or `{:error, errors}` with a list of error messages.

  ## Examples

      iex> CodePuppyControl.HookEngine.Validator.validate_hooks_config(%{})
      {:ok, %{}}

      iex> {:error, [msg | _]} = CodePuppyControl.HookEngine.Validator.validate_hooks_config(%{"UnknownType" => []})
      iex> String.contains?(msg, "Unknown event type")
      true
  """
  @spec validate_hooks_config(map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate_hooks_config(config) when is_map(config) do
    errors =
      config
      |> Enum.reduce([], fn {event_type, hook_groups}, acc ->
        et = to_string(event_type)

        if String.starts_with?(et, "_") do
          acc
        else
          acc ++ validate_event_entry(et, hook_groups)
        end
      end)

    if errors == [] do
      {:ok, config}
    else
      {:error, errors}
    end
  end

  def validate_hooks_config(_config) do
    {:error, ["Configuration must be a map"]}
  end

  @doc """
  Returns a formatted validation report string.
  """
  @spec format_validation_report({:ok, term()} | {:error, [String.t()]}) :: String.t()
  def format_validation_report({:ok, _config}) do
    "✓ Configuration is valid"
  end

  def format_validation_report({:error, errors}) do
    lines = [
      "✗ Configuration has #{length(errors)} error(s):"
      | Enum.map(errors, &"  • #{&1}")
    ]

    suggestions = get_config_suggestions(errors)

    lines =
      if suggestions != [] do
        lines ++ ["" | ["Suggestions:" | Enum.map(suggestions, &"  → #{&1}")]]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  @doc """
  Returns a list of suggestions based on validation errors.
  """
  @spec get_config_suggestions([String.t()]) :: [String.t()]
  def get_config_suggestions(errors) when is_list(errors) do
    suggestions = []

    suggestions =
      if Enum.any?(errors, &String.contains?(&1, "Unknown event type")) do
        suggestions ++ ["Valid event types are: #{Enum.join(@valid_event_types, ", ")}"]
      else
        suggestions
      end

    suggestions =
      if Enum.any?(errors, &String.contains?(&1, "missing required field 'command'")) do
        suggestions ++
          [
            ~s(Hook commands should be shell commands like: 'bash .claude/hooks/my-hook.sh')
          ]
      else
        suggestions
      end

    suggestions
  end

  # ── Private ─────────────────────────────────────────────────────

  @spec validate_event_entry(String.t(), term()) :: [String.t()]
  defp validate_event_entry(event_type, hook_groups) do
    errors = []

    errors =
      if event_type not in @valid_event_types do
        errors ++
          [
            "Unknown event type '#{event_type}'. Valid types: #{Enum.join(@valid_event_types, ", ")}"
          ]
      else
        errors
      end

    errors ++ validate_hook_groups(event_type, hook_groups)
  end

  @spec validate_hook_groups(String.t(), term()) :: [String.t()]
  defp validate_hook_groups(_event_type, hook_groups) when is_list(hook_groups) do
    hook_groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {group, i} -> validate_hook_group(group, i) end)
  end

  defp validate_hook_groups(event_type, _hook_groups) do
    ["'#{event_type}' must be a list of hook groups"]
  end

  @spec validate_hook_group(term(), non_neg_integer()) :: [String.t()]
  defp validate_hook_group(group, index) when is_map(group) do
    errors = []

    errors =
      if not Map.has_key?(group, "matcher") do
        errors ++ ["'[#{index}]' missing required field 'matcher'"]
      else
        errors
      end

    errors =
      if not Map.has_key?(group, "hooks") do
        errors ++ ["'[#{index}]' missing required field 'hooks'"]
      else
        hooks = Map.get(group, "hooks", [])

        if is_list(hooks) do
          errors ++ validate_hooks_list(hooks, index)
        else
          errors ++ ["'[#{index}].hooks' must be a list"]
        end
      end

    errors
  end

  defp validate_hook_group(_group, index) do
    ["'[#{index}]' must be a map with 'matcher' and 'hooks'"]
  end

  @spec validate_hooks_list(list(), non_neg_integer()) :: [String.t()]
  defp validate_hooks_list(hooks, group_idx) do
    hooks
    |> Enum.with_index()
    |> Enum.flat_map(fn {hook, i} -> validate_single_hook(hook, group_idx, i) end)
  end

  @spec validate_single_hook(term(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  defp validate_single_hook(hook, group_idx, hook_idx) when is_map(hook) do
    prefix = "[#{group_idx}].hooks[#{hook_idx}]"
    errors = []

    hook_type = Map.get(hook, "type", Map.get(hook, :type))

    errors =
      if is_nil(hook_type) do
        errors ++ ["'#{prefix}' missing required field 'type'"]
      else
        ht = to_string(hook_type)

        if ht not in @valid_hook_type_strings do
          errors ++
            [
              "'#{prefix}' invalid type '#{ht}'. Must be one of: command, prompt"
            ]
        else
          errors
        end
      end

    errors =
      cond do
        to_string(hook_type) == "command" and is_nil(Map.get(hook, "command")) ->
          errors ++ ["'#{prefix}' missing required field 'command' for type 'command'"]

        to_string(hook_type) == "prompt" and
          is_nil(Map.get(hook, "prompt")) and is_nil(Map.get(hook, "command")) ->
          errors ++
            ["'#{prefix}' missing required field 'prompt' (or 'command') for type 'prompt'"]

        true ->
          errors
      end

    timeout = Map.get(hook, "timeout")

    errors =
      if not is_nil(timeout) and (not is_integer(timeout) or timeout < 100) do
        errors ++ ["'#{prefix}' 'timeout' must be >= 100ms, got: #{inspect(timeout)}"]
      else
        errors
      end

    errors
  end

  defp validate_single_hook(_hook, group_idx, hook_idx) do
    ["'[#{group_idx}].hooks[#{hook_idx}]' must be a map"]
  end
end
