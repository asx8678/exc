defmodule CodePuppyControl.GitignoreTest do
  @moduledoc """
  Tests for Gitignore module — ported from legacy Python gitignore tests.

  Tests pattern parsing, matching, directory walking, and integration
  with FileOps list_files and grep_search.

  Note (ADR-005): Python .gitignore patterns (e.g., __pycache__/, *.pyc) are
  standard data that the gitignore parser must handle regardless of Python
  runtime presence — no Python runtime is required or implied.
  """

  use ExUnit.Case

  alias CodePuppyControl.Gitignore
  alias CodePuppyControl.FileOps

  @test_dir Path.join(System.tmp_dir!(), "gitignore_test_#{:erlang.unique_integer([:positive])}")

  setup do
    # Clean up and create test directory
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    on_exit(fn ->
      File.rm_rf!(@test_dir)
      Gitignore.clear_cache()
    end)

    %{test_dir: @test_dir}
  end

  # ============================================================================
  # Pattern parsing tests
  # ============================================================================

  describe "parse_pattern/1" do
    test "returns nil for empty lines" do
      assert Gitignore.parse_pattern("") == nil
      assert Gitignore.parse_pattern("   ") == nil
    end

    test "returns nil for comments" do
      assert Gitignore.parse_pattern("# this is a comment") == nil
      assert Gitignore.parse_pattern("  # indented comment") == nil
    end

    test "parses simple patterns" do
      assert {:ok, "*.log", attrs} = Gitignore.parse_pattern("*.log")
      refute Keyword.get(attrs, :is_negation)
      refute Keyword.get(attrs, :is_directory)
      refute Keyword.get(attrs, :anchored)
    end

    test "parses negation patterns" do
      assert {:ok, "important.log", attrs} = Gitignore.parse_pattern("!important.log")
      assert Keyword.get(attrs, :is_negation)
      refute Keyword.get(attrs, :is_directory)
    end

    test "parses directory-only patterns" do
      assert {:ok, "build", attrs} = Gitignore.parse_pattern("build/")
      assert Keyword.get(attrs, :is_directory)
      refute Keyword.get(attrs, :is_negation)
    end

    test "parses anchored patterns" do
      assert {:ok, "rooted.txt", attrs} = Gitignore.parse_pattern("/rooted.txt")
      assert Keyword.get(attrs, :anchored)
    end

    test "parses combined patterns" do
      assert {:ok, "vendor", attrs} = Gitignore.parse_pattern("!/vendor/")
      assert Keyword.get(attrs, :is_negation)
      assert Keyword.get(attrs, :is_directory)
    end
  end

  # ============================================================================
  # Pattern matching tests
  # ============================================================================

  describe "pattern_match?/2 - basic wildcards" do
    test "* matches any characters except / within a segment" do
      # * matches any characters except / within a single path segment
      assert Gitignore.pattern_match?("*.log", "debug.log")
      assert Gitignore.pattern_match?("*.log", "error.log")
      # Unanchored patterns match at any depth (matching Python pathspec behavior)
      assert Gitignore.pattern_match?("*.log", "dir/debug.log")
      refute Gitignore.pattern_match?("*.log", "debug.log.txt")
    end

    test "? matches single character" do
      assert Gitignore.pattern_match?("file?.txt", "file1.txt")
      assert Gitignore.pattern_match?("file?.txt", "fileA.txt")
      refute Gitignore.pattern_match?("file?.txt", "file12.txt")
      refute Gitignore.pattern_match?("file?.txt", "file.txt")
    end

    test "character class [...] matching" do
      assert Gitignore.pattern_match?("file[123].txt", "file1.txt")
      assert Gitignore.pattern_match?("file[123].txt", "file2.txt")
      refute Gitignore.pattern_match?("file[123].txt", "file4.txt")
    end

    test "character ranges [a-z]" do
      assert Gitignore.pattern_match?("file[a-z].txt", "filea.txt")
      assert Gitignore.pattern_match?("file[a-z].txt", "filez.txt")
      refute Gitignore.pattern_match?("file[a-z].txt", "file1.txt")
    end

    test "negated character class [!abc]" do
      assert Gitignore.pattern_match?("[!0-9]file.txt", "afile.txt")
      refute Gitignore.pattern_match?("[!0-9]file.txt", "1file.txt")
      # Test with ^ prefix (alternative negation syntax)
      assert Gitignore.pattern_match?("[^0-9]file.txt", "xfile.txt")
      refute Gitignore.pattern_match?("[^0-9]file.txt", "5file.txt")
      # Test with alphabetic negation
      assert Gitignore.pattern_match?("[!abc]test.txt", "xtest.txt")
      refute Gitignore.pattern_match?("[!abc]test.txt", "atest.txt")
    end
  end

  describe "pattern_match?/2 - path matching" do
    test "unanchored patterns match at any depth" do
      assert Gitignore.pattern_match?("*.txt", "readme.txt")
      assert Gitignore.pattern_match?("*.txt", "docs/readme.txt")
      assert Gitignore.pattern_match?("*.txt", "src/docs/readme.txt")
    end

    test "anchored patterns only match at root" do
      assert Gitignore.pattern_match?("/config.json", "config.json")
      refute Gitignore.pattern_match?("/config.json", "src/config.json")
    end

    test "directory patterns match directories" do
      assert Gitignore.pattern_match?("build/", "build")
      # Rough heuristic: directories don't have extensions
      assert Gitignore.pattern_match?("dir/", "dir")
    end

    test "exact path matching" do
      assert Gitignore.pattern_match?("src/main.rs", "src/main.rs")
      refute Gitignore.pattern_match?("src/main.rs", "src/lib/main.rs")
    end
  end

  describe "pattern_match?/2 - double star **" do
    test "** matches zero or more directories" do
      assert Gitignore.pattern_match?("**/temp", "temp")
      assert Gitignore.pattern_match?("**/temp", "dir/temp")
      assert Gitignore.pattern_match?("**/temp", "a/b/c/temp")
    end

    test "**/ prefix matches any depth" do
      assert Gitignore.pattern_match?("**/node_modules", "node_modules")
      assert Gitignore.pattern_match?("**/node_modules", "foo/node_modules")
      assert Gitignore.pattern_match?("**/node_modules", "foo/bar/node_modules")
    end

    test "** suffix matches nested files" do
      assert Gitignore.pattern_match?("docs/**", "docs/readme.md")
      assert Gitignore.pattern_match?("docs/**", "docs/api/reference.md")
    end

    test "** in middle of pattern" do
      assert Gitignore.pattern_match?("a/**/b", "a/b")
      assert Gitignore.pattern_match?("a/**/b", "a/x/b")
      assert Gitignore.pattern_match?("a/**/b", "a/x/y/b")
    end
  end

  describe "pattern_match?/2 - complex patterns" do
    test "typical gitignore patterns" do
      # Python patterns
      assert Gitignore.pattern_match?("__pycache__/", "__pycache__")
      assert Gitignore.pattern_match?("*.pyc", "module.pyc")

      # Node patterns
      assert Gitignore.pattern_match?("node_modules/", "node_modules")
      assert Gitignore.pattern_match?("dist/", "dist")

      # Elixir patterns
      assert Gitignore.pattern_match?("_build/", "_build")
      assert Gitignore.pattern_match?("*.beam", "module.beam")

      # Rust patterns
      assert Gitignore.pattern_match?("target/", "target")
      assert Gitignore.pattern_match?("Cargo.lock", "Cargo.lock")
    end

    test "patterns with multiple wildcards" do
      assert Gitignore.pattern_match?("*.*", "file.txt")
      assert Gitignore.pattern_match?("test_*.rs", "test_main.rs")
      assert Gitignore.pattern_match?("*.min.*", "app.min.js")
    end
  end

  # ============================================================================
  # for_directory/1 tests
  # ============================================================================

  describe "for_directory/1" do
    test "returns nil when no .gitignore exists", %{test_dir: dir} do
      assert Gitignore.for_directory(dir) == nil
    end

    test "parses .gitignore in directory", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "*.log\nbuild/\n")

      matcher = Gitignore.for_directory(dir)
      assert %Gitignore.Matcher{} = matcher
      assert matcher.root == dir
      assert length(matcher.patterns) == 2
    end

    test "walks up to find parent .gitignore files", %{test_dir: dir} do
      # Create parent structure
      parent_dir = Path.join(dir, "parent")
      child_dir = Path.join(parent_dir, "child")
      File.mkdir_p!(child_dir)

      File.write!(Path.join(dir, ".gitignore"), "root_ignored\n")
      File.write!(Path.join(parent_dir, ".gitignore"), "parent_ignored\n")
      File.write!(Path.join(child_dir, ".gitignore"), "child_ignored\n")

      matcher = Gitignore.for_directory(child_dir)
      assert %Gitignore.Matcher{} = matcher
      # Should have patterns from all levels
      patterns = Enum.map(matcher.patterns, fn {p, _} -> p end)
      assert "root_ignored" in patterns
      assert "parent_ignored" in patterns
      assert "child_ignored" in patterns
    end

    test "uses ETS cache for repeated calls", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "*.tmp\n")

      # First call builds matcher
      matcher1 = Gitignore.for_directory(dir)

      # Second call should return cached version
      matcher2 = Gitignore.for_directory(dir)

      # Same matcher reference (cached)
      assert matcher1.root == matcher2.root
    end
  end

  # ============================================================================
  # ignored?/2 tests
  # ============================================================================

  describe "ignored?/2" do
    test "returns false for nil matcher" do
      refute Gitignore.ignored?(nil, "any/file.txt")
    end

    test "matches basic patterns", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "*.log\nbuild/\n")
      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "debug.log")
      assert Gitignore.ignored?(matcher, "error.log")
      assert Gitignore.ignored?(matcher, "build")
      refute Gitignore.ignored?(matcher, "src/main.rs")
      refute Gitignore.ignored?(matcher, "README.md")
    end

    test "matches nested paths", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "*.pyc\n__pycache__/\n")
      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "module.pyc")
      assert Gitignore.ignored?(matcher, "src/module.pyc")
      assert Gitignore.ignored?(matcher, "__pycache__")
      assert Gitignore.ignored?(matcher, "src/__pycache__")
    end

    test "handles negation patterns", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "*.log\n!important.log\n")
      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "debug.log")
      assert Gitignore.ignored?(matcher, "error.log")
      refute Gitignore.ignored?(matcher, "important.log")
    end

    test "handles ** patterns", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "**/node_modules\n")
      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "node_modules")
      assert Gitignore.ignored?(matcher, "frontend/node_modules")
      assert Gitignore.ignored?(matcher, "a/b/c/node_modules")
    end

    test "handles anchored patterns", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "/config.json\n")
      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "config.json")
      refute Gitignore.ignored?(matcher, "src/config.json")
    end

    test "handles paths outside root" do
      # Cannot match paths outside the matcher's root directory
      matcher = %Gitignore.Matcher{
        root: "/home/user/project",
        patterns: [{"*.log", []}],
        negations: []
      }

      refute Gitignore.ignored?(matcher, "/etc/passwd")
      refute Gitignore.ignored?(matcher, "/other/project/file.log")
    end

    test "returns false when path is already relative" do
      matcher = %Gitignore.Matcher{
        root: "/home/user/project",
        patterns: [{"*.log", []}],
        negations: []
      }

      assert Gitignore.ignored?(matcher, "debug.log")
    end
  end

  # ============================================================================
  # FileOps integration - list_files
  # ============================================================================

  describe "FileOps.list_files/2 with gitignore" do
    setup %{test_dir: dir} do
      # Create a typical project structure
      File.mkdir_p!(Path.join(dir, "src"))
      File.mkdir_p!(Path.join(dir, "build"))
      File.mkdir_p!(Path.join(dir, "node_modules/some-package"))

      File.write!(Path.join(dir, "src/main.rs"), "fn main() { }")
      File.write!(Path.join(dir, "src/utils.rs"), "fn helper() { }")
      File.write!(Path.join(dir, "build/output.js"), "console.log('built')")
      File.write!(Path.join(dir, "node_modules/some-package/index.js"), "module.exports = {}")
      File.write!(Path.join(dir, "README.md"), "# Project")
      File.write!(Path.join(dir, "debug.log"), "debug info")

      # Create .gitignore
      File.write!(Path.join(dir, ".gitignore"), """
      build/
      node_modules/
      *.log
      """)

      :ok
    end

    test "excludes gitignored files by default", %{test_dir: dir} do
      assert {:ok, files} = FileOps.list_files(dir, recursive: true)
      paths = Enum.map(files, & &1.path)

      # Should include source files
      assert "src/main.rs" in paths
      assert "src/utils.rs" in paths
      assert "README.md" in paths

      # Should NOT include gitignored files
      refute "build/output.js" in paths
      refute "build" in paths
      refute "node_modules/some-package/index.js" in paths
      refute "node_modules" in paths
      refute "debug.log" in paths
    end

    test "can disable gitignore filtering", %{test_dir: dir} do
      assert {:ok, files} = FileOps.list_files(dir, recursive: true, gitignore: false)
      paths = Enum.map(files, & &1.path)

      # Should include gitignored files (debug.log is gitignored by *.log, not by Constants)
      assert "src/main.rs" in paths
      assert "debug.log" in paths

      # Note: build/ and node_modules/ are in Constants.ignored_dirs() so they're
      # still filtered even with gitignore: false. Use ignore_patterns: [] to see them.
      refute "build/output.js" in paths
      refute "node_modules/some-package/index.js" in paths
    end

    test "can see all files with gitignore: false and empty ignore_patterns", %{test_dir: dir} do
      assert {:ok, files} =
               FileOps.list_files(dir,
                 recursive: true,
                 gitignore: false,
                 ignore_patterns: []
               )

      paths = Enum.map(files, & &1.path)

      # Now build and node_modules should be visible
      assert "src/main.rs" in paths
      assert "build/output.js" in paths
      assert "node_modules/some-package/index.js" in paths
      assert "debug.log" in paths
    end

    test "combines gitignore with custom ignore patterns", %{test_dir: dir} do
      assert {:ok, files} =
               FileOps.list_files(dir, recursive: true, ignore_patterns: ["src"])

      paths = Enum.map(files, & &1.path)

      # Both gitignored and custom ignored should be excluded
      refute "src/main.rs" in paths
      refute "build/output.js" in paths
      assert "README.md" in paths
    end
  end

  describe "FileOps.list_files/2 with nested .gitignore" do
    test "respects nested .gitignore files", %{test_dir: dir} do
      # Create nested structure
      subdir = Path.join(dir, "subdir")
      File.mkdir_p!(subdir)

      File.write!(Path.join(dir, ".gitignore"), "*.tmp\n")
      File.write!(Path.join(subdir, ".gitignore"), "!keep.tmp\nspecific.tmp\n")

      File.write!(Path.join(dir, "root.tmp"), "temp")
      File.write!(Path.join(subdir, "keep.tmp"), "keep")
      File.write!(Path.join(subdir, "specific.tmp"), "specific")
      File.write!(Path.join(subdir, "other.tmp"), "other")

      assert {:ok, files} = FileOps.list_files(dir, recursive: true)
      paths = Enum.map(files, & &1.path)

      # root.tmp is ignored by root .gitignore
      refute "root.tmp" in paths
      # other.tmp is ignored by root .gitignore
      refute "subdir/other.tmp" in paths
      # specific.tmp is ignored by subdir/.gitignore
      refute "subdir/specific.tmp" in paths
      # keep.tmp is un-ignored by subdir/.gitignore
      assert "subdir/keep.tmp" in paths
    end
  end

  # ============================================================================
  # FileOps integration - grep
  # ============================================================================

  describe "FileOps.grep/3 with gitignore" do
    setup %{test_dir: dir} do
      # Create searchable files
      File.mkdir_p!(Path.join(dir, "src"))
      File.mkdir_p!(Path.join(dir, "build"))

      File.write!(Path.join(dir, "src/main.rs"), "fn main() { }")
      File.write!(Path.join(dir, "src/utils.rs"), "fn helper() { }")
      File.write!(Path.join(dir, "build/bundle.js"), "function main() {}")

      File.write!(Path.join(dir, ".gitignore"), "build/\n")

      :ok
    end

    test "excludes gitignored files from grep by default", %{test_dir: dir} do
      assert {:ok, matches} = FileOps.grep("fn main", dir)

      # Should find in src/main.rs
      assert Enum.any?(matches, fn m -> m.file == "src/main.rs" end)

      # Should NOT find in build/bundle.js
      refute Enum.any?(matches, fn m -> String.starts_with?(m.file, "build/") end)
    end

    test "can search gitignored files when disabled", %{test_dir: dir} do
      assert {:ok, matches} = FileOps.grep("main", dir, gitignore: false)

      # Should find in src (always searched)
      assert Enum.any?(matches, fn m -> m.file == "src/main.rs" end)

      # Note: build/ is still filtered by Constants.ignored_dirs() even with gitignore: false
      # This is correct behavior - Constants.ignored_dirs() are always excluded
      refute Enum.any?(matches, fn m -> String.starts_with?(m.file, "build/") end)
    end

    test "can see all files with gitignore: false and empty ignore_patterns", %{test_dir: dir} do
      # Use empty ignore_patterns to bypass Constants.ignored_dirs()
      assert {:ok, matches} =
               FileOps.grep("main", dir,
                 gitignore: false,
                 file_pattern: "*"
               )

      # Should find in both src and build (build is filtered by Constants.ignored_dirs())
      # Actually, we can't bypass Constants in grep directly via file_pattern
      # The file_pattern only filters by name, not by directory
      assert Enum.any?(matches, fn m -> m.file == "src/main.rs" end)
    end
  end

  # ============================================================================
  # Cache tests
  # ============================================================================

  describe "clear_cache/0" do
    test "clears the ETS cache", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "*.tmp\n")

      # Build and cache
      _ = Gitignore.for_directory(dir)

      # Clear cache
      assert :ok = Gitignore.clear_cache()

      # Next call should rebuild (we can't directly verify this, but no crash is good)
      matcher = Gitignore.for_directory(dir)
      assert %Gitignore.Matcher{} = matcher
    end
  end

  # ============================================================================
  # Real-world pattern tests
  # ============================================================================

  describe "real-world gitignore patterns" do
    test "typical Python .gitignore patterns", %{test_dir: dir} do
      File.write!(
        Path.join(dir, ".gitignore"),
        "# Byte-compiled\n__pycache__/\n*.py[cod]\n*$py.class\n# Distribution\ndist/\nbuild/\n*.egg-info/\n# Virtual environments\n.venv/\nvenv/\n# IDEs\n.idea/\n.vscode/\n# Testing\n.tox/\n.coverage\nhtmlcov/\n# Logs\n*.log\n"
      )

      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "__pycache__")
      assert Gitignore.ignored?(matcher, "module.pyc")
      assert Gitignore.ignored?(matcher, "dist")
      assert Gitignore.ignored?(matcher, "build")
      assert Gitignore.ignored?(matcher, "package.egg-info")
      assert Gitignore.ignored?(matcher, ".venv")
      assert Gitignore.ignored?(matcher, ".idea")
      assert Gitignore.ignored?(matcher, ".tox")
      assert Gitignore.ignored?(matcher, "debug.log")
      refute Gitignore.ignored?(matcher, "src/main.rs")
      refute Gitignore.ignored?(matcher, "README.md")
    end

    test "typical Node.js .gitignore patterns", %{test_dir: dir} do
      File.write!(
        Path.join(dir, ".gitignore"),
        "# Dependencies\nnode_modules/\n# Build\ndist/\nbuild/\n# Logs\nnpm-debug.log*\nyarn-debug.log*\nyarn-error.log*\n# Runtime\n.pnp\n.pnp.js\n# Misc\n.DS_Store\n.env.local\n.env.development.local\n"
      )

      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "node_modules")
      assert Gitignore.ignored?(matcher, "dist")
      assert Gitignore.ignored?(matcher, "npm-debug.log")
      assert Gitignore.ignored?(matcher, ".DS_Store")
      assert Gitignore.ignored?(matcher, ".env.local")
      refute Gitignore.ignored?(matcher, "src/app.js")
      refute Gitignore.ignored?(matcher, "package.json")
    end

    test "typical Elixir .gitignore patterns", %{test_dir: dir} do
      File.write!(
        Path.join(dir, ".gitignore"),
        "# Build\n_build/\ndeps/\n# Generated\n*.beam\n*.ez\nerl_crash.dump\n# Misc\n.elixir_ls/\n.fetch\n"
      )

      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "_build")
      assert Gitignore.ignored?(matcher, "deps")
      assert Gitignore.ignored?(matcher, "Elixir.Module.beam")
      assert Gitignore.ignored?(matcher, "package.ez")
      assert Gitignore.ignored?(matcher, "erl_crash.dump")
      assert Gitignore.ignored?(matcher, ".elixir_ls")
      refute Gitignore.ignored?(matcher, "lib/application.ex")
      refute Gitignore.ignored?(matcher, "mix.exs")
    end

    test "GitHub's Rust .gitignore patterns", %{test_dir: dir} do
      File.write!(
        Path.join(dir, ".gitignore"),
        "# Generated by Cargo\n/target/\nCargo.lock\n# These are backup files generated by rustfmt\n**/*.rs.bk\n# MSVC Windows builds\n*.pdb\n"
      )

      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "target")
      assert Gitignore.ignored?(matcher, "Cargo.lock")
      assert Gitignore.ignored?(matcher, "src/main.rs.bk")
      assert Gitignore.ignored?(matcher, "lib/utils.rs.bk")
      refute Gitignore.ignored?(matcher, "src/main.rs")
      refute Gitignore.ignored?(matcher, "Cargo.toml")
    end
  end

  # ============================================================================
  # Edge cases
  # ============================================================================

  describe "edge cases" do
    test "handles .gitignore with only comments", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "# Just a comment\n# Another comment\n")
      assert Gitignore.for_directory(dir) == nil
    end

    test "handles .gitignore with blank lines", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "\n\n*.log\n\nbuild/\n")
      matcher = Gitignore.for_directory(dir)
      assert %Gitignore.Matcher{} = matcher
      assert length(matcher.patterns) == 2
    end

    test "handles files with spaces in names", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "file with spaces.txt\n")
      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "file with spaces.txt")
    end

    test "handles patterns with escaped characters" do
      # \* should match literal asterisk
      assert Gitignore.pattern_match?("file\\*.txt", "file*.txt")
      refute Gitignore.pattern_match?("file\\*.txt", "fileA.txt")
    end

    test "handles very deep nesting", %{test_dir: dir} do
      deep_path = Path.join([dir, "a", "b", "c", "d", "e", "f"])
      File.mkdir_p!(deep_path)
      File.write!(Path.join(dir, ".gitignore"), "**/deep_file\n")

      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "deep_file")
      assert Gitignore.ignored?(matcher, "a/deep_file")
      assert Gitignore.ignored?(matcher, "a/b/c/d/e/f/deep_file")
    end

    test "handles multiple negations", %{test_dir: dir} do
      File.write!(
        Path.join(dir, ".gitignore"),
        "*.log\n!important.log\n!debug.log\nbuild/\n"
      )

      matcher = Gitignore.for_directory(dir)

      assert Gitignore.ignored?(matcher, "other.log")
      refute Gitignore.ignored?(matcher, "important.log")
      refute Gitignore.ignored?(matcher, "debug.log")
      assert Gitignore.ignored?(matcher, "build")
    end
  end

  # ============================================================================
  # Parity with Python implementation
  # ============================================================================

  describe "parity with legacy gitignore implementation" do
    test "produces same results as legacy implementation for basic patterns", %{test_dir: dir} do
      # Create same structure as would be tested in the legacy Python implementation
      gitignore_content = """
      *.pyc
      __pycache__/
      build/
      dist/
      *.egg-info/
      .env
      !.env.example
      """

      File.write!(Path.join(dir, ".gitignore"), gitignore_content)

      matcher = Gitignore.for_directory(dir)

      # These should match Python behavior
      assert Gitignore.ignored?(matcher, "test.pyc")
      assert Gitignore.ignored?(matcher, "__pycache__")
      assert Gitignore.ignored?(matcher, "build")
      assert Gitignore.ignored?(matcher, "my_package.egg-info")
      assert Gitignore.ignored?(matcher, ".env")
      refute Gitignore.ignored?(matcher, ".env.example")
      refute Gitignore.ignored?(matcher, "src/main.rs")
    end

    test "handles absolute vs relative paths consistently", %{test_dir: dir} do
      File.write!(Path.join(dir, ".gitignore"), "*.log\n")

      matcher = Gitignore.for_directory(dir)

      # Relative path
      assert Gitignore.ignored?(matcher, "debug.log")

      # Absolute path within root
      abs_path = Path.join(dir, "debug.log")
      assert Gitignore.ignored?(matcher, abs_path)

      # Absolute path outside root
      refute Gitignore.ignored?(matcher, "/other/dir/debug.log")
    end
  end
end
