defmodule CodePuppyControl.Tools.FileModifications.DeleteFileTest do
  @moduledoc "Tests for the DeleteFile tool (stat-based, no deleted_content)."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.DeleteFile

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "delete_file_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "name/0" do
    test "returns :delete_file" do
      assert DeleteFile.name() == :delete_file
    end
  end

  describe "parameters/0" do
    test "requires file_path" do
      schema = DeleteFile.parameters()
      assert "file_path" in schema["required"]
    end
  end

  describe "invoke/2" do
    test "deletes an existing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete_target.txt")
      File.write!(path, "delete me")

      args = %{"file_path" => path}

      assert {:ok, result} = DeleteFile.invoke(args, %{})
      assert result.success == true
      assert result.changed == true
      assert not File.exists?(path)
    end

    test "does NOT return deleted_content (large-file safety)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_content_test.txt")
      File.write!(path, "important content")

      args = %{"file_path" => path}

      assert {:ok, result} = DeleteFile.invoke(args, %{})
      refute Map.has_key?(result, :deleted_content)
    end

    test "generates summary diff (lines/bytes)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "diff_test.txt")
      File.write!(path, "line 1\nline 2\n")

      args = %{"file_path" => path}

      assert {:ok, result} = DeleteFile.invoke(args, %{})
      assert result.diff =~ "lines"
      assert result.diff =~ "bytes"
    end

    test "fails on non-existent file", %{tmp_dir: tmp_dir} do
      args = %{"file_path" => Path.join(tmp_dir, "nonexistent.txt")}

      assert {:error, result} = DeleteFile.invoke(args, %{})
      assert result.message =~ "not found"
    end

    test "refuses to delete directories", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dir_target")
      File.mkdir_p!(path)

      args = %{"file_path" => path}

      assert {:error, result} = DeleteFile.invoke(args, %{})
      assert result.message =~ "Cannot delete directory"
    end
  end

  describe "permission_check/2" do
    test "allows non-sensitive paths" do
      args = %{"file_path" => "/tmp/safe_to_delete.txt"}
      assert :ok = DeleteFile.permission_check(args, %{})
    end

    test "denies SSH key deletion" do
      args = %{"file_path" => Path.join(System.user_home!(), ".ssh/id_rsa")}
      assert {:deny, _reason} = DeleteFile.permission_check(args, %{})
    end
  end
end
