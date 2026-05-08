defmodule CodePuppyControl.Parsing.Lexers.RustLexerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Parsing.Lexers.RustLexer

  describe "tokenize/1" do
    test "tokenizes fn keyword" do
      source = "fn main() {}"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:fn, 1} in tokens
      assert {:identifier, 1, :main} in tokens
    end

    test "tokenizes struct keyword" do
      source = "struct Point { x: i32, y: i32 }"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:struct, 1} in tokens
      assert {:identifier, 1, :Point} in tokens
    end

    test "tokenizes enum keyword" do
      source = "enum Color { Red, Green, Blue }"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:enum, 1} in tokens
      assert {:identifier, 1, :Color} in tokens
      assert {:identifier, 1, :Red} in tokens
      assert {:identifier, 1, :Green} in tokens
      assert {:identifier, 1, :Blue} in tokens
    end

    test "tokenizes impl keyword" do
      source = "impl Shape for Circle {}"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:impl, 1} in tokens
      assert {:identifier, 1, :Shape} in tokens
      assert {:for, 1} in tokens
      assert {:identifier, 1, :Circle} in tokens
    end

    test "tokenizes mod keyword" do
      source = "mod utils { pub fn helper() {} }"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:mod, 1} in tokens
      assert {:identifier, 1, :utils} in tokens
      assert {:pub, 1} in tokens
      assert {:fn, 1} in tokens
      assert {:identifier, 1, :helper} in tokens
    end

    test "tokenizes use keyword" do
      source = "use std::collections::HashMap;"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:use, 1} in tokens
      assert {:identifier, 1, :std} in tokens
      assert {:path_sep, 1} in tokens
      assert {:identifier, 1, :collections} in tokens
      assert {:identifier, 1, :HashMap} in tokens
    end

    test "tokenizes trait keyword" do
      source = "trait Drawable { fn draw(&self); }"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:trait, 1} in tokens
      assert {:identifier, 1, :Drawable} in tokens
      assert {:fn, 1} in tokens
      assert {:identifier, 1, :draw} in tokens
    end

    test "tokenizes let and mut keywords" do
      source = "let mut x = 5;"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:let, 1} in tokens
      assert {:mut, 1} in tokens
      assert {:identifier, 1, :x} in tokens
      assert {:assign, 1} in tokens
      assert {:integer, 1, 5} in tokens
    end

    test "tokenizes arrow operators" do
      source = "fn add() -> i32 { 42 }"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:fn, 1} in tokens
      assert {:arrow, 1} in tokens
      assert {:identifier, 1, :i32} in tokens
    end

    test "tokenizes match expression" do
      source = "match x { Some => 1, None => 0 }"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:match, 1} in tokens
      assert {:identifier, 1, :x} in tokens
      assert {:identifier, 1, :Some} in tokens
      assert {:fat_arrow, 1} in tokens
      assert {:integer, 1, 1} in tokens
      assert {:identifier, 1, :None} in tokens
    end

    test "tokenizes string literals" do
      source = ~s{let s = "hello";}
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:let, 1} in tokens
      assert {:identifier, 1, :s} in tokens

      string_token =
        Enum.find(tokens, fn
          {:string, 1, _} -> true
          _ -> false
        end)

      assert string_token != nil
    end

    test "tokenizes integer literals" do
      source = "let x = 42;"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:integer, 1, 42} in tokens
    end

    test "tokenizes integer with underscores" do
      source = "let x = 1_000_000;"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:integer, 1, 1_000_000} in tokens
    end

    test "tokenizes float literals" do
      source = "let x = 3.14;"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:float, 1, 3.14} in tokens
    end

    test "tokenizes hexadecimal literals" do
      source = "let x = 0xFF;"
      assert {:ok, tokens} = RustLexer.tokenize(source)
      assert {:integer, 1, 255} in tokens
    end

    test "handles empty source" do
      source = ""
      assert {:ok, []} = RustLexer.tokenize(source)
    end
  end
end
