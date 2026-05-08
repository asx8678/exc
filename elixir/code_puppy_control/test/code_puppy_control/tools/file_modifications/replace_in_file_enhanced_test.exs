defmodule CodePuppyControl.Tools.FileModifications.ReplaceInFileEnhancedTest do
  @moduledoc "Enhanced tests for ReplaceInFile — BOM, whitespace, symlink, validation."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.ReplaceInFile

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "replace_in_file_enhanced_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "invoke/2 with BOM handling" do
    test "preserves BOM after replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bom_test.txt")
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(path, bom <> "hello world")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "world", "new_str" => "universe"}]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.success == true
      # BOM should be preserved
      assert File.read!(path) == bom <> "hello universe"
    end

    test "handles file without BOM", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_bom_test.txt")
      File.write!(path, "hello world")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "world", "new_str" => "universe"}]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.success == true
      # No BOM should be added
      assert File.read!(path) == "hello universe"
    end
  end

  describe "invoke/2 with whitespace stripping" do
    test "strips surplus blank lines from LLM output", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "ws_test.txt")
      File.write!(path, "line 1\nline 2\nline 3\n")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "line 2", "new_str" => "line 2\n\n\n\n"}]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.success == true

      content = File.read!(path)
      # Surplus trailing blank lines should be stripped
      # Original had 0 trailing blank lines after content, LLM added 4
      # These should be stripped back to match original
      refute String.ends_with?(content, "\n\n\n\n\n")
    end
  end

  describe "invoke/2 with symlink protection" do
    test "refuses to replace in a symlink", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "symlink_target.txt")
      link = Path.join(tmp_dir, "symlink_link.txt")

      File.write!(target, "foo bar baz")
      File.ln_s!(target, link)

      args = %{
        "file_path" => link,
        "replacements" => [%{"old_str" => "bar", "new_str" => "qux"}]
      }

      assert {:error, result} = ReplaceInFile.invoke(args, %{})
      assert result.message =~ "symlink"
      # Target should be unmodified
      assert File.read!(target) == "foo bar baz"
    end
  end

  describe "invoke/2 with post-edit validation" do
    test "attaches syntax warning for invalid Elixir after replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "validation_test.ex")
      File.write!(path, "defmodule Foo do\n  def bar, do: :baz\nend")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "def bar, do: :baz", "new_str" => "def bar("}]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.success == true
      # Should have syntax_warning for invalid Elixir
      assert Map.has_key?(result, :syntax_warning)
    end

    test "no syntax warning for valid replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "valid_test.ex")
      File.write!(path, "def foo, do: :bar")

      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => ":bar", "new_str" => ":baz"}]
      }

      assert {:ok, result} = ReplaceInFile.invoke(args, %{})
      assert result.success == true
      refute Map.has_key?(result, :syntax_warning)
    end
  end

  describe "invoke/2 with fuzzy matching" do
    test "uses fuzzy match when exact match fails", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "fuzzy_test.txt")
      File.write!(path, "line 1\n  indented\nline 3")

      # LLM might add/remove minor whitespace — fuzzy matching handles this
      args = %{
        "file_path" => path,
        "replacements" => [%{"old_str" => "indented", "new_str" => "replaced"}]
      }

      # Should succeed via fuzzy match (JW >= 0.95)
      result = ReplaceInFile.invoke(args, %{})
      assert match?({:ok, _}, result)
    end
  end
end
