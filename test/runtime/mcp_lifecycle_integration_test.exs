defmodule CodePuppyControl.Runtime.MCPLifecycleIntegrationTest do
  @moduledoc """
  Integration tests for MCP server lifecycle with a real configured mock server.

  Exercises the full supervised lifecycle:
  - Start a mock MCP server via MCP.Supervisor / MCP.Manager
  - Verify status, health, and list membership
  - Stop the server and confirm :ok (regression: stop_server/1 used to
    return {:error, :not_found} due to double-stop of DynamicSupervisor child)
  - Verify double-stop returns {:error, :not_found} on the SECOND call
  - Bulk start-all / stop-all semantics

  Tagged :integration — run with `mix test --only integration`.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.MCP.{Manager, Server, Supervisor}

  @moduletag :integration
  @moduletag timeout: 30_000

  # Elixir stdio mock MCP server (test/support/mock_mcp_server.exs)
  alias CodePuppyControl.Support.MockMCPServerHelper, as: MockHelper

  # ── Helpers ────────────────────────────────────────────────────────────

  defp skip_if_no_mock_server do
    MockHelper.require_available!()
  end

  defp skip_if_no_supervisor do
    unless Process.whereis(Supervisor) do
      flunk("MCP.Supervisor not running — cannot test supervised lifecycle")
    end
  end

  defp unique_id do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "mock-#{suffix}"
  end

  defp start_mock!(server_id) do
    skip_if_no_mock_server()
    skip_if_no_supervisor()

    assert {:ok, _pid} =
             Supervisor.start_server(
               server_id: server_id,
               name: "mock-test",
               command: MockHelper.mock_server_command(),
               args: MockHelper.mock_server_args(),
               env: %{}
             )
  end

  defp cleanup_all do
    try do
      Supervisor.list_servers()
      |> Enum.each(&Supervisor.stop_server/1)
    catch
      _, _ -> :ok
    end
  end

  # ── Supervisor.stop_server regression ──────────────────────────────────

  describe "Supervisor.stop_server/1 — double-stop regression" do
    setup do
      skip_if_no_mock_server()
      skip_if_no_supervisor()

      on_exit(fn -> cleanup_all() end)
      :ok
    end

    test "returns :ok when stopping a running server" do
      sid = unique_id()
      start_mock!(sid)

      # The core regression: stop_server must return :ok, NOT {:error, :not_found}
      assert :ok = Supervisor.stop_server(sid)
    end

    test "returns {:error, :not_found} for a server that was never started" do
      assert {:error, :not_found} = Supervisor.stop_server("never-started-xyz")
    end

    test "returns {:error, :not_found} on double-stop" do
      sid = unique_id()
      start_mock!(sid)

      assert :ok = Supervisor.stop_server(sid)
      # Second stop — the server is already gone
      assert {:error, :not_found} = Supervisor.stop_server(sid)
    end

    test "removes server from list_servers after stop" do
      sid = unique_id()
      start_mock!(sid)

      assert sid in Supervisor.list_servers()

      assert :ok = Supervisor.stop_server(sid)

      refute sid in Supervisor.list_servers()
    end

    test "server count decrements after stop" do
      sid = unique_id()
      count_before = Supervisor.server_count()
      start_mock!(sid)

      assert Supervisor.server_count() == count_before + 1

      assert :ok = Supervisor.stop_server(sid)

      assert Supervisor.server_count() == count_before
    end
  end

  # ── Full lifecycle via Supervisor ──────────────────────────────────────

  describe "full supervised lifecycle (start → status → stop)" do
    setup do
      skip_if_no_mock_server()
      skip_if_no_supervisor()

      on_exit(fn -> cleanup_all() end)
      :ok
    end

    test "start → get_status → stop" do
      sid = unique_id()
      start_mock!(sid)

      # Status should be a map with expected keys
      status = Server.get_status(sid)
      assert is_map(status)
      assert status.server_id == sid
      assert status.name == "mock-test"
      assert status.status == :running
      assert status.health == :healthy

      assert :ok = Supervisor.stop_server(sid)
    end

    test "start → server_details → stop" do
      sid = unique_id()
      start_mock!(sid)

      details = Supervisor.server_details()
      assert is_list(details)
      found = Enum.find(details, &(&1.server_id == sid))
      assert found != nil
      assert found.health == :healthy

      assert :ok = Supervisor.stop_server(sid)
    end
  end

  # ── Full lifecycle via Manager ──────────────────────────────────────────

  describe "Manager lifecycle (register → status → unregister)" do
    setup do
      skip_if_no_mock_server()
      skip_if_no_supervisor()

      on_exit(fn -> cleanup_all() end)
      :ok
    end

    test "register_server → unregister_server returns :ok" do
      skip_if_no_mock_server()

      assert {:ok, server_id} =
               Manager.register_server("mock-mgr", MockHelper.mock_server_command(),
                 args: MockHelper.mock_server_args(),
                 env: %{}
               )

      # unregister_server delegates to Supervisor.stop_server
      # This is the same code path that used to return {:error, :not_found}
      assert :ok = Manager.unregister_server(server_id)
    end

    test "double unregister returns {:error, :not_found}" do
      skip_if_no_mock_server()

      assert {:ok, server_id} =
               Manager.register_server("mock-dbl", MockHelper.mock_server_command(),
                 args: MockHelper.mock_server_args(),
                 env: %{}
               )

      assert :ok = Manager.unregister_server(server_id)
      assert {:error, :not_found} = Manager.unregister_server(server_id)
    end

    test "Manager.list_servers includes running server" do
      skip_if_no_mock_server()

      assert {:ok, server_id} =
               Manager.register_server("mock-list", MockHelper.mock_server_command(),
                 args: MockHelper.mock_server_args(),
                 env: %{}
               )

      servers = Manager.list_servers()
      ids = Enum.map(servers, & &1.server_id)
      assert server_id in ids

      assert :ok = Manager.unregister_server(server_id)
    end
  end

  # ── Config-driven start/stop by name ───────────────────────────────────

  describe "Manager start_server_by_name / stop_server_by_name" do
    setup do
      skip_if_no_mock_server()
      skip_if_no_supervisor()

      # Set up a temp home with mcp_servers.json pointing at mock server
      tmp_home =
        Path.join(System.tmp_dir!(), "mcp_lifecycle_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_home)

      File.write!(
        Path.join(tmp_home, "mcp_servers.json"),
        Jason.encode!(%{
          "mock-srv" => %{
            "command" => MockHelper.mock_server_command(),
            "args" => MockHelper.mock_server_args(),
            "env" => %{}
          }
        })
      )

      orig_pup_ex = System.get_env("PUP_EX_HOME")
      System.put_env("PUP_EX_HOME", tmp_home)

      on_exit(fn ->
        if orig_pup_ex,
          do: System.put_env("PUP_EX_HOME", orig_pup_ex),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(tmp_home)
        cleanup_all()
      end)

      {:ok, tmp_home: tmp_home}
    end

    test "start_server_by_name → stop_server_by_name round-trip" do
      assert {:ok, _server_id} = Manager.start_server_by_name("mock-srv")

      assert :ok = Manager.stop_server_by_name("mock-srv")
    end

    test "stop_server_by_name returns :ok and subsequent call returns not_running" do
      assert {:ok, _server_id} = Manager.start_server_by_name("mock-srv")

      assert :ok = Manager.stop_server_by_name("mock-srv")
      assert {:error, :not_running} = Manager.stop_server_by_name("mock-srv")
    end

    test "start_server_by_name returns already_running on second call" do
      assert {:ok, _server_id} = Manager.start_server_by_name("mock-srv")
      assert {:ok, :already_running} = Manager.start_server_by_name("mock-srv")

      assert :ok = Manager.stop_server_by_name("mock-srv")
    end
  end

  # ── Bulk start-all / stop-all ──────────────────────────────────────────

  describe "Manager start_all_configured / stop_all_running" do
    setup do
      skip_if_no_mock_server()
      skip_if_no_supervisor()

      tmp_home =
        Path.join(System.tmp_dir!(), "mcp_bulk_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(tmp_home)

      File.write!(
        Path.join(tmp_home, "mcp_servers.json"),
        Jason.encode!(%{
          "bulk-a" => %{
            "command" => MockHelper.mock_server_command(),
            "args" => MockHelper.mock_server_args(),
            "env" => %{}
          },
          "bulk-b" => %{
            "command" => MockHelper.mock_server_command(),
            "args" => MockHelper.mock_server_args(),
            "env" => %{}
          }
        })
      )

      orig_pup_ex = System.get_env("PUP_EX_HOME")
      System.put_env("PUP_EX_HOME", tmp_home)

      on_exit(fn ->
        if orig_pup_ex,
          do: System.put_env("PUP_EX_HOME", orig_pup_ex),
          else: System.delete_env("PUP_EX_HOME")

        File.rm_rf!(tmp_home)
        cleanup_all()
      end)

      :ok
    end

    test "start_all_configured starts configured servers" do
      results = Manager.start_all_configured()

      assert length(results) == 2

      names = Enum.map(results, fn {name, _result} -> name end)
      assert "bulk-a" in names
      assert "bulk-b" in names

      # Each result should be {:ok, server_id}
      Enum.each(results, fn {_name, result} ->
        assert match?({:ok, _}, result)
      end)
    end

    test "stop_all_running stops all running servers with :ok" do
      Manager.start_all_configured()

      results = Manager.stop_all_running()

      assert length(results) == 2

      # Each result should be :ok (the bug fix ensures this)
      Enum.each(results, fn {_name, result} ->
        assert result == :ok
      end)
    end

    test "start_all → stop_all → start_all is idempotent" do
      # First start
      results1 = Manager.start_all_configured()
      assert length(results1) == 2

      # Stop all
      Manager.stop_all_running()

      # Verify none running
      assert Manager.list_servers() == []

      # Second start should succeed again
      results2 = Manager.start_all_configured()
      assert length(results2) == 2

      Manager.stop_all_running()
    end

    test "stop_all returns :ok" do
      Manager.start_all_configured()

      assert :ok = Manager.stop_all()
      assert Manager.list_servers() == []
    end
  end
end
