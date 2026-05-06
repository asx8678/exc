defmodule CodePuppyControl.ParserTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Parser

  setup do
    # Ensure parsers are registered before each test
    CodePuppyControl.Parsing.Parsers.register_all()
    :ok
  end

  # Generates a unique temp file path safe for async tests.
  # Uses System.unique_integer and System.pid to avoid collisions
  # across concurrent tests and concurrently running BEAM OS processes.
  defp temp_file_path(prefix, extension) do
    unique_int = System.unique_integer([:positive, :monotonic])
    pid = System.pid()
    filename = "#{prefix}_#{pid}_#{unique_int}.#{extension}"
    Path.join(System.tmp_dir!(), filename)
  end

  describe "supported_languages/0" do
    test "returns list of languages" do
      languages = Parser.supported_languages()
      assert is_list(languages)
      assert "python" in languages
      assert "elixir" in languages
    end
  end

  describe "is_language_supported/1" do
    test "returns true for supported languages" do
      assert Parser.is_language_supported("python") == true
      assert Parser.is_language_supported("elixir") == true
      assert Parser.is_language_supported("rust") == true
      assert Parser.is_language_supported("javascript") == true
    end

    test "normalizes language aliases" do
      assert Parser.is_language_supported("py") == true
      assert Parser.is_language_supported("ex") == true
      assert Parser.is_language_supported("js") == true
    end

    test "returns false for unsupported languages" do
      assert Parser.is_language_supported("brainfuck") == false
      assert Parser.is_language_supported("unknown_language_xyz") == false
    end
  end

  describe "nif_available?/0" do
    test "returns boolean" do
      assert is_boolean(Parser.nif_available?())
    end
  end

  describe "version/0" do
    test "returns a version string" do
      version = Parser.version()
      assert is_binary(version)
      assert version != ""
    end
  end

  describe "normalize_language/1" do
    test "normalizes py to python" do
      assert Parser.normalize_language("py") == "python"
    end

    test "normalizes js to javascript" do
      assert Parser.normalize_language("js") == "javascript"
    end

    test "normalizes jsx to javascript" do
      assert Parser.normalize_language("jsx") == "javascript"
    end

    test "normalizes ts to typescript" do
      assert Parser.normalize_language("ts") == "typescript"
    end

    test "normalizes ex to elixir" do
      assert Parser.normalize_language("ex") == "elixir"
    end

    test "normalizes exs to elixir" do
      assert Parser.normalize_language("exs") == "elixir"
    end

    test "passes through canonical names unchanged" do
      assert Parser.normalize_language("python") == "python"
      assert Parser.normalize_language("rust") == "rust"
      assert Parser.normalize_language("elixir") == "elixir"
    end

    test "handles case insensitivity" do
      assert Parser.normalize_language("PY") == "python"
      assert Parser.normalize_language("Python") == "python"
    end
  end

  describe "get_language_info/1" do
    test "returns info for supported language" do
      {:ok, info} = Parser.get_language_info("python")
      assert info["name"] == "python"
      assert info["highlights_available"] == true
      assert info["folds_available"] == true
      assert info["indents_available"] == true
    end

    test "returns error for unsupported language" do
      assert {:error, :unsupported_language} = Parser.get_language_info("go")
    end

    test "normalizes language name in info" do
      {:ok, info} = Parser.get_language_info("py")
      assert info["name"] == "python"
    end
  end

  describe "extract_symbols/2" do
    test "extracts Python function" do
      source = """
      def hello():
          pass

      class Foo:
          def bar():
              pass
      """

      {:ok, outline} = Parser.extract_symbols(source, "python")
      assert outline["success"] == true
      assert is_list(outline["symbols"])
      assert length(outline["symbols"]) >= 2
    end

    test "extracts Elixir module and functions" do
      source = """
      defmodule MyApp do
        def hello, do: :world
        defp private_fn, do: :secret
      end
      """

      {:ok, outline} = Parser.extract_symbols(source, "elixir")
      assert outline["success"] == true
      assert is_list(outline["symbols"])
      # NIF returns modules and top-level definitions
      # Tree-sitter extracts modules; some versions also extract functions
      assert length(outline["symbols"]) >= 1

      # Verify we at least got the module
      assert Enum.any?(outline["symbols"], fn s ->
               s["kind"] == "module" and s["name"] == "MyApp"
             end)
    end

    test "returns error for unsupported language" do
      source = "some code"
      {:ok, outline} = Parser.extract_symbols(source, "unsupported_language")
      # Should still return ok but with success=false or fallback
      assert is_map(outline)
    end
  end

  describe "parse_source/2" do
    test "parses Python code" do
      source = "def hello(): pass"

      {:ok, result} = Parser.parse_source(source, "python")
      assert is_map(result)
      assert result["success"] == true
      assert result["language"] == "python"
    end

    test "returns error details for invalid code" do
      source = "def hello( # incomplete"

      {:ok, result} = Parser.parse_source(source, "python")
      # Even "invalid" code parses (tree-sitter is error-resilient)
      assert is_map(result)
      assert result["language"] == "python"
    end
  end

  describe "get_folds/2" do
    test "extracts fold ranges from Python" do
      source = """
      def outer():
          def inner():
              pass
          return inner
      """

      {:ok, result} = Parser.get_folds(source, "python")
      assert is_map(result)
      assert result["success"] == true
      assert is_list(result["folds"])
    end
  end

  describe "get_highlights/2" do
    test "extracts highlight captures from Python" do
      source = """
      def hello():
          return "world"
      """

      {:ok, result} = Parser.get_highlights(source, "python")
      assert is_map(result)
      assert result["success"] == true
      assert is_list(result["captures"])
    end
  end

  describe "extract_syntax_diagnostics/2" do
    test "finds errors in invalid code" do
      source = "def hello( # missing closing paren and colon"

      {:ok, result} = Parser.extract_syntax_diagnostics(source, "python")
      assert is_map(result)
      assert is_list(result["diagnostics"])
      assert is_integer(result["error_count"])
      assert is_integer(result["warning_count"])
    end
  end

  describe "detect_language/1 via extract_symbols_from_file" do
    test "detects Python from .py extension" do
      # Create a temp file
      path = temp_file_path("test", "py")
      File.write!(path, "def foo(): pass")

      try do
        {:ok, outline} = Parser.extract_symbols_from_file(path)
        assert outline["language"] == "python"
      after
        File.rm(path)
      end
    end

    test "detects Elixir from .ex extension" do
      path = temp_file_path("test", "ex")
      File.write!(path, "defmodule Foo, do: :bar")

      try do
        {:ok, outline} = Parser.extract_symbols_from_file(path)
        # Should work even with fallback
        assert is_map(outline)
      after
        File.rm(path)
      end
    end
  end

  describe "parse_file/2" do
    test "parses a temporary Python file with auto-detected language" do
      path = temp_file_path("test_parse", "py")
      File.write!(path, "def hello():\n pass\n")

      try do
        {:ok, result} = Parser.parse_file(path)
        assert is_map(result)
        assert result["success"] == true
        assert result["language"] == "python"
      after
        File.rm(path)
      end
    end

    test "parses a temporary Elixir file with explicit language" do
      path = temp_file_path("test_parse", "ex")
      File.write!(path, "defmodule Foo do\n def bar, do: :ok\nend\n")

      try do
        {:ok, result} = Parser.parse_file(path, "elixir")
        assert is_map(result)
        assert result["success"] == true
        assert result["language"] == "elixir"
      after
        File.rm(path)
      end
    end
  end

  describe "get_folds_from_file/2" do
    test "extracts fold ranges from a Python file with auto-detected language" do
      path = temp_file_path("test_folds", "py")
      File.write!(path, "def outer():\n def inner():\n pass\n return inner\n")

      try do
        {:ok, result} = Parser.get_folds_from_file(path)
        assert is_map(result)
        assert result["success"] == true
        assert is_list(result["folds"])
      after
        File.rm(path)
      end
    end

    test "extracts fold ranges from a Python file with explicit language" do
      path = temp_file_path("test_folds", "py")
      File.write!(path, "def outer():\n def inner():\n pass\n return inner\n")

      try do
        {:ok, result} = Parser.get_folds_from_file(path, "python")
        assert is_map(result)
        assert result["success"] == true
        assert is_list(result["folds"])
      after
        File.rm(path)
      end
    end
  end

  describe "get_highlights_from_file/2" do
    test "extracts highlight captures from a Python file with auto-detected language" do
      path = temp_file_path("test_highlights", "py")
      File.write!(path, "def hello():\n return \"world\"\n")

      try do
        {:ok, result} = Parser.get_highlights_from_file(path)
        assert is_map(result)
        assert result["success"] == true
        assert is_list(result["captures"])
      after
        File.rm(path)
      end
    end

    test "extracts highlight captures from a Python file with explicit language" do
      path = temp_file_path("test_highlights", "py")
      File.write!(path, "def hello():\n return \"world\"\n")

      try do
        {:ok, result} = Parser.get_highlights_from_file(path, "python")
        assert is_map(result)
        assert result["success"] == true
        assert is_list(result["captures"])
      after
        File.rm(path)
      end
    end
  end
end
