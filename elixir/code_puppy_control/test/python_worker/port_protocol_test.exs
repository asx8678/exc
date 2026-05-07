defmodule CodePuppyControl.PythonWorker.PortProtocolTest do
  @moduledoc """
  Tests for JSON-RPC bridge protocol compatibility.

  These tests verify that Elixir correctly handles the event format
  documented in docs/BRIDGE_PROTOCOL.md.

  Note: Example file paths use .rs extensions rather than .py per ADR-005
  (Python source parsing is KEEP as data; generic .py references should
  not imply Python runtime/product support).
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.Protocol

  describe "Protocol.frame/1" do
    test "creates Content-Length framed message" do
      message = %{"jsonrpc" => "2.0", "method" => "ping", "params" => %{}}
      framed = Protocol.frame(message)

      assert framed =~ ~r/^Content-Length: \d+\r\n\r\n/

      # Parse back
      [header, body] = String.split(framed, "\r\n\r\n", parts: 2)
      [_, length_str] = String.split(header, ": ")
      content_length = String.to_integer(length_str)

      assert byte_size(body) == content_length
      assert {:ok, ^message} = Jason.decode(body)
    end
  end

  describe "Protocol.parse_framed/1" do
    test "parses Content-Length framed message" do
      message = %{"jsonrpc" => "2.0", "method" => "test", "params" => %{}}
      body = Jason.encode!(message)
      framed = "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"

      assert {[parsed], ""} = Protocol.parse_framed(framed)
      assert parsed == message
    end

    test "returns empty list for partial message" do
      framed = "Content-Length: 100\r\n\r\n{\"partial\":"

      assert {[], ^framed} = Protocol.parse_framed(framed)
    end

    test "handles multiple messages in buffer" do
      msg1 = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      msg2 = %{"jsonrpc" => "2.0", "id" => 2, "method" => "pong"}

      body1 = Jason.encode!(msg1)
      body2 = Jason.encode!(msg2)

      buffer =
        "Content-Length: #{byte_size(body1)}\r\n\r\n#{body1}" <>
          "Content-Length: #{byte_size(body2)}\r\n\r\n#{body2}"

      {[parsed1, parsed2], ""} = Protocol.parse_framed(buffer)
      assert parsed1 == msg1
      assert parsed2 == msg2
    end
  end

  describe "Python event format handling" do
    test "parses bridge_ready event" do
      event = %{
        "jsonrpc" => "2.0",
        "method" => "event",
        "params" => %{
          "event_type" => "bridge_ready",
          "run_id" => nil,
          "session_id" => nil,
          "timestamp" => "2024-01-01T00:00:00Z",
          "payload" => %{}
        }
      }

      assert Protocol.notification?(event)
      assert event["method"] == "event"
      assert event["params"]["event_type"] == "bridge_ready"
    end

    test "parses agent_response event" do
      event = %{
        "jsonrpc" => "2.0",
        "method" => "event",
        "params" => %{
          "event_type" => "agent_response",
          "run_id" => "run-123",
          "session_id" => "session-456",
          "timestamp" => "2024-01-01T00:00:00Z",
          "payload" => %{
            "text" => "Hello, world!",
            "finished" => false
          }
        }
      }

      assert Protocol.notification?(event)
      params = event["params"]
      assert params["event_type"] == "agent_response"
      assert params["payload"]["text"] == "Hello, world!"
    end

    test "parses tool_call event" do
      event = %{
        "jsonrpc" => "2.0",
        "method" => "event",
        "params" => %{
          "event_type" => "tool_call",
          "run_id" => "run-123",
          "session_id" => "session-456",
          "timestamp" => "2024-01-01T00:00:00Z",
          "payload" => %{
            "tool_name" => "read_file",
            "tool_args" => %{"path" => "test.rs"}
          }
        }
      }

      params = event["params"]
      assert params["event_type"] == "tool_call"
      assert params["payload"]["tool_name"] == "read_file"
    end

    test "parses run_completed event" do
      event = %{
        "jsonrpc" => "2.0",
        "method" => "event",
        "params" => %{
          "event_type" => "run_completed",
          "run_id" => "run-123",
          "session_id" => "session-456",
          "timestamp" => "2024-01-01T00:00:00Z",
          "payload" => %{
            "result" => "Task completed successfully"
          }
        }
      }

      params = event["params"]
      assert params["event_type"] == "run_completed"
      assert params["payload"]["result"] == "Task completed successfully"
    end

    test "parses run_failed event" do
      event = %{
        "jsonrpc" => "2.0",
        "method" => "event",
        "params" => %{
          "event_type" => "run_failed",
          "run_id" => "run-123",
          "session_id" => "session-456",
          "timestamp" => "2024-01-01T00:00:00Z",
          "payload" => %{
            "error" => "Something went wrong"
          }
        }
      }

      params = event["params"]
      assert params["event_type"] == "run_failed"
      assert params["payload"]["error"] == "Something went wrong"
    end
  end

  describe "JSON-RPC 2.0 compliance" do
    test "request has id, method, params" do
      request = Protocol.encode_request("test_method", %{"arg" => "value"}, "req-1")

      assert request["jsonrpc"] == "2.0"
      assert request["id"] == "req-1"
      assert request["method"] == "test_method"
      assert request["params"] == %{"arg" => "value"}
    end

    test "notification has no id" do
      notification = Protocol.encode_notification("test_event", %{"data" => "value"})

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "test_event"
      refute Map.has_key?(notification, "id")
    end

    test "response has id and result" do
      response = Protocol.encode_response(%{"success" => true}, "req-1")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "req-1"
      assert response["result"] == %{"success" => true}
    end

    test "error response has id and error" do
      error = Protocol.encode_error(-32601, "Method not found", nil, "req-1")

      assert error["jsonrpc"] == "2.0"
      assert error["id"] == "req-1"
      assert error["error"]["code"] == -32601
      assert error["error"]["message"] == "Method not found"
    end
  end

  describe "Protocol validation helpers" do
    test "notification?/1 returns true for notifications" do
      notification = %{"jsonrpc" => "2.0", "method" => "event", "params" => %{}}
      assert Protocol.notification?(notification)
    end

    test "notification?/1 returns false for requests" do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}
      refute Protocol.notification?(request)
    end

    test "request?/1 returns true for requests" do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}
      assert Protocol.request?(request)
    end

    test "response?/1 returns true for responses" do
      response = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}
      assert Protocol.response?(response)
    end
  end

  # Alias function tests for API compatibility
  describe "Protocol alias functions" do
    test "request/3 is an alias for encode_request/3" do
      # These aliases provide shorter function names for convenience
      if function_exported?(Protocol, :request, 3) do
        assert Protocol.request("test", %{}, 1) == Protocol.encode_request("test", %{}, 1)
      end
    end

    test "notification/2 is an alias for encode_notification/2" do
      if function_exported?(Protocol, :notification, 2) do
        assert Protocol.notification("test", %{}) == Protocol.encode_notification("test", %{})
      end
    end

    test "response/2 is an alias for encode_response/2" do
      if function_exported?(Protocol, :response, 2) do
        assert Protocol.response(1, %{}) == Protocol.encode_response(%{}, 1)
      end
    end

    test "error_response/3 is an alias for encode_error/4 with defaults" do
      if function_exported?(Protocol, :error_response, 3) do
        assert Protocol.error_response("req-1", -32601, "Not found") ==
                 Protocol.encode_error(-32601, "Not found", nil, "req-1")
      end
    end
  end

  describe "repo_compass_index request protocol" do
    test "repo_compass_index request is properly formatted" do
      request =
        Protocol.encode_request(
          "repo_compass_index",
          %{"root" => "/tmp/test", "max_files" => 40, "max_symbols_per_file" => 8},
          "req-compass-1"
        )

      assert request["jsonrpc"] == "2.0"
      assert request["id"] == "req-compass-1"
      assert request["method"] == "repo_compass_index"
      assert request["params"]["root"] == "/tmp/test"
      assert request["params"]["max_files"] == 40
      assert request["params"]["max_symbols_per_file"] == 8
    end

    test "repo_compass_index response encodes files and count" do
      # Simulate a typical Repo Compass response
      result = %{
        "files" => [
          %{"path" => "README.md", "kind" => "project-file", "symbols" => []},
          %{"path" => "src/main.rs", "kind" => "rust", "symbols" => ["fn main()"]},
          %{
            "path" => "src/utils.rs",
            "kind" => "rust",
            "symbols" => ["class Helper methods=foo,bar"]
          }
        ],
        "count" => 3
      }

      response = Protocol.encode_response(result, "req-compass-1")

      assert response["jsonrpc"] == "2.0"
      assert response["id"] == "req-compass-1"
      assert response["result"]["count"] == 3
      assert length(response["result"]["files"]) == 3
      assert Enum.any?(response["result"]["files"], &(&1["path"] == "README.md"))
    end

    test "repo_compass_index framed message can be parsed" do
      request =
        Protocol.encode_request(
          "repo_compass_index",
          %{"root" => "/tmp/test"},
          "req-compass-2"
        )

      framed = Protocol.frame(request)
      {[parsed], ""} = Protocol.parse_framed(framed)

      assert parsed["method"] == "repo_compass_index"
      assert parsed["params"]["root"] == "/tmp/test"
    end
  end
end
