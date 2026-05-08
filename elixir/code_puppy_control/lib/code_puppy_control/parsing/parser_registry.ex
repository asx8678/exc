defmodule CodePuppyControl.Parsing.ParserRegistry do
  @moduledoc """
  Registry for language parsers. Maps languages and extensions to parser modules.

  This registry uses an Agent to maintain state about registered parsers,
  allowing dynamic registration of parsers at runtime.

  ## Usage

      # Register a parser module
      ParserRegistry.register(MyLanguageParser)

      # Get parser for a language
      ParserRegistry.get("elixir")
      # => {:ok, MyElixirParser}

      # Get parser by file extension
      ParserRegistry.for_extension(".ex")
      # => {:ok, MyElixirParser}

  """

  use Agent

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the registry Agent with empty state.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    initial_state = %{
      parsers: %{},
      extensions: %{}
    }

    Agent.start_link(fn -> initial_state end, name: name)
  end

  @doc """
  Registers a parser module in the registry.

  The module must implement the `ParserBehaviour` behaviour.
  Registration extracts the language name and file extensions from the module.

  ## Parameters
    - module: The parser module to register

  ## Returns
    - `:ok` on successful registration
    - `{:error, :unsupported}` if the parser reports `supported?/0` as false
    - `{:error, :invalid_module}` if the module doesn't implement required callbacks

  ## Examples
      iex> ParserRegistry.register(MyElixirParser)
      :ok
  """
  @spec register(module()) :: :ok | {:error, :unsupported | :invalid_module}
  def register(module) do
    cond do
      not behaviour_implemented?(module) ->
        {:error, :invalid_module}

      not module.supported?() ->
        {:error, :unsupported}

      true ->
        language = module.language()
        extensions = module.file_extensions()

        Agent.update(__MODULE__, fn state ->
          parsers = Map.put(state.parsers, language, module)

          extensions_map =
            Enum.reduce(extensions, state.extensions, fn ext, acc ->
              Map.put(acc, ext, module)
            end)

          %{state | parsers: parsers, extensions: extensions_map}
        end)

        :ok
    end
  end

  @doc """
  Gets the parser module for a given language name.

  ## Parameters
    - language: The canonical language name (e.g., "elixir", "python")

  ## Returns
    - `{:ok, module}` if a parser is registered for the language
    - `:error` if no parser is registered

  ## Examples
      iex> ParserRegistry.get("elixir")
      {:ok, MyElixirParser}

      iex> ParserRegistry.get("unknown")
      :error
  """
  @spec get(String.t()) :: {:ok, module()} | :error
  def get(language) do
    Agent.get(__MODULE__, fn state ->
      Map.fetch(state.parsers, language)
    end)
  end

  @doc """
  Gets the parser module for a given file extension.

  ## Parameters
    - extension: The file extension including the dot (e.g., ".ex", ".py")

  ## Returns
    - `{:ok, module}` if a parser is registered for the extension
    - `:error` if no parser is registered

  ## Examples
      iex> ParserRegistry.for_extension(".ex")
      {:ok, MyElixirParser}

      iex> ParserRegistry.for_extension(".unknown")
      :error
  """
  @spec for_extension(String.t()) :: {:ok, module()} | :error
  def for_extension(extension) do
    # Normalize extension to lowercase
    normalized = String.downcase(extension)

    Agent.get(__MODULE__, fn state ->
      Map.fetch(state.extensions, normalized)
    end)
  end

  @doc """
  Lists all registered language parsers.

  ## Returns
    A list of tuples `{language, parser_module}` sorted by language name.

  ## Examples
      iex> ParserRegistry.list_languages()
      [{"elixir", MyElixirParser}, {"python", MyPythonParser}]
  """
  @spec list_languages() :: [{String.t(), module()}]
  def list_languages() do
    Agent.get(__MODULE__, fn state ->
      state.parsers
      |> Map.to_list()
      |> Enum.sort_by(fn {lang, _mod} -> lang end)
    end)
  end

  @doc """
  Lists all registered file extensions.

  ## Returns
    A list of tuples `{extension, parser_module}` sorted by extension.

  ## Examples
      iex> ParserRegistry.list_extensions()
      [{".ex", MyElixirParser}, {".exs", MyElixirParser}, {".py", MyPythonParser}]
  """
  @spec list_extensions() :: [{String.t(), module()}]
  def list_extensions() do
    Agent.get(__MODULE__, fn state ->
      state.extensions
      |> Map.to_list()
      |> Enum.sort_by(fn {ext, _mod} -> ext end)
    end)
  end

  @doc """
  Unregisters a parser module by language name.

  ## Parameters
    - language: The language name to unregister

  ## Returns
    - `:ok` on success

  ## Examples
      iex> ParserRegistry.unregister("elixir")
      :ok
  """
  @spec unregister(String.t()) :: :ok
  def unregister(language) do
    Agent.update(__MODULE__, fn state ->
      case Map.fetch(state.parsers, language) do
        {:ok, module} ->
          extensions = module.file_extensions()

          new_extensions =
            Enum.reduce(extensions, state.extensions, fn ext, acc ->
              Map.delete(acc, ext)
            end)

          new_parsers = Map.delete(state.parsers, language)

          %{state | parsers: new_parsers, extensions: new_extensions}

        :error ->
          state
      end
    end)

    :ok
  end

  @doc """
  Clears all registered parsers from the registry.

  ## Returns
    - `:ok` on success
  """
  @spec clear() :: :ok
  def clear() do
    Agent.update(__MODULE__, fn _state ->
      %{parsers: %{}, extensions: %{}}
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  # Check if a module implements the ParserBehaviour callbacks
  defp behaviour_implemented?(module) do
    required_functions = [
      {:parse, 1},
      {:language, 0},
      {:file_extensions, 0},
      {:supported?, 0}
    ]

    Enum.all?(required_functions, fn {fun, arity} ->
      function_exported?(module, fun, arity)
    end)
  end
end
