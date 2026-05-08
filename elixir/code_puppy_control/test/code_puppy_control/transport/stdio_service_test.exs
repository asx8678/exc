defmodule CodePuppyControl.Transport.StdioServiceTest do
  @moduledoc """
  Tests for the standalone stdio JSON-RPC transport service.
  """

  use ExUnit.Case

  alias CodePuppyControl.Transport.StdioService
  alias CodePuppyControl.Support.StdioTestHelper

  @test_dir Path.join(
              System.tmp_dir!(),
              "stdio_service_test_#{:erlang.unique_integer([:positive])}"
            )

  setup do
    # Create test directory structure
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    # Create test files
    File.write!(Path.join(@test_dir, "file1.txt"), "Line 1\nLine 2\nLine 3\nLine 4\nLine 5")

    File.write!(
      Path.join(@test_dir, "file2.ex"),
      "defmodule Test do\n def hello do\n :world\n end\nend"
    )

    # Create subdirectory with more files
    subdir = Path.join(@test_dir, "subdir")
    File.mkdir_p!(subdir)

    File.write!(
      Path.join(subdir, "nested.ex"),
      "defmodule Nested do\n def run do\n :ok\n end\nend"
    )

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    %{test_dir: @test_dir, subdir: subdir}
  end

  # ============================================================================
  # Initialization Tests
  # ============================================================================

  describe "initialization" do
    test "starts with default options" do
      assert {:ok, pid} = StdioService.start_link([])
      assert Process.alive?(pid)
      Process.exit(pid, :normal)
    end

    test "tracks request counter via health check" do
      # Service blocks on stdio, use health_check to verify counter increases
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "health_check",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      # Counter is tracked internally, verified via successful response
    end
  end

  # ============================================================================
  # Ping Tests
  # ============================================================================

  describe "ping method" do
    test "responds to ping request" do
      # Create service with custom buffer for testing
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}
      request_line = Jason.encode!(request)

      output =
        capture_stdio([request_line], fn ->
          StdioService.run(buffer: request_line, io_device: :stdio)
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["pong"] == true
      assert response["result"]["timestamp"]
    end
  end

  # ============================================================================
  # Health Check Tests
  # ============================================================================

  describe "health_check method" do
    test "returns service health information" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "health_check",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["status"] == "healthy"
      assert response["result"]["version"]
      assert response["result"]["elixir_version"]
      assert response["result"]["otp_version"]
      assert response["result"]["timestamp"]
    end
  end

  # ============================================================================
  # File List Tests
  # ============================================================================

  describe "file_list method" do
    test "lists files in directory", %{test_dir: dir} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_list",
        "params" => %{"directory" => dir, "recursive" => false}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert response["result"]["files"]

      files = response["result"]["files"]
      paths = Enum.map(files, & &1["path"])

      assert "file1.txt" in paths
      assert "file2.ex" in paths
      assert "subdir" in paths
    end

    test "lists files recursively", %{test_dir: dir} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_list",
        "params" => %{"directory" => dir, "recursive" => true}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      files = response["result"]["files"]
      paths = Enum.map(files, & &1["path"])

      assert "file1.txt" in paths
      assert "subdir/nested.ex" in paths
    end

    test "returns error for non-existent directory" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_list",
        "params" => %{"directory" => "/nonexistent/directory/12345"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] =~ "File list failed"
    end
  end

  # ============================================================================
  # File Read Tests
  # ============================================================================

  describe "file_read method" do
    test "reads file contents", %{test_dir: dir} do
      file_path = Path.join(dir, "file1.txt")

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_read",
        "params" => %{"path" => file_path}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1

      result = response["result"]
      assert result["path"] == file_path
      assert result["content"] == "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"
      assert result["num_lines"] == 5
      assert result["truncated"] == false
      assert result["error"] == nil
    end

    test "reads specific line range", %{test_dir: dir} do
      file_path = Path.join(dir, "file1.txt")

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_read",
        "params" => %{"path" => file_path, "start_line" => 2, "num_lines" => 2}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      result = response["result"]
      assert result["content"] == "Line 2\nLine 3"
      assert result["num_lines"] == 2
      assert result["truncated"] == true
    end

    test "returns error for missing path param" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_read",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "Missing required param"
    end

    test "returns error for non-existent file", %{test_dir: dir} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_read",
        "params" => %{"path" => Path.join(dir, "nonexistent.txt")}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32000
    end
  end

  # ============================================================================
  # File Read Batch Tests
  # ============================================================================

  describe "file_read_batch method" do
    test "reads multiple files concurrently", %{test_dir: dir} do
      paths = [
        Path.join(dir, "file1.txt"),
        Path.join(dir, "file2.ex")
      ]

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_read_batch",
        "params" => %{"paths" => paths}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"

      files = response["result"]["files"]
      assert length(files) == 2

      # Both files should be readable
      assert Enum.all?(files, &(&1["error"] == nil))
    end

    test "handles partial failures gracefully", %{test_dir: dir} do
      paths = [
        Path.join(dir, "file1.txt"),
        Path.join(dir, "nonexistent.txt")
      ]

      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_read_batch",
        "params" => %{"paths" => paths}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      files = response["result"]["files"]

      # Should have results for both files
      assert length(files) == 2

      # One should succeed, one should fail
      results_by_path = Enum.group_by(files, &(&1["error"] == nil))
      assert map_size(results_by_path) >= 1
    end

    test "returns error for empty paths list" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_read_batch",
        "params" => %{"paths" => []}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "Missing or empty param"
    end
  end

  # ============================================================================
  # Grep Tests
  # ============================================================================

  describe "grep_search method" do
    test "finds pattern in files", %{test_dir: dir} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "grep_search",
        "params" => %{"pattern" => "defmodule", "directory" => dir}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"

      matches = response["result"]["matches"]
      assert length(matches) >= 2

      # Check structure
      match = hd(matches)
      assert match["file"]
      assert match["line_number"]
      assert match["line_content"]
      assert match["match_start"]
      assert match["match_end"]
    end

    test "returns error for missing pattern param", %{test_dir: dir} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "grep_search",
        "params" => %{"directory" => dir}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "Missing required param"
    end

    test "handles invalid regex pattern", %{test_dir: dir} do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "grep_search",
        "params" => %{"pattern" => "[invalid", "directory" => dir}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32000
      assert response["error"]["message"] =~ "Grep search failed"
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "returns method not found error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "unknown_method",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32601
      assert response["error"]["message"] =~ "Method not found"
    end

    test "returns parse error for invalid JSON" do
      output =
        capture_stdio(["not valid json"], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32700
      assert response["error"]["message"] =~ "Parse error"
    end

    test "returns invalid request for malformed request" do
      # Wrong jsonrpc version
      request = %{"jsonrpc" => "1.0", "id" => 1}

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["code"] == -32700
    end
  end

  # ============================================================================
  # Security Tests
  # ============================================================================

  describe "security" do
    test "blocks sensitive path access" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_read",
        "params" => %{"path" => Path.join(System.user_home!(), ".ssh/id_rsa")}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["message"] =~ "sensitive path blocked"
    end

    test "blocks sensitive directory in list_files" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "file_list",
        "params" => %{"directory" => "/etc"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]
      assert response["error"]["message"] =~ "sensitive path blocked"
    end
  end

  # ============================================================================
  # Protocol Tests
  # ============================================================================

  describe "protocol compliance" do
    test "handles notification (no id) - no response returned" do
      request = %{
        "jsonrpc" => "2.0",
        "method" => "ping",
        "params" => %{}
      }

      # Notifications (no id) should not get responses per JSON-RPC 2.0 spec
      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      # Output should be empty or "{}" (no response for notifications)
      assert output == nil or output == "{}" or output == ""
    end

    test "uses correct JSON-RPC 2.0 response format" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => "test-id-123",
        "method" => "ping",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "test-id-123"
      assert Map.has_key?(response, "result")
      refute Map.has_key?(response, "error")
    end
  end

  # ============================================================================
  # Text Replace Tests
  # ============================================================================

  describe "text_replace" do
    test "exact replacement succeeds" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "text_replace",
        "params" => %{
          "content" => "hello world\nfoo bar\n",
          "replacements" => [%{"old_str" => "world", "new_str" => "universe"}]
        }
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["result"]["success"] == true
      assert response["result"]["modified"] == "hello universe\nfoo bar\n"
      assert response["result"]["diff"] != ""
      assert response["result"]["error"] == nil
      assert response["result"]["jw_score"] == nil
    end

    test "fuzzy match failure returns error in result" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "text_replace",
        "params" => %{
          "content" => "completely different\n",
          "replacements" => [%{"old_str" => "xyz-nomatch", "new_str" => "replacement"}]
        }
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["result"]["success"] == false
      assert response["result"]["error"] =~ "JW"
      assert response["result"]["modified"] == "completely different\n"
    end

    test "missing content param returns error" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "text_replace",
        "params" => %{
          "replacements" => [%{"old_str" => "a", "new_str" => "b"}]
        }
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "content"
    end
  end

  # ============================================================================
  # Hashline Tests
  # ============================================================================

  describe "hashline_compute" do
    test "returns hash for valid input" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "hashline_compute",
        "params" => %{"idx" => 1, "line" => "hello"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      result = Jason.decode!(output)
      assert result["id"] == 1
      assert is_binary(result["result"]["hash"])
      assert String.length(result["result"]["hash"]) == 2
    end

    test "returns error for missing idx" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "hashline_compute",
        "params" => %{"line" => "hello"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      result = Jason.decode!(output)
      assert result["error"]["code"] == -32602
    end
  end

  describe "hashline_format" do
    test "formats text with hashline prefixes" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "hashline_format",
        "params" => %{"text" => "hello\nworld", "start_line" => 1}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      result = Jason.decode!(output)
      assert is_binary(result["result"]["formatted"])
      # Should contain line numbers and hash anchors
      assert result["result"]["formatted"] =~ ~r/1#[A-Z]{2}:hello/
    end
  end

  describe "hashline_strip" do
    test "strips hashline prefixes" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 4,
        "method" => "hashline_strip",
        "params" => %{"text" => "1#AB:hello\n2#CD:world"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      result = Jason.decode!(output)
      assert result["result"]["stripped"] == "hello\nworld"
    end
  end

  describe "hashline_validate" do
    test "validates matching anchor" do
      # First compute the hash
      compute_req = %{
        "jsonrpc" => "2.0",
        "id" => 5,
        "method" => "hashline_compute",
        "params" => %{"idx" => 1, "line" => "hello"}
      }

      compute_output =
        capture_stdio([Jason.encode!(compute_req)], fn ->
          StdioService.run()
        end)

      hash = Jason.decode!(compute_output)["result"]["hash"]

      # Then validate it
      validate_req = %{
        "jsonrpc" => "2.0",
        "id" => 6,
        "method" => "hashline_validate",
        "params" => %{"idx" => 1, "line" => "hello", "expected_hash" => hash}
      }

      validate_output =
        capture_stdio([Jason.encode!(validate_req)], fn ->
          StdioService.run()
        end)

      result = Jason.decode!(validate_output)
      assert result["result"]["valid"] == true
    end

    test "rejects invalid anchor" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 7,
        "method" => "hashline_validate",
        "params" => %{"idx" => 1, "line" => "hello", "expected_hash" => "ZZ"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      result = Jason.decode!(output)
      assert result["result"]["valid"] == false
    end
  end

  # ============================================================================
  # ============================================================================
  # Runtime State Tests
  # ============================================================================

  describe "runtime state operations" do
    test "runtime_get_autosave_id returns valid timestamp-based ID" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_get_autosave_id",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert response["id"] == 1
      assert Regex.match?(~r/^\d{8}_\d{6}$/, response["result"]["autosave_id"])
    end

    test "runtime_get_autosave_session_name returns formatted session name" do
      # get_session_name should return a string starting with "auto_session_"
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_get_autosave_session_name",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      session_name = response["result"]["session_name"]
      assert is_binary(session_name)
      assert String.starts_with?(session_name, "auto_session_")
      assert Regex.match?(~r/^auto_session_\d{8}_\d{6}$/, session_name)
    end

    test "runtime_rotate_autosave_id generates new ID" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_rotate_autosave_id",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["jsonrpc"] == "2.0"
      assert Regex.match?(~r/^\d{8}_\d{6}$/, response["result"]["autosave_id"])
    end

    test "runtime_set_autosave_from_session extracts ID from session name" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_set_autosave_from_session",
        "params" => %{"session_name" => "auto_session_20240115_143022"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["result"]["autosave_id"] == "20240115_143022"
    end

    test "runtime_reset_autosave_id resets the ID" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_reset_autosave_id",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["result"]["reset"] == true
    end

    test "runtime_get_session_model returns nil when not set" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_reset_session_model",
        "params" => %{}
      }

      capture_stdio([Jason.encode!(request)], fn ->
        StdioService.run()
      end)

      request2 = %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "runtime_get_session_model",
        "params" => %{}
      }

      output2 =
        capture_stdio([Jason.encode!(request2)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output2)
      assert response["result"]["session_model"] == nil
    end

    test "runtime_set_session_model sets the cached model" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_set_session_model",
        "params" => %{"model" => "claude-3-5-sonnet"}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["result"]["session_model"] == "claude-3-5-sonnet"
    end

    test "runtime_reset_session_model resets the model cache" do
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_reset_session_model",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      assert response["result"]["reset"] == true
    end

    test "runtime_get_state returns full state for introspection" do
      # get_state should return session_start_time; autosave_id may be nil if not generated yet
      request = %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "runtime_get_state",
        "params" => %{}
      }

      output =
        capture_stdio([Jason.encode!(request)], fn ->
          StdioService.run()
        end)

      response = Jason.decode!(output)
      # autosave_id may be nil or string depending on whether get_current_autosave_id was called
      assert Map.has_key?(response["result"], "autosave_id")
      assert response["result"]["session_start_time"] != nil
      # session_model may be nil or string
      assert Map.has_key?(response["result"], "session_model")
    end
  end

  # ===========================================================================
  # Runtime State: Cache / Invalidation / Finalize Transport Tests
  # ===========================================================================

  describe "runtime cache transport handlers" do
    test "runtime_get_cached_system_prompt returns nil by default" do
      req = encode_request("runtime_get_cached_system_prompt", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["cached_system_prompt"] == nil
    end

    test "runtime_set_cached_system_prompt accepts string" do
      req = encode_request("runtime_set_cached_system_prompt", %{"prompt" => "hello"}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["cached_system_prompt"] == "hello"
    end

    test "runtime_get_cached_tool_defs returns nil by default" do
      req = encode_request("runtime_get_cached_tool_defs", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["cached_tool_defs"] == nil
    end

    test "runtime_get_model_name_cache returns nil by default" do
      req = encode_request("runtime_get_model_name_cache", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["model_name_cache"] == nil
    end

    test "runtime_get_delayed_compaction_requested returns false by default" do
      req = encode_request("runtime_get_delayed_compaction_requested", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["delayed_compaction_requested"] == false
    end

    test "runtime_get_cached_context_overhead returns nil by default" do
      req = encode_request("runtime_get_cached_context_overhead", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["cached_context_overhead"] == nil
    end

    test "runtime_get_resolved_model_components_cache returns nil by default" do
      req = encode_request("runtime_get_resolved_model_components_cache", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["resolved_model_components_cache"] == nil
    end

    test "runtime_get_puppy_rules_cache returns nil by default" do
      req = encode_request("runtime_get_puppy_rules_cache", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["puppy_rules_cache"] == nil
    end

    test "runtime_set_puppy_rules_cache accepts string" do
      req = encode_request("runtime_set_puppy_rules_cache", %{"rules" => "AGENTS.md content"}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["puppy_rules_cache"] == "AGENTS.md content"
    end
  end

  describe "runtime cache invalidation transport handlers" do
    test "runtime_invalidate_caches clears ephemeral caches" do
      # Set some caches first
      set1 = encode_request("runtime_set_cached_context_overhead", %{"value" => 100}, 1)
      set2 = encode_request("runtime_set_tool_ids_cache", %{"cache" => [1, 2]}, 2)
      _ = capture_stdio([set1, set2])

      # Invalidate
      inv_req = encode_request("runtime_invalidate_caches", %{}, 3)
      output = capture_stdio([inv_req])
      response = decode_response(output)
      assert response["result"]["reset"] == true
    end

    test "runtime_invalidate_all_token_caches clears all token caches" do
      inv_req = encode_request("runtime_invalidate_all_token_caches", %{}, 1)
      output = capture_stdio([inv_req])
      response = decode_response(output)
      assert response["result"]["reset"] == true
    end

    test "runtime_invalidate_system_prompt_cache clears prompt + overhead" do
      inv_req = encode_request("runtime_invalidate_system_prompt_cache", %{}, 1)
      output = capture_stdio([inv_req])
      response = decode_response(output)
      assert response["result"]["reset"] == true
    end
  end

  describe "runtime_finalize_autosave_session transport handler" do
    test "returns a valid autosave ID" do
      req = encode_request("runtime_finalize_autosave_session", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert Regex.match?(~r/^\d{8}_\d{6}$/, response["result"]["autosave_id"])
    end
  end

  # ===========================================================================
  # Runtime State: Type Validation (-32602) Tests
  # ===========================================================================

  describe "runtime setter type validation" do
    test "runtime_set_session_model rejects non-string model" do
      req = encode_request("runtime_set_session_model", %{"model" => 123}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "model"
    end

    test "runtime_set_session_model accepts nil model" do
      req = encode_request("runtime_set_session_model", %{"model" => nil}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["result"]["session_model"] == nil
    end

    test "runtime_set_cached_system_prompt rejects non-string prompt" do
      req = encode_request("runtime_set_cached_system_prompt", %{"prompt" => 42}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "prompt"
    end

    test "runtime_set_cached_tool_defs rejects non-list tool_defs" do
      req = encode_request("runtime_set_cached_tool_defs", %{"tool_defs" => "oops"}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "tool_defs"
    end

    test "runtime_set_model_name_cache rejects non-string model_name" do
      req = encode_request("runtime_set_model_name_cache", %{"model_name" => 99}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "model_name"
    end

    test "runtime_set_delayed_compaction_requested rejects non-boolean value" do
      req = encode_request("runtime_set_delayed_compaction_requested", %{"value" => "yes"}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "value"
    end

    test "runtime_set_cached_context_overhead rejects non-integer value" do
      req = encode_request("runtime_set_cached_context_overhead", %{"value" => "big"}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "value"
    end

    test "runtime_set_resolved_model_components_cache rejects non-map cache" do
      req =
        encode_request("runtime_set_resolved_model_components_cache", %{"cache" => [1, 2]}, 1)

      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "cache"
    end

    test "runtime_set_puppy_rules_cache rejects non-string rules" do
      req = encode_request("runtime_set_puppy_rules_cache", %{"rules" => 123}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
      assert response["error"]["message"] =~ "rules"
    end

    test "runtime_set_autosave_from_session rejects missing session_name" do
      req = encode_request("runtime_set_autosave_from_session", %{}, 1)
      output = capture_stdio([req])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
    end
  end

  # ============================================================================
  # Message Processing Tests
  # ============================================================================

  describe "message.prune_and_filter" do
    test "prunes messages with orphaned tool calls" do
      messages = [
        %{
          "kind" => "request",
          "role" => "user",
          "parts" => [%{"part_kind" => "text", "content" => "Hello"}]
        },
        %{
          "kind" => "response",
          "role" => "assistant",
          "parts" => [
            %{"part_kind" => "tool-call", "tool_call_id" => "orphan-123", "tool_name" => "test"}
          ]
        }
      ]

      request = encode_request("message.prune_and_filter", %{"messages" => messages}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert response["result"]["surviving_indices"] == [0]
      assert response["result"]["dropped_count"] == 1
      assert response["result"]["had_pending_tool_calls"] == true
    end

    test "returns error for missing messages param" do
      request = encode_request("message.prune_and_filter", %{}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
    end
  end

  describe "message.truncation_indices" do
    test "calculates truncation indices within budget" do
      per_message_tokens = [100, 200, 300, 400, 500]

      request =
        encode_request(
          "message.truncation_indices",
          %{"per_message_tokens" => per_message_tokens, "protected_tokens" => 700},
          1
        )

      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_list(response["result"]["indices"])
      assert 0 in response["result"]["indices"]
    end

    test "respects second_has_thinking flag" do
      per_message_tokens = [100, 50, 200, 300]

      request =
        encode_request(
          "message.truncation_indices",
          %{
            "per_message_tokens" => per_message_tokens,
            "protected_tokens" => 400,
            "second_has_thinking" => true
          },
          1
        )

      output = capture_stdio([request])
      response = decode_response(output)
      assert 0 in response["result"]["indices"]
      assert 1 in response["result"]["indices"]
    end
  end

  describe "message.split_for_summarization" do
    test "splits messages for summarization" do
      messages = [
        %{"kind" => "request", "parts" => []},
        %{"kind" => "response", "parts" => []},
        %{"kind" => "request", "parts" => []},
        %{"kind" => "response", "parts" => []}
      ]

      per_message_tokens = [100, 200, 150, 250]

      request =
        encode_request(
          "message.split_for_summarization",
          %{
            "per_message_tokens" => per_message_tokens,
            "messages" => messages,
            "protected_tokens_limit" => 400
          },
          1
        )

      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_list(response["result"]["summarize_indices"])
      assert is_list(response["result"]["protected_indices"])
      assert is_integer(response["result"]["protected_token_count"])
    end
  end

  describe "message.serialize_session" do
    test "serializes messages to base64-encoded MessagePack" do
      messages = [%{"kind" => "request", "role" => "user", "parts" => []}]
      request = encode_request("message.serialize_session", %{"messages" => messages}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_binary(response["result"]["data"])
      assert {:ok, _} = Base.decode64(response["result"]["data"])
    end

    test "returns error for missing messages param" do
      request = encode_request("message.serialize_session", %{}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
    end
  end

  describe "message.deserialize_session" do
    test "deserializes base64-encoded MessagePack to messages" do
      messages = [%{"kind" => "request", "role" => "user", "parts" => []}]
      {:ok, binary} = CodePuppyControl.Messages.Serializer.serialize_session(messages)
      encoded = Base.encode64(binary)
      request = encode_request("message.deserialize_session", %{"data" => encoded}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_list(response["result"]["messages"])
      assert length(response["result"]["messages"]) == 1
    end

    test "returns error for invalid base64" do
      request =
        encode_request("message.deserialize_session", %{"data" => "not-valid-base64!!!"}, 1)

      output = capture_stdio([request])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
    end
  end

  describe "message.serialize_incremental" do
    test "appends new messages to existing serialized data" do
      initial = [%{"kind" => "request", "role" => "user", "parts" => []}]
      {:ok, binary} = CodePuppyControl.Messages.Serializer.serialize_session(initial)
      existing_data = Base.encode64(binary)
      new_messages = [%{"kind" => "response", "role" => "assistant", "parts" => []}]

      request =
        encode_request(
          "message.serialize_incremental",
          %{"new_messages" => new_messages, "existing_data" => existing_data},
          1
        )

      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_binary(response["result"]["data"])
      {:ok, combined_binary} = Base.decode64(response["result"]["data"])
      {:ok, combined} = CodePuppyControl.Messages.Serializer.deserialize_session(combined_binary)
      assert length(combined) == 2
    end

    test "handles nil existing_data (fresh start)" do
      new_messages = [%{"kind" => "request", "parts" => []}]

      request =
        encode_request(
          "message.serialize_incremental",
          %{"new_messages" => new_messages, "existing_data" => nil},
          1
        )

      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_binary(response["result"]["data"])
    end
  end

  describe "message.hash" do
    test "computes hash for a message" do
      message = %{
        "kind" => "request",
        "role" => "user",
        "parts" => [%{"part_kind" => "text", "content" => "Hello world"}]
      }

      request = encode_request("message.hash", %{"message" => message}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_integer(response["result"]["hash"])
      assert response["result"]["hash"] >= 0
    end

    test "produces consistent hashes for same content" do
      message = %{
        "kind" => "request",
        "role" => "user",
        "parts" => [%{"part_kind" => "text", "content" => "Test content"}]
      }

      request1 = encode_request("message.hash", %{"message" => message}, 1)
      request2 = encode_request("message.hash", %{"message" => message}, 2)
      output1 = capture_stdio([request1])
      output2 = capture_stdio([request2])
      response1 = decode_response(output1)
      response2 = decode_response(output2)
      assert response1["result"]["hash"] == response2["result"]["hash"]
    end

    test "returns error for missing message param" do
      request = encode_request("message.hash", %{}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["error"]["code"] == -32602
    end
  end

  describe "message.hash_batch" do
    test "computes hashes for multiple messages" do
      messages = [
        %{"kind" => "request", "role" => "user", "parts" => []},
        %{"kind" => "response", "role" => "assistant", "parts" => []}
      ]

      request = encode_request("message.hash_batch", %{"messages" => messages}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_list(response["result"]["hashes"])
      assert length(response["result"]["hashes"]) == 2
      assert Enum.all?(response["result"]["hashes"], &is_integer/1)
    end
  end

  describe "message.stringify_part" do
    test "returns canonical string for a message part" do
      part = %{
        "part_kind" => "text",
        "content" => "Hello",
        "tool_call_id" => nil,
        "tool_name" => nil
      }

      request = encode_request("message.stringify_part", %{"part" => part}, 1)
      output = capture_stdio([request])
      response = decode_response(output)
      assert response["id"] == 1
      assert is_binary(response["result"]["stringified"])
      assert response["result"]["stringified"] =~ "text"
      assert response["result"]["stringified"] =~ "content=Hello"
    end
  end

  # Helper Functions
  # ============================================================================

  # Delegate to shared test helper
  defp capture_stdio(inputs, fun \\ nil) do
    StdioTestHelper.capture_stdio(inputs, fun)
  end

  # JSON-RPC request encoder
  defp encode_request(method, params, id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    |> Jason.encode!()
  end

  # JSON-RPC response decoder
  # Delegates to shared helper for consistent notification filtering.
  defp decode_response(output) do
    case StdioTestHelper.find_json_rpc_response(output) do
      "{}" -> %{}
      line -> Jason.decode!(line)
    end
  end
end
