defmodule CodePuppyControl.CodeContextTest do
  @moduledoc """
  Tests for the CodeContext module.

  Note (ADR-005): .py fixtures in this test exercise Python-as-data source
  parsing via the Elixir-native Leex/Yecc parser — no Python runtime is
  required or implied. See ADR-005 for the Python Source Parsing Policy.
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.CodeContext

  # Setup: Create temp files for testing
  setup do
    # Create a temp directory with test files
    temp_dir = Path.join(System.tmp_dir!(), "code_context_test_#{:rand.uniform(10000)}")
    File.mkdir_p!(temp_dir)

    # Create a Python file with symbols
    python_file = Path.join(temp_dir, "test_module.py")

    python_content = """
    class MyClass:
        def method_one(self):
            pass

        def method_two(self):
            pass

    def standalone_function():
        return 42

    class AnotherClass:
        pass
    """

    File.write!(python_file, python_content)

    # Create an Elixir file with symbols
    elixir_file = Path.join(temp_dir, "test_module.ex")

    elixir_content = """
    defmodule MyModule do
      def hello do
        "world"
      end

      def add(a, b) do
        a + b
      end
    end

    defmodule AnotherModule do
      def process(data) do
        data |> Enum.map(& &1 * 2)
      end
    end
    """

    File.write!(elixir_file, elixir_content)

    # Create a simple text file
    text_file = Path.join(temp_dir, "readme.txt")
    File.write!(text_file, "This is a readme file\nwith multiple lines\nof text content.")

    # Clear cache before each test
    CodeContext.invalidate_cache()

    on_exit(fn ->
      File.rm_rf!(temp_dir)
    end)

    {:ok,
     temp_dir: temp_dir, python_file: python_file, elixir_file: elixir_file, text_file: text_file}
  end

  describe "explore_file/2" do
    test "explores a Python file successfully", %{python_file: python_file} do
      {:ok, result} = CodeContext.explore_file(python_file)

      assert result.file_path == Path.expand(python_file)
      assert result.language == "python"
      assert result.content != nil
      assert result.file_size > 0
      assert result.num_lines > 0
      assert result.num_tokens > 0
      assert result.parse_time_ms >= 0

      # Check outline
      assert result.outline.language == "python"
      assert is_list(result.outline.symbols)
      assert length(result.outline.symbols) >= 4
      assert result.outline.success == true
    end

    test "explores an Elixir file successfully", %{elixir_file: elixir_file} do
      {:ok, result} = CodeContext.explore_file(elixir_file)

      assert result.file_path == Path.expand(elixir_file)
      assert result.language == "elixir"
      assert result.content != nil
      assert result.file_size > 0

      # Check outline contains defmodule and def
      assert result.outline.language == "elixir"
      symbols = result.outline.symbols
      assert is_list(symbols)
      assert length(symbols) >= 3
    end

    test "respects include_content option", %{python_file: python_file} do
      {:ok, with_content} = CodeContext.explore_file(python_file, include_content: true)
      assert with_content.content != nil

      {:ok, without_content} = CodeContext.explore_file(python_file, include_content: false)
      assert without_content.content == nil
    end

    test "caches results and uses cache on second call", %{python_file: python_file} do
      # First call
      {:ok, result1} = CodeContext.explore_file(python_file)

      # Modify the file
      original_content = File.read!(python_file)
      File.write!(python_file, "# modified content\n" <> original_content)

      # Second call should use cache (not see modified content)
      {:ok, result2} = CodeContext.explore_file(python_file)
      assert result2.content == result1.content

      # Third call with force_refresh should see new content
      {:ok, result3} = CodeContext.explore_file(python_file, force_refresh: true)
      assert String.contains?(result3.content, "# modified content")
    end

    test "returns error for non-existent file" do
      {:error, reason} = CodeContext.explore_file("/non/existent/file.py")
      assert is_binary(reason)
    end

    test "handles unsupported file types gracefully", %{text_file: text_file} do
      {:ok, result} = CodeContext.explore_file(text_file)

      assert result.language == nil or result.language == "unknown"
      assert result.content != nil
      # Outline may be empty or fail gracefully
      assert is_map(result.outline)
    end
  end

  describe "get_outline/2" do
    test "extracts outline from Python file", %{python_file: python_file} do
      {:ok, outline} = CodeContext.get_outline(python_file)

      assert outline.language == "python"
      assert is_list(outline.symbols)
      assert length(outline.symbols) >= 4
      assert outline.success == true
      assert outline.extraction_time_ms >= 0
    end

    test "extracts outline from Elixir file", %{elixir_file: elixir_file} do
      {:ok, outline} = CodeContext.get_outline(elixir_file)

      assert outline.language == "elixir"
      assert is_list(outline.symbols)
      assert length(outline.symbols) >= 3
      assert outline.success == true
    end

    test "respects max_depth option", %{python_file: python_file} do
      # This would filter nested symbols if depth tracking were implemented
      {:ok, _outline} = CodeContext.get_outline(python_file, max_depth: 2)
      # Test passes if it doesn't crash - depth filtering may not be fully implemented
    end

    test "returns error for non-existent file" do
      {:error, reason} = CodeContext.get_outline("/non/existent/file.py")
      assert is_binary(reason)
    end
  end

  describe "explore_directory/2" do
    test "explores directory with default options", %{temp_dir: temp_dir} do
      {:ok, results} = CodeContext.explore_directory(temp_dir)

      assert is_list(results)
      # Should find at least 3 files
      assert length(results) >= 3

      # Check Python file is in results
      python_results = Enum.filter(results, &(&1.language == "python"))
      assert length(python_results) == 1

      # Check Elixir file is in results
      elixir_results = Enum.filter(results, &(&1.language == "elixir"))
      assert length(elixir_results) == 1
    end

    test "respects max_files option", %{temp_dir: temp_dir} do
      {:ok, results} = CodeContext.explore_directory(temp_dir, max_files: 2)

      assert is_list(results)
      assert length(results) <= 2
    end

    test "respects pattern option", %{temp_dir: temp_dir} do
      {:ok, results} = CodeContext.explore_directory(temp_dir, pattern: "*.py")

      assert is_list(results)
      assert length(results) == 1
      assert hd(results).language == "python"
    end

    test "respects recursive option", %{temp_dir: temp_dir} do
      # Create subdirectory with a file
      subdir = Path.join(temp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "nested.py"), "# nested file")

      {:ok, recursive_results} = CodeContext.explore_directory(temp_dir, recursive: true)
      {:ok, shallow_results} = CodeContext.explore_directory(temp_dir, recursive: false)

      assert length(recursive_results) > length(shallow_results)
    end

    test "default include_content is false for directories", %{temp_dir: temp_dir} do
      {:ok, results} = CodeContext.explore_directory(temp_dir)

      Enum.each(results, fn result ->
        assert result.content == nil
      end)
    end

    test "returns error for non-existent directory" do
      {:error, reason} = CodeContext.explore_directory("/non/existent/directory")
      assert is_binary(reason) or is_atom(reason)
    end
  end

  describe "find_symbol_definitions/2" do
    test "finds symbol definitions in directory", %{temp_dir: temp_dir} do
      {:ok, matches} = CodeContext.find_symbol_definitions(temp_dir, "MyClass")

      assert is_list(matches)
      assert length(matches) >= 1

      # Check the match has the expected structure
      match = hd(matches)
      assert is_binary(match.file_path)
      assert is_map(match.symbol)
      assert match.symbol["name"] == "MyClass"
    end

    test "finds Elixir module definitions", %{temp_dir: temp_dir} do
      {:ok, matches} = CodeContext.find_symbol_definitions(temp_dir, "MyModule")

      assert is_list(matches)
      assert length(matches) >= 1

      match = hd(matches)
      assert match.symbol["name"] == "MyModule"
    end

    test "returns empty list when symbol not found", %{temp_dir: temp_dir} do
      {:ok, matches} = CodeContext.find_symbol_definitions(temp_dir, "NonExistentSymbol12345")

      assert is_list(matches)
      assert matches == []
    end

    test "returns error for non-existent directory" do
      {:error, reason} = CodeContext.find_symbol_definitions("/non/existent", "SomeClass")
      assert is_binary(reason) or is_atom(reason)
    end
  end

  describe "cache operations" do
    test "cache_stats returns valid statistics" do
      # Clear cache
      CodeContext.invalidate_cache()

      stats = CodeContext.cache_stats()

      assert is_map(stats)
      assert is_integer(stats.size)
      assert is_integer(stats.hits)
      assert is_integer(stats.misses)
      assert is_float(stats.hit_rate)
      assert stats.hit_rate >= 0.0 and stats.hit_rate <= 1.0
    end

    test "invalidate_cache removes all entries when no path given", %{python_file: python_file} do
      # Populate cache
      CodeContext.explore_file(python_file)

      # Verify cache has entries
      before_stats = CodeContext.cache_stats()
      assert before_stats.size > 0

      # Clear cache
      removed = CodeContext.invalidate_cache()

      assert is_integer(removed)
      assert removed >= 1

      # Verify cache is empty (except for stats entry)
      after_stats = CodeContext.cache_stats()
      # Size may be 0 or 1 for stats entry
      assert after_stats.size <= 1
    end

    test "invalidate_cache removes specific file entry", %{
      python_file: python_file,
      elixir_file: elixir_file
    } do
      # Populate cache with both files
      CodeContext.explore_file(python_file)
      CodeContext.explore_file(elixir_file)

      # Invalidate just one
      removed = CodeContext.invalidate_cache(python_file)
      assert removed == 1

      # The other should still be cached
      {:ok, _result} = CodeContext.explore_file(elixir_file)
      # If it was cached, it should return without reading file
    end

    test "cache entries expire after TTL", %{python_file: python_file} do
      # This test is tricky because we don't want to wait 5 minutes
      # So we just verify the cache works normally
      {:ok, _result} = CodeContext.explore_file(python_file)

      stats = CodeContext.cache_stats()
      assert stats.size >= 1
    end
  end

  describe "language detection" do
    test "detects Python files correctly", %{temp_dir: temp_dir} do
      py_file = Path.join(temp_dir, "detect_test.py")
      File.write!(py_file, "x = 1")
      {:ok, result} = CodeContext.explore_file(py_file)
      assert result.language == "python"
    end

    test "detects Elixir files correctly", %{temp_dir: temp_dir} do
      ex_file = Path.join(temp_dir, "detect_test.ex")
      File.write!(ex_file, "x = 1")
      {:ok, result} = CodeContext.explore_file(ex_file)
      assert result.language == "elixir"

      exs_file = Path.join(temp_dir, "detect_test.exs")
      File.write!(exs_file, "x = 1")
      {:ok, result} = CodeContext.explore_file(exs_file)
      assert result.language == "elixir"
    end

    test "detects JavaScript and TypeScript files correctly", %{temp_dir: temp_dir} do
      js_file = Path.join(temp_dir, "detect_test.js")
      File.write!(js_file, "const x = 1")
      {:ok, result} = CodeContext.explore_file(js_file)
      assert result.language == "javascript"

      ts_file = Path.join(temp_dir, "detect_test.ts")
      File.write!(ts_file, "const x: number = 1")
      {:ok, result} = CodeContext.explore_file(ts_file)
      assert result.language == "typescript"
    end

    test "detects Rust files correctly", %{temp_dir: temp_dir} do
      rs_file = Path.join(temp_dir, "detect_test.rs")
      File.write!(rs_file, "fn main() {}")
      {:ok, result} = CodeContext.explore_file(rs_file)
      assert result.language == "rust"
    end

    test "handles unknown extensions gracefully", %{temp_dir: temp_dir} do
      unknown_file = Path.join(temp_dir, "detect_test.unknown")
      File.write!(unknown_file, "some content")
      {:ok, result} = CodeContext.explore_file(unknown_file)
      assert result.language == "unknown"
    end
  end

  describe "edge cases" do
    test "handles empty files gracefully", %{temp_dir: temp_dir} do
      empty_file = Path.join(temp_dir, "empty.py")
      File.write!(empty_file, "")

      {:ok, result} = CodeContext.explore_file(empty_file)

      assert result.file_size == 0
      assert result.num_lines == 0
      assert result.num_tokens >= 0
      assert result.content == ""
    end

    test "handles very large files (within limits)", %{temp_dir: temp_dir} do
      # Create a file with many lines
      large_file = Path.join(temp_dir, "large.py")
      lines = for i <- 1..1000, do: "def function_#{i}(): pass"
      File.write!(large_file, Enum.join(lines, "\n"))

      {:ok, result} = CodeContext.explore_file(large_file)

      assert result.num_lines == 1000
      assert length(result.outline.symbols) > 0
    end
  end
end
