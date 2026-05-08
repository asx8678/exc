defmodule CodePuppyControl.MCP.ServerTest do
  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Protocol

  describe "MCP protocol messages" do
    test "initialize request has correct format" do
      request =
        Protocol.encode_request(
          "initialize",
          %{
            "protocolVersion" => "2024-11-05",
            "capabilities" => %{},
            "clientInfo" => %{
              "name" => "code_puppy_control",
              "version" => "0.1.0"
            }
          },
          1
        )

      assert request["method"] == "initialize"
      assert request["id"] == 1
      assert request["params"]["protocolVersion"] == "2024-11-05"
      assert request["params"]["clientInfo"]["name"] == "code_puppy_control"
    end

    test "notifications/initialized is a notification (no id)" do
      notification = Protocol.encode_notification("notifications/initialized", %{})

      assert notification["method"] == "notifications/initialized"
      assert notification["params"] == %{}
      refute Map.has_key?(notification, "id")
    end

    test "tools/call request has correct format" do
      request =
        Protocol.encode_request(
          "tools/call",
          %{
            "name" => "read_file",
            "arguments" => %{"path" => "/tmp/test.txt"}
          },
          "req-123"
        )

      assert request["method"] == "tools/call"
      assert request["id"] == "req-123"
      assert request["params"]["name"] == "read_file"
      assert request["params"]["arguments"]["path"] == "/tmp/test.txt"
    end

    test "tools/list request has correct format" do
      request = Protocol.encode_request("tools/list", %{}, nil)

      assert request["method"] == "tools/list"
    end

    test "framed initialize round-trips correctly" do
      request = Protocol.encode_request("initialize", %{"protocolVersion" => "2024-11-05"}, 1)
      framed = Protocol.frame(request)

      assert framed =~ "Content-Length:"
      assert framed =~ "initialize"

      {messages, ""} = Protocol.parse_framed(framed)
      assert length(messages) == 1
      assert hd(messages)["method"] == "initialize"
    end
  end

  describe "server startup messages" do
    test "no zig references in startup flow" do
      # Verify the startup message doesn't contain any Zig-related methods
      init_request =
        Protocol.encode_request("initialize", %{"protocolVersion" => "2024-11-05"}, 1)

      framed = Protocol.frame(init_request)

      refute framed =~ "zig"
      refute framed =~ "mcp_start"
      refute framed =~ "process_runner"
    end
  end
end
