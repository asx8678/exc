defmodule CodePuppyControl.Parsing.Lexers.JavaScriptLexer do
  @moduledoc """
  JavaScript lexer using Leex-generated tokenizer.

  This module provides a high-level Elixir interface to the Leex-generated
  `:javascript_lexer` module. It handles tokenization of JavaScript source code
  including ES6+ features like:

  - Arrow functions (`=>`)
  - Template literals (backtick strings)
  - Class syntax
  - Import/export statements
  - Async/await
  - Destructuring

  ## Usage

      iex> JavaScriptLexer.tokenize("const foo = () => {}")
      {:ok, [
        {:const, 1},
        {:identifier, 1, 'foo'},
        {:assign, 1},
        {:lparen, 1},
        {:rparen, 1},
        {:arrow, 1},
        {:lbrace, 1},
        {:rbrace, 1}
      ]}

  ## Leex Integration

  The lexer is generated from `src/javascript_lexer.xrl` at compile time.
  Use `@external_resource` to ensure recompilation when the `.xrl` file changes.
  """

  @external_resource "src/javascript_lexer.xrl"

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
  Tokenize JavaScript source code into a list of tokens.

  ## Parameters

    * `source` - Binary string containing JavaScript source code

  ## Returns

    * `{:ok, tokens}` - List of token tuples on success
    * `{:error, {line, error}}` - Error tuple with line number and error info

  ## Examples

      iex> JavaScriptLexer.tokenize("function foo() { return 42; }")
      {:ok, [
        {:function, 1},
        {:identifier, 1, 'foo'},
        {:lparen, 1},
        {:rparen, 1},
        {:lbrace, 1},
        {:return, 1},
        {:integer, 1, 42},
        {:semicolon, 1},
        {:rbrace, 1}
      ]}

      iex> JavaScriptLexer.tokenize("const add = (a, b) => a + b")
      {:ok, [
        {:const, 1},
        {:identifier, 1, 'add'},
        {:assign, 1},
        {:lparen, 1},
        {:identifier, 1, 'a'},
        {:comma, 1},
        {:identifier, 1, 'b'},
        {:rparen, 1},
        {:arrow, 1},
        {:identifier, 1, 'a'},
        {:plus, 1},
        {:identifier, 1, 'b'}
      ]}
  """
  @spec tokenize(String.t()) :: tokenize_result()
  def tokenize(source) when is_binary(source) do
    charlist = String.to_charlist(source)

    case :javascript_lexer.string(charlist) do
      {:ok, tokens, _rest} -> {:ok, tokens}
      {:error, {line, _module, error}, _rest} -> {:error, {line, error}}
    end
  end

  @doc """
  Tokenize JavaScript source code, raising on error.

  ## Parameters

    * `source` - Binary string containing JavaScript source code

  ## Returns

    List of token tuples

  ## Raises

    `RuntimeError` if tokenization fails

  ## Examples

      iex> JavaScriptLexer.tokenize!("let x = 5")
      [
        {:let, 1},
        {:identifier, 1, 'x'},
        {:assign, 1},
        {:integer, 1, 5}
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
  Tokenize JavaScript and convert charlists to strings for readability.

  This is useful for debugging and testing where charlist output
  (like `'foo'` instead of `"foo"`) can be confusing.

  ## Parameters

    * `source` - Binary string containing JavaScript source code

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
