defmodule CodePuppyControl.Test.ProviderContract do
  @moduledoc """
  Contract validation for LLM providers.

  Ported from Python's `tests.contracts.ProviderContract`. Provides two
  validation functions:

    * `validate_provider_interface/2` — runtime check that a module exports
      every callback required by `CodePuppyControl.LLM.Provider`.
    * `validate_model_config/2` — runtime check that a config map contains
      the required fields (`"model_name"` and `"provider"`).

  ## Elixir vs Python adaptation

  Python uses `hasattr` + `callable` checks against `REQUIRED_METHODS`.
  Elixir uses `function_exported?/3` against the `Provider` `@callback`
  list.  The "non-callable" edge-case from Python is adapted to mean
  "function exists with wrong arity" — the closest Elixir equivalent of
  an attribute that is present but not invocable with the expected signature.
  """

  alias CodePuppyControl.LLM.Provider
  alias CodePuppyControl.Test.ContractViolation

  # Derive required callbacks from the Provider behaviour itself so that
  # adding a new @callback to Provider automatically updates contract
  # checks — no manual sync needed.
  @required_callbacks Provider.behaviour_info(:callbacks)

  # Fields that every model config map MUST contain.
  @required_config_fields ["model_name", "provider"]

  @doc """
  Validate that `provider_module` exports every required Provider callback.

  Returns `:ok` on success.  Raises `ContractViolation` on failure,
  distinguishing between completely missing callbacks and callbacks that
  exist but with the wrong arity (Elixir's "not callable" equivalent).
  """
  @spec validate_provider_interface(module(), String.t()) :: :ok
  def validate_provider_interface(provider_module, provider_name) do
    missing = find_missing_callbacks(provider_module)
    not_callable = find_not_callable_callbacks(provider_module)
    problems = missing ++ not_callable

    if problems == [] do
      :ok
    else
      raise ContractViolation,
        component: "provider:#{provider_name}",
        issue: "Missing required callbacks: #{Enum.join(problems, ", ")}",
        details: %{missing_callbacks: problems}
    end
  end

  @doc """
  Validate that `config` contains all required model configuration fields.

  Returns `:ok` on success.  Raises `ContractViolation` on failure.
  """
  @spec validate_model_config(map(), String.t()) :: :ok
  def validate_model_config(config, provider_name) when is_map(config) do
    missing = Enum.filter(@required_config_fields, &(not Map.has_key?(config, &1)))

    if missing == [] do
      :ok
    else
      raise ContractViolation,
        component: "provider:#{provider_name}",
        issue: "Model config missing fields: #{inspect(missing)}",
        details: %{missing_fields: missing}
    end
  end

  # Callbacks with no export at *any* arity — completely absent.
  defp find_missing_callbacks(module) do
    @required_callbacks
    |> Enum.reject(fn {name, arity} ->
      function_exported?(module, name, arity) or any_arity_exported?(module, name)
    end)
    |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
  end

  # Callbacks absent at the expected arity but present at another arity.
  # This is the Elixir equivalent of Python's "not callable" case.
  defp find_not_callable_callbacks(module) do
    @required_callbacks
    |> Enum.filter(fn {name, arity} ->
      not function_exported?(module, name, arity) and any_arity_exported?(module, name)
    end)
    |> Enum.map(fn {name, arity} -> "#{name}/#{arity} (not callable)" end)
  end

  defp any_arity_exported?(module, name) do
    module.__info__(:functions)
    |> Enum.any?(fn {f, _a} -> f == name end)
  end
end
