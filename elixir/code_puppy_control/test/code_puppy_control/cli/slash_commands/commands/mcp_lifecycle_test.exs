defmodule CodePuppyControl.CLI.SlashCommands.Commands.MCPLifecycleTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.{CommandInfo, Registry}
  alias CodePuppyControl.CLI.SlashCommands.Commands.{MCP, MCPLifecycle}

  # async: false because Registry is a named singleton.

  @tmp_dir System.tmp_dir!()
  @test_home Path.join(@tmp_dir, "mcp_lifecycle_test_#{:erlang.unique_integer([:positive])}")

  setup do
    File.mkdir_p!(@test_home)

    orig_pup_ex = System.get_env("PUP_EX_HOME")
    orig_pup_home = System.get_env("PUP_HOME")
    orig_puppy_home = System.get_env("PUPPY_HOME")

    System.put_env("PUP_EX_HOME", @test_home)
    System.delete_env("PUP_HOME")
    System.delete_env("PUPPY_HOME")

    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.clear()

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

  # ── Helper ──────────────────────────────────────────────────────────────

  defp write_mcp_config(dir, data) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "mcp_servers.json")
    :ok = File.write!(path, Jason.encode!(data))
    path
  end

  # ── Subcommand: start ───────────────────────────────────────────────────

  describe "/mcp start" do
    test "shows usage hint when no server name given" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp start", %{})
        end)

      assert output =~ "Usage"
      assert output =~ "/mcp start"
    end

    test "format_start_result — success" do
      text = MCP.format_start_result("filesystem", {:ok, "filesystem-abc123"})
      assert text =~ "✓"
      assert text =~ "filesystem-abc123"
    end

    test "format_start_result — already running" do
      text = MCP.format_start_result("filesystem", {:ok, :already_running})
      assert text =~ "already running"
      assert text =~ "filesystem"
    end

    test "format_start_result — not configured" do
      text = MCP.format_start_result("nope", {:error, :not_configured})
      assert text =~ "not found in configuration"
      assert text =~ "/mcp list"
    end

    test "format_start_result — supervisor not running" do
      text = MCP.format_start_result("fs", {:error, :supervisor_not_running})
      assert text =~ "supervisor is not running"
    end

    test "format_start_result — generic error" do
      text = MCP.format_start_result("fs", {:error, :timeout})
      assert text =~ "Failed to start"
      assert text =~ ":timeout"
    end

    test "delegates to MCPLifecycle.format_start_result" do
      # Verify that MCP.format_start_result delegates correctly
      text = MCP.format_start_result("test", {:ok, "test-123"})
      direct = MCPLifecycle.format_start_result("test", {:ok, "test-123"})
      assert text == direct
    end
  end

  # ── Subcommand: stop ───────────────────────────────────────────────────

  describe "/mcp stop" do
    test "shows usage hint when no server name given" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp stop", %{})
        end)

      assert output =~ "Usage"
      assert output =~ "/mcp stop"
    end

    test "format_stop_result — success" do
      text = MCP.format_stop_result("filesystem", :ok)
      assert text =~ "✓"
      assert text =~ "Stopped"
      assert text =~ "filesystem"
    end

    test "format_stop_result — not running" do
      text = MCP.format_stop_result("filesystem", {:error, :not_running})
      assert text =~ "not currently running"
    end

    test "format_stop_result — supervisor not running" do
      text = MCP.format_stop_result("fs", {:error, :supervisor_not_running})
      assert text =~ "supervisor is not running"
    end

    test "format_stop_result — generic error" do
      text = MCP.format_stop_result("fs", {:error, :timeout})
      assert text =~ "Failed to stop"
    end
  end

  # ── Subcommand: restart ────────────────────────────────────────────────

  describe "/mcp restart" do
    test "shows usage hint when no server name given" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp restart", %{})
        end)

      assert output =~ "Usage"
      assert output =~ "/mcp restart"
    end

    test "format_restart_result — success" do
      text = MCP.format_restart_result("filesystem", {:ok, "filesystem-abc123"})
      assert text =~ "✓"
      assert text =~ "Restarted"
      assert text =~ "filesystem-abc123"
    end

    test "format_restart_result — not configured" do
      text = MCP.format_restart_result("nope", {:error, :not_configured})
      assert text =~ "not found in configuration"
      assert text =~ "/mcp list"
    end

    test "format_restart_result — supervisor not running" do
      text = MCP.format_restart_result("fs", {:error, :supervisor_not_running})
      assert text =~ "supervisor is not running"
    end

    test "format_restart_result — generic error" do
      text = MCP.format_restart_result("fs", {:error, :some_reason})
      assert text =~ "Failed to restart"
    end
  end

  # ── Subcommand: start-all ───────────────────────────────────────────────

  describe "/mcp start-all" do
    test "format_start_all_result — empty list shows no servers configured" do
      text = MCP.format_start_all_result([])
      assert text =~ "No MCP servers configured"
    end

    test "format_start_all_result — mixed results" do
      results = [
        {"fs", {:ok, "fs-abc123"}},
        {"gh", {:ok, :already_running}},
        {"bad", {:error, :not_configured}}
      ]

      text = MCP.format_start_all_result(results)
      assert text =~ "Starting all configured servers"
      assert text =~ "✓ Started: fs"
      assert text =~ "already running"
      assert text =~ "not configured"
      assert text =~ "1 started, 1 already running, 1 failed"
    end

    test "format_start_all_result — all started" do
      results = [
        {"fs", {:ok, "fs-abc"}},
        {"gh", {:ok, "gh-def"}}
      ]

      text = MCP.format_start_all_result(results)
      assert text =~ "2 started, 0 already running, 0 failed"
    end
  end

  # ── Subcommand: stop-all ────────────────────────────────────────────────

  describe "/mcp stop-all" do
    test "format_stop_all_result — empty list shows no servers running" do
      text = MCP.format_stop_all_result([])
      assert text =~ "No MCP servers currently running"
    end

    test "format_stop_all_result — mixed results" do
      results = [
        {"fs", :ok},
        {"gh", {:error, :timeout}}
      ]

      text = MCP.format_stop_all_result(results)
      assert text =~ "Stopping all running servers"
      assert text =~ "✓ Stopped: fs"
      assert text =~ "✗ gh"
      assert text =~ "1 stopped, 1 failed"
    end

    test "format_stop_all_result — all stopped" do
      results = [{"fs", :ok}, {"gh", :ok}]

      text = MCP.format_stop_all_result(results)
      assert text =~ "2 stopped, 0 failed"
    end
  end

  # ── Help includes lifecycle commands ─────────────────────────────────────

  describe "help includes lifecycle commands" do
    test "format_help includes start/stop/restart/start-all/stop-all" do
      text = MCP.format_help()
      assert text =~ "/mcp start"
      assert text =~ "/mcp stop"
      assert text =~ "/mcp restart"
      assert text =~ "/mcp start-all"
      assert text =~ "/mcp stop-all"
      assert text =~ "Lifecycle Commands"
    end

    test "/mcp help shows lifecycle commands via IO" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp help", %{})
        end)

      assert output =~ "/mcp start"
      assert output =~ "/mcp stop"
      assert output =~ "/mcp restart"
    end
  end

  # ── Case-insensitive lifecycle subcommands ───────────────────────────────

  describe "case-insensitive lifecycle subcommands" do
    test "/mcp START shows usage" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp START", %{})
        end)

      assert output =~ "Usage"
    end

    test "/mcp STOP shows usage" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp STOP", %{})
        end)

      assert output =~ "Usage"
    end

    test "/mcp RESTART shows usage" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp RESTART", %{})
        end)

      assert output =~ "Usage"
    end

    test "/mcp START-ALL routes correctly" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp START-ALL", %{})
        end)

      # Supervisor not running → empty result or no servers configured
      assert output =~ "No MCP servers configured" or output =~ "Starting all" or
               output =~ "supervisor"
    end

    test "/mcp STOP-ALL routes correctly" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp STOP-ALL", %{})
        end)

      assert output =~ "No MCP servers currently running" or output =~ "Stopping all" or
               output =~ "supervisor"
    end
  end

  # ── Canonical name preservation on start/restart (Critic 1 regression) ──

  describe "canonical name preservation on start/restart" do
    test "/mcp start myserver preserves canonical casing in result" do
      write_mcp_config(@test_home, %{
        "MyServer" => %{"command" => "echo", "args" => [], "env" => %{}}
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp start myserver", %{})
        end)

      # Should NOT say "not configured" because "myserver" should match "MyServer"
      refute output =~ "not found in configuration"
      # Supervisor likely not running, so we'll see that error — but the key
      # thing is it didn't say "not configured"
    end

    test "/mcp RESTART myserver preserves canonical casing" do
      write_mcp_config(@test_home, %{
        "MyServer" => %{"command" => "echo", "args" => [], "env" => %{}}
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp RESTART myserver", %{})
        end)

      refute output =~ "not found in configuration"
    end

    test "/mcp start MixedCase-Server matches config case-insensitively" do
      write_mcp_config(@test_home, %{
        "MixedCase-Server" => %{"command" => "echo", "args" => [], "env" => %{}}
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, _} = MCP.handle_mcp("/mcp start mixedcase-server", %{})
        end)

      refute output =~ "not found in configuration"
    end
  end

  # ── MCPLifecycle.format_error_reason ────────────────────────────────────

  describe "MCPLifecycle.format_error_reason/1" do
    test "formats known error reasons" do
      assert MCPLifecycle.format_error_reason(:not_configured) == "not configured"
      assert MCPLifecycle.format_error_reason(:not_running) == "not running"
      assert MCPLifecycle.format_error_reason(:supervisor_not_running) == "supervisor not running"
    end

    test "inspects unknown error reasons" do
      assert MCPLifecycle.format_error_reason(:timeout) == ":timeout"
      assert MCPLifecycle.format_error_reason("weird") == ~s("weird")
    end
  end
end
