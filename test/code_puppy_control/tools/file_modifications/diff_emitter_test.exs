defmodule CodePuppyControl.Tools.FileModifications.DiffEmitterTest do
  @moduledoc "Tests for DiffEmitter — structured diff message emission."

  use ExUnit.Case, async: true

  alias CodePuppyControl.Tools.FileModifications.DiffEmitter

  describe "parse_diff_lines/1" do
    test "parses add lines" do
      diff = "--- a/test.txt\n+++ b/test.txt\n@@ -0,0 +1 @@\n+new line"

      lines = DiffEmitter.parse_diff_lines(diff)

      add_lines = Enum.filter(lines, &(&1.type == :add))
      assert length(add_lines) >= 1
      assert Enum.any?(add_lines, &(&1.content == "new line"))
    end

    test "parses remove lines" do
      diff = "--- a/test.txt\n+++ b/test.txt\n@@ -1 +0,0 @@\n-old line"

      lines = DiffEmitter.parse_diff_lines(diff)

      remove_lines = Enum.filter(lines, &(&1.type == :remove))
      assert length(remove_lines) >= 1
      assert Enum.any?(remove_lines, &(&1.content == "old line"))
    end

    test "parses hunk header and extracts line number" do
      diff = "--- a/test.txt\n+++ b/test.txt\n@@ -1,3 +1,3 @@\n context\n-old\n+new\n context"

      lines = DiffEmitter.parse_diff_lines(diff)

      hunk_lines =
        Enum.filter(lines, &(&1.type == :context and String.starts_with?(&1.content, "@@")))

      assert length(hunk_lines) >= 1
    end

    test "handles empty diff" do
      assert DiffEmitter.parse_diff_lines("") == []
      assert DiffEmitter.parse_diff_lines("   ") == []
    end

    test "handles context lines" do
      diff =
        "--- a/test.txt\n+++ b/test.txt\n@@ -1,3 +1,3 @@\n context line\n-old\n+new\n context line"

      lines = DiffEmitter.parse_diff_lines(diff)

      context_lines =
        Enum.filter(
          lines,
          &(&1.type == :context and not String.starts_with?(&1.content, "@@") and
              not String.starts_with?(&1.content, "---") and
              not String.starts_with?(&1.content, "+++"))
        )

      assert length(context_lines) >= 1
    end

    test "treats file headers as context" do
      diff = "--- a/test.txt\n+++ b/test.txt"

      lines = DiffEmitter.parse_diff_lines(diff)

      header_lines = Enum.filter(lines, &(&1.type == :context))
      assert length(header_lines) == 2
    end
  end

  describe "emit_diff/4" do
    test "returns :ok for empty diff" do
      assert :ok = DiffEmitter.emit_diff("/tmp/test.txt", :modify, "")
    end

    test "returns :ok for nil diff" do
      assert :ok = DiffEmitter.emit_diff("/tmp/test.txt", :modify, nil)
    end

    test "returns :ok for valid diff" do
      diff = "--- a/test.txt\n+++ b/test.txt\n@@ -1 +1 @@\n-old\n+new"

      # Should not crash even without EventBus running
      assert :ok = DiffEmitter.emit_diff("/tmp/test.txt", :modify, diff)
    end
  end
end
