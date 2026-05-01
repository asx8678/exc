defmodule CodePuppyControl.Pack.RemoteNodeProxyMalformedTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Pack.RemoteNodeProxy

  @test_node :pup_test_worker@localhost

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp start_proxy(opts) do
    base = [
      node_name: @test_node,
      name: nil,
      monitor_fn: fn _node, _flag -> true end,
      handshake_fn: fn _node, _timeout -> {:error, :noproc} end
    ]

    RemoteNodeProxy.start_link(Keyword.merge(base, opts))
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

  # ── Malformed Casts ──────────────────────────────────────────────────────

  describe "malformed cast guards" do
    test "malformed result cast (non-binary run_id) is ignored" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      GenServer.cast(pid, {:result, 12345, %{status: :success}})

      # Should not crash
      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "malformed result cast (non-map result) is ignored" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      GenServer.cast(pid, {:result, "some_run", "not_a_map"})

      # Should not crash
      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "malformed progress cast (non-binary run_id) is ignored" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      GenServer.cast(pid, {:progress, 12345, %{type: :milestone, message: "hi"}})

      # Should not crash
      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "malformed progress cast (non-map msg) is ignored" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      GenServer.cast(pid, {:progress, "some_run", "not_a_map"})

      # Should not crash
      assert %{active_runs: 0} = RemoteNodeProxy.status(pid)

      GenServer.stop(pid, :normal)
    end

    test "malformed capabilities cast (non-map caps) is ignored" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      initial_caps = RemoteNodeProxy.capabilities(pid)

      # Send a non-map capabilities cast
      GenServer.cast(pid, {:capabilities, "not_a_map"})

      # Should not crash and capabilities should be unchanged
      assert RemoteNodeProxy.capabilities(pid) == initial_caps

      GenServer.stop(pid, :normal)
    end

    test "malformed capabilities cast (nil caps) is ignored" do
      {:ok, pid} =
        start_proxy(handshake_fn: fn _node, _timeout -> {:ok, mock_caps()} end)

      initial_caps = RemoteNodeProxy.capabilities(pid)

      # Send nil as capabilities
      GenServer.cast(pid, {:capabilities, nil})

      # Should not crash and capabilities should be unchanged
      assert RemoteNodeProxy.capabilities(pid) == initial_caps

      GenServer.stop(pid, :normal)
    end
  end
end
