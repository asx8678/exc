defmodule CodePuppyControl.FileOpsTest do
  @moduledoc """
  Tests for FileOps module — ported from legacy Python file_operations tests.

  Note: .py fixture references have been replaced with .rs (Rust) equivalents
  per ADR-005 (Python source parsing is KEEP as data; generic .py fixtures
  should not imply Python runtime/product support).
  """

  use ExUnit.Case

  alias CodePuppyControl.FileOps

  @test_dir Path.join(System.tmp_dir!(), "file_ops_test_#{:erlang.unique_integer([:positive])}")

  setup do
    # Create test directory structure
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    # Create test files
    File.write!(Path.join(@test_dir, "file1.txt"), "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")

    File.write!(
      Path.join(@test_dir, "file2.ex"),
      "defmodule Test do\n def hello do\n :world\n end\nend"
    )

    File.write!(
      Path.join(@test_dir, "file3.rs"),
      "// TODO: implement this\nfn main() {\n    // pass\n}"
    )

    # Create subdirectory with more files
    subdir = Path.join(@test_dir, "subdir")
    File.mkdir_p!(subdir)

    File.write!(
      Path.join(subdir, "nested.ex"),
      "defmodule Nested do\n # FIXME: fix this\n def run do\n :ok\n end\nend"
    )

    # Create hidden file (should be excluded by default)
    File.write!(Path.join(@test_dir, ".hidden"), "secret content")

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    %{test_dir: @test_dir, subdir: subdir}
  end

  # ============================================================================
  # list_files tests
  # ============================================================================

  describe "list_files/2" do
    test "lists files in a directory (shallow)", %{test_dir: dir} do
      assert {:ok, files} = FileOps.list_files(dir, recursive: false)

      # Should have file1.txt, file2.ex, file3.rs, subdir (but not .hidden by default)
      paths = Enum.map(files, & &1.path)

      assert "file1.txt" in paths
      assert "file2.ex" in paths
      assert "file3.rs" in paths
      assert "subdir" in paths
      refute ".hidden" in paths

      # Check structure
      file1 = Enum.find(files, &(&1.path == "file1.txt"))
      assert file1.type == :file
      # "Line 1\nLine 2\nLine 3\nLine 4\nLine 5" (may have trailing newline)
      assert file1.size >= 29
      assert %DateTime{} = file1.modified
    end

    test "lists files recursively", %{test_dir: dir} do
      assert {:ok, files} = FileOps.list_files(dir, recursive: true)

      paths = Enum.map(files, & &1.path)

      # Should include all files including nested
      assert "file1.txt" in paths
      assert "subdir/nested.ex" in paths
      assert "subdir" in paths
    end

    test "can include hidden files", %{test_dir: dir} do
      assert {:ok, files} = FileOps.list_files(dir, recursive: false, include_hidden: true)

      paths = Enum.map(files, & &1.path)
      assert ".hidden" in paths
    end

    test "respects ignore patterns", %{test_dir: dir} do
      assert {:ok, files} = FileOps.list_files(dir, recursive: true, ignore_patterns: ["subdir"])

      paths = Enum.map(files, & &1.path)
      assert "file1.txt" in paths
      refute "subdir" in paths
      refute "subdir/nested.ex" in paths
    end

    test "respects max_files limit", %{test_dir: dir} do
      assert {:ok, files} = FileOps.list_files(dir, recursive: true, max_files: 3)
      assert length(files) <= 3
    end

    test "returns error for non-existent directory" do
      assert {:error, _} = FileOps.list_files("/nonexistent/directory/12345")
    end

    test "returns error for file instead of directory", %{test_dir: dir} do
      file_path = Path.join(dir, "file1.txt")
      assert {:error, _} = FileOps.list_files(file_path)
    end
  end

  # ============================================================================
  # grep tests
  # ============================================================================

  describe "grep/3" do
    test "finds pattern in files", %{test_dir: dir} do
      assert {:ok, matches} = FileOps.grep("defmodule", dir)

      assert length(matches) >= 2

      # Check structure
      match = hd(matches)
      assert is_binary(match.file)
      assert is_integer(match.line_number)
      assert is_binary(match.line_content)
      assert match.line_content =~ "defmodule"
      assert is_integer(match.match_start)
      assert is_integer(match.match_end)
    end

    test "is case sensitive by default", %{test_dir: dir} do
      # "DEFMODULE" should not match "defmodule"
      assert {:ok, matches} = FileOps.grep("DEFMODULE", dir)
      assert matches == []
    end

    test "can be case insensitive", %{test_dir: dir} do
      # Create file with uppercase DEFMODULE
      File.write!(Path.join(dir, "upper.ex"), "DEFMODULE Upper do\nend")

      assert {:ok, matches} = FileOps.grep("defmodule", dir, case_sensitive: false)
      assert length(matches) >= 1
    end

    test "respects max_matches limit", %{test_dir: dir} do
      assert {:ok, matches} = FileOps.grep("Line", dir, max_matches: 2)
      assert length(matches) <= 2
    end

    test "returns empty list for non-matching pattern", %{test_dir: dir} do
      assert {:ok, matches} = FileOps.grep("XYZ_NONEXISTENT_PATTERN_123", dir)
      assert matches == []
    end

    test "returns error for invalid regex", %{test_dir: dir} do
      assert {:error, _} = FileOps.grep("[invalid", dir)
    end

    test "supports glob file_pattern matching", %{test_dir: dir} do
      # *.ex should match .ex files only
      assert {:ok, matches} = FileOps.grep("defmodule", dir, file_pattern: "*.ex")
      assert length(matches) >= 1
      assert Enum.all?(matches, fn m -> String.ends_with?(m.file, ".ex") end)

      # *.rs should match .rs files only
      assert {:ok, rs_matches} = FileOps.grep("fn", dir, file_pattern: "*.rs")
      assert length(rs_matches) >= 1
      assert Enum.all?(rs_matches, fn m -> String.ends_with?(m.file, ".rs") end)

      # *.txt should not find defmodule
      assert {:ok, txt_matches} = FileOps.grep("defmodule", dir, file_pattern: "*.txt")
      assert txt_matches == []
    end
  end

  # ============================================================================
  # read_file tests
  # ============================================================================

  describe "read_file/2" do
    test "reads file contents", %{test_dir: dir} do
      file_path = Path.join(dir, "file1.txt")
      assert {:ok, result} = FileOps.read_file(file_path)

      assert result.path == file_path
      assert result.content == "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
      assert result.num_lines == 5
      # File may have trailing newline
      assert result.size >= 29
      assert result.truncated == false
      assert result.error == nil
    end

    test "reads specific line range", %{test_dir: dir} do
      file_path = Path.join(dir, "file1.txt")
      assert {:ok, result} = FileOps.read_file(file_path, start_line: 2, num_lines: 2)

      assert result.content == "Line 2\nLine 3"
      assert result.num_lines == 2
      assert result.truncated == true
    end

    test "returns error for non-existent file", %{test_dir: dir} do
      assert {:error, _} = FileOps.read_file(Path.join(dir, "nonexistent.txt"))
    end

    test "returns error for directory", %{test_dir: dir} do
      assert {:error, _} = FileOps.read_file(dir)
    end

    test "reads start_line from end", %{test_dir: dir} do
      file_path = Path.join(dir, "file1.txt")
      # Request more lines than exist from a starting point near the end
      assert {:ok, result} = FileOps.read_file(file_path, start_line: 4, num_lines: 10)

      assert result.content == "Line 4\nLine 5"
      assert result.num_lines == 2
    end
  end

  # ============================================================================
  # read_files tests (batch)
  # ============================================================================

  describe "read_files/2" do
    test "reads multiple files concurrently", %{test_dir: dir} do
      paths = [
        Path.join(dir, "file1.txt"),
        Path.join(dir, "file2.ex"),
        Path.join(dir, "file3.rs")
      ]

      assert {:ok, results} = FileOps.read_files(paths)
      assert length(results) == 3

      # All should have content
      assert Enum.all?(results, &(&1.error == nil))

      # Check each file was read
      paths_returned = Enum.map(results, & &1.path)
      assert Enum.all?(paths, fn p -> p in paths_returned end)
    end

    test "handles partial failures gracefully", %{test_dir: dir} do
      paths = [
        Path.join(dir, "file1.txt"),
        Path.join(dir, "nonexistent.txt"),
        Path.join(dir, "file2.ex")
      ]

      assert {:ok, results} = FileOps.read_files(paths)
      assert length(results) == 3

      # Check that nonexistent file has an error
      nonexistent = Enum.find(results, fn r -> r.path =~ "nonexistent" end)
      assert nonexistent.error != nil

      # Check we have the valid results too
      contents = Enum.map(results, & &1.content)
      assert Enum.any?(contents, &(is_binary(&1) and &1 =~ "Line 1"))
      assert Enum.any?(contents, &(is_binary(&1) and &1 =~ "defmodule"))
    end

    test "respects concurrency limit", %{test_dir: dir} do
      # Create many files
      for i <- 1..20 do
        File.write!(Path.join(dir, "bulk#{i}.txt"), "content #{i}")
      end

      paths = for i <- 1..20, do: Path.join(dir, "bulk#{i}.txt")

      assert {:ok, results} = FileOps.read_files(paths, max_concurrency: 2)
      assert length(results) == 20
    end

    test "returns error entries when all paths are invalid" do
      paths = [
        "/nonexistent1.txt",
        "/nonexistent2.txt"
      ]

      assert {:ok, results} = FileOps.read_files(paths)
      assert length(results) == 2
      # All entries should have errors
      assert Enum.all?(results, &(&1.error != nil))
    end
  end

  # ============================================================================
  # Security tests
  # ============================================================================

  describe "security" do
    test "blocks sensitive paths" do
      assert FileOps.sensitive_path?(Path.join(System.user_home!(), ".ssh/id_rsa"))
      assert FileOps.sensitive_path?("/etc/shadow")
      assert FileOps.sensitive_path?("/private/etc/sudoers")
      assert FileOps.sensitive_path?(Path.join(System.user_home!(), ".aws/credentials"))
      assert FileOps.sensitive_path?("/root/.ssh/authorized_keys")
    end

    test "allows safe paths", %{test_dir: dir} do
      refute FileOps.sensitive_path?(Path.join(dir, "file1.txt"))
      refute FileOps.sensitive_path?("/home/user/project/main.rs")
    end

    test "blocks .env files except examples" do
      assert FileOps.sensitive_path?(Path.join(System.user_home!(), ".env"))
      assert FileOps.sensitive_path?("/project/.env.local")

      # Allow examples
      refute FileOps.sensitive_path?("/project/.env.example")
      refute FileOps.sensitive_path?("/project/.env.sample")
    end

    test "blocks private key files by extension" do
      assert FileOps.sensitive_path?("/path/to/cert.pem")
      assert FileOps.sensitive_path?("/path/to/key.key")
      assert FileOps.sensitive_path?("/path/to/keystore.p12")
    end

    test "list_files filters sensitive paths" do
      # Create a mock sensitive file (won't actually exist, but path validation should catch it)
      assert {:error, _} = FileOps.list_files(Path.join(System.user_home!(), ".ssh"))
    end

    test "read_file blocks sensitive paths" do
      assert {:error, _} = FileOps.read_file(Path.join(System.user_home!(), ".ssh/id_rsa"))
    end

    test "grep blocks sensitive directory searches" do
      assert {:error, _} = FileOps.grep("test", "/etc")
    end

    test "read_files marks sensitive paths with errors", %{test_dir: dir} do
      # Mix of safe and sensitive paths
      paths = [
        Path.join(dir, "file1.txt"),
        Path.join(System.user_home!(), ".ssh/id_rsa")
      ]

      # Sensitive paths are included but marked with errors
      assert {:ok, results} = FileOps.read_files(paths)
      assert length(results) == 2

      # Safe path should succeed
      safe_result = Enum.find(results, fn r -> String.contains?(r.path, "file1.txt") end)
      assert safe_result.error == nil

      # Sensitive path should have error
      sensitive_result = Enum.find(results, fn r -> String.contains?(r.path, ".ssh") end)
      assert sensitive_result.error =~ "sensitive path blocked"
    end
  end

  # ============================================================================
  # Case-insensitive path matching tests
  # ============================================================================

  describe "case-insensitive path matching" do
    test "blocks case-variant sensitive directory paths" do
      # /etc should be blocked regardless of case on case-insensitive FS
      assert FileOps.sensitive_path?("/ETC/shadow")
      assert FileOps.sensitive_path?("/Etc/Passwd")
      assert FileOps.sensitive_path?("/PRIVATE/ETC/sudoers")
      assert FileOps.sensitive_path?("/ETC")
      assert FileOps.sensitive_path?("/VAR/LOG")
    end

    test "blocks case-variant home directory paths" do
      home = System.user_home!()
      # Build a case-swapped version of the home path
      upper_home = String.upcase(home)

      assert FileOps.sensitive_path?(Path.join(upper_home, ".ssh/id_rsa"))
      assert FileOps.sensitive_path?(Path.join(upper_home, ".aws/credentials"))
      assert FileOps.sensitive_path?(Path.join(upper_home, ".gnupg/pubring.gpg"))
    end

    test "blocks case-variant exact file paths" do
      assert FileOps.sensitive_path?("/ETC/SHADOW")
      assert FileOps.sensitive_path?("/ETC/PASSWD")
      assert FileOps.sensitive_path?("/PRIVATE/ETC/MASTER.PASSWD")
    end

    test "blocks case-variant sensitive extensions" do
      assert FileOps.sensitive_path?("/path/to/cert.PEM")
      assert FileOps.sensitive_path?("/path/to/key.KEY")
      assert FileOps.sensitive_path?("/path/to/store.P12")
      assert FileOps.sensitive_path?("/path/to/cert.Pem")
    end

    test "blocks case-variant .env files" do
      assert FileOps.sensitive_path?("/project/.ENV")
      assert FileOps.sensitive_path?("/project/.Env.Local")
      # But still allows examples
      refute FileOps.sensitive_path?("/project/.ENV.EXAMPLE")
      refute FileOps.sensitive_path?("/project/.Env.Sample")
    end

    test "validate_path blocks case-variant sensitive paths" do
      assert {:error, msg} = FileOps.validate_path("/ETC/passwd", "read")
      assert msg =~ "sensitive path blocked"

      assert {:error, _} = FileOps.validate_path("/PRIVATE/ETC/sudoers", "list")
    end
  end

  # ============================================================================
  # Symlink bypass tests
  # ============================================================================

  describe "symlink bypass protection" do
    test "blocks symlink pointing to sensitive file by extension", %{test_dir: dir} do
      secret = Path.join(dir, "secret.pem")
      link = Path.join(dir, "innocent.txt")
      File.write!(secret, "PRIVATE KEY DATA")
      File.ln_s!(secret, link)

      assert FileOps.sensitive_path?(link)
      assert {:error, msg} = FileOps.validate_path(link, "read")
      assert msg =~ "sensitive path blocked"
    end

    test "blocks symlink chain to sensitive target", %{test_dir: dir} do
      # Create a chain: link1 -> link2 -> secret.pem
      secret = Path.join(dir, "secret.key")
      link2 = Path.join(dir, "step2.txt")
      link1 = Path.join(dir, "step1.txt")
      File.write!(secret, "KEY DATA")
      File.ln_s!(secret, link2)
      File.ln_s!(link2, link1)

      assert FileOps.sensitive_path?(link1)
    end

    test "blocks symlink pointing to sensitive directory", %{test_dir: dir} do
      link = Path.join(dir, "safe_looking")

      # Only test if /etc exists (should on macOS/Linux)
      if File.dir?("/etc") do
        File.ln_s!("/etc", link)
        assert FileOps.sensitive_path?(link)
      end
    end

    test "read_file blocks symlink to sensitive file", %{test_dir: dir} do
      secret = Path.join(dir, "my_key.pem")
      link = Path.join(dir, "readme.txt")
      File.write!(secret, "SECRET")
      File.ln_s!(secret, link)

      assert {:error, msg} = FileOps.read_file(link)
      assert msg =~ "sensitive path blocked"
    end

    test "allows symlink to safe target", %{test_dir: dir} do
      safe_file = Path.join(dir, "file1.txt")
      link = Path.join(dir, "link_to_safe.txt")
      File.ln_s!(safe_file, link)

      refute FileOps.sensitive_path?(link)
    end

    test "handles broken symlinks gracefully", %{test_dir: dir} do
      link = Path.join(dir, "broken_link")
      File.ln_s!("/nonexistent/path/abc", link)

      # Should not crash, and should not report as sensitive
      # (can't resolve target, so check the link path itself)
      refute FileOps.sensitive_path?(link)
    end

    test "handles non-existent paths gracefully" do
      # Non-existent path can't be a symlink, just check the string
      refute FileOps.sensitive_path?("/tmp/does_not_exist_12345.txt")
      assert FileOps.sensitive_path?("/etc/does_not_exist_12345")
    end
  end

  # ============================================================================
  # EOL normalization tests
  # ============================================================================

  describe "EOL normalization" do
    test "read_file strips BOM when normalize_eol is true", %{test_dir: dir} do
      # Create file with BOM
      file_path = Path.join(dir, "bom_file.txt")
      File.write!(file_path, <<0xEF, 0xBB, 0xBF, "Hello World">>)

      assert {:ok, result} = FileOps.read_file(file_path, normalize_eol: true)

      assert result.content == "Hello World"
      assert result.bom == <<0xEF, 0xBB, 0xBF>>
      assert result.error == nil
    end

    test "read_file normalizes CRLF when normalize_eol is true", %{test_dir: dir} do
      file_path = Path.join(dir, "crlf_file.txt")
      File.write!(file_path, "Line 1\r\nLine 2\r\nLine 3")

      assert {:ok, result} = FileOps.read_file(file_path, normalize_eol: true)

      assert result.content == "Line 1\nLine 2\nLine 3"
      assert result.bom == nil
    end

    test "read_file normalizes CR when normalize_eol is true", %{test_dir: dir} do
      file_path = Path.join(dir, "cr_file.txt")
      File.write!(file_path, "Line 1\rLine 2\rLine 3")

      assert {:ok, result} = FileOps.read_file(file_path, normalize_eol: true)

      assert result.content == "Line 1\nLine 2\nLine 3"
    end

    test "read_file handles BOM + CRLF together", %{test_dir: dir} do
      file_path = Path.join(dir, "bom_crlf.txt")
      File.write!(file_path, <<0xEF, 0xBB, 0xBF, "Header\r\nLine1\r\nLine2">>)

      assert {:ok, result} = FileOps.read_file(file_path, normalize_eol: true)

      assert result.content == "Header\nLine1\nLine2"
      assert result.bom == <<0xEF, 0xBB, 0xBF>>
    end

    test "read_file leaves binary files unchanged", %{test_dir: dir} do
      file_path = Path.join(dir, "binary.bin")
      # Binary content with some bytes that look like CRLF but aren't text
      File.write!(file_path, <<0x00, 0x0D, 0x0A, 0x01, 0x02, 0x03>>)

      assert {:ok, result} = FileOps.read_file(file_path, normalize_eol: true)

      # Binary files should not be normalized (contains NUL)
      assert result.content == <<0x00, 0x0D, 0x0A, 0x01, 0x02, 0x03>>
    end

    test "read_file without normalize_eol preserves BOM in content", %{test_dir: dir} do
      file_path = Path.join(dir, "raw_bom.txt")
      File.write!(file_path, <<0xEF, 0xBB, 0xBF, "content">>)

      assert {:ok, result} = FileOps.read_file(file_path, normalize_eol: false)

      # BOM is part of content when not normalizing
      assert result.content == <<0xEF, 0xBB, 0xBF, "content">>
      assert result.bom == nil
    end

    test "read_file with line range and EOL normalization", %{test_dir: dir} do
      file_path = Path.join(dir, "range_crlf.txt")
      File.write!(file_path, "Line1\r\nLine2\r\nLine3\r\nLine4\r\nLine5")

      assert {:ok, result} =
               FileOps.read_file(file_path, start_line: 2, num_lines: 2, normalize_eol: true)

      assert result.content == "Line2\nLine3"
      assert result.num_lines == 2
      assert result.truncated == true
    end

    test "read_files with normalize_eol applies to all files", %{test_dir: dir} do
      file1 = Path.join(dir, "file1_bom.txt")
      file2 = Path.join(dir, "file2_crlf.txt")

      File.write!(file1, <<0xEF, 0xBB, 0xBF, "File1">>)
      File.write!(file2, "File2\r\nContent")

      assert {:ok, results} = FileOps.read_files([file1, file2], normalize_eol: true)

      result1 = Enum.find(results, &(&1.path == file1))
      result2 = Enum.find(results, &(&1.path == file2))

      assert result1.content == "File1"
      assert result1.bom == <<0xEF, 0xBB, 0xBF>>

      assert result2.content == "File2\nContent"
      assert result2.bom == nil
    end
  end

  # ============================================================================
  # validate_path tests
  # ============================================================================

  describe "validate_path/2" do
    test "accepts valid paths", %{test_dir: dir} do
      assert {:ok, _} = FileOps.validate_path(dir, "list")
      assert {:ok, _} = FileOps.validate_path(Path.join(dir, "file1.txt"), "read")
    end

    test "rejects empty paths" do
      assert {:error, "File path cannot be empty"} = FileOps.validate_path("", "read")
    end

    test "rejects paths with null bytes" do
      assert {:error, "File path contains null byte"} =
               FileOps.validate_path("/path/with\0null", "read")
    end

    test "rejects sensitive paths with appropriate message" do
      assert {:error, msg} =
               FileOps.validate_path(Path.join(System.user_home!(), ".ssh/id_rsa"), "read")

      assert msg =~ "sensitive path blocked"
      assert msg =~ "read"
    end

    test "normalizes paths", %{test_dir: dir} do
      # Path with .. should be normalized
      assert {:ok, normalized} =
               FileOps.validate_path(Path.join(dir, "../#{Path.basename(dir)}/file1.txt"), "read")

      assert normalized == Path.join(dir, "file1.txt")
    end
  end
end
