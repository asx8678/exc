defmodule CodePuppyControl.ProtocolTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Protocol

  describe "encode_request/3" do
    test "encodes a JSON-RPC 2.0 request" do
      result = Protocol.encode_request("initialize", %{"foo" => "bar"}, 1)

      assert result == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"foo" => "bar"}
             }
    end

    test "handles string ids" do
      result = Protocol.encode_request("test", %{}, "req-123")

      assert result["id"] == "req-123"
    end
  end

  describe "encode_notification/2" do
    test "encodes a JSON-RPC 2.0 notification (no id)" do
      result = Protocol.encode_notification("exit", %{"code" => 0})

      assert result == %{
               "jsonrpc" => "2.0",
               "method" => "exit",
               "params" => %{"code" => 0}
             }

      assert not Map.has_key?(result, "id")
    end
  end

  describe "encode_response/2" do
    test "encodes a JSON-RPC 2.0 success response" do
      result = Protocol.encode_response(%{"status" => "ok"}, 1)

      assert result == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "result" => %{"status" => "ok"}
             }
    end
  end

  describe "encode_error/4" do
    test "encodes a JSON-RPC 2.0 error without data" do
      result = Protocol.encode_error(-32600, "Invalid Request", nil, 1)

      assert result == %{
               "jsonrpc" => "2.0",
               "id" => 1,
               "error" => %{"code" => -32600, "message" => "Invalid Request"}
             }
    end

    test "encodes a JSON-RPC 2.0 error with data" do
      result = Protocol.encode_error(-32600, "Invalid Request", %{"details" => "extra"}, 1)

      assert result["error"]["data"] == %{"details" => "extra"}
    end
  end

  describe "decode/1" do
    test "decodes valid JSON-RPC message" do
      json = ~s({"jsonrpc":"2.0","id":1,"result":{}})
      assert {:ok, decoded} = Protocol.decode(json)
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
    end

    test "returns error for invalid JSON" do
      assert {:error, {:invalid_json, _}} = Protocol.decode(~s({"invalid))
    end

    test "returns error for missing jsonrpc field" do
      assert {:error, {:invalid_jsonrpc, _}} = Protocol.decode(~s({"id":1,"result":{}}))
    end

    test "returns error for wrong jsonrpc version" do
      assert {:error, {:invalid_jsonrpc, _}} = Protocol.decode(~s({"jsonrpc":"1.0"}))
    end
  end

  describe "frame/1" do
    test "frames a message with Content-Length header" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "test"}
      framed = Protocol.frame(message)

      # Should contain Content-Length header
      assert String.starts_with?(framed, "Content-Length:")
      assert String.contains?(framed, "\r\n\r\n")

      # Should contain the JSON body after the double newline
      [header, body] = String.split(framed, "\r\n\r\n", parts: 2)
      assert {:ok, _} = Jason.decode(body)
    end

    test "correct Content-Length matches body bytes" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "test"}
      body = Jason.encode!(message)

      framed = Protocol.frame(message)

      # Extract content length from header
      [header | _] = String.split(framed, "\r\n\r\n")
      [_, length_str] = String.split(header, "Content-Length: ")
      {length, _} = Integer.parse(length_str)

      assert length == byte_size(body)
    end
  end

  describe "parse_framed/1" do
    test "parses single framed message" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"ok" => true}}
      framed = Protocol.frame(message)

      assert {[decoded], ""} = Protocol.parse_framed(framed)
      assert decoded["id"] == 1
      assert decoded["result"]["ok"] == true
    end

    test "parses multiple framed messages" do
      msg1 = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{"a" => 1}})
      msg2 = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"b" => 2}})

      combined = msg1 <> msg2

      assert {[decoded1, decoded2], ""} = Protocol.parse_framed(combined)
      assert decoded1["id"] == 1
      assert decoded2["id"] == 2
    end

    test "returns incomplete data as rest buffer" do
      # Incomplete - missing part of body
      incomplete = "Content-Length: 50\r\n\r\n{\"jsonrpc\":\"2.0\""

      assert {[], ^incomplete} = Protocol.parse_framed(incomplete)
    end

    test "parses complete messages and keeps incomplete rest" do
      complete = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      incomplete = "Content-Length: 50\r\n\r\n{\"jsonrpc\":\"2.0\""

      buffer = complete <> incomplete

      assert {[decoded], rest} = Protocol.parse_framed(buffer)
      assert decoded["id"] == 1
      assert rest == incomplete
    end
  end

  describe "notification?/1" do
    test "returns true for notification (no id)" do
      assert Protocol.notification?(%{"jsonrpc" => "2.0", "method" => "test"})
    end

    test "returns false for request (has id)" do
      refute Protocol.notification?(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})
    end
  end

  describe "request?/1" do
    test "returns true for request (has method and id)" do
      assert Protocol.request?(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})
    end

    test "returns false for notification (no id)" do
      refute Protocol.request?(%{"jsonrpc" => "2.0", "method" => "test"})
    end

    test "returns false for response (no method)" do
      refute Protocol.request?(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
    end
  end

  describe "response?/1" do
    test "returns true for success response" do
      assert Protocol.response?(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
    end

    test "returns true for error response" do
      assert Protocol.response?(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{}})
    end

    test "returns false for request" do
      refute Protocol.response?(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})
    end
  end

  # Batch support tests
  describe "frame_batch/1" do
    test "frames multiple messages as JSON array" do
      messages = [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "file_read",
          "params" => %{"path" => "a.rs"}
        },
        %{"jsonrpc" => "2.0", "id" => 2, "method" => "file_read", "params" => %{"path" => "b.rs"}}
      ]

      framed = Protocol.frame_batch(messages)

      assert String.starts_with?(framed, "Content-Length:")
      assert String.contains?(framed, "\r\n\r\n")

      [header, body] = String.split(framed, "\r\n\r\n", parts: 2)
      assert {:ok, decoded} = Jason.decode(body)
      assert is_list(decoded)
      assert length(decoded) == 2

      [_, length_str] = String.split(header, "Content-Length: ")
      {length, _} = Integer.parse(length_str)
      assert length == byte_size(body)
    end

    test "handles single-element batch" do
      messages = [%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]

      framed = Protocol.frame_batch(messages)
      [_, body] = String.split(framed, "\r\n\r\n", parts: 2)
      assert {:ok, [decoded]} = Jason.decode(body)
      assert decoded["id"] == 1
    end

    test "handles empty batch" do
      framed = Protocol.frame_batch([])
      [_, body] = String.split(framed, "\r\n\r\n", parts: 2)
      assert {:ok, []} = Jason.decode(body)
    end
  end

  describe "decode/1 batch support" do
    test "decodes JSON array (batch format)" do
      json = ~s([{"jsonrpc":"2.0","id":1},{"jsonrpc":"2.0","id":2}])
      assert {:ok, decoded} = Protocol.decode(json)
      assert is_list(decoded)
      assert length(decoded) == 2
    end

    test "rejects batch with invalid messages" do
      json = ~s([{"jsonrpc":"2.0","id":1},{"id":2}])
      assert {:error, {:invalid_jsonrpc, _}} = Protocol.decode(json)
    end
  end

  describe "parse_framed/1 batch support" do
    test "parses batch message from buffer" do
      messages = [
        %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"a" => 1}},
        %{"jsonrpc" => "2.0", "id" => 2, "result" => %{"b" => 2}}
      ]

      framed = Protocol.frame_batch(messages)
      assert {[decoded], ""} = Protocol.parse_framed(framed)
      assert is_list(decoded)
      assert length(decoded) == 2
    end

    test "parses batch followed by single message" do
      batch =
        Protocol.frame_batch([
          %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}},
          %{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}
        ])

      single = Protocol.frame(%{"jsonrpc" => "2.0", "id" => 3, "result" => %{}})

      buffer = batch <> single

      assert {[decoded_batch, decoded_single], ""} = Protocol.parse_framed(buffer)
      assert is_list(decoded_batch)
      assert length(decoded_batch) == 2
      assert decoded_single["id"] == 3
    end
  end

  describe "frame_newline/1" do
    test "encodes message as JSON with trailing newline" do
      msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "test"}
      framed = Protocol.frame_newline(msg)

      assert framed =~ "\"jsonrpc\":\"2.0\""
      assert String.ends_with?(framed, "\n")
    end

    test "round-trips with parse_newline" do
      msg = %{
        "jsonrpc" => "2.0",
        "id" => 42,
        "method" => "initialize",
        "params" => %{"x" => 1}
      }

      framed = Protocol.frame_newline(msg)

      {messages, ""} = Protocol.parse_newline(framed)
      assert length(messages) == 1
      assert hd(messages) == msg
    end
  end

  describe "parse_newline/1" do
    test "parses single message" do
      line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1}) <> "\n"
      {messages, ""} = Protocol.parse_newline(line)
      assert length(messages) == 1
      assert hd(messages)["id"] == 1
    end

    test "parses multiple messages" do
      data =
        (Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1}) <> "\n") <>
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2}) <> "\n"

      {messages, ""} = Protocol.parse_newline(data)
      assert length(messages) == 2
      assert Enum.map(messages, & &1["id"]) == [1, 2]
    end

    test "handles incomplete trailing data" do
      data = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1}) <> "\n{\"partial"
      {messages, rest} = Protocol.parse_newline(data)

      assert length(messages) == 1
      assert rest == "{\"partial"
    end

    test "skips malformed JSON lines" do
      data = "not json\n" <> Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1}) <> "\n"
      {messages, ""} = Protocol.parse_newline(data)

      assert length(messages) == 1
      assert hd(messages)["id"] == 1
    end

    test "handles empty buffer" do
      {messages, ""} = Protocol.parse_newline("")
      assert messages == []
    end

    test "handles buffer with only newline" do
      {messages, ""} = Protocol.parse_newline("\n")
      assert messages == []
    end
  end
end
