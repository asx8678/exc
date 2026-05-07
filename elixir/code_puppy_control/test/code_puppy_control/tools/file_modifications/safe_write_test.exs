defmodule CodePuppyControl.Tools.FileModifications.SafeWriteTest do
  @moduledoc "Tests for SafeWrite — symlink-safe file writing."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.SafeWrite

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "safe_write_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "safe_write/2" do
    test "writes content to a new file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "new_file.txt")

      assert :ok = SafeWrite.safe_write(path, "hello world")
      assert File.read!(path) == "hello world"
    end

    test "overwrites existing file content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "overwrite_test.txt")
      File.write!(path, "original")

      assert :ok = SafeWrite.safe_write(path, "updated")
      assert File.read!(path) == "updated"
    end

    test "creates parent directories if they don't exist", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "deep", "file.txt"])

      assert :ok = SafeWrite.safe_write(path, "nested content")
      assert File.exists?(path)
    end

    test "refuses to write to a symlink", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "symlink_target.txt")
      link = Path.join(tmp_dir, "symlink_link.txt")

      File.write!(target, "target content")
      File.ln_s!(target, link)

      assert {:error, :symlink_detected} = SafeWrite.safe_write(link, "evil content")
      # Target should not be modified
      assert File.read!(target) == "target content"
    end

    test "rejects paths with null bytes" do
      assert {:error, reason} = SafeWrite.safe_write("/tmp/test\0.txt", "content")
      assert reason =~ "null byte"
    end

    test "writes UTF-8 content correctly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "utf8_test.txt")

      assert :ok = SafeWrite.safe_write(path, "日本語テスト 🐶")
      assert File.read!(path) == "日本語テスト 🐶"
    end

    test "writes content with BOM correctly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bom_test.txt")
      bom = <<0xEF, 0xBB, 0xBF>>
      content = bom <> "BOM content"

      assert :ok = SafeWrite.safe_write(path, content)
      assert File.read!(path) == content
    end
  end

  describe "symlink?/1" do
    test "returns true for symlinks", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "symlink_target.txt")
      link = Path.join(tmp_dir, "symlink_link.txt")

      File.write!(target, "target")
      File.ln_s!(target, link)

      assert SafeWrite.symlink?(link) == true
    end

    test "returns false for regular files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "regular_file.txt")
      File.write!(path, "regular")

      assert SafeWrite.symlink?(path) == false
    end

    test "returns false for non-existent files" do
      assert SafeWrite.symlink?("/tmp/nonexistent_abc123.txt") == false
    end

    test "returns false for directories", %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "dir_test")
      File.mkdir_p!(dir)

      assert SafeWrite.symlink?(dir) == false
    end
  end
end
