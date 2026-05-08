defmodule CodePuppyControl.Parsing.Lexers.TypeScriptLexer do
  @moduledoc """
  TypeScript lexer using Leex-generated tokenizer.

  This module provides a high-level Elixir interface to the Leex-generated
  `:typescript_lexer` module. It extends the JavaScript lexer with
  TypeScript-specific keywords including:

  - Interface declarations (`interface`)
  - Type aliases (`type`)
  - Enums (`enum`)
  - Namespaces/modules (`namespace`, `module`)
  - Access modifiers (`public`, `private`, `protected`, `readonly`)
  - Abstract classes (`abstract`)
  - Implements clause (`implements`)
  - Declare keyword (`declare`)

  ## Usage

      iex> TypeScriptLexer.tokenize("interface Point { x: number; y: number; }")
      {:ok, [
        {:interface, 1},
        {:identifier, 1, 'Point'},
        {:lbrace, 1},
        ...
      ]}

      iex> TypeScriptLexer.tokenize("type ID = string")
      {:ok, [
        {:type, 1},
        {:identifier, 1, 'ID'},
        {:assign, 1},
        {:identifier, 1, 'string'}
      ]}

  ## Leex Integration

  The lexer is generated from `src/typescript_lexer.xrl` at compile time.
  Use `@external_resource` to ensure recompilation when the `.xrl` file changes.
  """

  @external_resource "src/typescript_lexer.xrl"

  @typedoc """
  Token tuple returned by the lexer.
  """
  @type token ::
          {:keyword, non_neg_integer(), atom()}
          | {:identifier, non_neg_integer(), charlist()}
          | {:integer, non_neg_integer(), integer()}
          | {:float, non_neg_integer(), float()}
          | {:string, non_neg_integer(), charlist()}
          | {:template_string, non_neg_integer(), charlist()}
          | {:regex, non_neg_integer(), charlist()}
          | {:operator, non_neg_integer(), atom()}
          | {:delimiter, non_neg_integer(), atom()}
          | {atom(), non_neg_integer()}

  @typedoc """
  Result of tokenization.
  """
  @type tokenize_result ::
          {:ok, [token()]}
          | {:error, {line :: non_neg_integer(), error :: term()}}

  @doc """
  Tokenize TypeScript source code into a list of tokens.

  ## Parameters

    * `source` - Binary string containing TypeScript source code

  ## Returns

    * `{:ok, tokens}` - List of token tuples on success
    * `{:error, {line, error}}` - Error tuple with line number and error info

  ## Examples

      iex> TypeScriptLexer.tokenize("type Result = string | number")
      {:ok, [
        {:type, 1},
        {:identifier, 1, 'Result'},
        {:assign, 1},
        {:identifier, 1, 'string'},
        {:bitor, 1},
        {:identifier, 1, 'number'}
      ]}

      iex> TypeScriptLexer.tokenize("interface User { name: string; }")
      {:ok, [
        {:interface, 1},
        {:identifier, 1, 'User'},
        {:lbrace, 1},
        {:identifier, 1, 'name'},
        {:colon, 1},
        {:identifier, 1, 'string'},
        {:semicolon, 1},
        {:rbrace, 1}
      ]}
  """
  @spec tokenize(String.t()) :: tokenize_result()
  def tokenize(source) when is_binary(source) do
    charlist = String.to_charlist(source)

    case :typescript_lexer.string(charlist) do
      {:ok, tokens, _rest} -> {:ok, tokens}
      {:error, {line, _module, error}, _rest} -> {:error, {line, error}}
    end
  end

  @doc """
  Tokenize TypeScript source code, raising on error.

  ## Parameters

    * `source` - Binary string containing TypeScript source code

  ## Returns

    List of token tuples

  ## Raises

    `RuntimeError` if tokenization fails

  ## Examples

      iex> TypeScriptLexer.tokenize!("enum Color { Red, Green, Blue }")
      [
        {:enum, 1},
        {:identifier, 1, 'Color'},
        {:lbrace, 1},
        {:identifier, 1, 'Red'},
        {:comma, 1},
        {:identifier, 1, 'Green'},
        {:comma, 1},
        {:identifier, 1, 'Blue'},
        {:rbrace, 1}
      ]
  """
  @spec tokenize!(String.t()) :: [token()]
  def tokenize!(source) when is_binary(source) do
    case tokenize(source) do
      {:ok, tokens} -> tokens
      {:error, {line, error}} -> raise "Tokenization error at line #{line}: #{inspect(error)}"
    end
  end

  @doc """
  Tokenize TypeScript and convert charlists to strings for readability.

  This is useful for debugging and testing where charlist output
  (like `'foo'` instead of `"foo"`) can be confusing.

  ## Parameters

    * `source` - Binary string containing TypeScript source code

  ## Returns

    Token list with charlists converted to binaries
  """
  @spec tokenize_readable(String.t()) ::
          {:ok, [term()]} | {:error, {non_neg_integer(), term()}}
  def tokenize_readable(source) when is_binary(source) do
    case tokenize(source) do
      {:ok, tokens} -> {:ok, Enum.map(tokens, &token_to_readable/1)}
      error -> error
    end
  end

  # Convert charlist values in tokens to strings for readability
  defp token_to_readable({type, line, value}) when is_list(value) do
    {type, line, to_string(value)}
  end

  defp token_to_readable(token), do: token
end
