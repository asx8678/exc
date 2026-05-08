defmodule CodePuppyControl.CLI.SlashCommands.Commands.MCPTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Dispatcher, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.MCP

  # async: false because Registry is a named singleton.

  @tmp_dir System.tmp_dir!()
  @test_home Path.join(@tmp_dir, "mcp_test_#{:erlang.unique_integer([:positive])}")

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

  # ── Help subcommand ──────────────────────────────────────────────────────

  describe "/mcp help" do
    test "shows MCP command help" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp help", %{})
        end)

      assert output =~ "MCP Server Management Commands"
      assert output =~ "/mcp list"
      assert output =~ "/mcp status"
      assert output =~ "/mcp help"
    end

    test "format_help returns help text" do
      text = MCP.format_help()
      assert text =~ "MCP Server Management Commands"
      assert text =~ "/mcp list"
      assert text =~ "/mcp status"
    end
  end

  # ── List subcommand ──────────────────────────────────────────────────────

  describe "/mcp list" do
    test "shows no servers when none configured" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp list", %{})
        end)

      assert output =~ "No MCP servers configured"
    end

    test "format_list with configured servers from realistic data" do
      configured = [
        %{
          "name" => "filesystem",
          "command" => "npx",
          "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
          "env" => %{}
        }
      ]

      text = MCP.format_list(configured, [])
      assert text =~ "filesystem"
      assert text =~ "npx"
      assert text =~ "1 configured"
    end

    test "format_list with empty data shows no servers message" do
      text = MCP.format_list([], [])
      assert text =~ "No MCP servers configured"
    end

    test "format_list with configured servers shows them" do
      configured = [
        %{
          "name" => "filesystem",
          "command" => "npx",
          "args" => ["-y", "mcp-server"],
          "env" => %{}
        },
        %{"name" => "github", "command" => "npx", "args" => ["-y", "mcp-github"], "env" => %{}}
      ]

      text = MCP.format_list(configured, [])
      assert text =~ "filesystem"
      assert text =~ "github"
      assert text =~ "2 configured"
    end

    test "format_list with runtime data shows health" do
      configured = [
        %{"name" => "filesystem", "command" => "npx"}
      ]

      runtime = [
        %{
          name: "filesystem",
          status: :running,
          health: :healthy,
          error_count: 0,
          quarantined: false
        }
      ]

      text = MCP.format_list(configured, runtime)
      assert text =~ "filesystem"
      assert text =~ "healthy"
    end

    test "stopped configured server shows stopped icon" do
      configured = [%{"name" => "idle-srv", "command" => "echo"}]

      text = MCP.format_list(configured, [])
      # Stopped = no runtime entry → faint ✗
      assert text =~ "idle-srv"
      assert text =~ "✗"
    end
  end

  # ── Status subcommand ────────────────────────────────────────────────────

  describe "/mcp status" do
    test "shows no servers when none configured" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp status", %{})
        end)

      assert output =~ "No MCP servers configured"
    end

    test "format_status_dashboard with servers" do
      configured = [
        %{"name" => "filesystem", "command" => "npx"},
        %{"name" => "github", "command" => "npx"}
      ]

      runtime = [
        %{
          name: "filesystem",
          status: :running,
          health: :healthy,
          error_count: 0,
          quarantined: false
        }
      ]

      text = MCP.format_status_dashboard(configured, runtime)
      assert text =~ "MCP Status Dashboard"
      assert text =~ "filesystem"
      assert text =~ "github"
    end

    test "format_status_dashboard shows running status" do
      configured = [%{"name" => "test-srv", "command" => "echo"}]

      runtime = [
        %{
          name: "test-srv",
          status: :running,
          health: :healthy,
          error_count: 0,
          quarantined: false
        }
      ]

      text = MCP.format_status_dashboard(configured, runtime)
      assert text =~ "running"
      assert text =~ "healthy"
    end

    test "stopped server dashboard uses ✗ icon, not literal 'stopped'" do
      configured = [%{"name" => "idle-srv", "command" => "echo"}]

      text = MCP.format_status_dashboard(configured, [])
      # Must contain the stopped icon (✗), NOT the literal word as the icon
      assert text =~ "✗"
      # The status column should say "stopped" — but the *icon* must be ✗
      refute text =~ ~r/^\s+stopped \w+.*stopped/, "icon should be ✗, not literal 'stopped'"
    end

    test "stopped server with atom :status renders icon correctly" do
      configured = [%{"name" => "srv", "command" => "echo"}]

      runtime = [
        %{
          name: "srv",
          status: :stopped,
          health: :unknown,
          error_count: 0,
          quarantined: false
        }
      ]

      text = MCP.format_status_dashboard(configured, runtime)
      assert text =~ "✗"
      assert text =~ "stopped"
    end

    test "stopped server with string status renders icon correctly" do
      configured = [%{"name" => "srv", "command" => "echo"}]

      runtime = [
        %{
          name: "srv",
          status: "stopped",
          health: :unknown,
          error_count: 0,
          quarantined: false
        }
      ]

      text = MCP.format_status_dashboard(configured, runtime)
      assert text =~ "✗"
      assert text =~ "stopped"
    end

    test "format_status_dashboard shows crashed server" do
      configured = [%{"name" => "crash-srv", "command" => "false"}]

      runtime = [
        %{
          name: "crash-srv",
          status: :crashed,
          health: :unhealthy,
          error_count: 3,
          quarantined: true
        }
      ]

      text = MCP.format_status_dashboard(configured, runtime)
      assert text =~ "crashed"
      assert text =~ "unhealthy"
      assert text =~ "3 errors"
      assert text =~ "Quarantined"
    end
  end

  # ── Status <name> subcommand ─────────────────────────────────────────────

  describe "/mcp status <name>" do
    test "shows detailed status for a running server" do
      configured = [
        %{
          "name" => "filesystem",
          "command" => "npx",
          "args" => ["-y", "mcp-server"],
          "env" => %{}
        }
      ]

      runtime = [
        %{
          name: "filesystem",
          status: :running,
          health: :healthy,
          error_count: 0,
          quarantined: false,
          server_id: "filesystem-abc123",
          quarantine_until: nil,
          last_health_check: "2026-04-19T12:00:00Z"
        }
      ]

      {:ok, text} = MCP.format_server_status("filesystem", configured, runtime)
      assert text =~ "Server: filesystem"
      assert text =~ "npx"
      assert text =~ "running"
      assert text =~ "healthy"
      assert text =~ "filesystem-abc123"
    end

    test "shows 'Not currently running' for configured but not running server" do
      configured = [
        %{"name" => "filesystem", "command" => "npx"}
      ]

      {:ok, text} = MCP.format_server_status("filesystem", configured, [])
      assert text =~ "filesystem"
      assert text =~ "Not currently running"
    end

    test "returns not_found for unknown server" do
      assert {:error, :not_found} = MCP.format_server_status("nope", [], [])
    end

    test "shows quarantine info when server is quarantined" do
      configured = [%{"name" => "bad-srv", "command" => "false"}]

      runtime = [
        %{
          name: "bad-srv",
          status: :running,
          health: :unhealthy,
          error_count: 5,
          quarantined: true,
          server_id: "bad-srv-xyz",
          quarantine_until: "2026-04-19T13:00:00Z",
          last_health_check: "2026-04-19T12:30:00Z"
        }
      ]

      {:ok, text} = MCP.format_server_status("bad-srv", configured, runtime)
      assert text =~ "Quarantined: true"
      assert text =~ "Quarantined until"
      assert text =~ "5"
    end
  end

  # ── Default (bare /mcp) ──────────────────────────────────────────────────

  describe "/mcp (no args)" do
    test "shows list by default" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp", %{})
        end)

      # Bare /mcp should show the list (same as /mcp list)
      assert output =~ "MCP Servers" or output =~ "No MCP servers configured"
    end
  end

  # ── Unknown subcommand ──────────────────────────────────────────────────

  describe "unknown subcommand" do
    test "shows error for unknown subcommand" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp bogus", %{})
        end)

      assert output =~ "Unknown MCP subcommand"
      assert output =~ "bogus"
      assert output =~ "/mcp help"
    end
  end

  # ── Case-insensitive subcommands ────────────────────────────────────────

  describe "case-insensitive subcommands" do
    test "/mcp HELP works" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp HELP", %{})
        end)

      assert output =~ "MCP Server Management Commands"
    end

    test "/mcp List works" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp List", %{})
        end)

      assert output =~ "MCP Servers" or output =~ "No MCP servers configured"
    end

    test "/mcp STATUS works" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp STATUS", %{})
        end)

      assert output =~ "MCP Status Dashboard" or output =~ "No MCP servers configured"
    end
  end

  # ── Registration and dispatch ────────────────────────────────────────────

  describe "registration and dispatch" do
    test "/mcp is registered and dispatchable" do
      assert {:ok, _} = Registry.get("mcp")
    end

    test "/mcp dispatches via Dispatcher" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:ok, {:continue, _}} = Dispatcher.dispatch("/mcp help", %{})
        end)

      assert output =~ "MCP Server Management Commands"
    end

    test "/mcp appears in all_names for tab completion" do
      names = Registry.all_names()
      assert "mcp" in names
    end

    test "/mcp appears in list_all" do
      commands = Registry.list_all()
      assert Enum.any?(commands, &(&1.name == "mcp"))
    end

    test "/mcp is in mcp category" do
      commands = Registry.list_by_category("mcp")
      mcp_cmd = Enum.find(commands, &(&1.name == "mcp"))
      assert mcp_cmd != nil
      assert mcp_cmd.category == "mcp"
    end

    test "/mcp usage is correct" do
      {:ok, cmd} = Registry.get("mcp")
      assert cmd.usage =~ "start"
      assert cmd.usage =~ "stop"
      assert cmd.usage =~ "restart"
    end

    test "/mcp has detailed_help when registered with it" do
      Registry.clear()

      :ok =
        Registry.register(
          CommandInfo.new(
            name: "mcp",
            description: "Show MCP server status",
            handler: &MCP.handle_mcp/2,
            category: "mcp",
            detailed_help: "View configured MCP servers and their runtime status."
          )
        )

      {:ok, cmd} = Registry.get("mcp")
      assert cmd.detailed_help != nil
      assert cmd.detailed_help =~ "MCP"
    end
  end

  # ── fetch_server_data ────────────────────────────────────────────────────

  describe "fetch_server_data" do
    test "returns empty lists when no config file exists" do
      File.rm(Path.join(@test_home, "mcp_servers.json"))

      {configured, runtime} = MCP.fetch_server_data()
      assert is_list(configured)
      assert is_list(runtime)
      assert configured == []
    end
  end

  # ── Pure formatting edge cases ────────────────────────────────────────────

  describe "format_list edge cases" do
    test "server with missing command shows dash" do
      configured = [%{"name" => "minimal"}]
      text = MCP.format_list(configured, [])
      assert text =~ "minimal"
      assert text =~ "—"
    end

    test "server with unknown name falls back" do
      configured = [%{"command" => "echo"}]
      text = MCP.format_list(configured, [])
      assert text =~ "unknown"
    end
  end

  describe "format_server_status edge cases" do
    test "server with only runtime data (not in config) still shows" do
      runtime = [
        %{
          name: "runtime-only",
          status: :running,
          health: :healthy,
          error_count: 0,
          quarantined: false,
          server_id: "rt-123",
          quarantine_until: nil,
          last_health_check: nil
        }
      ]

      {:ok, text} = MCP.format_server_status("runtime-only", [], runtime)
      assert text =~ "Server: runtime-only"
      assert text =~ "running"
    end

    test "server with no config or runtime data returns not found" do
      assert {:error, :not_found} = MCP.format_server_status("ghost", [], [])
    end
  end

  # ── IO dispatch integration ──────────────────────────────────────────────

  describe "/mcp status <name> via IO" do
    test "shows not found message for missing server" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp status nonexistent", %{})
        end)

      assert output =~ "not found"
      assert output =~ "/mcp list"
    end
  end
end
