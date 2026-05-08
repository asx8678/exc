defmodule CodePuppyControl.Tools.FileModifications.CreateFileEnhancedTest do
  @moduledoc "Enhanced tests for CreateFile — BOM, whitespace, symlink, validation."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.CreateFile

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "create_file_enhanced_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "invoke/2 with BOM handling" do
    test "preserves BOM when overwriting existing file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bom_test.txt")
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(path, bom <> "original content")

      args = %{
        "file_path" => path,
        "content" => "new content",
        "overwrite" => true
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      # BOM should be preserved
      assert File.read!(path) == bom <> "new content"
    end

    test "handles file without BOM correctly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_bom_test.txt")
      File.write!(path, "no bom here")

      args = %{
        "file_path" => path,
        "content" => "updated content",
        "overwrite" => true
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      # No BOM should be added
      assert File.read!(path) == "updated content"
    end
  end

  describe "invoke/2 with whitespace stripping" do
    test "strips surplus leading blank lines from LLM output", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ws_test.txt")
      File.write!(path, "line 1\nline 2\n")

      args = %{
        "file_path" => path,
        "content" => "\n\n\nline 1\nline 2\n",
        "overwrite" => true
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      # Surplus leading blank lines should be stripped
      content = File.read!(path)
      refute String.starts_with?(content, "\n\n\n")
    end

    test "preserves original leading blank lines", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ws_preserve_test.txt")
      File.write!(path, "\nline 1\nline 2\n")

      args = %{
        "file_path" => path,
        "content" => "\nmodified line 1\nline 2\n",
        "overwrite" => true
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      # Original had 1 leading blank line, so 1 is preserved
      content = File.read!(path)
      assert String.starts_with?(content, "\n")
    end
  end

  describe "invoke/2 with symlink protection" do
    test "refuses to overwrite a symlink", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "symlink_target.txt")
      link = Path.join(tmp_dir, "symlink_link.txt")

      File.write!(target, "target content")
      File.ln_s!(target, link)

      args = %{
        "file_path" => link,
        "content" => "evil content",
        "overwrite" => true
      }

      assert {:error, result} = CreateFile.invoke(args, %{})
      assert result.message =~ "symlink"
      # Target should be unmodified
      assert File.read!(target) == "target content"
    end

    test "refuses to create a new file at a symlink path", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "symlink_new_target.txt")
      link = Path.join(tmp_dir, "symlink_new_link.txt")

      File.write!(target, "target content")
      File.ln_s!(target, link)

      args = %{
        "file_path" => link,
        "content" => "new content"
      }

      # The file exists (as a symlink), and overwrite is false
      assert {:error, result} = CreateFile.invoke(args, %{})
      # Either "already exists" or "symlink" — both are correct rejections
      assert result.success == false
    end
  end

  describe "invoke/2 with post-edit validation" do
    test "attaches syntax warning for invalid Elixir code", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "validation_test.ex")

      args = %{
        "file_path" => path,
        "content" => "defmodule Foo do\n  def bar(\nend"
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      # Should have syntax_warning for invalid Elixir
      assert Map.has_key?(result, :syntax_warning)
    end

    test "no syntax warning for valid Elixir code", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "valid_ex_test.ex")

      args = %{
        "file_path" => path,
        "content" => "defmodule Foo do\n  def bar, do: :baz\nend"
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      refute Map.has_key?(result, :syntax_warning)
    end

    test "no syntax warning for non-code extensions", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "plain_text.txt")

      args = %{
        "file_path" => path,
        "content" => "just text"
      }

      assert {:ok, result} = CreateFile.invoke(args, %{})
      assert result.success == true
      refute Map.has_key?(result, :syntax_warning)
    end
  end
end
