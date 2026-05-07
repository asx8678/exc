defmodule CodePuppyControl.Parsing.ParserTest do
  @moduledoc """
  Tests for the unified Parser API (facade).

  These tests verify that the high-level parsing API correctly routes
  to language-specific parsers and handles various scenarios.

  Note (ADR-005): Python parser references (.py, "python") in this test
  exercise Python-as-data source parsing via the Elixir-native Leex/Yecc
  parser — no Python runtime is required or implied. See ADR-005 for the
  Python Source Parsing Policy.
  """
  use ExUnit.Case

  alias CodePuppyControl.Parsing.Parser
  alias CodePuppyControl.Parsing.ParserRegistry
  alias CodePuppyControl.Parsing.ParserBehaviour

  # Test parser modules
  defmodule TestElixirParser do
    @behaviour ParserBehaviour

    @impl true
    def parse(source) do
      symbols =
        if String.contains?(source, "defmodule") do
          [
            %{
              name: "TestModule",
              kind: :module,
              line: 1,
              end_line: 3,
              doc: nil,
              children: []
            }
          ]
        else
          []
        end

      {:ok,
       %{
         language: "elixir",
         symbols: symbols,
         diagnostics: [],
         success: true,
         parse_time_ms: 0.5
       }}
    end

    @impl true
    def language, do: "elixir"

    @impl true
    def file_extensions, do: [".ex", ".exs"]

    @impl true
    def supported?, do: true
  end

  defmodule TestPythonParser do
    @behaviour ParserBehaviour

    @impl true
    def parse(source) do
      symbols =
        if String.contains?(source, "def ") do
          [
            %{
              name: "test_function",
              kind: :function,
              line: 1,
              end_line: 2,
              doc: nil,
              children: []
            }
          ]
        else
          []
        end

      {:ok,
       %{
         language: "python",
         symbols: symbols,
         diagnostics: [],
         success: true,
         parse_time_ms: 0.3
       }}
    end

    @impl true
    def language, do: "python"

    @impl true
    def file_extensions, do: [".py"]

    @impl true
    def supported?, do: true
  end

  defmodule TestErrorParser do
    @behaviour ParserBehaviour

    @impl true
    def parse(_source) do
      {:error, :parse_error}
    end

    @impl true
    def language, do: "error_lang"

    @impl true
    def file_extensions, do: [".err"]

    @impl true
    def supported?, do: true
  end

  setup do
    # Ensure registry is started (either by application or test supervision)
    # If already running (application supervision), clear its state
    # If not running, start it under test supervision
    case Process.whereis(ParserRegistry) do
      nil ->
        # Not running, start fresh
        start_supervised!(ParserRegistry)

      pid when is_pid(pid) ->
        # Running (likely from application supervision), clear state
        Agent.update(ParserRegistry, fn _ -> %{parsers: %{}, extensions: %{}} end)
    end

    # Register test parsers
    ParserRegistry.register(TestElixirParser)
    ParserRegistry.register(TestPythonParser)
    ParserRegistry.register(TestErrorParser)

    :ok
  end

  describe "parse/2" do
    test "parses source code for registered language" do
      assert {:ok, result} = Parser.parse("defmodule Test do end", "elixir")
      assert result.language == "elixir"
      assert result.success == true
      assert length(result.symbols) == 1
    end

    test "returns error for unsupported language" do
      assert {:error, :unsupported_language} = Parser.parse("code", "unknown")
    end

    test "normalizes language aliases" do
      # ex -> elixir, py -> python
      assert {:ok, _} = Parser.parse("defmodule Test do end", "ex")
      assert {:ok, _} = Parser.parse("def foo(): pass", "py")
    end

    test "returns error when parser returns error" do
      assert {:error, :parse_error} = Parser.parse("code", "error_lang")
    end

    test "parse result contains expected fields" do
      assert {:ok, result} = Parser.parse("defmodule Test do end", "elixir")
      assert is_binary(result.language)
      assert is_list(result.symbols)
      assert is_list(result.diagnostics)
      assert is_boolean(result.success)
      assert is_float(result.parse_time_ms)
    end
  end

  describe "parse_file/1" do
    test "parses file with registered extension" do
      # Create a temporary file
      test_file = Path.join(System.tmp_dir!(), "test_#{System.unique_integer()}.ex")
      File.write!(test_file, "defmodule Test do end")

      on_exit(fn -> File.rm(test_file) end)

      assert {:ok, result} = Parser.parse_file(test_file)
      assert result.language == "elixir"
    end

    test "returns error for file with unsupported extension" do
      test_file = Path.join(System.tmp_dir!(), "test_#{System.unique_integer()}.unknown")
      File.write!(test_file, "some content")

      on_exit(fn -> File.rm(test_file) end)

      assert {:error, :unsupported_language} = Parser.parse_file(test_file)
    end

    test "returns error for non-existent file" do
      assert {:error, :file_not_found} = Parser.parse_file("/nonexistent/file.ex")
    end
  end

  describe "extract_symbols/2" do
    test "extracts symbols from source code" do
      assert {:ok, symbols} = Parser.extract_symbols("defmodule Test do end", "elixir")
      assert length(symbols) == 1
      assert hd(symbols).name == "TestModule"
      assert hd(symbols).kind == :module
    end

    test "returns empty list when no symbols found" do
      assert {:ok, []} = Parser.extract_symbols("# just a comment", "elixir")
    end

    test "returns error for unsupported language" do
      assert {:error, :unsupported_language} = Parser.extract_symbols("code", "unknown")
    end
  end

  describe "extract_diagnostics/2" do
    test "extracts diagnostics from source code" do
      # Our test parser returns empty diagnostics
      assert {:ok, []} = Parser.extract_diagnostics("code", "elixir")
    end

    test "returns error for unsupported language" do
      assert {:error, :unsupported_language} = Parser.extract_diagnostics("code", "unknown")
    end
  end

  describe "supported_languages/0" do
    test "returns list of registered languages" do
      languages = Parser.supported_languages()
      assert is_list(languages)

      names = Enum.map(languages, fn {name, _} -> name end)
      assert "elixir" in names
      assert "python" in names
    end
  end

  describe "language_supported?/1" do
    test "returns true for registered languages" do
      assert Parser.language_supported?("elixir") == true
      assert Parser.language_supported?("python") == true
    end

    test "returns false for unregistered languages" do
      assert Parser.language_supported?("unknown") == false
    end

    test "handles language aliases" do
      assert Parser.language_supported?("ex") == true
      assert Parser.language_supported?("py") == true
    end
  end

  describe "get_parser/1" do
    test "returns parser for registered language" do
      assert {:ok, TestElixirParser} = Parser.get_parser("elixir")
      assert {:ok, TestPythonParser} = Parser.get_parser("python")
    end

    test "returns :error for unregistered language" do
      assert :error = Parser.get_parser("unknown")
    end

    test "normalizes language aliases" do
      assert {:ok, TestElixirParser} = Parser.get_parser("ex")
      assert {:ok, TestPythonParser} = Parser.get_parser("py")
    end
  end

  describe "get_parser_for_extension/1" do
    test "returns parser for registered extension" do
      assert {:ok, TestElixirParser} = Parser.get_parser_for_extension(".ex")
      assert {:ok, TestPythonParser} = Parser.get_parser_for_extension(".py")
    end

    test "returns :error for unregistered extension" do
      assert :error = Parser.get_parser_for_extension(".unknown")
    end
  end

  describe "normalize_language/1" do
    test "normalizes Elixir aliases" do
      assert Parser.normalize_language("ex") == "elixir"
      assert Parser.normalize_language("exs") == "elixir"
      assert Parser.normalize_language("EX") == "elixir"
    end

    test "normalizes Python aliases" do
      assert Parser.normalize_language("py") == "python"
      assert Parser.normalize_language("PY") == "python"
    end

    test "normalizes JavaScript aliases" do
      assert Parser.normalize_language("js") == "javascript"
      assert Parser.normalize_language("jsx") == "javascript"
    end

    test "normalizes TypeScript aliases" do
      assert Parser.normalize_language("ts") == "typescript"
      assert Parser.normalize_language("tsx") == "typescript"
    end

    test "normalizes Rust aliases" do
      assert Parser.normalize_language("rs") == "rust"
    end

    test "passes through unknown languages unchanged" do
      assert Parser.normalize_language("unknown") == "unknown"
      assert Parser.normalize_language("brainfuck") == "brainfuck"
    end
  end
end
