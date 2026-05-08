defmodule CodePuppyControl.Messaging.EntriesTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.Entries — nested entry model constructors.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.Entries

  # ===========================================================================
  # FileEntry
  # ===========================================================================

  describe "file_entry/1" do
    test "creates valid FileEntry with all required fields" do
      {:ok, entry} =
        Entries.file_entry(%{
          "path" => "lib/app.ex",
          "type" => "file",
          "size" => 1024,
          "depth" => 2
        })

      assert entry["path"] == "lib/app.ex"
      assert entry["type"] == "file"
      assert entry["size"] == 1024
      assert entry["depth"] == 2
    end

    test "accepts type 'dir'" do
      {:ok, entry} =
        Entries.file_entry(%{
          "path" => "lib/",
          "type" => "dir",
          "size" => 0,
          "depth" => 1
        })

      assert entry["type"] == "dir"
    end

    test "accepts size -1 (unknown in fast mode)" do
      {:ok, entry} =
        Entries.file_entry(%{
          "path" => "big.bin",
          "type" => "file",
          "size" => -1,
          "depth" => 0
        })

      assert entry["size"] == -1
    end

    test "accepts depth 0 (listing root)" do
      {:ok, entry} =
        Entries.file_entry(%{
          "path" => "root.txt",
          "type" => "file",
          "size" => 10,
          "depth" => 0
        })

      assert entry["depth"] == 0
    end

    test "rejects missing path" do
      assert {:error, {:missing_required_field, "path"}} =
               Entries.file_entry(%{"type" => "file", "size" => 0, "depth" => 0})
    end

    test "rejects non-string path" do
      assert {:error, {:invalid_field_type, "path", 123}} =
               Entries.file_entry(%{"path" => 123, "type" => "file", "size" => 0, "depth" => 0})
    end

    test "rejects invalid type literal" do
      assert {:error, {:invalid_literal, "type", "symlink", ~w(file dir)}} =
               Entries.file_entry(%{
                 "path" => "x",
                 "type" => "symlink",
                 "size" => 0,
                 "depth" => 0
               })
    end

    test "rejects non-string type" do
      assert {:error, {:invalid_field_type, "type", 42}} =
               Entries.file_entry(%{"path" => "x", "type" => 42, "size" => 0, "depth" => 0})
    end

    test "rejects size below -1" do
      assert {:error, {:value_below_min, "size", -2, -1}} =
               Entries.file_entry(%{
                 "path" => "x",
                 "type" => "file",
                 "size" => -2,
                 "depth" => 0
               })
    end

    test "rejects non-integer size" do
      assert {:error, {:invalid_field_type, "size", 1.5}} =
               Entries.file_entry(%{
                 "path" => "x",
                 "type" => "file",
                 "size" => 1.5,
                 "depth" => 0
               })
    end

    test "rejects depth below 0" do
      assert {:error, {:value_below_min, "depth", -1, 0}} =
               Entries.file_entry(%{
                 "path" => "x",
                 "type" => "file",
                 "size" => 0,
                 "depth" => -1
               })
    end

    test "rejects extra fields (extra='forbid')" do
      assert {:error, {:extra_fields_not_allowed, ["extra"]}} =
               Entries.file_entry(%{
                 "path" => "x",
                 "type" => "file",
                 "size" => 0,
                 "depth" => 0,
                 "extra" => "oops"
               })
    end

    test "rejects non-map input" do
      assert {:error, {:not_a_map, "string"}} = Entries.file_entry("string")
    end
  end

  # ===========================================================================
  # GrepMatch
  # ===========================================================================

  describe "grep_match/1" do
    test "creates valid GrepMatch" do
      {:ok, match} =
        Entries.grep_match(%{
          "file_path" => "lib/app.ex",
          "line_number" => 42,
          "line_content" => "defmodule App do"
        })

      assert match["file_path"] == "lib/app.ex"
      assert match["line_number"] == 42
      assert match["line_content"] == "defmodule App do"
    end

    test "accepts line_number 1 (minimum valid)" do
      {:ok, match} =
        Entries.grep_match(%{
          "file_path" => "f",
          "line_number" => 1,
          "line_content" => "first line"
        })

      assert match["line_number"] == 1
    end

    test "rejects line_number 0 (below min of 1)" do
      assert {:error, {:value_below_min, "line_number", 0, 1}} =
               Entries.grep_match(%{
                 "file_path" => "f",
                 "line_number" => 0,
                 "line_content" => "x"
               })
    end

    test "rejects negative line_number" do
      assert {:error, {:value_below_min, "line_number", -1, 1}} =
               Entries.grep_match(%{
                 "file_path" => "f",
                 "line_number" => -1,
                 "line_content" => "x"
               })
    end

    test "rejects non-integer line_number" do
      assert {:error, {:invalid_field_type, "line_number", "42"}} =
               Entries.grep_match(%{
                 "file_path" => "f",
                 "line_number" => "42",
                 "line_content" => "x"
               })
    end

    test "rejects missing file_path" do
      assert {:error, {:missing_required_field, "file_path"}} =
               Entries.grep_match(%{"line_number" => 1, "line_content" => "x"})
    end

    test "rejects missing line_content" do
      assert {:error, {:missing_required_field, "line_content"}} =
               Entries.grep_match(%{"file_path" => "f", "line_number" => 1})
    end

    test "rejects extra fields" do
      assert {:error, {:extra_fields_not_allowed, ["highlight"]}} =
               Entries.grep_match(%{
                 "file_path" => "f",
                 "line_number" => 1,
                 "line_content" => "x",
                 "highlight" => true
               })
    end
  end

  # ===========================================================================
  # DiffLine
  # ===========================================================================

  describe "diff_line/1" do
    test "creates valid DiffLine with add type" do
      {:ok, line} =
        Entries.diff_line(%{
          "line_number" => 5,
          "type" => "add",
          "content" => "+new line"
        })

      assert line["type"] == "add"
    end

    test "creates valid DiffLine with remove type" do
      {:ok, line} =
        Entries.diff_line(%{
          "line_number" => 5,
          "type" => "remove",
          "content" => "-old line"
        })

      assert line["type"] == "remove"
    end

    test "creates valid DiffLine with context type" do
      {:ok, line} =
        Entries.diff_line(%{
          "line_number" => 5,
          "type" => "context",
          "content" => " unchanged"
        })

      assert line["type"] == "context"
    end

    test "accepts line_number 0" do
      {:ok, line} =
        Entries.diff_line(%{
          "line_number" => 0,
          "type" => "context",
          "content" => "header"
        })

      assert line["line_number"] == 0
    end

    test "rejects invalid type literal" do
      assert {:error, {:invalid_literal, "type", "change", ~w(add remove context)}} =
               Entries.diff_line(%{
                 "line_number" => 1,
                 "type" => "change",
                 "content" => "x"
               })
    end

    test "rejects negative line_number" do
      assert {:error, {:value_below_min, "line_number", -1, 0}} =
               Entries.diff_line(%{
                 "line_number" => -1,
                 "type" => "add",
                 "content" => "x"
               })
    end

    test "rejects missing content" do
      assert {:error, {:missing_required_field, "content"}} =
               Entries.diff_line(%{"line_number" => 1, "type" => "add"})
    end

    test "rejects extra fields" do
      assert {:error, {:extra_fields_not_allowed, ["color"]}} =
               Entries.diff_line(%{
                 "line_number" => 1,
                 "type" => "add",
                 "content" => "x",
                 "color" => "green"
               })
    end
  end

  # ===========================================================================
  # SkillEntry
  # ===========================================================================

  describe "skill_entry/1" do
    test "creates valid SkillEntry with required fields" do
      {:ok, entry} =
        Entries.skill_entry(%{
          "name" => "my_skill",
          "description" => "Does things",
          "path" => "/skills/my_skill"
        })

      assert entry["name"] == "my_skill"
      assert entry["description"] == "Does things"
      assert entry["path"] == "/skills/my_skill"
      assert entry["tags"] == []
      assert entry["enabled"] == true
    end

    test "accepts tags and enabled override" do
      {:ok, entry} =
        Entries.skill_entry(%{
          "name" => "s",
          "description" => "d",
          "path" => "/p",
          "tags" => ["a", "b"],
          "enabled" => false
        })

      assert entry["tags"] == ["a", "b"]
      assert entry["enabled"] == false
    end

    test "defaults tags to empty list" do
      {:ok, entry} =
        Entries.skill_entry(%{
          "name" => "s",
          "description" => "d",
          "path" => "/p"
        })

      assert entry["tags"] == []
    end

    test "defaults enabled to true" do
      {:ok, entry} =
        Entries.skill_entry(%{
          "name" => "s",
          "description" => "d",
          "path" => "/p"
        })

      assert entry["enabled"] == true
    end

    test "rejects non-string tags elements" do
      assert {:error, {:invalid_field_type, "tags", :not_all_strings}} =
               Entries.skill_entry(%{
                 "name" => "s",
                 "description" => "d",
                 "path" => "/p",
                 "tags" => ["ok", 42]
               })
    end

    test "rejects non-list tags" do
      assert {:error, {:invalid_field_type, "tags", "not-a-list"}} =
               Entries.skill_entry(%{
                 "name" => "s",
                 "description" => "d",
                 "path" => "/p",
                 "tags" => "not-a-list"
               })
    end

    test "rejects non-boolean enabled" do
      assert {:error, {:invalid_field_type, "enabled", "yes"}} =
               Entries.skill_entry(%{
                 "name" => "s",
                 "description" => "d",
                 "path" => "/p",
                 "enabled" => "yes"
               })
    end

    test "rejects missing name" do
      assert {:error, {:missing_required_field, "name"}} =
               Entries.skill_entry(%{"description" => "d", "path" => "/p"})
    end

    test "rejects extra fields" do
      assert {:error, {:extra_fields_not_allowed, ["version"]}} =
               Entries.skill_entry(%{
                 "name" => "s",
                 "description" => "d",
                 "path" => "/p",
                 "version" => "1.0"
               })
    end
  end
end
