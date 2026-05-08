defmodule CodePuppyControl.Integration.MCPDirectPortTest do
  @moduledoc """
  Integration test for MCP server lifecycle via direct Elixir Port.

  Tests with @modelcontextprotocol/server-filesystem which uses
  newline-delimited JSON (not Content-Length framing).

  Validates the full MCP flow:
  - Port.open to spawn node with MCP server
  - MCP initialize handshake
  - tools/list to discover available tools
  - tools/call to execute list_directory
  - Clean shutdown via Port.close

  Skips gracefully if npx or the MCP filesystem server package is unavailable.

  ## Running

      mix test test/integration/mcp_direct_port_test.exs --include integration
  """

  use CodePuppyControl.StatefulCase

  @moduletag :integration
  @moduletag timeout: 60_000

  @mcp_server_package "@modelcontextprotocol/server-filesystem"

  describe "direct port MCP lifecycle" do
    test "initialize -> tools/list -> tools/call -> shutdown" do
      npx_path = System.find_executable("npx")

      if is_nil(npx_path) do
        IO.puts("  SKIP: npx not available")
      else
        tmp_dir = System.tmp_dir!()
        server_path = find_mcp_server_path()

        if is_nil(server_path) do
          IO.puts("  SKIP: could not find #{@mcp_server_package} in npx cache")
        else
          node_path = System.find_executable("node") || "node"

          port =
            Port.open({:spawn_executable, to_charlist(node_path)}, [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [server_path, tmp_dir],
              env: []
            ])

          on_exit(fn ->
            try do
              Port.close(port)
            rescue
              _ -> :ok
            end
          end)

          # === 1. MCP Initialize Handshake ===
          init_msg =
            encode_mcp_request(
              "initialize",
              %{
                "protocolVersion" => "2024-11-05",
                "capabilities" => %{},
                "clientInfo" => %{
                  "name" => "integration_test",
                  "version" => "0.1.0"
                }
              },
              1
            )

          Port.command(port, init_msg)

          init_response = receive_mcp(port, 30_000)
          assert init_response, "No initialize response received"

          server_name = get_in(init_response, ["result", "serverInfo", "name"])
          assert is_binary(server_name)
          IO.puts("  MCP server: #{server_name}")

          # === 2. Send notifications/initialized ===
          notif = encode_mcp_notification("notifications/initialized", %{})
          Port.command(port, notif)

          # === 3. tools/list ===
          list_msg = encode_mcp_request("tools/list", %{}, 2)
          Port.command(port, list_msg)

          list_response = receive_mcp(port, 15_000)
          assert list_response, "No tools/list response received"

          tools = get_in(list_response, ["result", "tools"]) || []
          assert is_list(tools)
          tool_names = Enum.map(tools, & &1["name"])
          IO.puts("  Available tools: #{inspect(tool_names)}")

          assert Enum.any?(tool_names, fn name ->
                   name in ["read_file", "list_directory", "read_multiple_files"]
                 end)

          # === 4. tools/call (list_directory) ===
          call_msg =
            encode_mcp_request(
              "tools/call",
              %{
                "name" => "list_directory",
                "arguments" => %{"path" => tmp_dir}
              },
              3
            )

          Port.command(port, call_msg)

          call_response = receive_mcp(port, 15_000)
          assert call_response, "No tools/call response received"

          content = get_in(call_response, ["result", "content"])
          assert is_list(content)
          IO.puts("  Tool call succeeded with #{length(content)} content item(s)")

          # === 5. Shutdown ===
          # Close port - server may not exit immediately (stdin EOF)
          Port.close(port)

          # Drain any pending messages, then allow cleanup
          drain_messages(2_000)
          IO.puts("  Lifecycle test complete")
        end
      end
    end
  end

  # --- Helpers ---

  # Encode an MCP request as newline-delimited JSON
  defp encode_mcp_request(method, params, id) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    Jason.encode!(msg) <> "\n"
  end

  # Encode an MCP notification as newline-delimited JSON
  defp encode_mcp_notification(method, params) do
    msg = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    Jason.encode!(msg) <> "\n"
  end

  # Receive a newline-delimited JSON-RPC response message from the port
  defp receive_mcp(port, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_mcp(port, "", deadline)
  end

  defp do_receive_mcp(port, buffer, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      parse_mcp_line(buffer)
    else
      case String.split(buffer, "\n", parts: 2) do
        [line, rest] when byte_size(line) > 0 ->
          case Jason.decode(line) do
            {:ok, %{"result" => _} = msg} ->
              msg

            {:ok, %{"error" => _} = msg} ->
              msg

            {:ok, _msg} ->
              # Notification or request - skip and continue
              do_receive_mcp(port, rest, deadline)

            {:error, _} ->
              # Not valid JSON (e.g. stderr output) - skip line
              do_receive_mcp(port, rest, deadline)
          end

        _ ->
          # No complete line yet - wait for more data
          recv_timeout = min(remaining, 10_000)

          receive do
            {^port, {:data, data}} ->
              do_receive_mcp(port, buffer <> data, deadline)

            {^port, {:exit_status, _status}} ->
              parse_mcp_line(buffer)
          after
            recv_timeout ->
              do_receive_mcp(port, buffer, deadline)
          end
      end
    end
  end

  defp parse_mcp_line(buffer) do
    case String.split(buffer, "\n", parts: 2) do
      [line, _] when byte_size(line) > 0 ->
        case Jason.decode(line) do
          {:ok, msg} when is_map(msg) -> msg
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Drain any pending messages from the port mailbox
  defp drain_messages(timeout) do
    receive do
      {_port, _} -> drain_messages(timeout)
    after
      timeout -> :ok
    end
  end

  # Find the MCP filesystem server JS path from npx cache
  defp find_mcp_server_path do
    npx_cache = Path.join([System.get_env("HOME", ""), ".npm", "_npx"])

    case File.ls(npx_cache) do
      {:ok, dirs} ->
        Enum.find_value(dirs, fn dir ->
          candidate =
            Path.join([npx_cache, dir, "node_modules", @mcp_server_package, "dist", "index.js"])

          if File.exists?(candidate), do: candidate
        end)

      _ ->
        nil
    end
  end
end
