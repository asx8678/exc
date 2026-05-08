defmodule CodePuppyControl.Telemetry.DistributedPackTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Telemetry.DistributedPack, as: PackTelemetry

  @event_prefix [:code_puppy, :distributed_pack]

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp attach_handler(event_name, test_pid, ref) do
    :telemetry.attach(
      ref,
      event_name,
      fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
  end

  # ── Node Lifecycle ──────────────────────────────────────────────────────

  describe "node_connected/2" do
    test "emits [:code_puppy, :distributed_pack, :node, :connected]" do
      ref = make_ref()
      event = @event_prefix ++ [:node, :connected]
      attach_handler(event, self(), ref)

      PackTelemetry.node_connected(:worker@localhost, %{sub_agents: [:terrier]})

      assert_receive {^ref, ^event, measurements, metadata}
      assert metadata.node == :worker@localhost
      assert metadata.capabilities == %{sub_agents: [:terrier]}
      assert is_integer(measurements.system_time)
      assert is_integer(measurements.monotonic_time)
    end
  end

  describe "node_disconnected/3" do
    test "emits [:code_puppy, :distributed_pack, :node, :disconnected]" do
      ref = make_ref()
      event = @event_prefix ++ [:node, :disconnected]
      attach_handler(event, self(), ref)

      PackTelemetry.node_disconnected(:worker@localhost, ["run-1", "run-2"], :nodedown)

      assert_receive {^ref, ^event, measurements, metadata}
      assert metadata.node == :worker@localhost
      assert metadata.active_runs == ["run-1", "run-2"]
      assert metadata.reason == :nodedown
      assert is_integer(measurements.system_time)
    end
  end

  describe "node_reconnected/2" do
    test "emits [:code_puppy, :distributed_pack, :node, :reconnected]" do
      ref = make_ref()
      event = @event_prefix ++ [:node, :reconnected]
      attach_handler(event, self(), ref)

      PackTelemetry.node_reconnected(:worker@localhost, 5000)

      assert_receive {^ref, ^event, measurements, metadata}
      assert metadata.node == :worker@localhost
      assert metadata.grace_period_ms == 5000
      assert is_integer(measurements.system_time)
    end
  end

  # ── Dispatch Lifecycle ──────────────────────────────────────────────────

  describe "dispatch_start/3" do
    test "emits [:code_puppy, :distributed_pack, :dispatch, :start]" do
      ref = make_ref()
      event = @event_prefix ++ [:dispatch, :start]
      attach_handler(event, self(), ref)

      PackTelemetry.dispatch_start("run-123", :terrier, :worker@localhost)

      assert_receive {^ref, ^event, measurements, metadata}
      assert metadata.run_id == "run-123"
      assert metadata.sub_agent == :terrier
      assert metadata.target_node == :worker@localhost
      assert is_integer(measurements.system_time)
    end
  end

  describe "dispatch_stop/3" do
    test "emits [:code_puppy, :distributed_pack, :dispatch, :stop]" do
      ref = make_ref()
      event = @event_prefix ++ [:dispatch, :stop]
      attach_handler(event, self(), ref)

      PackTelemetry.dispatch_stop("run-123", :success, 1500)

      assert_receive {^ref, ^event, measurements, metadata}
      assert metadata.run_id == "run-123"
      assert metadata.status == :success
      assert measurements.duration_ms == 1500
      assert is_integer(measurements.system_time)
    end
  end

  describe "dispatch_exception/2" do
    test "emits [:code_puppy, :distributed_pack, :dispatch, :exception]" do
      ref = make_ref()
      event = @event_prefix ++ [:dispatch, :exception]
      attach_handler(event, self(), ref)

      PackTelemetry.dispatch_exception("run-123", "timeout")

      assert_receive {^ref, ^event, measurements, metadata}
      assert metadata.run_id == "run-123"
      assert metadata.error == "timeout"
      assert is_integer(measurements.system_time)
    end
  end

  # ── Capability Events ──────────────────────────────────────────────────

  describe "capabilities_updated/2" do
    test "emits [:code_puppy, :distributed_pack, :capabilities, :updated]" do
      ref = make_ref()
      event = @event_prefix ++ [:capabilities, :updated]
      attach_handler(event, self(), ref)

      PackTelemetry.capabilities_updated(:worker@localhost, %{sub_agents: [:terrier, :watchdog]})

      assert_receive {^ref, ^event, measurements, metadata}
      assert metadata.node == :worker@localhost
      assert metadata.capabilities == %{sub_agents: [:terrier, :watchdog]}
      assert is_integer(measurements.system_time)
    end
  end
end
