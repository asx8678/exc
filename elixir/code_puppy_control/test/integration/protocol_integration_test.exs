defmodule CodePuppyControl.ProtocolIntegrationTest do
  @moduledoc """
  Integration tests for the Protocol module with real JSON-RPC message flows.

  These tests verify end-to-end message encoding/decoding with
  Content-Length framing as used in actual Port communication.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Protocol

  describe "request/response round-trip" do
    test "encodes request and decodes response with Content-Length framing" do
      # Build a request
      request = Protocol.encode_request("initialize", %{"capabilities" => %{}}, "req-1")

      # Frame it as would happen in real Port communication
      framed = Protocol.frame(request)

      # Verify framing format
      assert String.starts_with?(framed, "Content-Length:")
      assert String.contains?(framed, "\r\n\r\n")

      # Parse the framed message back
      {[decoded], ""} = Protocol.parse_framed(framed)

      # Verify decoded matches original
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == "req-1"
      assert decoded["method"] == "initialize"
      assert decoded["params"]["capabilities"] == %{}
    end

    test "encodes success response and decodes correctly" do
      # Build a response
      result = %{"status" => "ok", "capabilities" => %{"tools" => ["read_file"]}}
      response = Protocol.encode_response(result, "req-1")

      # Frame and parse
      framed = Protocol.frame(response)
      {[decoded], ""} = Protocol.parse_framed(framed)

      # Verify
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == "req-1"
      assert decoded["result"]["status"] == "ok"
      assert decoded["result"]["capabilities"]["tools"] == ["read_file"]
      refute Map.has_key?(decoded, "error")
    end

    test "encodes error response and decodes correctly" do
      # Build an error response
      error =
        Protocol.encode_error(
          -32600,
          "Invalid Request",
          %{"details" => "Missing method"},
          "req-2"
        )

      # Frame and parse
      framed = Protocol.frame(error)
      {[decoded], ""} = Protocol.parse_framed(framed)

      # Verify
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == "req-2"
      assert decoded["error"]["code"] == -32600
      assert decoded["error"]["message"] == "Invalid Request"
      assert decoded["error"]["data"]["details"] == "Missing method"
      refute Map.has_key?(decoded, "result")
    end

    test "handles batch requests in sequence" do
      # Build multiple requests
      req1 = Protocol.encode_request("initialize", %{}, 1)
      req2 = Protocol.encode_request("ping", %{}, 2)
      req3 = Protocol.encode_request("echo", %{"message" => "hello"}, 3)

      # Frame each individually (batch encoding)
      framed1 = Protocol.frame(req1)
      framed2 = Protocol.frame(req2)
      framed3 = Protocol.frame(req3)

      # Concatenate as would happen in a batch
      combined = framed1 <> framed2 <> framed3

      # Parse all at once
      {[d1, d2, d3], ""} = Protocol.parse_framed(combined)

      # Verify each decoded correctly
      assert d1["id"] == 1
      assert d1["method"] == "initialize"

      assert d2["id"] == 2
      assert d2["method"] == "ping"

      assert d3["id"] == 3
      assert d3["method"] == "echo"
      assert d3["params"]["message"] == "hello"
    end

    test "preserves message order in batch processing" do
      messages =
        for i <- 1..5 do
          Protocol.encode_request("test", %{"index" => i}, "req-#{i}")
        end

      combined = Enum.map_join(messages, &Protocol.frame/1)

      {decoded, ""} = Protocol.parse_framed(combined)

      # Verify order is preserved (messages returned in order received)
      ids = Enum.map(decoded, & &1["id"])
      assert ids == ["req-1", "req-2", "req-3", "req-4", "req-5"]

      indices = Enum.map(decoded, & &1["params"]["index"])
      assert indices == [1, 2, 3, 4, 5]
    end
  end

  describe "malformed JSON handling" do
    test "gracefully handles truncated JSON in frame" do
      # Create a frame claiming larger size than provided
      bad_frame = "Content-Length: 100\r\n\r\n{\"jsonrpc\":\"2.0\"}"

      # Should return empty list and keep buffer as incomplete
      {[], rest} = Protocol.parse_framed(bad_frame)
      assert rest == bad_frame
    end

    test "gracefully handles invalid JSON in well-formed frame" do
      # Valid header but invalid JSON body
      invalid_json = "{invalid json content}"
      framed = Protocol.frame_body(invalid_json)

      # Should skip the invalid message and continue
      {[], ""} = Protocol.parse_framed(framed)
    end

    test "gracefully handles missing jsonrpc version" do
      # Valid JSON but missing jsonrpc field
      bad_message = ~s({"id": 1, "method": "test"})
      framed = Protocol.frame_body(bad_message)

      {[], ""} = Protocol.parse_framed(framed)
    end

    test "gracefully handles wrong jsonrpc version" do
      # Wrong version
      bad_message = ~s({"jsonrpc": "1.0", "id": 1, "method": "test"})
      framed = Protocol.frame_body(bad_message)

      {[], ""} = Protocol.parse_framed(framed)
    end

    test "continues processing after encountering malformed message" do
      # Valid message, then invalid, then valid
      good1 = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      bad = Protocol.frame_body("{invalid}")
      good2 = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{}})

      combined = good1 <> bad <> good2

      # Should parse good messages and skip bad (invalid messages are skipped)
      {decoded, ""} = Protocol.parse_framed(combined)

      # We should get both valid messages (invalid ones are skipped)
      assert length(decoded) == 2
      ids = Enum.map(decoded, & &1["id"])
      assert 1 in ids
      assert 2 in ids
    end

    test "handles completely garbled input gracefully" do
      garbled = "garbage data without proper framing"

      # Garbled input without valid Content-Length header is kept as incomplete
      {[], rest} = Protocol.parse_framed(garbled)
      # Protocol keeps incomplete data in buffer waiting for more
      assert rest == garbled
    end
  end

  describe "notification streaming" do
    test "decodes run.event notifications" do
      # Simulate a streaming event notification from Python
      notification =
        Protocol.encode_notification("run.event", %{
          "run_id" => "run-123",
          "event_type" => "tool_call",
          "data" => %{
            "tool" => "read_file",
            "args" => %{"path" => "/test.txt"}
          }
        })

      framed = Protocol.frame(notification)
      {[decoded], ""} = Protocol.parse_framed(framed)

      # Notifications have no id
      assert Protocol.notification?(decoded)
      refute Map.has_key?(decoded, "id")

      assert decoded["method"] == "run.event"
      assert decoded["params"]["run_id"] == "run-123"
      assert decoded["params"]["event_type"] == "tool_call"
      assert decoded["params"]["data"]["tool"] == "read_file"
    end

    test "decodes run.status notifications" do
      # Simulate status update notification
      notification =
        Protocol.encode_notification("run.status", %{
          "run_id" => "run-456",
          "status" => "running",
          "progress" => 0.5,
          "current_tool" => "grep"
        })

      framed = Protocol.frame(notification)
      {[decoded], ""} = Protocol.parse_framed(framed)

      assert Protocol.notification?(decoded)
      assert decoded["method"] == "run.status"
      assert decoded["params"]["status"] == "running"
      assert decoded["params"]["progress"] == 0.5
    end

    test "distinguishes notifications from requests and responses" do
      notification = Protocol.encode_notification("exit", %{"code" => 0})
      request = Protocol.encode_request("ping", %{}, 1)
      response = Protocol.encode_response(%{"pong" => true}, 1)

      # Verify predicates work correctly
      assert Protocol.notification?(notification)
      refute Protocol.notification?(request)
      refute Protocol.notification?(response)

      refute Protocol.request?(notification)
      assert Protocol.request?(request)
      refute Protocol.request?(response)

      refute Protocol.response?(notification)
      refute Protocol.response?(request)
      assert Protocol.response?(response)
    end

    test "handles mixed stream of notifications and responses" do
      # Simulate a realistic stream: response, notification, response
      resp1 = Protocol.frame(Protocol.encode_response(%{"result" => 1}, "req-1"))
      notif = Protocol.frame(Protocol.encode_notification("run.status", %{"progress" => 0.5}))
      resp2 = Protocol.frame(Protocol.encode_response(%{"result" => 2}, "req-2"))

      stream = resp1 <> notif <> resp2

      {[d1, d2, d3], ""} = Protocol.parse_framed(stream)

      # Check types
      assert Protocol.response?(d1)
      assert d1["id"] == "req-1"

      assert Protocol.notification?(d2)
      assert d2["method"] == "run.status"

      assert Protocol.response?(d3)
      assert d3["id"] == "req-2"
    end
  end

  describe "message type predicates" do
    test "request?/1 correctly identifies requests" do
      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "test"}
      assert Protocol.request?(request)

      # Missing id
      refute Protocol.request?(%{"jsonrpc" => "2.0", "method" => "test"})

      # Missing method
      refute Protocol.request?(%{"jsonrpc" => "2.0", "id" => 1})

      # Response (has id but no method)
      refute Protocol.request?(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
    end

    test "response?/1 correctly identifies responses" do
      success = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"ok" => true}}
      error = %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -1}}

      assert Protocol.response?(success)
      assert Protocol.response?(error)

      # Request is not a response
      refute Protocol.response?(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})

      # Notification is not a response
      refute Protocol.response?(%{"jsonrpc" => "2.0", "result" => %{}})
    end

    test "notification?/1 correctly identifies notifications" do
      notification = %{"jsonrpc" => "2.0", "method" => "exit", "params" => %{}}
      assert Protocol.notification?(notification)

      # Has id - not a notification
      refute Protocol.notification?(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})

      # Response is not a notification
      refute Protocol.notification?(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
    end
  end

  describe "binary buffer handling" do
    test "handles incomplete message in buffer" do
      complete = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      incomplete = "Content-Length: 50\r\n\r\n{\"jsonrpc\":\"2.0\""

      buffer = complete <> incomplete

      {[decoded], rest} = Protocol.parse_framed(buffer)
      assert decoded["id"] == 1
      assert rest == incomplete
    end

    test "handles multiple complete messages with trailing data" do
      msg1 = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"a" => 1}})
      msg2 = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"b" => 2}})
      # Note: Content-Length says 10 bytes but "{incomplete" is 11 chars
      # So 10 bytes will be consumed as body (leaving "e"), then "e" is left as rest
      trailing = "Content-Length: 10\r\n\r\n{incomplete"

      buffer = msg1 <> msg2 <> trailing

      {[d1, d2], rest} = Protocol.parse_framed(buffer)
      assert d1["id"] == 1
      assert d2["id"] == 2
      # The 'e' at the end remains after trying to parse 10 bytes from "{incomplete"
      assert rest == "e"
    end

    test "handles empty buffer" do
      {[], ""} = Protocol.parse_framed("")
    end

    test "handles buffer with only whitespace" do
      {[], "   "} = Protocol.parse_framed("   ")
    end
  end
end
