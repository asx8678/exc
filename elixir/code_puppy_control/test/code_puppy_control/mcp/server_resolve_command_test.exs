defmodule CodePuppyControl.MCP.ServerResolveCommandTest do
  @moduledoc """
  Tests for MCP.Server.resolve_command/1 — executable resolution for
  bare command names (npx, docker, etc.) before Port.spawn usage.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.MCP.Server

  describe "resolve_command/1" do
    test "resolves a bare command name via PATH" do
      # "echo" exists on all Unix systems
      assert {:ok, path} = Server.resolve_command("echo")
      assert is_binary(path)
      # Should be an absolute path
      assert String.starts_with?(path, "/")
    end

    test "returns absolute path unchanged" do
      assert {:ok, "/usr/bin/echo"} = Server.resolve_command("/usr/bin/echo")
    end

    test "returns relative path unchanged" do
      assert {:ok, "./some/binary"} = Server.resolve_command("./some/binary")
    end

    test "returns relative path with parent dir unchanged" do
      assert {:ok, "../bin/tool"} = Server.resolve_command("../bin/tool")
    end

    test "returns error for nonexistent bare command" do
      assert {:error, {:not_found, "totally_fake_cmd_xyz_12345"}} =
               Server.resolve_command("totally_fake_cmd_xyz_12345")
    end

    test "resolves npx if available on PATH" do
      case System.find_executable("npx") do
        nil ->
          # npx not available in CI — skip
          :ok

        _npx_path ->
          assert {:ok, path} = Server.resolve_command("npx")
          assert is_binary(path)
      end
    end

    test "resolves docker if available on PATH" do
      case System.find_executable("docker") do
        nil ->
          :ok

        _docker_path ->
          assert {:ok, path} = Server.resolve_command("docker")
          assert is_binary(path)
      end
    end

    test "handles empty string gracefully" do
      # Empty string is not an absolute or relative path, and won't be
      # found on PATH — should return not_found
      assert {:error, {:not_found, ""}} = Server.resolve_command("")
    end
  end
end
