defmodule CodePuppyControl.Reflection do
  @moduledoc """
  Reflection utilities for resolving Module.function paths.

  This module provides utilities for dynamically resolving dotted paths
  like "CodePuppyControl.Callbacks.register_callback" to their corresponding
  Elixir functions, with helpful error messages for missing dependencies.

  ## Path Formats

  Supports paths in two formats:
  - "Module.Submodule.function_name" (standard Elixir dot notation)
  - Aliases like "CodePuppyControl.Callbacks.register_callback/3"

  ## Examples

      iex> Reflection.resolve_function("Elixir.String.split/3")
      {:ok, &String.split/3}

      iex> Reflection.resolve_function("NonExistent.Module.function")
      {:error, :module_not_found}

  """

  require Logger

  @typedoc "Result of resolution"
  @type resolution_result :: {:ok, function()} | {:error, atom()}

  @typedoc "Path format - accepts dot-separated strings or function captures"
  @type path :: String.t() | function()

  # Mapping of module names to package hints for optional dependencies.
  @module_package_hints %{
    "NimbleParsec" => "nimble_parsec",
    "Phoenix" => "phoenix",
    "Ecto" => "ecto"
  }

  @doc """
  Resolves a module:function path to the corresponding Elixir function.

  Supports paths in the format:
  - "Module.Submodule.function_name" (dot notation)
  - "Module.Submodule.function_name/arity" (explicit arity)
  - Already-compiled function capture like `&Module.function/arity`

  ## Options

  - `:expected_type` - Check if resolved function matches expected type
    (e.g., `:function`, `:macro`). Not currently enforced.

  ## Returns

  - `{:ok, function}` - Successfully resolved function
  - `{:error, :invalid_path}` - Path format is invalid
  - `{:error, :module_not_found}` - Module doesn't exist
  - `{:error, :function_not_found}` - Function doesn't exist in module
  - `{:error, :arity_not_found}` - Specific arity not available

  ## Examples

      iex> Reflection.resolve_function("Elixir.String.split")
      {:ok, &String.split/3}

      iex> Reflection.resolve_function("Elixir.String.split/3")
      {:ok, &String.split/3}

      iex> Reflection.resolve_function("Elixir.String.nonexistent")
      {:error, :function_not_found}

  """
  @spec resolve_function(path :: String.t()) :: resolution_result()
  def resolve_function(path) when is_binary(path) do
    with {:ok, module_name, function_name, arity} <- parse_path(path),
         {:ok, module} <- load_module(module_name),
         {:ok, function} <- fetch_function(module, function_name, arity) do
      {:ok, function}
    end
  end

  def resolve_function(path) when is_function(path) do
    {:ok, path}
  end

  @doc """
  Same as resolve_function/1 but raises on error.

  ## Examples

      iex> Reflection.resolve_function!("Elixir.String.split")
      &String.split/3

      iex> Reflection.resolve_function!("Invalid.path")
      ** (ArgumentError) Invalid path format: "Invalid.path"

  """
  @spec resolve_function!(path :: String.t()) :: function()
  def resolve_function!(path) do
    case resolve_function(path) do
      {:ok, func} ->
        func

      {:error, :invalid_path} ->
        raise ArgumentError, "Invalid path format: #{inspect(path)}"

      {:error, :module_not_found} ->
        raise ArgumentError, "Module not found for path: #{inspect(path)}"

      {:error, :function_not_found} ->
        raise ArgumentError, "Function not found for path: #{inspect(path)}"

      {:error, :arity_not_found} ->
        raise ArgumentError, "Function arity not found for path: #{inspect(path)}"
    end
  end

  @doc """
  Lists all public functions in a given module.

  ## Examples

      iex> Reflection.list_functions("Elixir.String")
      {:ok, ["at/2", "bag_distance/2", "capitalize/1", ...]}

      iex> Reflection.list_functions("NonExistent.Module")
      {:error, :module_not_found}

  """
  @spec list_functions(module_name :: String.t()) ::
          {:ok, [String.t()]} | {:error, :module_not_found}
  def list_functions(module_name) when is_binary(module_name) do
    with {:ok, module} <- load_module(module_name) do
      functions =
        module.__info__(:functions)
        |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)
        |> Enum.sort()

      {:ok, functions}
    end
  end

  @doc """
  Returns available attributes in a module.

  ## Examples

      iex> Reflection.list_attributes("Elixir.String")
      {:ok, ["at", "bag_distance", "capitalize", ...]}

  """
  @spec list_attributes(module_name :: String.t()) ::
          {:ok, [String.t()]} | {:error, :module_not_found}
  def list_attributes(module_name) when is_binary(module_name) do
    with {:ok, module} <- load_module(module_name) do
      attributes =
        module.__info__(:functions)
        |> Enum.map(fn {name, _arity} -> to_string(name) end)
        |> Enum.uniq()
        |> Enum.sort()

      {:ok, attributes}
    end
  end

  @doc """
  Returns package install hint for known optional dependencies.

  ## Examples

      iex> Reflection.package_hint("NimbleParsec")
      "nimble_parsec"

      iex> Reflection.package_hint("UnknownModule")
      nil

  """
  @spec package_hint(module_name :: String.t()) :: String.t() | nil
  def package_hint(module_name) do
    Map.get(@module_package_hints, module_name)
  end

  # --------------------------------------------------------------------------
  # Private Functions
  # --------------------------------------------------------------------------

  @doc false
  @spec parse_path(String.t()) ::
          {:ok, String.t(), String.t(), non_neg_integer() | nil} | {:error, :invalid_path}
  defp parse_path(path) when is_binary(path) do
    # Check for explicit arity notation: Module.function/arity
    case Regex.run(~r/^(.*?)(?:\.(\w+))\/(\d+)$/, path) do
      [_, module_path, function_name, arity_str] ->
        {:ok, module_path, function_name, String.to_integer(arity_str)}

      nil ->
        # Standard dot notation: extract last component as function
        case String.split(path, ".") do
          [] ->
            {:error, :invalid_path}

          [_single] ->
            # No separator - cannot distinguish module from function
            {:error, :invalid_path}

          parts ->
            module_path = parts |> Enum.drop(-1) |> Enum.join(".")
            function_name = List.last(parts)
            {:ok, module_path, function_name, nil}
        end
    end
  end

  @doc false
  @spec load_module(String.t()) :: {:ok, module()} | {:error, :module_not_found}
  defp load_module(module_name) when is_binary(module_name) do
    # Ensure module is an atom (Elixir modules are atoms)
    module_atom = String.to_atom(module_name)

    # Check if the module is loaded, try to load if not
    if Code.ensure_loaded?(module_atom) do
      {:ok, module_atom}
    else
      # Try loading the module
      case Code.ensure_loaded(module_atom) do
        {:module, _} -> {:ok, module_atom}
        {:error, _} -> {:error, :module_not_found}
      end
    end
  rescue
    ArgumentError -> {:error, :module_not_found}
  end

  @doc false
  @spec fetch_function(module(), String.t(), non_neg_integer() | nil) ::
          {:ok, function()} | {:error, :function_not_found | :arity_not_found}
  defp fetch_function(module, function_name, arity) do
    function_atom = String.to_atom(function_name)
    functions = module.__info__(:functions)

    # Find matching function/arity
    matching_arities =
      functions
      |> Enum.filter(fn {name, _arity} -> name == function_atom end)
      |> Enum.map(fn {_name, ar} -> ar end)

    case matching_arities do
      [] ->
        {:error, :function_not_found}

      arities when is_nil(arity) ->
        # No specific arity requested, use first available
        [first_arity | _] = arities
        {:ok, Function.capture(module, function_atom, first_arity)}

      arities ->
        # Specific arity requested
        if arity in arities do
          {:ok, Function.capture(module, function_atom, arity)}
        else
          {:error, :arity_not_found}
        end
    end
  rescue
    _ -> {:error, :function_not_found}
  end
end
