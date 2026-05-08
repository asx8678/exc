defmodule CodePuppyControl.Parsing.Lexers.JavaScriptLexerTest do
  @moduledoc """
  Tests for the JavaScript Leex lexer.

  These tests verify correct tokenization of:
  - Basic declarations (function, class, const, let, var)
  - Arrow functions (=>)
  - Import/export statements
  - Template literals
  - Numbers (integers, floats, hex, binary, octal)
  - Strings (single and double quoted)
  - Operators and delimiters
  - Comments (skipped)
  - ES6+ keywords (async, await, etc.)
  """
  use ExUnit.Case

  alias CodePuppyControl.Parsing.Lexers.JavaScriptLexer

  describe "tokenize/1 basic functionality" do
    test "tokenizes simple function declaration" do
      source = "function foo() {}"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      expected = [
        {:function, 1},
        {:identifier, 1, 'foo'},
        {:lparen, 1},
        {:rparen, 1},
        {:lbrace, 1},
        {:rbrace, 1}
      ]

      assert tokens == expected
    end

    test "tokenizes function with body" do
      source = "function foo() { return 42; }"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:function, 1},
               {:identifier, 1, 'foo'},
               {:lparen, 1},
               {:rparen, 1},
               {:lbrace, 1},
               {:return, 1},
               {:integer, 1, 42},
               {:semicolon, 1},
               {:rbrace, 1}
             ] == tokens
    end

    test "returns error for invalid syntax" do
      # Unclosed string should cause a lexer error
      source = "\""
      assert {:error, {_line, _error}} = JavaScriptLexer.tokenize(source)
    end
  end

  describe "arrow functions" do
    test "tokenizes basic arrow function" do
      source = "const foo = () => {}"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      expected = [
        {:const, 1},
        {:identifier, 1, 'foo'},
        {:assign, 1},
        {:lparen, 1},
        {:rparen, 1},
        {:arrow, 1},
        {:lbrace, 1},
        {:rbrace, 1}
      ]

      assert tokens == expected
    end

    test "tokenizes arrow function with parameters" do
      source = "const add = (a, b) => a + b"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
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
             ] == tokens
    end

    test "tokenizes arrow function with implicit return" do
      source = "const double = x => x * 2"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:const, 1},
               {:identifier, 1, 'double'},
               {:assign, 1},
               {:identifier, 1, 'x'},
               {:arrow, 1},
               {:identifier, 1, 'x'},
               {:star, 1},
               {:integer, 1, 2}
             ] == tokens
    end
  end

  describe "class syntax" do
    test "tokenizes simple class declaration" do
      source = "class Foo {}"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:class, 1},
               {:identifier, 1, 'Foo'},
               {:lbrace, 1},
               {:rbrace, 1}
             ] == tokens
    end

    test "tokenizes class with extends" do
      source = "class Bar extends Foo {}"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:class, 1},
               {:identifier, 1, 'Bar'},
               {:extends_token, 1},
               {:identifier, 1, 'Foo'},
               {:lbrace, 1},
               {:rbrace, 1}
             ] == tokens
    end

    test "tokenizes class with method" do
      source = "class Foo { constructor() {} }"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:class, 1},
               {:identifier, 1, 'Foo'},
               {:lbrace, 1},
               {:identifier, 1, 'constructor'},
               {:lparen, 1},
               {:rparen, 1},
               {:lbrace, 1},
               {:rbrace, 1},
               {:rbrace, 1}
             ] == tokens
    end
  end

  describe "import/export statements" do
    test "tokenizes default import" do
      source = ~s(import React from 'react')

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:import, 1},
               {:identifier, 1, 'React'},
               {:from, 1},
               {:string, 1, ~c"'react'"}
             ] == tokens
    end

    test "tokenizes named import" do
      source = ~s(import { useState, useEffect } from 'react')

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:import, 1},
               {:lbrace, 1},
               {:identifier, 1, 'useState'},
               {:comma, 1},
               {:identifier, 1, 'useEffect'},
               {:rbrace, 1},
               {:from, 1},
               {:string, 1, ~c"'react'"}
             ] == tokens
    end

    test "tokenizes default export" do
      source = "export default function() {}"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:export, 1},
               {:default, 1},
               {:function, 1},
               {:lparen, 1},
               {:rparen, 1},
               {:lbrace, 1},
               {:rbrace, 1}
             ] == tokens
    end

    test "tokenizes named export" do
      source = "export const foo = 1"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:export, 1},
               {:const, 1},
               {:identifier, 1, 'foo'},
               {:assign, 1},
               {:integer, 1, 1}
             ] == tokens
    end
  end

  describe "template literals" do
    test "tokenizes simple template literal" do
      source = "const msg = `Hello World`"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:const, 1},
               {:identifier, 1, 'msg'},
               {:assign, 1},
               {:template_string, 1, '`Hello World`'}
             ] == tokens
    end

    test "tokenizes template literal with escaped backticks" do
      source = ~s[const code = `console.log(`test`);`]

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert {:template_string, 1, _} = List.last(tokens)
    end
  end

  describe "strings" do
    test "tokenizes double-quoted string" do
      source = ~s("hello world")

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:string, 1, '"hello world"'}] == tokens
    end

    test "tokenizes single-quoted string" do
      source = "'hello world'"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:string, 1, ~c"'hello world'"}] == tokens
    end

    test "tokenizes string with escaped quotes" do
      source = ~s("She said \\"hello\\"")

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:string, 1, _}] = tokens
    end
  end

  describe "numbers" do
    test "tokenizes integer" do
      source = "42"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:integer, 1, 42}] == tokens
    end

    test "tokenizes float" do
      source = "3.14159"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:float, 1, 3.14159}] == tokens
    end

    test "tokenizes float with exponent" do
      source = "1.5e10"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:float, 1, 1.5e10}] == tokens
    end

    test "tokenizes hex number" do
      source = "0xFF"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:integer, 1, 255}] == tokens
    end

    test "tokenizes binary number" do
      source = "0b1010"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:integer, 1, 10}] == tokens
    end

    test "tokenizes octal number" do
      source = "0o755"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert [{:integer, 1, 493}] == tokens
    end
  end

  describe "async/await" do
    test "tokenizes async function" do
      source = "async function fetchData() {}"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:async, 1},
               {:function, 1},
               {:identifier, 1, 'fetchData'},
               {:lparen, 1},
               {:rparen, 1},
               {:lbrace, 1},
               {:rbrace, 1}
             ] == tokens
    end

    test "tokenizes await expression" do
      source = "const data = await fetchData()"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:const, 1},
               {:identifier, 1, 'data'},
               {:assign, 1},
               {:await, 1},
               {:identifier, 1, 'fetchData'},
               {:lparen, 1},
               {:rparen, 1}
             ] == tokens
    end

    test "tokenizes async arrow function" do
      source = "const fetch = async () => {}"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:const, 1},
               {:identifier, 1, 'fetch'},
               {:assign, 1},
               {:async, 1},
               {:lparen, 1},
               {:rparen, 1},
               {:arrow, 1},
               {:lbrace, 1},
               {:rbrace, 1}
             ] == tokens
    end
  end

  describe "operators" do
    test "tokenizes arithmetic operators" do
      source = "a + b - c * d / e ** f"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:identifier, 1, ~c"a"},
               {:plus, 1},
               {:identifier, 1, ~c"b"},
               {:minus, 1},
               {:identifier, 1, ~c"c"},
               {:star, 1},
               {:identifier, 1, ~c"d"},
               {:slash, 1},
               {:identifier, 1, ~c"e"},
               {:exp, 1},
               {:identifier, 1, ~c"f"}
             ] == tokens
    end

    test "tokenizes comparison operators" do
      source = "a == b != c === d !== e < f > g <= h >= i"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:identifier, 1, 'a'},
               {:eq, 1},
               {:identifier, 1, 'b'},
               {:ne, 1},
               {:identifier, 1, 'c'},
               {:seq, 1},
               {:identifier, 1, 'd'},
               {:sne, 1},
               {:identifier, 1, 'e'},
               {:lt, 1},
               {:identifier, 1, ~c"f"},
               {:gt, 1},
               {:identifier, 1, 'g'},
               {:le, 1},
               {:identifier, 1, 'h'},
               {:ge, 1},
               {:identifier, 1, 'i'}
             ] == tokens
    end

    test "tokenizes logical operators" do
      source = "a && b || c ?? d"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:identifier, 1, 'a'},
               {:and_op, 1},
               {:identifier, 1, 'b'},
               {:or_op, 1},
               {:identifier, 1, 'c'},
               {:nullish, 1},
               {:identifier, 1, 'd'}
             ] == tokens
    end

    test "tokenizes increment/decrement" do
      source = "++a --b"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:increment, 1},
               {:identifier, 1, 'a'},
               {:decrement, 1},
               {:identifier, 1, 'b'}
             ] == tokens
    end
  end

  describe "comments" do
    test "skips single-line comments" do
      source = "const x = 5 // this is a comment"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:const, 1},
               {:identifier, 1, 'x'},
               {:assign, 1},
               {:integer, 1, 5}
             ] == tokens
    end

    test "skips multi-line comments" do
      source = "const x = 5 /* multi\nline\ncomment */ const y = 10"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:const, 1},
               {:identifier, 1, ~c"x"},
               {:assign, 1},
               {:integer, 1, 5},
               {:const, 3},
               {:identifier, 3, ~c"y"},
               {:assign, 3},
               {:integer, 3, 10}
             ] == tokens
    end
  end

  describe "whitespace handling" do
    test "skips regular whitespace" do
      source = "a   +   b"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:identifier, 1, 'a'},
               {:plus, 1},
               {:identifier, 1, 'b'}
             ] == tokens
    end

    test "tracks newlines" do
      source = "a\nb"

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)

      assert [
               {:identifier, 1, 'a'},
               {:newline, 1},
               {:identifier, 2, 'b'}
             ] == tokens
    end
  end

  describe "tokenize!/1" do
    test "returns tokens on success" do
      source = "const x = 5"

      tokens = JavaScriptLexer.tokenize!(source)

      assert [
               {:const, 1},
               {:identifier, 1, 'x'},
               {:assign, 1},
               {:integer, 1, 5}
             ] == tokens
    end

    test "raises on error" do
      source = "\""

      assert_raise RuntimeError, fn ->
        JavaScriptLexer.tokenize!(source)
      end
    end
  end

  describe "tokenize_readable/1" do
    test "converts charlists to strings" do
      source = ~s(const msg = "hello")

      assert {:ok, tokens} = JavaScriptLexer.tokenize_readable(source)

      # Should have strings instead of charlists
      assert [{:const, 1}, {:identifier, 1, "msg"}, {:assign, 1}, {:string, 1, ~s("hello")}] ==
               tokens
    end
  end

  describe "complex real-world examples" do
    test "tokenizes React component" do
      source = """
      import React, { useState } from 'react';

      export default function Counter() {
        const [count, setCount] = useState(0);

        return (
          <div>
            <p>Count: {count}</p>
            <button onClick={() => setCount(c => c + 1)}>+</button>
          </div>
        );
      }
      """

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      # Just verify we get tokens and it doesn't crash
      assert length(tokens) > 0
    end

    test "tokenizes modern ES2020+ features" do
      source = """
      const obj = {
        a: 1,
        b: 2,
        ...rest
      };

      const arr = [1, 2, 3];
      const [first, ...restArr] = arr;

      const val = obj?.prop ?? 'default';

      class MyClass {
        #privateField = 42;

        static staticMethod() {
          return this.#privateField;
        }
      }
      """

      assert {:ok, tokens} = JavaScriptLexer.tokenize(source)
      assert length(tokens) > 0

      # Check for some expected tokens
      assert Enum.any?(tokens, fn t -> t == {:ellipsis, 4} end)
      assert Enum.any?(tokens, fn t -> match?({:hash, _}, t) end)
      assert Enum.any?(tokens, fn t -> match?({:static_token, _}, t) end)
    end
  end
end
