defmodule CodePuppyControl.Compaction.FileOpsTrackerTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Compaction.FileOpsTracker

  describe "new/0" do
    test "creates empty tracker" do
      tracker = FileOpsTracker.new()
      assert FileOpsTracker.read_files(tracker) == []
      assert FileOpsTracker.modified_files(tracker) == []
      assert FileOpsTracker.has_ops?(tracker) == false
    end
  end

  describe "track_tool_call/3" do
    test "tracks read_file operations" do
      tracker = FileOpsTracker.new()

      tracker =
        FileOpsTracker.track_tool_call(tracker, "read_file", %{"file_path" => "lib/foo.ex"})

      assert FileOpsTracker.read_files(tracker) == ["lib/foo.ex"]
      assert FileOpsTracker.modified_files(tracker) == []
    end

    test "tracks create_file operations" do
      tracker = FileOpsTracker.new()

      tracker =
        FileOpsTracker.track_tool_call(tracker, "create_file", %{"file_path" => "lib/new.ex"})

      assert FileOpsTracker.modified_files(tracker) == ["lib/new.ex"]
      assert FileOpsTracker.read_files(tracker) == []
    end

    test "tracks replace_in_file operations" do
      tracker = FileOpsTracker.new()

      tracker =
        FileOpsTracker.track_tool_call(tracker, "replace_in_file", %{
          "file_path" => "lib/edit.ex"
        })

      assert FileOpsTracker.modified_files(tracker) == ["lib/edit.ex"]
    end

    test "handles 'path' key alternative" do
      tracker = FileOpsTracker.new()
      tracker = FileOpsTracker.track_tool_call(tracker, "read", %{"path" => "src/main.rs"})

      assert FileOpsTracker.read_files(tracker) == ["src/main.rs"]
    end

    test "ignores unknown tools" do
      tracker = FileOpsTracker.new()
      tracker = FileOpsTracker.track_tool_call(tracker, "unknown_tool", %{"file_path" => "x"})

      assert FileOpsTracker.has_ops?(tracker) == false
    end

    test "ignores non-string args" do
      tracker = FileOpsTracker.new()
      tracker = FileOpsTracker.track_tool_call(tracker, "read_file", %{"file_path" => 123})

      assert FileOpsTracker.has_ops?(tracker) == false
    end

    test "ignores empty path" do
      tracker = FileOpsTracker.new()
      tracker = FileOpsTracker.track_tool_call(tracker, "read_file", %{"file_path" => ""})

      assert FileOpsTracker.has_ops?(tracker) == false
    end

    test "deduplicates reads" do
      tracker = FileOpsTracker.new()

      tracker =
        FileOpsTracker.track_tool_call(tracker, "read_file", %{"file_path" => "lib/a.ex"})
        |> FileOpsTracker.track_tool_call("read_file", %{"file_path" => "lib/a.ex"})

      assert FileOpsTracker.read_files(tracker) == ["lib/a.ex"]
    end
  end

  describe "track_message/2" do
    test "extracts tool calls from message parts" do
      message = %{
        "parts" => [
          %{"part_kind" => "text", "content" => "hello"},
          %{
            "part_kind" => "tool-call",
            "tool_name" => "read_file",
            "args" => %{"file_path" => "lib/a.ex"}
          },
          %{
            "part_kind" => "tool-call",
            "tool_name" => "create_file",
            "args" => %{"file_path" => "lib/b.ex"}
          }
        ]
      }

      tracker = FileOpsTracker.track_message(FileOpsTracker.new(), message)

      assert FileOpsTracker.read_files(tracker) == ["lib/a.ex"]
      assert FileOpsTracker.modified_files(tracker) == ["lib/b.ex"]
    end

    test "ignores non-tool-call parts" do
      message = %{
        "parts" => [
          %{"part_kind" => "text", "content" => "hello"},
          %{"part_kind" => "tool-return", "tool_call_id" => "x", "content" => "result"}
        ]
      }

      tracker = FileOpsTracker.track_message(FileOpsTracker.new(), message)
      assert FileOpsTracker.has_ops?(tracker) == false
    end

    test "handles message with atom keys" do
      message = %{
        parts: [
          %{
            part_kind: "tool-call",
            tool_name: "read_file",
            args: %{"file_path" => "lib/a.ex"}
          }
        ]
      }

      tracker = FileOpsTracker.track_message(FileOpsTracker.new(), message)
      assert FileOpsTracker.read_files(tracker) == ["lib/a.ex"]
    end
  end

  describe "extract_from_messages/1" do
    test "processes list of messages" do
      messages = [
        %{
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_name" => "read_file",
              "args" => %{"file_path" => "a.ex"}
            }
          ]
        },
        %{
          "parts" => [
            %{
              "part_kind" => "tool-call",
              "tool_name" => "write_file",
              "args" => %{"file_path" => "b.ex"}
            }
          ]
        }
      ]

      tracker = FileOpsTracker.extract_from_messages(messages)

      assert FileOpsTracker.read_files(tracker) == ["a.ex"]
      assert FileOpsTracker.modified_files(tracker) == ["b.ex"]
    end
  end

  describe "merge/2" do
    test "combines two trackers" do
      t1 =
        FileOpsTracker.new()
        |> FileOpsTracker.track_tool_call("read_file", %{"file_path" => "a.ex"})

      t2 =
        FileOpsTracker.new()
        |> FileOpsTracker.track_tool_call("create_file", %{"file_path" => "b.ex"})

      merged = FileOpsTracker.merge(t1, t2)

      assert FileOpsTracker.read_files(merged) == ["a.ex"]
      assert FileOpsTracker.modified_files(merged) == ["b.ex"]
    end
  end

  describe "priority_scores/2" do
    test "returns scores for tracked files" do
      tracker =
        FileOpsTracker.new()
        |> FileOpsTracker.track_tool_call("read_file", %{"file_path" => "a.ex"})
        |> FileOpsTracker.track_tool_call("create_file", %{"file_path" => "b.ex"})

      scores = FileOpsTracker.priority_scores(tracker)

      assert Map.has_key?(scores, "a.ex")
      assert Map.has_key?(scores, "b.ex")
      # Modified files should have higher score
      assert scores["b.ex"] > scores["a.ex"]
    end

    test "returns empty map for empty tracker" do
      scores = FileOpsTracker.priority_scores(FileOpsTracker.new())
      assert scores == %{}
    end
  end

  describe "format_xml/1" do
    test "formats read and modified files as XML" do
      tracker =
        FileOpsTracker.new()
        |> FileOpsTracker.track_tool_call("read_file", %{"file_path" => "lib/a.ex"})
        |> FileOpsTracker.track_tool_call("create_file", %{"file_path" => "lib/b.ex"})

      xml = FileOpsTracker.format_xml(tracker)

      assert xml =~ "<read-files>"
      assert xml =~ "- lib/a.ex"
      assert xml =~ "</read-files>"
      assert xml =~ "<modified-files>"
      assert xml =~ "- lib/b.ex"
      assert xml =~ "</modified-files>"
    end

    test "returns empty string for empty tracker" do
      assert FileOpsTracker.format_xml(FileOpsTracker.new()) == ""
    end
  end
end
