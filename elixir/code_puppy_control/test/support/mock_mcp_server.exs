#!/usr/bin/env elixir
# Mock MCP server for testing the Elixir MCP client.
#
# Implements the MCP JSON-RPC protocol over stdio:
# - initialize / initialized handshake
# - tools/list → returns a list of test tools
# - tools/call → calls a tool and returns results
#
# Reads newline-delimited JSON-RPC from stdin, writes to stdout.
# Uses Elixir stdlib JSON (1.18+) — no external deps required.

defmodule MockMCPServer do
  @moduledoc false

  @protocol_version "2024-11-05"

  @tools [
    %{
      "name" => "echo",
      "description" => "Echoes back the input",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string", "description" => "The message to echo"}
        },
        "required" => ["message"]
      }
    },
    %{
      "name" => "add",
      "description" => "Adds two numbers",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "a" => %{"type" => "number"},
          "b" => %{"type" => "number"}
        },
        "required" => ["a", "b"]
      }
    }
  ]

  @spec main() :: no_return()
  def main do
    # Trap exits so :epipe from a disconnected client doesn't crash
    # the subprocess with a noisy stacktrace. The process will exit
    # normally once stdin closes.
    Process.flag(:trap_exit, true)

    IO.stream(:stdio, :line)
    |> Enum.each(&process_line/1)
  rescue
    _ -> exit(:normal)
  catch
    :exit, :normal -> exit(:normal)
    :exit, _ -> exit(:normal)
  end

  defp process_line(line) do
    line = String.trim(line)
    if line != "", do: handle_raw(line)
  end

  defp handle_raw(raw) do
    case JSON.decode(raw) do
      {:ok, msg} when is_map(msg) ->
        handle_message(msg)

      {:error, _} ->
        :ok
    end
  end

  # ── JSON-RPC method handlers ──────────────────────────────────────────

  defp handle_message(%{"method" => "initialize", "id" => id}) do
    reply(id, %{
      "protocolVersion" => @protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{
        "name" => "mock-mcp-server",
        "version" => "1.0.0"
      }
    })
  end

  defp handle_message(%{"method" => "tools/list", "id" => id}) do
    reply(id, %{"tools" => @tools})
  end

  defp handle_message(%{"method" => "tools/call", "id" => id, "params" => params}) do
    tool_name = params["name"] || ""
    arguments = params["arguments"] || %{}

    result =
      case tool_name do
        "echo" ->
          msg = arguments["message"] || ""
          %{"content" => [%{"type" => "text", "text" => msg}]}

        "add" ->
          a = arguments["a"] || 0
          b = arguments["b"] || 0
          %{"content" => [%{"type" => "text", "text" => to_string(a + b)}]}

        _ ->
          %{
            "isError" => true,
            "content" => [%{"type" => "text", "text" => "Unknown tool: #{tool_name}"}]
          }
      end

    reply(id, result)
  end

  # Notification — no response needed
  defp handle_message(%{"method" => "notifications/initialized"}) do
    :ok
  end

  # Unknown method with an id → JSON-RPC error
  defp handle_message(%{"method" => method, "id" => id}) do
    reply_error(id, -32601, "Method not found: #{method}")
  end

  # Catch-all
  defp handle_message(_), do: :ok

  # ── Wire helpers ─────────────────────────────────────────────────────

  defp reply(id, result) do
    write!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  defp reply_error(id, code, message) do
    write!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  defp write!(msg) do
    encoded = JSON.encode!(msg) <> "\n"

    case :io.put_chars(:standard_io, encoded) do
      :ok -> :ok
      {:error, _} -> exit(:normal)
    end
  end
end

MockMCPServer.main()
