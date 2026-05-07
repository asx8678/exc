defmodule CodePuppyControl.Tools.FileModifications.DeleteSnippetTest do
  @moduledoc "Tests for the DeleteSnippet tool."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.DeleteSnippet

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "delete_snippet_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "name/0" do
    test "returns :delete_snippet" do
      assert DeleteSnippet.name() == :delete_snippet
    end
  end

  describe "parameters/0" do
    test "requires file_path and snippet" do
      schema = DeleteSnippet.parameters()
      assert "file_path" in schema["required"]
      assert "snippet" in schema["required"]
    end
  end

  describe "invoke/2" do
    test "removes first occurrence of snippet", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "snippet_test.txt")
      File.write!(path, "line 1\nREMOVE ME\nline 3")

      args = %{
        "file_path" => path,
        "snippet" => "REMOVE ME"
      }

      assert {:ok, result} = DeleteSnippet.invoke(args, %{})
      assert result.success == true
      assert result.changed == true
      assert File.read!(path) == "line 1\n\nline 3"
    end

    test "removes only the first occurrence", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "first_test.txt")
      File.write!(path, "aaa xxx bbb xxx ccc")

      args = %{
        "file_path" => path,
        "snippet" => " xxx "
      }

      assert {:ok, result} = DeleteSnippet.invoke(args, %{})
      assert result.success == true
      # Only first " xxx " removed
      assert File.read!(path) == "aaabbb xxx ccc"
    end

    test "fails when snippet not found", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "notfound_test.txt")
      File.write!(path, "nothing to remove here")

      args = %{
        "file_path" => path,
        "snippet" => "NOT FOUND"
      }

      assert {:error, result} = DeleteSnippet.invoke(args, %{})
      assert result.message =~ "not found"
    end

    test "fails with empty snippet", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty_test.txt")
      File.write!(path, "content")

      args = %{
        "file_path" => path,
        "snippet" => ""
      }

      assert {:error, reason} = DeleteSnippet.invoke(args, %{})
      assert reason =~ "empty"
    end

    test "fails on non-existent file", %{tmp_dir: tmp_dir} do
      args = %{
        "file_path" => Path.join(tmp_dir, "nonexistent.txt"),
        "snippet" => "anything"
      }

      assert {:error, result} = DeleteSnippet.invoke(args, %{})
      assert result.message =~ "not found"
    end

    test "generates diff", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "diff_test.txt")
      File.write!(path, "keep this\nremove that\nkeep this too")

      args = %{
        "file_path" => path,
        "snippet" => "remove that\n"
      }

      assert {:ok, result} = DeleteSnippet.invoke(args, %{})
      assert result.diff =~ "-remove that"
    end
  end

  describe "permission_check/2" do
    test "allows non-sensitive paths" do
      args = %{"file_path" => "/tmp/safe_file.txt"}
      assert :ok = DeleteSnippet.permission_check(args, %{})
    end

    test "denies sensitive paths" do
      args = %{"file_path" => Path.join(System.user_home!(), ".ssh/config")}
      assert {:deny, _reason} = DeleteSnippet.permission_check(args, %{})
    end
  end
end
