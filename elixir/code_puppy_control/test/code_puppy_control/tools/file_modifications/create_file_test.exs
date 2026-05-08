defmodule CodePuppyControl.Tools.FileModifications.CreateFileTest do
  @moduledoc "Tests for the CreateFile tool."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.CreateFile

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "create_file_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "name/0" do
    test "returns :create_file" do
      assert CreateFile.name() == :create_file
    end
  end

  describe "description/0" do
    test "returns a non-empty string" do
      assert is_binary(CreateFile.description())
      assert String.length(CreateFile.description()) > 0
    end
  end

  describe "parameters/0" do
    test "returns valid JSON schema" do
      schema = CreateFile.parameters()
      assert schema["type"] == "object"
      assert "file_path" in schema["required"]
      assert "content" in schema["required"]
      assert Map.has_key?(schema["properties"], "file_path")
      assert Map.has_key?(schema["properties"], "content")
    end
  end

  describe "invoke/2" do
    test "creates a new file successfully", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "new_file.txt")

      args = %{
        "file_path" => path,
        "content" => "Hello, world!"
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      assert result.changed == true
      assert result.path == path
      assert File.exists?(path)
      assert File.read!(path) == "Hello, world!"
    end

    test "creates parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "file.txt"])

      args = %{
        "file_path" => path,
        "content" => "nested content"
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      assert File.exists?(path)
    end

    test "fails when file exists and overwrite is false", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "exists_test.txt")
      File.write!(path, "original")

      args = %{
        "file_path" => path,
        "content" => "new content"
      }

      assert {:error, result} = CreateFile.invoke(args, %{})
      assert result.success == false
      assert result.message =~ "already exists"
      assert File.read!(path) == "original"
    end

    test "overwrites when overwrite is true", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "overwrite_test.txt")
      File.write!(path, "original")

      args = %{
        "file_path" => path,
        "content" => "new content",
        "overwrite" => true
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      assert result.changed == true
      assert File.read!(path) == "new content"
    end

    test "returns no diff when overwriting with same content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "same_content_test.txt")
      File.write!(path, "same content")

      args = %{
        "file_path" => path,
        "content" => "same content",
        "overwrite" => true
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      assert result.changed == false
    end

    test "returns diff showing changes", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "diff_test.txt")
      File.write!(path, "line 1\nline 2\n")

      args = %{
        "file_path" => path,
        "content" => "line 1\nmodified\n",
        "overwrite" => true
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.diff =~ "-line 2"
      assert result.diff =~ "+modified"
    end
  end

  describe "permission_check/2" do
    test "allows non-sensitive paths" do
      args = %{"file_path" => "/tmp/test_file.txt"}
      assert :ok = CreateFile.permission_check(args, %{})
    end

    test "denies sensitive paths" do
      args = %{"file_path" => Path.join(System.user_home!(), ".ssh/id_rsa")}
      assert {:deny, _reason} = CreateFile.permission_check(args, %{})
    end
  end
end
