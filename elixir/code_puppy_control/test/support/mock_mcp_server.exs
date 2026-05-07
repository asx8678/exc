#!/usr/bin/env elixir
# Mock MCP server for testing the Elixir MCP client.
#
# Implements the MCP JSON-RPC protocol over stdio:
# - initialize / initialized handshake
# - tools/list → returns a list of test tools
# - tools/call → calls a tool and returns results
#
# Reads newline-delimited JSON-RPC from stdin, writes to stdout.
# Self-contained: includes a tiny JSON codec so it runs on any
# Elixir >= 1.15 without Mix deps or stdlib JSON (1.18+).

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

  # ── Entry point ──────────────────────────────────────────────────────

  @spec main() :: no_return()
  def main do
    Process.flag(:trap_exit, true)

    IO.binstream(:stdio, :line)
    |> Enum.each(&process_line/1)
  rescue
    # Broad catch: the subprocess may be killed or have its stdout pipe
    # closed by the client at any point.  We want to exit cleanly rather
    # than emit a noisy stacktrace on :epipe / :terminated / port-death.
    _ -> exit(:normal)
  catch
    :exit, :normal -> exit(:normal)
    # Broad catch for any exit signal (client disconnect, port closed, etc.)
    :exit, _ -> exit(:normal)
  end

  defp process_line(line) do
    line = String.trim(line)
    if line != "", do: handle_raw(line)
  end

  defp handle_raw(raw) do
    case json_decode(raw) do
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
    encoded = json_encode(msg) <> "\n"

    case :io.put_chars(:standard_io, encoded) do
      :ok -> :ok
      {:error, _} -> exit(:normal)
    end
  end

  # ── Tiny JSON codec (Elixir 1.15+ compatible, no deps) ──────────────
  #
  # Sufficient subset: maps with string keys, lists, strings, integers,
  # floats, booleans, nil. No streaming; no atom keys; no \uXXXX escapes.

  defp json_encode(v), do: enc_val(v)

  defp enc_val(m) when is_map(m) do
    inner =
      m
      |> Enum.map(fn {k, v} -> enc_str(to_string(k)) <> ":" <> enc_val(v) end)
      |> Enum.join(",")

    "{" <> inner <> "}"
  end

  defp enc_val(l) when is_list(l) do
    "[" <> Enum.map_join(l, ",", &enc_val/1) <> "]"
  end

  defp enc_val(s) when is_binary(s), do: enc_str(s)
  defp enc_val(n) when is_integer(n), do: Integer.to_string(n)

  defp enc_val(n) when is_float(n) do
    n |> :erlang.float_to_binary([:compact, decimals: 15])
  end

  defp enc_val(true), do: "true"
  defp enc_val(false), do: "false"
  defp enc_val(nil), do: "null"

  defp enc_str(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end

  defp json_decode(bin) do
    {val, rest} = dec_val(skip_ws(bin))

    if rest == "" or skip_ws(rest) == "" do
      {:ok, val}
    else
      {:error, :trailing_data}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp skip_ws(<<c, rest::binary>>) when c in ~c[ \t\n\r], do: skip_ws(rest)
  defp skip_ws(bin), do: bin

  defp dec_val(<<?", rest::binary>>), do: dec_str(rest, [])

  defp dec_val(<<?{, rest::binary>>), do: dec_obj(skip_ws(rest), %{})

  defp dec_val(<<?[, rest::binary>>), do: dec_arr(skip_ws(rest), [])

  defp dec_val(<<"true", rest::binary>>), do: {true, rest}
  defp dec_val(<<"false", rest::binary>>), do: {false, rest}
  defp dec_val(<<"null", rest::binary>>), do: {nil, rest}

  defp dec_val(<<c, _::binary>> = bin) when c in ?0..?9 or c == ?-,
    do: dec_num(bin, "")

  # ── String decoding ──────────────────────────────────────────────────

  defp dec_str(<<?", rest::binary>>, acc), do: {acc_reverse(acc), rest}

  defp dec_str(<<?\\, ?n, rest::binary>>, acc), do: dec_str(rest, ["\n" | acc])
  defp dec_str(<<?\\, ?r, rest::binary>>, acc), do: dec_str(rest, ["\r" | acc])
  defp dec_str(<<?\\, ?t, rest::binary>>, acc), do: dec_str(rest, ["\t" | acc])
  defp dec_str(<<?\\, ?", rest::binary>>, acc), do: dec_str(rest, ["\"" | acc])
  defp dec_str(<<?\\, ?\\, rest::binary>>, acc), do: dec_str(rest, ["\\" | acc])
  defp dec_str(<<?\\, ?/, rest::binary>>, acc), do: dec_str(rest, ["/" | acc])
  defp dec_str(<<?\\, c, rest::binary>>, acc), do: dec_str(rest, [<<c>> | acc])
  defp dec_str(<<c, rest::binary>>, acc), do: dec_str(rest, [<<c>> | acc])

  defp acc_reverse(acc) when is_list(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # ── Object decoding ──────────────────────────────────────────────────

  defp dec_obj(<<?}, rest::binary>>, acc), do: {acc, rest}

  defp dec_obj(bin, acc) do
    {key, rest} = dec_val(bin)
    <<?:, rest2::binary>> = skip_ws(rest)
    {val, rest3} = dec_val(skip_ws(rest2))
    new_acc = Map.put(acc, key, val)

    case skip_ws(rest3) do
      <<?,, rest4::binary>> -> dec_obj(skip_ws(rest4), new_acc)
      <<?}, rest4::binary>> -> {new_acc, rest4}
    end
  end

  # ── Array decoding ────────────────────────────────────────────────────

  defp dec_arr(<<?], rest::binary>>, acc), do: {Enum.reverse(acc), rest}

  defp dec_arr(bin, acc) do
    {val, rest} = dec_val(bin)
    new_acc = [val | acc]

    case skip_ws(rest) do
      <<?,, rest2::binary>> -> dec_arr(skip_ws(rest2), new_acc)
      <<?], rest2::binary>> -> {Enum.reverse(new_acc), rest2}
    end
  end

  # ── Number decoding ───────────────────────────────────────────────────

  defp dec_num(<<c, rest::binary>>, acc) when c in ?0..?9 or c == ?-,
    do: dec_num(rest, acc <> <<c>>)

  defp dec_num(<<c, rest::binary>>, acc) when c in [?., ?e, ?E, ?+, ?-],
    do: dec_num(rest, acc <> <<c>>)

  defp dec_num(rest, acc) do
    val =
      if String.contains?(acc, ".") or String.contains?(acc, "e") or
           String.contains?(acc, "E") do
        String.to_float(acc)
      else
        String.to_integer(acc)
      end

    {val, rest}
  end
end

MockMCPServer.main()
