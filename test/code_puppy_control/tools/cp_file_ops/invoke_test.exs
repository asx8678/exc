defmodule CodePuppyControl.Tools.CpFileOps.InvokeTest do
  @moduledoc """
  Tests for CpFileOps invoke/2 delegation and result shapes.

  Covers:
  - CpListFiles.invoke/2, CpReadFile.invoke/2, CpGrep.invoke/2
  - Result shape parity with bridge-caller expectations

  Refs: code_puppy-mmk.1
  """

  use ExUnit.Case

  alias CodePuppyControl.Tools.CpFileOps.{CpListFiles, CpReadFile, CpGrep}

  @test_dir Path.join(
              System.tmp_dir!(),
              "cp_file_ops_invoke_#{:erlang.unique_integer([:positive])}"
            )

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    File.write!(Path.join(@test_dir, "hello.txt"), "Hello World\nLine 2\nLine 3")
    File.write!(Path.join(@test_dir, "code.ex"), "defmodule Foo do\n  def bar, do: :ok\nend")

    subdir = Path.join(@test_dir, "sub")
    File.mkdir_p!(subdir)
    File.write!(Path.join(subdir, "nested.rs"), "fn main() {\n    // pass\n}\n")

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    %{test_dir: @test_dir, subdir: subdir}
  end

  # ============================================================================
  # CpListFiles — invoke/2
  # ============================================================================

  describe "CpListFiles.invoke/2" do
    test "lists files in directory with correct result shape", %{test_dir: dir} do
      assert {:ok, %{files: files, count: count}} =
               CpListFiles.invoke(%{"directory" => dir, "recursive" => false}, %{})

      assert is_list(files)
      assert count == length(files)

      paths = Enum.map(files, & &1.path)
      assert "hello.txt" in paths
      assert "code.ex" in paths
    end

    test "lists files recursively", %{test_dir: dir} do
      assert {:ok, %{files: files}} =
               CpListFiles.invoke(%{"directory" => dir, "recursive" => true}, %{})

      rel_paths = Enum.map(files, & &1.path)
      assert "sub/nested.rs" in rel_paths
    end

    test "defaults to current directory and recursive", %{test_dir: dir} do
      assert {:ok, %{files: _files}} =
               CpListFiles.invoke(%{"directory" => dir}, %{})
    end

    test "returns error for non-existent directory" do
      assert {:error, reason} =
               CpListFiles.invoke(%{"directory" => "/nonexistent_dir_xyz_12345"}, %{})

      assert is_binary(reason)
    end
  end

  # ============================================================================
  # CpReadFile — invoke/2
  # ============================================================================

  describe "CpReadFile.invoke/2" do
    test "reads file with correct result shape", %{test_dir: dir} do
      file_path = Path.join(dir, "hello.txt")

      assert {:ok, result} = CpReadFile.invoke(%{"file_path" => file_path}, %{})

      assert Map.has_key?(result, :path)
      assert Map.has_key?(result, :content)
      assert Map.has_key?(result, :num_lines)
      assert Map.has_key?(result, :size)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :error)
      assert result.content =~ "Hello World"
    end

    test "reads file with line range", %{test_dir: dir} do
      file_path = Path.join(dir, "hello.txt")

      assert {:ok, result} =
               CpReadFile.invoke(
                 %{"file_path" => file_path, "start_line" => 2, "num_lines" => 1},
                 %{}
               )

      assert result.content =~ "Line 2"
      assert result.truncated == true
    end

    test "returns error for non-existent file" do
      assert {:error, reason} =
               CpReadFile.invoke(%{"file_path" => "/nonexistent_file_xyz.txt"}, %{})

      assert is_binary(reason)
    end

    test "returns error for directory path", %{test_dir: dir} do
      assert {:error, reason} = CpReadFile.invoke(%{"file_path" => dir}, %{})
      assert is_binary(reason)
    end
  end

  # ============================================================================
  # CpGrep — invoke/2
  # ============================================================================

  describe "CpGrep.invoke/2" do
    test "finds pattern with correct result shape", %{test_dir: dir} do
      assert {:ok, %{matches: matches, count: count}} =
               CpGrep.invoke(%{"search_string" => "Hello", "directory" => dir}, %{})

      assert is_list(matches)
      assert count == length(matches)
      assert count >= 1

      match = hd(matches)
      assert Map.has_key?(match, :file)
      assert Map.has_key?(match, :line_number)
      assert Map.has_key?(match, :line_content)
      assert Map.has_key?(match, :match_start)
      assert Map.has_key?(match, :match_end)
      assert match.line_content =~ "Hello"
    end

    test "returns empty matches for non-matching pattern", %{test_dir: dir} do
      assert {:ok, %{matches: [], count: 0}} =
               CpGrep.invoke(
                 %{"search_string" => "ZZZ_NO_MATCH_12345", "directory" => dir},
                 %{}
               )
    end

    test "returns error for invalid regex" do
      assert {:error, reason} =
               CpGrep.invoke(%{"search_string" => "[invalid", "directory" => @test_dir}, %{})

      assert is_binary(reason)
    end

    test "defaults to current directory" do
      # Should not crash even with default directory
      assert {:ok, _} =
               CpGrep.invoke(%{"search_string" => "nonexistent_pattern_xyz"}, %{})
    end
  end

  # ============================================================================
  # Result shape parity with bridge callers
  # ============================================================================

  describe "result shapes match bridge-caller expectations" do
    test "CpListFiles result contains file_info maps with expected keys", %{test_dir: dir} do
      assert {:ok, %{files: [file | _]}} =
               CpListFiles.invoke(%{"directory" => dir, "recursive" => false}, %{})

      # Bridge callers expect: path, size, type, modified
      assert Map.has_key?(file, :path)
      assert Map.has_key?(file, :size)
      assert Map.has_key?(file, :type)
      assert Map.has_key?(file, :modified)

      assert file.type in [:file, :directory]
      assert is_integer(file.size)
    end

    test "CpReadFile result matches read_result type spec", %{test_dir: dir} do
      file_path = Path.join(dir, "hello.txt")
      assert {:ok, result} = CpReadFile.invoke(%{"file_path" => file_path}, %{})

      # Bridge callers expect: path, content, num_lines, size, truncated, error
      assert Map.has_key?(result, :path)
      assert Map.has_key?(result, :content)
      assert Map.has_key?(result, :num_lines)
      assert Map.has_key?(result, :size)
      assert Map.has_key?(result, :truncated)
      assert Map.has_key?(result, :error)

      assert is_binary(result.content)
      assert is_integer(result.num_lines)
      assert is_integer(result.size)
      assert is_boolean(result.truncated)
    end

    test "CpGrep result contains match maps with expected keys", %{test_dir: dir} do
      assert {:ok, %{matches: [match | _]}} =
               CpGrep.invoke(%{"search_string" => "Hello", "directory" => dir}, %{})

      # Bridge callers expect: file, line_number, line_content, match_start, match_end
      assert Map.has_key?(match, :file)
      assert Map.has_key?(match, :line_number)
      assert Map.has_key?(match, :line_content)
      assert Map.has_key?(match, :match_start)
      assert Map.has_key?(match, :match_end)

      assert is_binary(match.file)
      assert is_integer(match.line_number)
      assert is_binary(match.line_content)
      assert is_integer(match.match_start)
      assert is_integer(match.match_end)
    end

    test "CpReadFile error result shape for non-existent file" do
      assert {:error, reason} =
               CpReadFile.invoke(%{"file_path" => "/nonexistent_xyz.txt"}, %{})

      # Error is a string (inspect of the reason)
      assert is_binary(reason)
    end

    test "CpGrep error result shape for invalid regex" do
      assert {:error, reason} =
               CpGrep.invoke(%{"search_string" => "[invalid", "directory" => @test_dir}, %{})

      assert is_binary(reason)
    end
  end
end
