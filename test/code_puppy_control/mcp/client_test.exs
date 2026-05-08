defmodule CodePuppyControl.MCP.ClientTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.MCP.{Client, ToolIndex, ClientSupervisor}
  alias CodePuppyControl.Protocol
  alias CodePuppyControl.Support.MockMCPServerHelper, as: MockHelper

  describe "protocol message formatting" do
    test "initialize request has correct MCP format" do
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
          "init-1"
        )

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "initialize"
      assert request["id"] == "init-1"
      assert request["params"]["protocolVersion"] == "2024-11-05"
      assert request["params"]["clientInfo"]["name"] == "code_puppy_control"
    end

    test "notifications/initialized is a notification (no id)" do
      notification = Protocol.encode_notification("notifications/initialized", %{})

      assert notification["jsonrpc"] == "2.0"
      assert notification["method"] == "notifications/initialized"
      refute Map.has_key?(notification, "id")
    end

    test "tools/list request has correct format" do
      request = Protocol.encode_request("tools/list", %{}, "req-1")

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/list"
      assert request["id"] == "req-1"
    end

    test "tools/call request has correct format" do
      request =
        Protocol.encode_request(
          "tools/call",
          %{"name" => "echo", "arguments" => %{"message" => "hello"}},
          "req-2"
        )

      assert request["jsonrpc"] == "2.0"
      assert request["method"] == "tools/call"
      assert request["id"] == "req-2"
      assert request["params"]["name"] == "echo"
      assert request["params"]["arguments"]["message"] == "hello"
    end
  end

  describe "newline-delimited JSON framing" do
    test "frame_newline adds trailing newline" do
      framed = Protocol.frame_newline(%{"jsonrpc" => "2.0", "id" => 1, "method" => "test"})
      assert String.ends_with?(framed, "\n")

      body = String.trim_trailing(framed, "\n")
      assert {:ok, _} = Jason.decode(body)
    end

    test "parse_newline handles single message" do
      encoded = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}) <> "\n"
      {messages, rest} = Protocol.parse_newline(encoded)

      assert length(messages) == 1
      assert hd(messages)["id"] == 1
      assert rest == ""
    end

    test "parse_newline handles multiple messages" do
      msg1 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1}) <> "\n"
      msg2 = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2}) <> "\n"

      {messages, rest} = Protocol.parse_newline(msg1 <> msg2)

      assert length(messages) == 2
      assert Enum.at(messages, 0)["id"] == 1
      assert Enum.at(messages, 1)["id"] == 2
      assert rest == ""
    end

    test "parse_newline handles incomplete message" do
      complete = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1}) <> "\n"
      incomplete = ~s({"jsonrpc":"2.0","id":2)

      {messages, rest} = Protocol.parse_newline(complete <> incomplete)

      assert length(messages) == 1
      assert hd(messages)["id"] == 1
      assert rest == incomplete
    end
  end

  describe "stdio transport with mock server" do
    setup do
      MockHelper.require_available!()

      # Ensure the Registry, ToolIndex, and ClientSupervisor are running
      ensure_registry_started()
      ensure_tool_index_started()
      ensure_client_supervisor_started()

      :ok
    end

    test "client connects to stdio server and lists tools" do
      server_id = "test-stdio-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          id: server_id,
          transport: :stdio,
          command: MockHelper.mock_server_command(),
          args: MockHelper.mock_server_args()
        )

      # Wait for the client to become ready
      wait_for_status(server_id, :ready, 5_000)

      # List tools
      assert {:ok, tools} = Client.list_tools(server_id)
      assert length(tools) == 2
      assert Enum.any?(tools, &(&1["name"] == "echo"))
      assert Enum.any?(tools, &(&1["name"] == "add"))

      # Clean up
      Client.stop(server_id)
    end

    test "client calls echo tool" do
      server_id = "test-echo-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          id: server_id,
          transport: :stdio,
          command: MockHelper.mock_server_command(),
          args: MockHelper.mock_server_args()
        )

      wait_for_status(server_id, :ready, 5_000)

      assert {:ok, result} = Client.call_tool(server_id, "echo", %{"message" => "hello world"})
      assert %{"content" => [%{"type" => "text", "text" => "hello world"}]} = result

      Client.stop(server_id)
    end

    test "client calls add tool" do
      server_id = "test-add-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          id: server_id,
          transport: :stdio,
          command: MockHelper.mock_server_command(),
          args: MockHelper.mock_server_args()
        )

      wait_for_status(server_id, :ready, 5_000)

      assert {:ok, result} = Client.call_tool(server_id, "add", %{"a" => 3, "b" => 4})
      assert %{"content" => [%{"type" => "text", "text" => "7"}]} = result

      Client.stop(server_id)
    end

    test "client handles unknown tool" do
      server_id = "test-unknown-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          id: server_id,
          transport: :stdio,
          command: MockHelper.mock_server_command(),
          args: MockHelper.mock_server_args()
        )

      wait_for_status(server_id, :ready, 5_000)

      assert {:ok, result} = Client.call_tool(server_id, "nonexistent", %{})
      assert result["isError"] == true

      Client.stop(server_id)
    end

    test "client returns error when not ready" do
      server_id = "test-not-ready-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          id: server_id,
          transport: :stdio,
          command: MockHelper.mock_server_command(),
          args: MockHelper.mock_server_args()
        )

      # Don't wait for ready — immediately try to call a tool
      # The client might or might not be ready yet, but this tests the error path
      case Client.call_tool(server_id, "echo", %{"message" => "test"}, 1_000) do
        {:error, {:not_ready, status}} ->
          assert status in [:disconnected, :connecting, :connected]

        {:ok, _result} ->
          # Client became ready before our call — that's also fine
          :ok
      end

      Client.stop(server_id)
    end

    test "get_state returns client summary" do
      server_id = "test-state-#{:erlang.unique_integer([:positive])}"

      {:ok, _pid} =
        Client.start_link(
          id: server_id,
          transport: :stdio,
          command: MockHelper.mock_server_command(),
          args: MockHelper.mock_server_args()
        )

      wait_for_status(server_id, :ready, 5_000)

      state = Client.get_state(server_id)

      assert state.id == server_id
      assert state.transport == :stdio
      assert state.status == :ready
      assert state.tool_count == 2
      assert state.server_info["name"] == "mock-mcp-server"
      assert state.server_info["version"] == "1.0.0"

      Client.stop(server_id)
    end
  end

  describe "config validation" do
    test "stdio transport requires command" do
      # Trap exits since the GenServer will stop on bad config
      Process.flag(:trap_exit, true)

      result =
        Client.start_link(
          id: "no-cmd",
          transport: :stdio
        )

      assert {:error, _} = result
    end

    test "sse transport requires url" do
      Process.flag(:trap_exit, true)

      result =
        Client.start_link(
          id: "no-url-sse",
          transport: :sse
        )

      assert {:error, _} = result
    end

    test "streamable_http transport requires url" do
      Process.flag(:trap_exit, true)

      result =
        Client.start_link(
          id: "no-url-http",
          transport: :streamable_http
        )

      assert {:error, _} = result
    end
  end

  describe "ToolIndex" do
    setup do
      ensure_tool_index_started()
      :ok
    end

    test "register and find tools" do
      tools = [
        %{"name" => "read_file", "description" => "Read a file"},
        %{"name" => "write_file", "description" => "Write a file"}
      ]

      :ok = ToolIndex.register_tools("test-server-1", tools)

      assert {:ok, "test-server-1"} = ToolIndex.find_server_for_tool("read_file")
      assert {:ok, "test-server-1"} = ToolIndex.find_server_for_tool("write_file")
      assert :error = ToolIndex.find_server_for_tool("nonexistent")
    end

    test "get_tools returns tools for a server" do
      tools = [
        %{"name" => "tool_a", "description" => "Tool A"},
        %{"name" => "tool_b", "description" => "Tool B"}
      ]

      :ok = ToolIndex.register_tools("test-server-2", tools)

      assert ^tools = ToolIndex.get_tools("test-server-2")
      assert [] = ToolIndex.get_tools("nonexistent-server")
    end

    test "list_all_tools returns all registered tools" do
      :ok = ToolIndex.register_tools("srv-a", [%{"name" => "tool_x"}])
      :ok = ToolIndex.register_tools("srv-b", [%{"name" => "tool_y"}])

      all_tools = ToolIndex.list_all_tools()
      assert {"tool_x", "srv-a"} in all_tools
      assert {"tool_y", "srv-b"} in all_tools
    end

    test "unregister_server removes all tool entries" do
      :ok = ToolIndex.register_tools("srv-c", [%{"name" => "tool_z"}])
      assert {:ok, "srv-c"} = ToolIndex.find_server_for_tool("tool_z")

      :ok = ToolIndex.unregister_server("srv-c")
      assert :error = ToolIndex.find_server_for_tool("tool_z")
      assert [] = ToolIndex.get_tools("srv-c")
    end

    test "register_tools replaces existing tools for same server" do
      :ok = ToolIndex.register_tools("srv-d", [%{"name" => "old_tool"}])
      assert {:ok, "srv-d"} = ToolIndex.find_server_for_tool("old_tool")

      :ok = ToolIndex.register_tools("srv-d", [%{"name" => "new_tool"}])
      assert :error = ToolIndex.find_server_for_tool("old_tool")
      assert {:ok, "srv-d"} = ToolIndex.find_server_for_tool("new_tool")
    end

    test "server_summary returns counts" do
      :ok = ToolIndex.register_tools("srv-e", [%{"name" => "t1"}, %{"name" => "t2"}])
      :ok = ToolIndex.register_tools("srv-f", [%{"name" => "t3"}])

      summary = ToolIndex.server_summary()
      assert summary["srv-e"] == 2
      assert summary["srv-f"] == 1
    end
  end

  describe "ClientSupervisor" do
    setup do
      ensure_registry_started()
      ensure_tool_index_started()
      ensure_client_supervisor_started()
      :ok
    end

    test "start_client and stop_client" do
      server_id = "sup-test-#{:erlang.unique_integer([:positive])}"

      assert {:ok, _pid} =
               ClientSupervisor.start_client(
                 id: server_id,
                 transport: :stdio,
                 command: MockHelper.mock_server_command(),
                 args: MockHelper.mock_server_args()
               )

      wait_for_status(server_id, :ready, 5_000)

      assert server_id in ClientSupervisor.list_clients()
      assert ClientSupervisor.client_count() >= 1

      assert :ok = ClientSupervisor.stop_client(server_id)

      # Give it a moment to clean up
      Process.sleep(50)
      refute server_id in ClientSupervisor.list_clients()
    end

    test "stop_client returns error for nonexistent server" do
      assert {:error, :not_found} = ClientSupervisor.stop_client("nonexistent")
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp ensure_registry_started do
    case Registry.start_link(keys: :unique, name: CodePuppyControl.MCP.ClientRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_tool_index_started do
    case CodePuppyControl.MCP.ToolIndex.start_link(name: CodePuppyControl.MCP.ToolIndex) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp ensure_client_supervisor_started do
    case CodePuppyControl.MCP.ClientSupervisor.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  defp wait_for_status(server_id, status, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    do_wait_for_status(server_id, status, deadline)
  end

  defp do_wait_for_status(server_id, status, deadline) do
    current = System.monotonic_time(:millisecond)

    if current > deadline do
      flunk("Timed out waiting for client #{server_id} to reach status #{status}")
    end

    case Client.get_state(server_id) do
      %{status: ^status} ->
        :ok

      %{status: :disconnected} = state ->
        # Check if we've hit a failure
        if state.reconnect_attempts > 3 do
          flunk(
            "Client #{server_id} failed to connect (reconnect_attempts: #{state.reconnect_attempts})"
          )
        end

        Process.sleep(100)
        do_wait_for_status(server_id, status, deadline)

      _ ->
        Process.sleep(50)
        do_wait_for_status(server_id, status, deadline)
    end
  rescue
    _ ->
      Process.sleep(100)
      do_wait_for_status(server_id, status, deadline)
  end
end
