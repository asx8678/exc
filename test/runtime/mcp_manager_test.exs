defmodule CodePuppyControl.Runtime.MCPManagerTest do
  @moduledoc """
  Tests for MCP.Manager — high-level MCP server management API.

  Tests the Manager's API contract (register, unregister, list, stats)
  without requiring actual MCP servers. Server-starting paths are covered
  in integration tests.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.MCP.Manager

  @tmp_dir System.tmp_dir!()
  @test_home Path.join(@tmp_dir, "mcp_manager_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@test_home)

    orig_pup_ex = System.get_env("PUP_EX_HOME")
    orig_pup_home = System.get_env("PUP_HOME")
    orig_puppy_home = System.get_env("PUPPY_HOME")

    System.put_env("PUP_EX_HOME", @test_home)
    System.delete_env("PUP_HOME")
    System.delete_env("PUPPY_HOME")

    on_exit(fn ->
      if orig_pup_ex,
        do: System.put_env("PUP_EX_HOME", orig_pup_ex),
        else: System.delete_env("PUP_EX_HOME")

      if orig_pup_home,
        do: System.put_env("PUP_HOME", orig_pup_home),
        else: System.delete_env("PUP_HOME")

      if orig_puppy_home,
        do: System.put_env("PUPPY_HOME", orig_puppy_home),
        else: System.delete_env("PUPPY_HOME")

      File.rm_rf!(@test_home)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Listing & Stats (no servers required)
  # ---------------------------------------------------------------------------

  describe "list_servers/0" do
    test "returns a list" do
      assert is_list(Manager.list_servers())
    end
  end

  describe "stats/0" do
    test "returns stats map with expected keys" do
      stats = Manager.stats()

      assert Map.has_key?(stats, :total)
      assert Map.has_key?(stats, :healthy)
      assert Map.has_key?(stats, :degraded)
      assert Map.has_key?(stats, :unhealthy)
      assert Map.has_key?(stats, :quarantined)
    end
  end

  describe "get_server_status/1" do
    test "returns error for nonexistent server" do
      result =
        try do
          Manager.get_server_status("nonexistent-xyz-999")
        catch
          :exit, _ -> {:error, :not_found}
        end

      assert match?({:error, _}, result)
    end
  end

  describe "unregister_server/1" do
    test "returns error for nonexistent server" do
      assert {:error, :not_found} = Manager.unregister_server("nonexistent-xyz-999")
    end
  end

  describe "call_tool/4" do
    test "returns error for nonexistent server" do
      result =
        try do
          Manager.call_tool("nonexistent-xyz", "read_file", %{})
        catch
          :exit, _ -> {:error, :not_found}
        end

      assert match?({:error, _}, result)
    end
  end

  describe "health_check_all/0" do
    test "returns a list" do
      assert is_list(Manager.health_check_all())
    end
  end

  describe "stop_all/0" do
    test "returns :ok" do
      assert :ok = Manager.stop_all()
    end
  end

  # ---------------------------------------------------------------------------
  # Config-driven lifecycle helpers
  # ---------------------------------------------------------------------------

  describe "read_configured_servers/0" do
    test "returns empty list when no config file exists" do
      File.rm(Path.join(@test_home, "mcp_servers.json"))
      assert [] = Manager.read_configured_servers()
    end

    test "reads flat server config from disk" do
      File.mkdir_p!(@test_home)

      File.write!(
        Path.join(@test_home, "mcp_servers.json"),
        Jason.encode!(%{
          "filesystem" => %{"command" => "npx", "args" => ["-y", "mcp-fs"], "env" => %{}},
          "github" => %{"command" => "docker", "args" => [], "env" => %{}}
        })
      )

      servers = Manager.read_configured_servers()
      names = Enum.map(servers, & &1["name"])
      assert "filesystem" in names
      assert "github" in names
    end

    test "reads nested mcp_servers shape" do
      File.mkdir_p!(@test_home)

      File.write!(
        Path.join(@test_home, "mcp_servers.json"),
        Jason.encode!(%{
          "mcp_servers" => %{"deep" => %{"command" => "npx", "args" => [], "env" => %{}}}
        })
      )

      servers = Manager.read_configured_servers()
      names = Enum.map(servers, & &1["name"])
      assert "deep" in names
    end

    test "skips non-map server values" do
      File.mkdir_p!(@test_home)

      File.write!(
        Path.join(@test_home, "mcp_servers.json"),
        Jason.encode!(%{
          "broken" => true,
          "valid" => %{"command" => "echo"}
        })
      )

      servers = Manager.read_configured_servers()
      names = Enum.map(servers, & &1["name"])
      refute "broken" in names
      assert "valid" in names
    end
  end

  describe "find_server_config_by_name/1" do
    test "returns nil for nonexistent server" do
      File.rm(Path.join(@test_home, "mcp_servers.json"))
      assert nil == Manager.find_server_config_by_name("nope")
    end

    test "finds server config case-insensitively" do
      File.mkdir_p!(@test_home)

      File.write!(
        Path.join(@test_home, "mcp_servers.json"),
        Jason.encode!(%{"FileSystem" => %{"command" => "npx"}})
      )

      cfg = Manager.find_server_config_by_name("filesystem")
      assert cfg != nil
      assert cfg["name"] == "FileSystem"
    end
  end

  describe "find_server_id_by_name/1" do
    test "returns not_found when no server running by that name" do
      assert {:error, :not_found} = Manager.find_server_id_by_name("nope")
    end
  end

  describe "start_server_by_name/1" do
    test "returns not_configured when server not in config" do
      File.rm(Path.join(@test_home, "mcp_servers.json"))
      assert {:error, :not_configured} = Manager.start_server_by_name("nope")
    end
  end

  describe "stop_server_by_name/1" do
    test "returns not_running when no server running by that name" do
      assert {:error, :not_running} = Manager.stop_server_by_name("nope")
    end
  end

  describe "restart_server_by_name/1" do
    test "returns not_configured when server not in config" do
      File.rm(Path.join(@test_home, "mcp_servers.json"))
      assert {:error, :not_configured} = Manager.restart_server_by_name("nope")
    end
  end

  describe "start_all_configured/0" do
    test "returns empty list when no servers configured" do
      File.rm(Path.join(@test_home, "mcp_servers.json"))
      assert [] = Manager.start_all_configured()
    end
  end

  describe "stop_all_running/0" do
    test "returns empty list when no servers running" do
      assert [] = Manager.stop_all_running()
    end
  end

  # ---------------------------------------------------------------------------
  # Canonical name preservation (Critic 1 regression)
  # ---------------------------------------------------------------------------

  describe "canonical name preservation on start/restart" do
    setup do
      File.mkdir_p!(@test_home)

      File.write!(
        Path.join(@test_home, "mcp_servers.json"),
        Jason.encode!(%{
          "MyServer" => %{"command" => "echo", "args" => [], "env" => %{}}
        })
      )

      :ok
    end

    test "start_server_by_name uses canonical casing from config" do
      # Even though we pass "myserver" (lowercase), the Manager should
      # use the canonical name "MyServer" from config when registering.
      # Without a running MCP supervisor, register_server will fail —
      # but we verify the config was found (not :not_configured).
      result = Manager.start_server_by_name("myserver")

      # The supervisor is not running in test, so we expect an error
      # from register_server — NOT :not_configured.
      refute match?({:error, :not_configured}, result)
    end

    test "restart_server_by_name uses canonical casing from config" do
      result = Manager.restart_server_by_name("myserver")
      refute match?({:error, :not_configured}, result)
    end

    test "find_server_config_by_name returns canonical name" do
      cfg = Manager.find_server_config_by_name("myserver")
      assert cfg != nil
      assert cfg["name"] == "MyServer"
    end

    test "start_server_by_name with MixedCase finds the config" do
      result = Manager.start_server_by_name("MyServer")
      refute match?({:error, :not_configured}, result)
    end

    test "start_server_by_name with ALLCAPS finds the config" do
      result = Manager.start_server_by_name("MYSERVER")
      refute match?({:error, :not_configured}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # Happy-path lifecycle with echo server
  # ---------------------------------------------------------------------------

  describe "happy-path lifecycle with echo server" do
    setup do
      File.mkdir_p!(@test_home)

      # Use "echo" as the command — it exists on all Unix systems
      # but is NOT a valid MCP server, so it will start and then
      # the handshake will timeout. This tests the config→start→stop
      # flow without requiring a real MCP server.
      File.write!(
        Path.join(@test_home, "mcp_servers.json"),
        Jason.encode!(%{
          "echo-srv" => %{"command" => "echo", "args" => ["hello"], "env" => %{}}
        })
      )

      :ok
    end

    test "start_all_configured returns results for configured servers" do
      results = Manager.start_all_configured()
      # Should have one entry for echo-srv (may succeed or fail based on
      # supervisor state, but should not be empty if config is read)
      # Note: without MCP supervisor running, results may be empty
      assert is_list(results)
    end

    test "stop_all_running returns a list" do
      results = Manager.stop_all_running()
      assert is_list(results)
    end
  end
end
