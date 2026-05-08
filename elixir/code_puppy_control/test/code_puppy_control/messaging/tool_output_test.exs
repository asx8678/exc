defmodule CodePuppyControl.Messaging.ToolOutputTest do
  @moduledoc """
  Tests for CodePuppyControl.Messaging.ToolOutput — tool output message constructors.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Messaging.{ToolOutput, WireEvent}

  # ===========================================================================
  # FileListingMessage
  # ===========================================================================

  describe "file_listing_message/1" do
    test "happy path with all fields" do
      {:ok, msg} =
        ToolOutput.file_listing_message(%{
          "directory" => "/src",
          "recursive" => true,
          "files" => [
            %{"path" => "a.ex", "type" => "file", "size" => 10, "depth" => 0}
          ],
          "total_size" => 10,
          "dir_count" => 0,
          "file_count" => 1
        })

      assert msg["category"] == "tool_output"
      assert msg["directory"] == "/src"
      assert msg["recursive"] == true
      assert length(msg["files"]) == 1
      assert msg["total_size"] == 10
      assert msg["dir_count"] == 0
      assert msg["file_count"] == 1
      assert is_binary(msg["id"])
      assert is_integer(msg["timestamp_unix_ms"])
    end

    test "validates nested FileEntry list element-by-element" do
      assert {:error, {:invalid_list_element, "files", _}} =
               ToolOutput.file_listing_message(%{
                 "directory" => "/src",
                 "recursive" => false,
                 "files" => [%{"path" => "x", "type" => "bad", "size" => 0, "depth" => 0}]
               })
    end

    test "rejects non-map elements in files list" do
      assert {:error, {:invalid_list_element, "files", {:not_a_map, _}}} =
               ToolOutput.file_listing_message(%{
                 "directory" => "/src",
                 "recursive" => false,
                 "files" => ["not a map"]
               })
    end

    test "defaults files to empty list" do
      {:ok, msg} =
        ToolOutput.file_listing_message(%{
          "directory" => "/src",
          "recursive" => false,
          "total_size" => 0,
          "dir_count" => 0,
          "file_count" => 0
        })

      assert msg["files"] == []
    end

    test "rejects category mismatch" do
      assert {:error, {:category_mismatch, expected: "tool_output", got: "agent"}} =
               ToolOutput.file_listing_message(%{
                 "directory" => "/src",
                 "recursive" => false,
                 "category" => "agent"
               })
    end

    test "rejects negative total_size" do
      assert {:error, {:value_below_min, "total_size", -1, 0}} =
               ToolOutput.file_listing_message(%{
                 "directory" => "/src",
                 "recursive" => false,
                 "total_size" => -1
               })
    end

    test "rejects missing directory" do
      assert {:error, {:missing_required_field, "directory"}} =
               ToolOutput.file_listing_message(%{"recursive" => false})
    end

    test "round-trips through WireEvent" do
      {:ok, msg} =
        ToolOutput.file_listing_message(%{
          "directory" => "/src",
          "recursive" => true,
          "total_size" => 100,
          "dir_count" => 2,
          "file_count" => 3
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["directory"] == "/src"
      assert restored["recursive"] == true
      assert restored["total_size"] == 100
      assert restored["category"] == "tool_output"
    end
  end

  # ===========================================================================
  # FileContentMessage
  # ===========================================================================

  describe "file_content_message/1" do
    test "happy path with all fields" do
      {:ok, msg} =
        ToolOutput.file_content_message(%{
          "path" => "lib/app.ex",
          "content" => "defmodule App do end",
          "start_line" => 1,
          "num_lines" => 1,
          "total_lines" => 1,
          "num_tokens" => 5
        })

      assert msg["category"] == "tool_output"
      assert msg["path"] == "lib/app.ex"
      assert msg["start_line"] == 1
      assert msg["num_lines"] == 1
    end

    test "nil optional fields default properly" do
      {:ok, msg} =
        ToolOutput.file_content_message(%{
          "path" => "f.ex",
          "content" => "hi",
          "total_lines" => 1,
          "num_tokens" => 1
        })

      assert msg["start_line"] == nil
      assert msg["num_lines"] == nil
    end

    test "rejects start_line 0 (min is 1)" do
      assert {:error, {:value_below_min, "start_line", 0, 1}} =
               ToolOutput.file_content_message(%{
                 "path" => "f.ex",
                 "content" => "hi",
                 "start_line" => 0,
                 "total_lines" => 1,
                 "num_tokens" => 1
               })
    end

    test "rejects wrong type for optional start_line" do
      assert {:error, {:invalid_field_type, "start_line", "1"}} =
               ToolOutput.file_content_message(%{
                 "path" => "f.ex",
                 "content" => "hi",
                 "start_line" => "1",
                 "total_lines" => 1,
                 "num_tokens" => 1
               })
    end

    test "rejects missing path" do
      assert {:error, {:missing_required_field, "path"}} =
               ToolOutput.file_content_message(%{
                 "content" => "hi",
                 "total_lines" => 1,
                 "num_tokens" => 1
               })
    end

    test "JSON round-trip" do
      {:ok, msg} =
        ToolOutput.file_content_message(%{
          "path" => "f.ex",
          "content" => "hello world",
          "total_lines" => 1,
          "num_tokens" => 2
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["path"] == "f.ex"
      assert decoded["content"] == "hello world"
    end
  end

  # ===========================================================================
  # GrepResultMessage
  # ===========================================================================

  describe "grep_result_message/1" do
    test "happy path" do
      {:ok, msg} =
        ToolOutput.grep_result_message(%{
          "search_term" => "defmodule",
          "directory" => "/src",
          "matches" => [
            %{
              "file_path" => "a.ex",
              "line_number" => 1,
              "line_content" => "defmodule A do"
            }
          ],
          "total_matches" => 1,
          "files_searched" => 5
        })

      assert msg["category"] == "tool_output"
      assert msg["search_term"] == "defmodule"
      assert length(msg["matches"]) == 1
      assert msg["verbose"] == false
    end

    test "validates nested GrepMatch entries" do
      assert {:error, {:invalid_list_element, "matches", _}} =
               ToolOutput.grep_result_message(%{
                 "search_term" => "x",
                 "directory" => "/src",
                 "matches" => [%{"file_path" => "f", "line_number" => 0, "line_content" => "x"}],
                 "total_matches" => 1,
                 "files_searched" => 1
               })
    end

    test "defaults verbose to false" do
      {:ok, msg} =
        ToolOutput.grep_result_message(%{
          "search_term" => "x",
          "directory" => "/d",
          "total_matches" => 0,
          "files_searched" => 0
        })

      assert msg["verbose"] == false
    end

    test "round-trips through WireEvent" do
      {:ok, msg} =
        ToolOutput.grep_result_message(%{
          "search_term" => "todo",
          "directory" => "/app",
          "total_matches" => 3,
          "files_searched" => 10,
          "verbose" => true
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["search_term"] == "todo"
      assert restored["verbose"] == true
    end
  end

  # ===========================================================================
  # DiffMessage
  # ===========================================================================

  describe "diff_message/1" do
    test "happy path with create operation" do
      {:ok, msg} =
        ToolOutput.diff_message(%{
          "path" => "new_file.ex",
          "operation" => "create",
          "new_content" => "hello"
        })

      assert msg["operation"] == "create"
      assert msg["old_content"] == nil
      assert msg["diff_lines"] == []
      assert msg["raw_diff_text"] == ""
    end

    test "validates operation literals: create, modify, delete" do
      for op <- ~w(create modify delete) do
        assert {:ok, msg} =
                 ToolOutput.diff_message(%{
                   "path" => "f",
                   "operation" => op
                 })

        assert msg["operation"] == op
      end
    end

    test "rejects invalid operation" do
      assert {:error, {:invalid_literal, "operation", "rename", ~w(create modify delete)}} =
               ToolOutput.diff_message(%{"path" => "f", "operation" => "rename"})
    end

    test "validates nested DiffLine entries" do
      assert {:error, {:invalid_list_element, "diff_lines", _}} =
               ToolOutput.diff_message(%{
                 "path" => "f",
                 "operation" => "modify",
                 "diff_lines" => [
                   %{"line_number" => 1, "type" => "invalid", "content" => "x"}
                 ]
               })
    end

    test "round-trips through WireEvent" do
      {:ok, msg} =
        ToolOutput.diff_message(%{
          "path" => "f.ex",
          "operation" => "modify",
          "old_content" => "old",
          "new_content" => "new",
          "diff_lines" => [
            %{"line_number" => 1, "type" => "remove", "content" => "-old"},
            %{"line_number" => 1, "type" => "add", "content" => "+new"}
          ]
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["operation"] == "modify"
      assert length(restored["diff_lines"]) == 2
    end
  end

  # ===========================================================================
  # ShellStartMessage
  # ===========================================================================

  describe "shell_start_message/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        ToolOutput.shell_start_message(%{"command" => "ls -la"})

      assert msg["command"] == "ls -la"
      assert msg["cwd"] == nil
      assert msg["timeout"] == 60
      assert msg["background"] == false
    end

    test "overrides defaults" do
      {:ok, msg} =
        ToolOutput.shell_start_message(%{
          "command" => "sleep 10",
          "cwd" => "/tmp",
          "timeout" => 120,
          "background" => true
        })

      assert msg["cwd"] == "/tmp"
      assert msg["timeout"] == 120
      assert msg["background"] == true
    end

    test "rejects non-string command" do
      assert {:error, {:invalid_field_type, "command", 123}} =
               ToolOutput.shell_start_message(%{"command" => 123})
    end

    test "rejects non-integer timeout" do
      assert {:error, {:invalid_field_type, "timeout", "60"}} =
               ToolOutput.shell_start_message(%{"command" => "ls", "timeout" => "60"})
    end

    test "rejects missing command" do
      assert {:error, {:missing_required_field, "command"}} =
               ToolOutput.shell_start_message(%{})
    end
  end

  # ===========================================================================
  # ShellLineMessage
  # ===========================================================================

  describe "shell_line_message/1" do
    test "happy path with default stream" do
      {:ok, msg} =
        ToolOutput.shell_line_message(%{"line" => "output text"})

      assert msg["line"] == "output text"
      assert msg["stream"] == "stdout"
    end

    test "accepts stderr stream" do
      {:ok, msg} =
        ToolOutput.shell_line_message(%{"line" => "error!", "stream" => "stderr"})

      assert msg["stream"] == "stderr"
    end

    test "rejects invalid stream" do
      assert {:error, {:invalid_literal, "stream", "stdboth", ~w(stdout stderr)}} =
               ToolOutput.shell_line_message(%{"line" => "x", "stream" => "stdboth"})
    end

    test "rejects non-string stream" do
      assert {:error, {:invalid_literal, "stream", 0, ~w(stdout stderr)}} =
               ToolOutput.shell_line_message(%{"line" => "x", "stream" => 0})
    end
  end

  # ===========================================================================
  # ShellOutputMessage
  # ===========================================================================

  describe "shell_output_message/1" do
    test "happy path with defaults" do
      {:ok, msg} =
        ToolOutput.shell_output_message(%{
          "command" => "echo hi",
          "exit_code" => 0,
          "duration_seconds" => 0.5
        })

      assert msg["command"] == "echo hi"
      assert msg["stdout"] == ""
      assert msg["stderr"] == ""
      assert msg["exit_code"] == 0
      assert msg["duration_seconds"] == 0.5
    end

    test "rejects negative duration_seconds" do
      assert {:error, {:value_below_min, "duration_seconds", -0.1, 0}} =
               ToolOutput.shell_output_message(%{
                 "command" => "x",
                 "exit_code" => 0,
                 "duration_seconds" => -0.1
               })
    end

    test "accepts integer duration_seconds" do
      {:ok, msg} =
        ToolOutput.shell_output_message(%{
          "command" => "x",
          "exit_code" => 1,
          "duration_seconds" => 5
        })

      assert msg["duration_seconds"] == 5
    end

    test "rejects non-number duration_seconds" do
      assert {:error, {:invalid_field_type, "duration_seconds", "1.0"}} =
               ToolOutput.shell_output_message(%{
                 "command" => "x",
                 "exit_code" => 0,
                 "duration_seconds" => "1.0"
               })
    end

    test "JSON round-trip" do
      {:ok, msg} =
        ToolOutput.shell_output_message(%{
          "command" => "ls",
          "stdout" => "file1\nfile2",
          "stderr" => "",
          "exit_code" => 0,
          "duration_seconds" => 1.23
        })

      json = Jason.encode!(msg)
      decoded = Jason.decode!(json)
      assert decoded["exit_code"] == 0
      assert decoded["duration_seconds"] == 1.23
    end
  end

  # ===========================================================================
  # UniversalConstructorMessage
  # ===========================================================================

  describe "universal_constructor_message/1" do
    test "happy path" do
      {:ok, msg} =
        ToolOutput.universal_constructor_message(%{
          "action" => "call",
          "tool_name" => "read_file",
          "success" => true,
          "summary" => "File read successfully"
        })

      assert msg["action"] == "call"
      assert msg["tool_name"] == "read_file"
      assert msg["success"] == true
      assert msg["details"] == nil
    end

    test "accepts nil tool_name" do
      {:ok, msg} =
        ToolOutput.universal_constructor_message(%{
          "action" => "list",
          "success" => true,
          "summary" => "List of tools"
        })

      assert msg["tool_name"] == nil
    end

    test "rejects missing action" do
      assert {:error, {:missing_required_field, "action"}} =
               ToolOutput.universal_constructor_message(%{
                 "success" => true,
                 "summary" => "s"
               })
    end

    test "rejects missing success" do
      assert {:error, {:missing_required_field, "success"}} =
               ToolOutput.universal_constructor_message(%{
                 "action" => "list",
                 "summary" => "s"
               })
    end

    test "rejects non-boolean success" do
      assert {:error, {:invalid_field_type, "success", "yes"}} =
               ToolOutput.universal_constructor_message(%{
                 "action" => "list",
                 "success" => "yes",
                 "summary" => "s"
               })
    end

    test "round-trips through WireEvent" do
      {:ok, msg} =
        ToolOutput.universal_constructor_message(%{
          "action" => "call",
          "tool_name" => "write_file",
          "success" => false,
          "summary" => "Failed",
          "details" => "Permission denied"
        })

      {:ok, wire} = WireEvent.to_wire(msg)
      {:ok, restored} = WireEvent.from_wire(wire)

      assert restored["action"] == "call"
      assert restored["success"] == false
      assert restored["details"] == "Permission denied"
    end
  end
end
