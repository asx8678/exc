defmodule CodePuppyControl.Parsing.Parsers do
  @moduledoc """
  Module for registering built-in language parsers.

  This module provides a child_spec for use in the application supervision tree
  to ensure all built-in parsers are registered on startup.

  ## Parser Policy

  All parsers listed here are **data-only** — they parse source code as
  structured data using Elixir-native Leex/Yecc grammars, with no
  external runtime dependency.

  In particular, `PythonParser` parses `.py`/`.pyi` source to extract
  symbols (functions, classes, imports) for code context and repo indexing.
  It uses the same BEAM-native pipeline as Elixir/JS/TS/Rust parsers and
  requires **zero Python runtime**. See ADR-005 for the full rationale.
  """

  alias CodePuppyControl.Parsing.ParserRegistry

  # List of built-in parser modules
  # All parsers are pure-Elixir data parsers compiled via [:leex, :yecc].
  # PythonParser is a data-only parser (no Python runtime needed).
  @parser_modules [
    CodePuppyControl.Parsing.Parsers.ElixirParser,
    CodePuppyControl.Parsing.Parsers.ErlangParser,
    CodePuppyControl.Parsing.Parsers.PythonParser,
    CodePuppyControl.Parsing.Parsers.JavaScriptParser,
    CodePuppyControl.Parsing.Parsers.TypeScriptParser,
    CodePuppyControl.Parsing.Parsers.TsxParser,
    CodePuppyControl.Parsing.Parsers.RustParser
  ]

  @doc """
  Registers all built-in language parsers with the ParserRegistry.

  Should be called after the ParserRegistry has started.

  Note: This function ensures all parser modules are loaded via Code.ensure_loaded/1
  before attempting registration. This is necessary because Elixir modules are lazily
  loaded and the ParserRegistry uses function_exported?/3 to verify behaviour compliance.
  """
  @spec register_all() :: :ok
  def register_all do
    Enum.each(@parser_modules, fn parser_module ->
      # Ensure module is loaded before registering
      # This is critical because function_exported?/3 only works on loaded modules
      case Code.ensure_loaded(parser_module) do
        {:module, ^parser_module} ->
          case ParserRegistry.register(parser_module) do
            :ok -> :ok
            {:error, :unsupported} -> :ok
            {:error, :invalid_module} -> :ok
          end

        {:error, _reason} ->
          # Module could not be loaded, skip it
          :ok
      end
    end)

    :ok
  end

  @doc """
  Child spec for supervision tree.

  Registers all parsers on startup and returns :ignore so it does not
  remain in the supervision tree.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  @doc false
  def start_link do
    register_all()
    # Return :ignore so this does not stay in the supervision tree
    :ignore
  end
end
