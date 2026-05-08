defmodule CodePuppyControl.Parsing.Lexers.RustLexer do
  @moduledoc """
  Rust lexer using Leex-generated tokenizer.

  This module provides tokenization of Rust source code using
  a Leex-generated lexer. It handles Rust-specific features including:

  - Keywords (fn, struct, enum, impl, trait, mod, use, etc.)
  - Lifetimes ('a, 'static)
  - Raw string literals (r#"..."#)
  - Numeric literals with underscores (1_000_000)
  - Hexadecimal, octal, and binary literals
  - Arrow operators (->, =>)
  - Path separator (::)

  ## Usage

      iex> RustLexer.tokenize("fn main() { println!(\\"Hello\\"); }")
      {:ok, [
        {:fn, 1},
        {:identifier, 1, :main},
        {:'(', 1},
        {:')', 1},
        {:'{', 1},
        {:identifier, 1, :println},
        {:'!', 1},
        {:'(', 1},
        {:string, 1, '"Hello"'},
        {:', 1},
        {:'}', 1}
      ]}

  ## Leex Integration

  The lexer is generated from `src/rust_lexer.xrl` at compile time.
  Use `@external_resource` to ensure recompilation when the `.xrl` file changes.
  """

  @external_resource "src/rust_lexer.xrl"

  @typedoc """
  Token tuple returned by the lexer.
  """
  @type token ::
          {:keyword, non_neg_integer(), atom()}
          | {:identifier, non_neg_integer(), atom()}
          | {:integer, non_neg_integer(), integer()}
          | {:float, non_neg_integer(), float()}
          | {:string, non_neg_integer(), charlist()}
          | {:raw_string, non_neg_integer(), charlist()}
          | {:char, non_neg_integer(), charlist()}
          | {:lifetime, non_neg_integer(), charlist()}
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
  Tokenize Rust source code into a list of tokens.

  ## Parameters

    * `source` - Binary string containing Rust source code

  ## Returns

    * `{:ok, tokens}` - List of token tuples on success
    * `{:error, {line, error}}` - Error tuple with line number and error info

  ## Examples

      iex> RustLexer.tokenize("fn foo() {}")
      {:ok, [
        {:fn, 1},
        {:identifier, 1, :foo},
        {:'(', 1},
        {:')', 1},
        {:'{', 1},
        {:'}', 1}
      ]}

      iex> RustLexer.tokenize("struct Point { x: i32, y: i32 }")
      {:ok, [
        {:struct, 1},
        {:identifier, 1, :Point},
        {:'{', 1},
        {:identifier, 1, :x},
        {:', 1},
        {:identifier, 1, :i32},
        {:', 1},
        {:identifier, 1, :y},
        {:', 1},
        {:identifier, 1, :i32},
        {:'}', 1}
      ]}
  """
  @spec tokenize(String.t()) :: tokenize_result()
  def tokenize(source) when is_binary(source) do
    charlist = String.to_charlist(source)

    case :rust_lexer.string(charlist) do
      {:ok, tokens, _rest} -> {:ok, tokens}
      {:error, {line, _module, error}, _rest} -> {:error, {line, error}}
    end
  end

  @doc """
  Tokenize Rust source code, raising on error.

  ## Parameters

    * `source` - Binary string containing Rust source code

  ## Returns

    List of token tuples

  ## Raises

    `RuntimeError` if tokenization fails

  ## Examples

      iex> RustLexer.tokenize!("let x = 42")
      [
        {:let, 1},
        {:identifier, 1, :x},
        {:assign, 1},
        {:integer, 1, 42}
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
  Tokenize Rust and convert charlists to strings for readability.

  This is useful for debugging and testing where charlist output
  (like `'foo'` instead of `"foo"`) can be confusing.

  ## Parameters

    * `source` - Binary string containing Rust source code

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
