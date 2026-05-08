defmodule CodePuppyControl.Parsing.Lexers.PythonLexer do
  @moduledoc """
  Python lexer using Leex-generated tokenizer.

  This module provides tokenization of Python source code using
  a Leex-generated lexer. It handles conversion between Elixir
  strings and Erlang charlists for the underlying lexer.

  **Architectural note:** This is a **data-only** lexer - it tokenizes Python
  source as structured data for the data-only PythonParser. It requires zero
  Python runtime and is compiled via Leex as part of the BEAM-native pipeline.
  See ADR-005 for the full policy rationale.

  ## Examples

      iex> PythonLexer.tokenize("def foo():\n    pass")
      {:ok, [
        {:def, 1},
        {:identifier, 1, ~c"foo"},
        {: "(" , 1},
        {: ")" , 1},
        {: ":" , 1},
        {:newline, 1},
        {:indent, 2},
        {:pass, 2}
      ]}

  """

  @external_resource "src/python_lexer.xrl"

  @doc """
  Tokenize Python source code into a list of tokens.

  ## Parameters
    - source: Python source code as a binary string

  ## Returns
    - `{:ok, tokens}` - List of tuples representing tokens
    - `{:error, {line, reason}}` - Error with line number and reason

  ## Examples

      iex> PythonLexer.tokenize("x = 42")
      {:ok, [
        {:identifier, 1, ~c"x"},
        {:\"=\"", 1},
        {:integer, 1, 42}
      ]}

  """
  @spec tokenize(String.t()) :: {:ok, list()} | {:error, {pos_integer(), term()}}
  def tokenize(source) when is_binary(source) do
    charlist = String.to_charlist(source)

    case :python_lexer.string(charlist) do
      {:ok, tokens, _} -> {:ok, tokens}
      {:error, {line, _mod, error}, _} -> {:error, {line, error}}
    end
  end

  @doc """
  Tokenize with line information preserved.

  Similar to `tokenize/1` but returns tokens with their line numbers
  in a structured format for easier processing.

  ## Examples

      iex> PythonLexer.tokenize_with_lines("x = 1\\ny = 2")
      {:ok, [
        %{token: :identifier, line: 1, value: ~c"x"},
        %{token: :"=", line: 1},
        %{token: :integer, line: 1, value: 1},
        %{token: :newline, line: 1},
        %{token: :identifier, line: 2, value: ~c"y"},
        %{token: :"=", line: 2},
        %{token: :integer, line: 2, value: 2}
      ]}

  """
  @spec tokenize_with_lines(String.t()) :: {:ok, list(map())} | {:error, {pos_integer(), term()}}
  def tokenize_with_lines(source) when is_binary(source) do
    case tokenize(source) do
      {:ok, tokens} -> {:ok, Enum.map(tokens, &format_token/1)}
      {:error, _} = error -> error
    end
  end

  defp format_token({token_type, line}) do
    %{token: token_type, line: line}
  end

  defp format_token({token_type, line, value}) do
    %{token: token_type, line: line, value: value}
  end
end
