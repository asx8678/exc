defmodule CodePuppyControl.Pack.RemoteNodeSupervisorTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Pack.RemoteNodeProxy
  alias CodePuppyControl.Pack.RemoteNodeSupervisor

  @test_node :pup_sup_test_worker@localhost

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Default proxy options that avoid calling Node.monitor/2 and
  # default_handshake/2 in test — both crash without a running
  # Erlang distribution layer.
  defp default_proxy_opts do
    [
      name: nil,
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end
    ]
  end

  defp start_supervisor(node_name \\ @test_node, extra_proxy_opts \\ []) do
    proxy_opts = Keyword.merge(default_proxy_opts(), extra_proxy_opts)
    RemoteNodeSupervisor.start_link(node_name, proxy_opts: proxy_opts, name: nil)
  end

  defp start_supervisor_with_name(node_name \\ @test_node, extra_proxy_opts \\ []) do
    proxy_opts =
      default_proxy_opts()
      |> Keyword.merge(extra_proxy_opts)
      |> Keyword.delete(:name)

    RemoteNodeSupervisor.start_link(node_name, proxy_opts: proxy_opts)
  end

  defp mock_caps do
    %{
      node_name: @test_node,
      sub_agents: [:terrier, :watchdog],
      host_os: "linux",
      available_models: ["claude-sonnet-4-20250514"],
      max_concurrent_runs: 4,
      features: %{file_ops: true, shell_access: true, git_access: true}
    }
  end

  defp find_proxy_pid(sup_pid) do
    children = Supervisor.which_children(sup_pid)

    case Enum.find(children, fn {id, _pid, _type, _modules} -> id == :remote_node_proxy end) do
      {:remote_node_proxy, proxy_pid, :worker, _} when is_pid(proxy_pid) -> {:ok, proxy_pid}
      {:remote_node_proxy, :restarting, _, _} -> {:error, :restarting}
      {:remote_node_proxy, :undefined, _, _} -> {:error, :undefined}
      nil -> {:error, :not_found}
    end
  end

  # ── Startup & Structure ──────────────────────────────────────────────────

  describe "startup" do
    test "starts successfully with a valid node name" do
      {:ok, sup_pid} = start_supervisor()
      assert Process.alive?(sup_pid)
      Supervisor.stop(sup_pid, :normal)
    end

    test "starts a single RemoteNodeProxy child" do
      {:ok, sup_pid} = start_supervisor()

      children = Supervisor.which_children(sup_pid)
      assert length(children) == 1

      {:remote_node_proxy, proxy_pid, :worker, _} =
        Enum.find(children, fn {id, _, _, _} -> id == :remote_node_proxy end)

      assert is_pid(proxy_pid)
      assert Process.alive?(proxy_pid)

      Supervisor.stop(sup_pid, :normal)
    end

    test "proxy child module is RemoteNodeProxy" do
      {:ok, sup_pid} = start_supervisor()

      children = Supervisor.which_children(sup_pid)

      {:remote_node_proxy, _pid, :worker, modules} =
        Enum.find(children, fn {id, _, _, _} -> id == :remote_node_proxy end)

      assert modules == [RemoteNodeProxy]

      Supervisor.stop(sup_pid, :normal)
    end

    test "supervisor stops cleanly within reasonable timeout" do
      # The child spec sets shutdown: 5_000ms. We verify that
      # the supervisor stops cleanly — if the timeout were
      # :infinity, this could hang.
      {:ok, sup_pid} = start_supervisor()
      assert :ok = Supervisor.stop(sup_pid, :normal)
    end
  end

  # ── Proxy Integration ────────────────────────────────────────────────────

  describe "proxy integration via supervisor" do
    test "proxy tracks the correct node name" do
      {:ok, sup_pid} = start_supervisor()

      {:ok, proxy_pid} = find_proxy_pid(sup_pid)
      assert RemoteNodeProxy.node_name(proxy_pid) == @test_node

      Supervisor.stop(sup_pid, :normal)
    end

    test "proxy starts in :connecting status (no real remote node)" do
      {:ok, sup_pid} = start_supervisor()

      {:ok, proxy_pid} = find_proxy_pid(sup_pid)
      assert %{status: :connecting} = RemoteNodeProxy.status(proxy_pid)

      Supervisor.stop(sup_pid, :normal)
    end

    test "proxy dispatch is rejected when not connected" do
      {:ok, sup_pid} = start_supervisor()

      {:ok, proxy_pid} = find_proxy_pid(sup_pid)

      assert {:error, {:node_not_ready, @test_node}} =
               RemoteNodeProxy.dispatch(proxy_pid, :terrier, %{worktree_path: "."})

      Supervisor.stop(sup_pid, :normal)
    end

    test "proxy handles capabilities cast via supervisor" do
      {:ok, sup_pid} = start_supervisor()

      {:ok, proxy_pid} = find_proxy_pid(sup_pid)

      # Push capabilities via cast (simulates remote worker advertising)
      GenServer.cast(proxy_pid, {:capabilities, mock_caps()})

      # Flush the cast
      RemoteNodeProxy.status(proxy_pid)

      assert %{status: :connected} = RemoteNodeProxy.status(proxy_pid)
      assert RemoteNodeProxy.capabilities(proxy_pid) == mock_caps()

      Supervisor.stop(sup_pid, :normal)
    end

    test "proxy transitions through full lifecycle via supervisor" do
      {:ok, sup_pid} =
        start_supervisor(@test_node,
          handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end
        )

      {:ok, proxy_pid} = find_proxy_pid(sup_pid)

      # Initially connected (handshake succeeded)
      assert %{status: :connected} = RemoteNodeProxy.status(proxy_pid)

      # Simulate nodedown
      send(proxy_pid, {:nodedown, @test_node})
      assert %{status: :disconnected} = RemoteNodeProxy.status(proxy_pid)

      # Simulate nodeup with handshake succeeding
      send(proxy_pid, {:nodeup, @test_node})
      assert %{status: :connected} = RemoteNodeProxy.status(proxy_pid)

      Supervisor.stop(sup_pid, :normal)
    end
  end

  # ── Shutdown ─────────────────────────────────────────────────────────────

  describe "shutdown" do
    test "supervisor terminates cleanly on :normal" do
      {:ok, sup_pid} = start_supervisor()
      assert Process.alive?(sup_pid)

      assert :ok = Supervisor.stop(sup_pid, :normal)
      refute Process.alive?(sup_pid)
    end

    test "proxy is stopped when supervisor stops" do
      {:ok, sup_pid} = start_supervisor()

      {:ok, proxy_pid} = find_proxy_pid(sup_pid)
      assert Process.alive?(proxy_pid)

      Supervisor.stop(sup_pid, :normal)

      # Wait for the proxy process to terminate
      ref = Process.monitor(proxy_pid)

      receive do
        {:DOWN, ^ref, :process, ^proxy_pid, _reason} -> :ok
      after
        100 -> flunk("proxy was not stopped within 100ms")
      end
    end
  end

  # ── Supervision Strategy ─────────────────────────────────────────────────

  describe "supervision strategy" do
    test "restarts proxy on abnormal exit (:one_for_one + :transient)" do
      {:ok, sup_pid} = start_supervisor()

      {:ok, proxy_pid} = find_proxy_pid(sup_pid)

      # Kill the proxy abnormally — :transient means it should restart
      ref = Process.monitor(proxy_pid)
      Process.exit(proxy_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^proxy_pid, :killed} -> :ok
      after
        100 -> :ok
      end

      # Give the supervisor time to restart the child
      Process.sleep(100)

      # The supervisor should still be alive
      assert Process.alive?(sup_pid)

      # A new proxy should have been started
      {:ok, new_proxy_pid} = find_proxy_pid(sup_pid)
      assert is_pid(new_proxy_pid)
      assert new_proxy_pid != proxy_pid

      # New proxy should track the same node
      assert RemoteNodeProxy.node_name(new_proxy_pid) == @test_node

      Supervisor.stop(sup_pid, :normal)
    end

    test "does not restart proxy on normal exit (:transient)" do
      {:ok, sup_pid} = start_supervisor()

      {:ok, proxy_pid} = find_proxy_pid(sup_pid)

      # Stop the proxy normally — :transient means no restart
      GenServer.stop(proxy_pid, :normal)

      # Give the supervisor time to process the exit
      Process.sleep(100)

      # The supervisor should still be alive
      assert Process.alive?(sup_pid)

      # No proxy should be running (transient = no restart on normal exit)
      assert {:error, :undefined} = find_proxy_pid(sup_pid)

      Supervisor.stop(sup_pid, :normal)
    end
  end

  # ── Registry Naming ─────────────────────────────────────────────────────

  describe "via-tuple naming" do
    setup do
      # Start the Registries supervisor so via-tuple lookups work.
      # If it's already running (e.g., started by the application tree),
      # we skip starting a duplicate — the registries are shared state.
      case GenServer.whereis(CodePuppyControl.Pack.Registries) do
        nil -> start_supervised!(CodePuppyControl.Pack.Registries)
        _pid -> :ok
      end

      :ok
    end

    test "supervisor is registered under via name" do
      {:ok, sup_pid} = start_supervisor_with_name()

      via = RemoteNodeSupervisor.via_name(@test_node)
      found_pid = GenServer.whereis(via)
      assert found_pid == sup_pid

      Supervisor.stop(sup_pid, :normal)
    end

    test "proxy is registered under its via name" do
      {:ok, sup_pid} = start_supervisor_with_name()

      via = RemoteNodeProxy.via_name(@test_node)
      found_pid = GenServer.whereis(via)
      assert is_pid(found_pid)
      assert Process.alive?(found_pid)

      Supervisor.stop(sup_pid, :normal)
    end

    test "via_name returns valid :via tuple" do
      via = RemoteNodeSupervisor.via_name(@test_node)
      assert {:via, Registry, {RemoteNodeSupervisor.Registry, @test_node}} = via
    end
  end

  # ── Multiple Nodes ──────────────────────────────────────────────────────

  describe "multiple node supervisors" do
    test "can start supervisors for different nodes concurrently" do
      other_node = :pup_other_worker@localhost

      {:ok, sup1} = start_supervisor(@test_node)
      {:ok, sup2} = start_supervisor(other_node)

      assert Process.alive?(sup1)
      assert Process.alive?(sup2)

      {:ok, proxy1} = find_proxy_pid(sup1)
      {:ok, proxy2} = find_proxy_pid(sup2)

      assert RemoteNodeProxy.node_name(proxy1) == @test_node
      assert RemoteNodeProxy.node_name(proxy2) == other_node

      Supervisor.stop(sup1, :normal)
      Supervisor.stop(sup2, :normal)
    end
  end

  # ── Restart Limits ──────────────────────────────────────────────────────

  describe "restart limits" do
    test "supervisor crashes after exceeding max_restarts" do
      # Trap exits so the supervisor crash doesn't kill the test process
      Process.flag(:trap_exit, true)

      {:ok, sup_pid} = start_supervisor()

      ref = Process.monitor(sup_pid)

      # Kill the proxy repeatedly until the supervisor crashes
      # (max_restarts: 3, max_seconds: 5)
      kill_loop(sup_pid, ref, 10)

      # The supervisor should have crashed
      assert_receive {:DOWN, ^ref, :process, ^sup_pid, _reason}, 500

      Process.flag(:trap_exit, false)
    end

    defp kill_loop(_sup_pid, _ref, 0), do: :ok

    defp kill_loop(sup_pid, ref, remaining) do
      if Process.alive?(sup_pid) do
        case find_proxy_pid(sup_pid) do
          {:ok, proxy_pid} when is_pid(proxy_pid) ->
            Process.exit(proxy_pid, :kill)

          _ ->
            :ok
        end

        # Brief pause to let the supervisor process the exit
        Process.sleep(20)
        kill_loop(sup_pid, ref, remaining - 1)
      end
    end
  end
end
