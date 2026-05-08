defmodule CodePuppyControl.Support.MockMCPServerHelper do
  @moduledoc """
  Test helper for the Elixir stdio-based mock MCP server.

  Provides `mock_server_command/0` and `mock_server_args/0` so tests can
  spawn the mock server via Port without knowing its location or the
  `elixir` executable path.

  ## Usage in tests

      alias CodePuppyControl.Support.MockMCPServerHelper, as: MockHelper

      Supervisor.start_server(
        server_id: sid,
        name: "mock-test",
        command: MockHelper.mock_server_command(),
        args: MockHelper.mock_server_args(),
        env: %{}
      )

  ## Design

  The mock server is a standalone `.exs` script that speaks MCP JSON-RPC
  over stdio (newline-delimited).  It includes a tiny self-contained
  JSON codec and requires no Mix deps or Elixir 1.18+ stdlib JSON,
  making it compatible with the project's Elixir `~> 1.15` requirement.
  No Python runtime needed at test time.
  """

  @script_path Path.join([__DIR__, "mock_mcp_server.exs"])

  @doc """
  Returns the executable command for the mock MCP server.

  Falls back to `nil` if `elixir` is not on PATH (tests using this
  should skip with `flunk/1` in that case).
  """
  @spec mock_server_command() :: String.t() | nil
  def mock_server_command do
    System.find_executable("elixir")
  end

  @doc """
  Returns the command-line arguments needed to launch the mock server.

  Typically `[path_to_script]`. The path is verified at compile time;
  if the script is missing, raises at compile time.
  """
  @spec mock_server_args() :: [String.t()]
  def mock_server_args do
    [@script_path]
  end

  @doc """
  Returns `true` when both `elixir` and the mock server script are
  available.  Use this to conditionally skip integration tests.
  """
  @spec available?() :: boolean()
  def available? do
    mock_server_command() != nil and File.exists?(@script_path)
  end

  @doc """
  Raises if the mock server is not available.
  Call in `setup` blocks before any test that needs the server.
  """
  @spec require_available!() :: :ok | no_return()
  def require_available! do
    unless available?() do
      raise ExUnit.AssertionError,
        message:
          "Elixir stdio mock MCP server not available — elixir not on PATH or script missing"
    end

    :ok
  end
end
