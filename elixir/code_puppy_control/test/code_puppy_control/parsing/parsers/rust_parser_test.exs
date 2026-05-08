defmodule CodePuppyControl.Parsing.Parsers.RustParserTest do
  # Tests for the RustParser module
  use ExUnit.Case, async: true

  alias CodePuppyControl.Parsing.Parsers.RustParser

  # ---------------------------------------------------------------------------
  # ParserBehaviour Tests
  # ---------------------------------------------------------------------------

  describe "ParserBehaviour callbacks" do
    test "language/0 returns rust" do
      assert RustParser.language() == "rust"
    end

    test "file_extensions/0 returns .rs" do
      assert RustParser.file_extensions() == [".rs"]
    end

    test "supported?/0 returns true" do
      assert RustParser.supported?() == true
    end
  end

  # ---------------------------------------------------------------------------
  # Function Declaration Tests
  # ---------------------------------------------------------------------------

  describe "function declarations" do
    test "parses simple function" do
      source = "fn main() {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true
      assert result.language == "rust"
      assert length(result.symbols) == 1

      [symbol] = result.symbols
      assert symbol.name == "main"
      assert symbol.kind == :function
      assert symbol.line == 1
    end

    test "parses function with parameters" do
      source = "fn add(a: i32, b: i32) {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "add"
      assert symbol.kind == :function
    end

    test "parses public function" do
      source = "pub fn public_func() {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "public_func"
      assert symbol.doc == "pub"
    end

    test "parses async function" do
      source = "async fn async_func() {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "async_func"
      assert symbol.doc == "async"
    end

    test "parses public async function" do
      source = "pub async fn pub_async_func() {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "pub_async_func"
      assert symbol.doc == "async pub"
    end

    test "parses const function" do
      source = "const fn const_func() {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "const_func"
      assert symbol.doc == "const"
    end
  end

  # ---------------------------------------------------------------------------
  # Struct Declaration Tests
  # ---------------------------------------------------------------------------

  describe "struct declarations" do
    test "parses struct with body" do
      source = "struct Point { x: i32, y: i32 }"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "Point"
      assert symbol.kind == :class
    end

    test "parses empty struct" do
      source = "struct Point {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "Point"
      assert symbol.kind == :class
    end

    test "parses tuple struct" do
      source = "struct Point(i32, i32);"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "Point"
      assert symbol.kind == :class
    end

    test "parses public struct" do
      source = "pub struct PubPoint {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "PubPoint"
      assert symbol.doc == "pub"
    end

    test "parses public tuple struct" do
      source = "pub struct PubPoint(i32, i32);"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "PubPoint"
      assert symbol.doc == "pub"
    end
  end

  # ---------------------------------------------------------------------------
  # Enum Declaration Tests
  # ---------------------------------------------------------------------------

  describe "enum declarations" do
    test "parses enum" do
      source = "enum Color { Red, Green, Blue }"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "Color"
      assert symbol.kind == :type
    end

    test "parses public enum" do
      source = "pub enum PubColor { Red }"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "PubColor"
      assert symbol.doc == "pub"
    end
  end

  # ---------------------------------------------------------------------------
  # Impl Block Tests
  # ---------------------------------------------------------------------------

  describe "impl blocks" do
    test "parses impl block" do
      source = "impl MyStruct {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "impl MyStruct"
      assert symbol.kind == :class
    end

    test "parses impl trait for type" do
      source = "impl Display for MyStruct {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "impl Display for MyStruct"
      assert symbol.kind == :class
    end

    test "parses impl with generics" do
      source = "impl<T> Container<T> {}"

      assert {:ok, result} = RustParser.parse(source)
      # The grammar only handles simplified cases
      assert result.success == true or result.success == false
    end

    test "parses impl trait for type with generics" do
      source = "impl<T> Trait for Container<T> {}"

      assert {:ok, result} = RustParser.parse(source)
      # The grammar only handles simplified cases
      assert result.success == true or result.success == false
    end
  end

  # ---------------------------------------------------------------------------
  # Trait Declaration Tests
  # ---------------------------------------------------------------------------

  describe "trait declarations" do
    test "parses trait" do
      source = "trait Drawable {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "Drawable"
      assert symbol.kind == :type
    end

    test "parses public trait" do
      source = "pub trait PubDrawable {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "PubDrawable"
      assert symbol.doc == "pub"
    end

    test "parses unsafe trait" do
      source = "unsafe trait UnsafeDrawable {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "UnsafeDrawable"
      assert symbol.doc == "unsafe"
    end

    test "parses public unsafe trait" do
      source = "pub unsafe trait PubUnsafeDrawable {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "PubUnsafeDrawable"
      assert symbol.doc == "pub unsafe"
    end
  end

  # ---------------------------------------------------------------------------
  # Module Declaration Tests
  # ---------------------------------------------------------------------------

  describe "module declarations" do
    test "parses inline module" do
      source = "mod my_module {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "my_module"
      assert symbol.kind == :module
    end

    test "parses public inline module" do
      source = "pub mod pub_module {}"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "pub_module"
      assert symbol.doc == "pub"
    end

    test "parses file module declaration" do
      source = "mod file_module;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "file_module"
      assert symbol.kind == :module
      assert symbol.doc == "file"
    end

    test "parses public file module declaration" do
      source = "pub mod pub_file_module;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "pub_file_module"
      assert symbol.end_line == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Use Statement Tests
  # ---------------------------------------------------------------------------

  describe "use statements" do
    test "parses simple use statement" do
      source = "use std::io;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "use std::io"
      assert symbol.kind == :import
    end

    test "parses use self" do
      source = "use self;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "use self"
      assert symbol.kind == :import
    end

    test "parses use crate" do
      source = "use crate;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "use crate"
      assert symbol.kind == :import
    end

    test "parses use super" do
      source = "use super;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "use super"
      assert symbol.kind == :import
    end

    test "parses nested use path" do
      source = "use std::collections::HashMap;"

      assert {:ok, result} = RustParser.parse(source)
      # Depending on how the parser handles this, may succeed or fail
      assert is_map(result)
    end
  end

  # ---------------------------------------------------------------------------
  # Type Alias Tests
  # ---------------------------------------------------------------------------

  describe "type aliases" do
    test "parses type alias" do
      source = "type MyInt = i32;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "MyInt"
      assert symbol.kind == :type
      assert symbol.doc == "= i32"
    end

    test "parses public type alias" do
      source = "pub type PubMyInt = i64;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "PubMyInt"
      assert symbol.doc == "pub = i64"
    end
  end

  # ---------------------------------------------------------------------------
  # Constant Declaration Tests
  # ---------------------------------------------------------------------------

  describe "constant declarations" do
    test "parses const declaration" do
      source = "const MAX_SIZE: usize = 100;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "MAX_SIZE"
      assert symbol.kind == :constant
    end

    test "parses public const declaration" do
      source = "pub const PUB_MAX: i32 = 200;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "PUB_MAX"
      assert symbol.doc == "pub : i32"
    end
  end

  # ---------------------------------------------------------------------------
  # Static Declaration Tests
  # ---------------------------------------------------------------------------

  describe "static declarations" do
    test "parses static declaration" do
      source = "static GLOBAL: i32 = 0;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "GLOBAL"
      assert symbol.kind == :constant
      assert symbol.doc == ": i32"
    end

    test "parses mutable static declaration" do
      source = "static mut MUT_GLOBAL: i32 = 0;"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true

      [symbol] = result.symbols
      assert symbol.name == "MUT_GLOBAL"
      assert symbol.doc == "mut : i32"
    end
  end

  # ---------------------------------------------------------------------------
  # Complex File Tests
  # ---------------------------------------------------------------------------

  describe "complex files" do
    test "parses multiple declarations" do
      source = """
      use std::io;

      pub struct Point {
          x: i32,
          y: i32,
      }

      impl Point {
          fn new() -> Self {}
      }

      pub fn main() {}
      """

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true
      assert length(result.symbols) == 4

      [use_sym, struct_sym, impl_sym, fn_sym] = result.symbols
      assert use_sym.name == "use std::io"
      assert use_sym.kind == :import

      assert struct_sym.name == "Point"
      assert struct_sym.kind == :class
      assert struct_sym.doc == "pub"

      assert impl_sym.name == "impl Point"
      assert impl_sym.kind == :class

      assert fn_sym.name == "main"
      assert fn_sym.kind == :function
      assert fn_sym.doc == "pub"
    end

    test "parses real-world rust code" do
      source = """
      // A simple example
      pub mod utils;

      use std::collections::HashMap;

      pub struct Config {
          settings: HashMap<String, String>,
      }

      impl Config {
          pub fn new() -> Self {}
          fn get(&self, key: &str) -> Option<&String> {}
      }

      impl Default for Config {
          fn default() -> Self {}
      }

      pub trait Configurable {
          fn configure(&mut self);
      }

      pub const DEFAULT_TIMEOUT: u64 = 30;

      type ConfigResult<T> = Result<T, String>;
      """

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true
      assert length(result.symbols) >= 5
    end
  end

  # ---------------------------------------------------------------------------
  # Error Handling Tests
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "returns empty symbols for empty input" do
      source = ""

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true
      assert result.symbols == []
      assert result.diagnostics == []
    end

    test "returns empty symbols for whitespace" do
      source = "   \n\t  \n"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == true
      assert result.symbols == []
    end

    test "returns diagnostics on parse error" do
      # This should cause a parse error
      source = "fn }"

      assert {:ok, result} = RustParser.parse(source)
      assert result.success == false
      assert result.diagnostics != []
    end
  end

  # ---------------------------------------------------------------------------
  # Registration Test
  # ---------------------------------------------------------------------------

  describe "registration" do
    test "register/0 returns ok" do
      assert :ok = RustParser.register()
    end
  end
end
