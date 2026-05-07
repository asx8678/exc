defmodule CodePuppyControl.Tools.FileModifications.EditFileTest do
  @moduledoc "Tests for the EditFile tool (comprehensive editor dispatcher)."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.EditFile

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "edit_file_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "name/0" do
    test "returns :edit_file" do
      assert EditFile.name() == :edit_file
    end
  end

  describe "parameters/0" do
    test "supports content, replacements, and delete_snippet" do
      schema = EditFile.parameters()
      props = schema["properties"]
      assert Map.has_key?(props, "file_path")
      assert Map.has_key?(props, "content")
      assert Map.has_key?(props, "replacements")
      assert Map.has_key?(props, "delete_snippet")
    end
  end

  describe "invoke/2 with content payload" do
    test "creates file with content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "content_test.txt")

      args = %{
        "file_path" => path,
        "content" => "hello from edit_file"
      }

      assert {:ok, result} = EditFile.invoke(args, %{})
      assert result.success == true
      assert File.read!(path) == "hello from edit_file"
    end
  end

  describe "invoke/2 with replacements payload" do
    test "applies replacements", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "replace_test.txt")
      File.write!(path, "foo bar baz")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "bar", "new_str" => "qux"}]
      }

      assert {:ok, result} = EditFile.invoke(args, %{})
      assert result.success == true
      assert File.read!(path) == "foo qux baz"
    end
  end

  describe "invoke/2 with delete_snippet payload" do
    test "deletes snippet from file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete_test.txt")
      File.write!(path, "line 1\nremove this\nline 3")

      args = %{
        "file_path" => path,
        "delete_snippet" => "remove this\n"
      }

      assert {:ok, result} = EditFile.invoke(args, %{})
      assert result.success == true
      assert File.read!(path) == "line 1\nline 3"
    end
  end

  describe "invoke/2 with no payload" do
    test "returns error when no modification payload given" do
      args = %{"file_path" => "/tmp/test.txt"}

      assert {:error, result} = EditFile.invoke(args, %{})
      assert result.message =~ "Must provide one of"
    end
  end
end
