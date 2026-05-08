defmodule CodePuppyControl.Tools.FileModifications.DeleteFileEnhancedTest do
  @moduledoc "Enhanced tests for DeleteFile — symlink protection, summary diff, no deleted_content."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.DeleteFile

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "delete_file_enhanced_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "invoke/2 with symlink protection" do
    test "refuses to delete a symlink", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "symlink_target.txt")
      link = Path.join(tmp_dir, "symlink_link.txt")

      File.write!(target, "target content")
      File.ln_s!(target, link)

      args = %{"file_path" => link}

      assert {:error, result} = DeleteFile.invoke(args, %{})
      assert result.message =~ "symlink"
      assert File.exists?(target)
      assert File.read!(target) == "target content"
    end
  end

  describe "invoke/2 with summary diff" do
    test "generates summary diff with lines and bytes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "summary_test.txt")

      content = Enum.map_join(1..50, "\n", &"line #{&1}")
      File.write!(path, content)

      args = %{"file_path" => path}

      assert {:ok, result} = DeleteFile.invoke(args, %{})
      assert result.success == true
      assert result.diff =~ "lines"
      assert result.diff =~ "bytes"
    end

    test "does NOT include deleted_content field", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_deleted_content_test.txt")
      File.write!(path, "some content")

      args = %{"file_path" => path}

      assert {:ok, result} = DeleteFile.invoke(args, %{})
      refute Map.has_key?(result, :deleted_content)
    end
  end

  describe "invoke/2 edge cases" do
    test "fails on non-existent file", %{tmp_dir: tmp_dir} do
      args = %{"file_path" => Path.join(tmp_dir, "nonexistent.txt")}

      assert {:error, result} = DeleteFile.invoke(args, %{})
      assert result.message =~ "not found"
    end

    test "refuses to delete directories", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "dir_test")
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
