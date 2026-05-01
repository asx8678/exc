defmodule CodePuppyControl.TelemetryTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Telemetry

  setup do
    # Generate unique handler IDs for each test to avoid collisions
    handler_id = "telemetry-test-#{:erlang.unique_integer()}"
    test_pid = self()

    %{handler_id: handler_id, test_pid: test_pid}
  end

  defp attach_handler(handler_id, event, test_pid) do
    :telemetry.attach(
      handler_id,
      event,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )
  end

  describe "distributed_node_connected/2" do
    test "emits correct event with node and capabilities", %{
      handler_id: handler_id,
      test_pid: test_pid
    } do
      attach_handler(handler_id, [:code_puppy, :distributed_pack, :node, :connected], test_pid)

      node = Node.self()
      capabilities = %{sub_agents: [:terrier], max_concurrent_runs: 2}

      assert :ok = Telemetry.distributed_node_connected(node, capabilities)

      assert_receive {:telemetry, [:code_puppy, :distributed_pack, :node, :connected],
                      measurements, metadata},
                     500

      assert Map.has_key?(measurements, :system_time)
      assert Map.has_key?(measurements, :monotonic_time)
      assert metadata.node == node
      assert metadata.capabilities == capabilities

      :telemetry.detach(handler_id)
    end

    test "returns :ok", %{} do
      assert :ok = Telemetry.distributed_node_connected(Node.self(), %{})
    end
  end

  describe "distributed_node_disconnected/3" do
    test "emits correct event with active runs and reason", %{
      handler_id: handler_id,
      test_pid: test_pid
    } do
      attach_handler(
        handler_id,
        [:code_puppy, :distributed_pack, :node, :disconnected],
        test_pid
      )

      node = Node.self()

      assert :ok =
               Telemetry.distributed_node_disconnected(node, ["run-1", "run-2"], :nodedown)

      assert_receive {:telemetry, [:code_puppy, :distributed_pack, :node, :disconnected],
                      measurements, metadata},
                     500

      assert Map.has_key?(measurements, :system_time)
      assert Map.has_key?(measurements, :monotonic_time)
      assert metadata.node == node
      assert metadata.active_runs == ["run-1", "run-2"]
      assert metadata.reason == :nodedown

      :telemetry.detach(handler_id)
    end

    test "returns :ok", %{} do
      assert :ok = Telemetry.distributed_node_disconnected(Node.self(), [], :normal)
    end
  end

  describe "distributed_node_reconnected/2" do
    test "emits correct event with grace period", %{
      handler_id: handler_id,
      test_pid: test_pid
    } do
      attach_handler(
        handler_id,
        [:code_puppy, :distributed_pack, :node, :reconnected],
        test_pid
      )

      node = Node.self()

      assert :ok = Telemetry.distributed_node_reconnected(node, 30_000)

      assert_receive {:telemetry, [:code_puppy, :distributed_pack, :node, :reconnected],
                      measurements, metadata},
                     500

      assert Map.has_key?(measurements, :system_time)
      assert Map.has_key?(measurements, :monotonic_time)
      assert metadata.node == node
      assert metadata.grace_period_ms == 30_000

      :telemetry.detach(handler_id)
    end

    test "returns :ok", %{} do
      assert :ok = Telemetry.distributed_node_reconnected(Node.self(), 5_000)
    end
  end

  describe "distributed_dispatch_start/3" do
    test "emits correct event with run_id, sub_agent, and target_node", %{
      handler_id: handler_id,
      test_pid: test_pid
    } do
      attach_handler(
        handler_id,
        [:code_puppy, :distributed_pack, :dispatch, :start],
        test_pid
      )

      node = Node.self()

      assert :ok = Telemetry.distributed_dispatch_start("run-123", :terrier, node)

      assert_receive {:telemetry, [:code_puppy, :distributed_pack, :dispatch, :start],
                      measurements, metadata},
                     500

      assert Map.has_key?(measurements, :system_time)
      assert Map.has_key?(measurements, :monotonic_time)
      assert metadata.run_id == "run-123"
      assert metadata.sub_agent == :terrier
      assert metadata.target_node == node

      :telemetry.detach(handler_id)
    end

    test "returns :ok", %{} do
      assert :ok = Telemetry.distributed_dispatch_start("run-456", :watchdog, Node.self())
    end
  end

  describe "distributed_dispatch_stop/3" do
    test "emits correct event with status and duration", %{
      handler_id: handler_id,
      test_pid: test_pid
    } do
      attach_handler(
        handler_id,
        [:code_puppy, :distributed_pack, :dispatch, :stop],
        test_pid
      )

      assert :ok = Telemetry.distributed_dispatch_stop("run-123", :ok, 1_500)

      assert_receive {:telemetry, [:code_puppy, :distributed_pack, :dispatch, :stop],
                      measurements, metadata},
                     500

      assert measurements.duration_ms == 1_500
      assert Map.has_key?(measurements, :system_time)
      assert metadata.run_id == "run-123"
      assert metadata.status == :ok
      assert metadata.duration_ms == 1_500

      :telemetry.detach(handler_id)
    end

    test "returns :ok", %{} do
      assert :ok = Telemetry.distributed_dispatch_stop("run-789", :error, 500)
    end
  end

  describe "distributed_dispatch_exception/2" do
    test "emits correct event with run_id and error", %{
      handler_id: handler_id,
      test_pid: test_pid
    } do
      attach_handler(
        handler_id,
        [:code_puppy, :distributed_pack, :dispatch, :exception],
        test_pid
      )

      assert :ok = Telemetry.distributed_dispatch_exception("run-123", "unsupported_sub_agent")

      assert_receive {:telemetry, [:code_puppy, :distributed_pack, :dispatch, :exception],
                      measurements, metadata},
                     500

      assert Map.has_key?(measurements, :system_time)
      assert Map.has_key?(measurements, :monotonic_time)
      assert metadata.run_id == "run-123"
      assert metadata.error == "unsupported_sub_agent"

      :telemetry.detach(handler_id)
    end

    test "returns :ok", %{} do
      assert :ok = Telemetry.distributed_dispatch_exception("run-999", "timeout")
    end
  end

  describe "distributed_capabilities_updated/2" do
    test "emits correct event with node and capabilities", %{
      handler_id: handler_id,
      test_pid: test_pid
    } do
      attach_handler(
        handler_id,
        [:code_puppy, :distributed_pack, :capabilities, :updated],
        test_pid
      )

      node = Node.self()
      capabilities = %{available_models: ["claude-sonnet-4-20250514"]}

      assert :ok = Telemetry.distributed_capabilities_updated(node, capabilities)

      assert_receive {:telemetry, [:code_puppy, :distributed_pack, :capabilities, :updated],
                      measurements, metadata},
                     500

      assert Map.has_key?(measurements, :system_time)
      assert Map.has_key?(measurements, :monotonic_time)
      assert metadata.node == node
      assert metadata.capabilities == capabilities

      :telemetry.detach(handler_id)
    end

    test "returns :ok", %{} do
      assert :ok = Telemetry.distributed_capabilities_updated(Node.self(), %{})
    end
  end
end
