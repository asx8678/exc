defmodule CodePuppyControl.Support.StdioTestHelper do
  @moduledoc """
  Test helper functions for stdio-based transport testing.

  Provides `capture_stdio/2` which runs the stdio service with given inputs
  and captures the output for testing.
  """

  @doc """
  Capture stdio output during service execution.

  Takes a list of JSON-RPC request strings, runs the stdio service,
  and returns the first JSON-RPC *response* (a line with an "id" field),
  skipping the `_ready` handshake notification and any non-JSON noise.

  ## Options

    * `:env` — list of `{key, value}` tuples passed to the subprocess
      via `System.cmd/3`. Useful for overriding Application config
      at subprocess startup (e.g. `PUP_BUNDLED_MODELS_PATH`).

  ## Examples

      request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}
      output = capture_stdio([Jason.encode!(request)])
      response = Jason.decode!(output)
      assert response["result"]["pong"] == true

  """
  def capture_stdio(inputs, _fun \\ nil, opts \\ []) do
    do_capture_stdio(inputs, opts)
  end

  defp do_capture_stdio(inputs, opts) do
    # Write inputs to a temp file
    input_file =
      Path.join(System.tmp_dir!(), "stdio_input_#{:erlang.unique_integer([:positive])}.jsonl")

    File.write!(input_file, Enum.join(inputs, "\n") <> "\n")

    # Find the project root (where mix.exs lives)
    # __DIR__ is test/support/
    # We need to go up to elixir/code_puppy_control/
    project_path = Path.expand(Path.join(__DIR__, "../.."))

    # Verify mix.exs exists
    result =
      if File.exists?(Path.join(project_path, "mix.exs")) do
        # Use shell command with explicit cd to the project directory.
        # Do NOT merge stderr into stdout — Logger/compilation noise belongs
        # on stderr and would pollute JSON-RPC output parsing.
        env = Keyword.get(opts, :env, [])

        {output, exit_code} =
          System.cmd(
            "sh",
            [
              "-c",
              "cd #{project_path} && cat #{input_file} | mix code_puppy.stdio_service"
            ],
            env: env,
            stderr_to_stdout: false
          )

        if exit_code == 0 do
          find_json_rpc_response(output)
        else
          # Return error structure for non-zero exit
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{
              "code" => -32000,
              "message" => "Service exited with code #{exit_code}: #{output}"
            }
          })
        end
      else
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => %{
            "code" => -32000,
            "message" => "Could not find mix.exs in #{project_path}"
          }
        })
      end

    # Clean up
    File.rm(input_file)

    result
  end

  @doc """
  Parse multi-line output and return the first JSON-RPC response.

  Skips:
  - Non-JSON lines (compilation noise, blank lines)
  - The `_ready` handshake notification (has "method" but no "id")

  Returns the first line that decodes as a JSON-RPC response (has "id"),
  or "{}" if none found.
  """
  def find_json_rpc_response(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, "{") and &1 != ""))
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} when is_map(decoded) ->
          # JSON-RPC responses have an "id" field; notifications don't.
          # The _ready handshake is a notification: {"jsonrpc":"2.0","method":"_ready","params":{}}
          if Map.has_key?(decoded, "id") do
            line
          else
            # Notification — skip it
            nil
          end

        _ ->
          nil
      end
    end)
    |> case do
      nil -> "{}"
      line -> line
    end
  end
end
