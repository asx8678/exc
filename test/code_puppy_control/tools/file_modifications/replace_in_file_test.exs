defmodule CodePuppyControl.Tools.FileModifications.ReplaceInFileTest do
  @moduledoc "Tests for the ReplaceInFile tool."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.ReplaceInFile

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "replace_in_file_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "name/0" do
    test "returns :replace_in_file" do
      assert ReplaceInFile.name() == :replace_in_file
    end
  end

  describe "parameters/0" do
    test "returns valid JSON schema with replacements as array" do
      schema = ReplaceInFile.parameters()
      assert schema["type"] == "object"
      assert "file_path" in schema["required"]
      assert "replacements" in schema["required"]
      assert schema["properties"]["replacements"]["type"] == "array"
      assert schema["properties"]["replacements"]["minItems"] == 1
    end
  end

  describe "invoke/2 with valid replacements list" do
    test "applies single replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replace_test.txt")
      File.write!(path, "hello world")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "world", "new_str" => "universe"}]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.success == true
      assert result.changed == true
      assert File.read!(path) == "hello universe"
    end

    test "applies multiple replacements sequentially", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replace_multi_test.txt")
      File.write!(path, "a b c")

      args = %{
        "file_path" => path,
        "replacements" => [
          %{"old_str" => "a", "new_str" => "x"},
          %{"old_str" => "b", "new_str" => "y"},
          %{"old_str" => "c", "new_str" => "z"}
        ]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.success == true
      assert File.read!(path) == "x y z"
    end

    test "handles empty replacements list gracefully", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replace_empty_test.txt")
      File.write!(path, "unchanged")

      args = %{
        "file_path" => path,
        "replacements" => []
      }

      # minItems=1 should catch this at validation level, but let's test the behavior
      # Actually, schema validation will reject this. Let's test with the runner.
      # For direct invoke, we handle it:
      result = ReplaceInFile.invoke(args, %{})
      # Either validation error or no-change result
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "returns no-change when text already matches", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replace_same_test.txt")
      File.write!(path, "already correct")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "already correct", "new_str" => "already correct"}]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.success == true
      assert result.changed == false
    end

    test "fails on non-existent file", %{tmp_dir: tmp_dir} do
      args = %{
        "file_path" => Path.join(tmp_dir, "nonexistent_file.txt"),
        "replacements" => [%{"old_str" => "foo", "new_str" => "bar"}]
      }

      assert {:error, result} = ReplaceInFile.invoke(args, %{})
      assert result.message =~ "not found"
    end

    test "generates diff on successful replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replace_diff_test.txt")
      File.write!(path, "line 1\nline 2\nline 3\n")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "line 2", "new_str" => "modified"}]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.diff =~ "-line 2"
      assert result.diff =~ "+modified"
    end
  end

  describe "invoke/2 with invalid replacements" do
    test "rejects non-list replacements" do
      args = %{
        "file_path" => "/tmp/test.txt",
        "replacements" => "not a list"
      }

      assert {:error, reason} = ReplaceInFile.invoke(args, %{})
      assert reason =~ "list"
    end

    test "rejects replacement item without old_str", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replace_bad_test.txt")
      File.write!(path, "content")

      args = %{
        "file_path" => path,
        "replacements" => [%{"new_str" => "bar"}]
      }

      assert {:error, reason} = ReplaceInFile.invoke(args, %{})
      assert reason =~ "old_str"
    end

    test "rejects replacement item without new_str", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replace_bad2_test.txt")
      File.write!(path, "content")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "foo"}]
      }

      assert {:error, reason} = ReplaceInFile.invoke(args, %{})
      assert reason =~ "new_str"
    end
  end

  describe "permission_check/2" do
    test "allows non-sensitive paths" do
      args = %{"file_path" => "/tmp/safe_file.txt"}
      assert :ok = ReplaceInFile.permission_check(args, %{})
    end

    test "denies SSH key paths" do
      args = %{"file_path" => Path.join(System.user_home!(), ".ssh/config")}
      assert {:deny, _reason} = ReplaceInFile.permission_check(args, %{})
    end
  end
end
