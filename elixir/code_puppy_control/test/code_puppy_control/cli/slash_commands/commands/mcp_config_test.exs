defmodule CodePuppyControl.CLI.SlashCommands.Commands.MCPConfigTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.MCP

  # async: false because Registry is a named singleton.
  # Tests config-file schema variants, malformed entries, and regressions.

  @tmp_dir System.tmp_dir!()
  @test_home Path.join(@tmp_dir, "mcp_config_test_#{:erlang.unique_integer([:positive])}")

  setup do
    # ── Isolate config from real home ──────────────────────────────────────
    File.mkdir_p!(@test_home)

    orig_pup_ex = System.get_env("PUP_EX_HOME")
    orig_pup_home = System.get_env("PUP_HOME")
    orig_puppy_home = System.get_env("PUPPY_HOME")

    System.put_env("PUP_EX_HOME", @test_home)
    System.delete_env("PUP_HOME")
    System.delete_env("PUPPY_HOME")

    # Start the Registry GenServer if not already running
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()

    # Register /mcp command
    :ok =
      Registry.register(
        CommandInfo.new(
          name: "mcp",
          description: "Show MCP server status and management",
          handler: &MCP.handle_mcp/2,
          usage: "/mcp [help|list|status|start|stop|restart|start-all|stop-all]",
          category: "mcp"
        )
      )

    on_exit(fn ->
      # Restore env
      if orig_pup_ex,
        do: System.put_env("PUP_EX_HOME", orig_pup_ex),
        else: System.delete_env("PUP_EX_HOME")

      if orig_pup_home,
        do: System.put_env("PUP_HOME", orig_pup_home),
        else: System.delete_env("PUP_HOME")

      if orig_puppy_home,
        do: System.put_env("PUPPY_HOME", orig_puppy_home),
        else: System.delete_env("PUPPY_HOME")

      Registry.clear()
      Registry.register_builtin_commands()
      File.rm_rf!(@test_home)
    end)

    state = %{session_id: "test-session", running: true}
    {:ok, state: state, test_home: @test_home}
  end

  # ── Helper: write mcp_servers.json into isolated home ───────────────────

  defp write_mcp_config(dir, data) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "mcp_servers.json")
    :ok = File.write!(path, Jason.encode!(data))
    path
  end

  # ── Config schema: flat vs nested ───────────────────────────────────────

  describe "read_configured_servers — schema support" do
    test "reads flat top-level map (fixture shape)" do
      write_mcp_config(@test_home, %{
        "filesystem" => %{
          "command" => "npx",
          "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
          "env" => %{}
        },
        "github" => %{
          "command" => "docker",
          "args" => ["run", "-i", "--rm", "ghcr.io/github/github-mcp-server"],
          "env" => %{"GITHUB_TOKEN" => "${GITHUB_TOKEN}"}
        }
      })

      {configured, _runtime} = MCP.fetch_server_data()
      names = Enum.map(configured, & &1["name"])
      assert "filesystem" in names
      assert "github" in names
    end

    test "reads nested {\"mcp_servers\": {...}} shape" do
      write_mcp_config(@test_home, %{
        "mcp_servers" => %{
          "deep-srv" => %{"command" => "npx", "args" => [], "env" => %{}}
        }
      })

      {configured, _runtime} = MCP.fetch_server_data()
      names = Enum.map(configured, & &1["name"])
      assert "deep-srv" in names
    end

    test "returns empty for non-map JSON (e.g. array)" do
      File.mkdir_p!(@test_home)
      File.write!(Path.join(@test_home, "mcp_servers.json"), Jason.encode!([1, 2, 3]))

      {configured, _runtime} = MCP.fetch_server_data()
      assert configured == []
    end

    test "returns empty when file missing" do
      File.rm(Path.join(@test_home, "mcp_servers.json"))

      {configured, _runtime} = MCP.fetch_server_data()
      assert configured == []
    end
  end

  # ── Adversarial configured-server cases ─────────────────────────────────

  describe "malformed-but-JSON-valid entries" do
    test "skips non-map server values (e.g. \"broken\": true)" do
      write_mcp_config(@test_home, %{
        "broken" => true,
        "also_broken" => "just a string",
        "valid" => %{"command" => "npx", "args" => [], "env" => %{}}
      })

      {configured, _runtime} = MCP.fetch_server_data()
      names = Enum.map(configured, & &1["name"])
      assert "valid" in names
      refute "broken" in names
      refute "also_broken" in names
    end

    test "entirely non-map values → empty list" do
      write_mcp_config(@test_home, %{
        "a" => 1,
        "b" => true,
        "c" => "hello"
      })

      {configured, _runtime} = MCP.fetch_server_data()
      assert configured == []
    end

    test "/mcp does not crash with malformed entries" do
      write_mcp_config(@test_home, %{
        "broken" => true,
        "ok" => %{"command" => "echo"}
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp list", %{})
        end)

      assert output =~ "ok"
      refute output =~ "broken"
    end
  end

  # ── Server name case-preservation regression ──────────────────────────────

  describe "/mcp status <Name> preserves server name casing" do
    test "routes to the correct server preserving original name" do
      write_mcp_config(@test_home, %{
        "MyServer" => %{"command" => "npx", "args" => [], "env" => %{}}
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp status MyServer", %{})
        end)

      # Should find the server (not "not found" because it was lowercased)
      refute output =~ "not found"
      assert output =~ "MyServer"
    end

    test "/mcp STATUS MyServer (uppercase subcommand) still preserves server name" do
      write_mcp_config(@test_home, %{
        "MyServer" => %{"command" => "npx", "args" => [], "env" => %{}}
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp STATUS MyServer", %{})
        end)

      refute output =~ "not found"
      assert output =~ "MyServer"
    end
  end

  # ── Malformed env/args in server config (regression) ─────────────

  describe "/mcp status <name> with malformed env/args" do
    test "does not crash when env is a string instead of a map" do
      configured = [
        %{"name" => "weird", "command" => "echo", "env" => "oops", "args" => []}
      ]

      {:ok, text} = MCP.format_server_status("weird", configured, [])
      assert text =~ "Server: weird"
      assert text =~ "echo"
      # env fallback: 0 keys (not a crash)
      assert text =~ "0"
    end

    test "does not crash when args is a string instead of a list" do
      configured = [
        %{"name" => "borked", "command" => "echo", "args" => "not-a-list", "env" => %{}}
      ]

      {:ok, text} = MCP.format_server_status("borked", configured, [])
      assert text =~ "Server: borked"
      # args fallback: [] (not a crash)
      assert text =~ "[]"
    end

    test "does not crash when both env and args are wrong types" do
      configured = [
        %{"name" => "mega-bork", "command" => "echo", "env" => 42, "args" => nil}
      ]

      {:ok, text} = MCP.format_server_status("mega-bork", configured, [])
      assert text =~ "Server: mega-bork"
    end

    test "end-to-end /mcp status weird with malformed env in config file" do
      write_mcp_config(@test_home, %{
        "weird" => %{"command" => "echo", "env" => "oops"}
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp status weird", %{})
        end)

      refute output =~ "not found"
      assert output =~ "weird"
      assert output =~ "echo"
    end
  end
end
