defmodule CodePuppyControl.Pack.PackClusterTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.Commands.PackCluster
  alias CodePuppyControl.Pack.{NodeMonitor, NamingService}

  setup do
    # Ensure NodeMonitor is started for tests that enable distributed packs
    case Process.whereis(NodeMonitor) do
      nil -> start_supervised!({NodeMonitor, [enabled: false]})
      _pid -> :ok
    end

    # Ensure NamingService is started
    case Process.whereis(NamingService) do
      nil -> start_supervised!(NamingService)
      _pid -> :ok
    end

    state = %{session_id: "test-session", running: true}
    {:ok, state: state}
  end

  describe "/pack cluster (disabled)" do
    test "shows disabled status when distributed packs are off" do
      # Default config has enabled: false
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("", %{})
        end)

      assert output =~ "disabled"
    end

    test "shows enable hint when disabled" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("status", %{})
        end)

      assert output =~ "packs.distributed.enabled"
    end

    test "nodes subcommand shows disabled message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("nodes", %{})
        end)

      assert output =~ "disabled"
    end

    test "capabilities subcommand shows disabled message" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("capabilities", %{})
        end)

      assert output =~ "disabled"
    end
  end

  describe "/pack cluster (enabled, no workers)" do
    setup do
      # Temporarily enable distributed packs
      original = Application.get_env(:code_puppy_control, :distributed_packs)
      Application.put_env(:code_puppy_control, :distributed_packs, %{enabled: true, workers: []})

      on_exit(fn ->
        if original do
          Application.put_env(:code_puppy_control, :distributed_packs, original)
        else
          Application.delete_env(:code_puppy_control, :distributed_packs)
        end
      end)

      :ok
    end

    test "shows enabled status" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("status", %{})
        end)

      assert output =~ "enabled"
    end

    test "shows zero workers" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("status", %{})
        end)

      assert output =~ "0 connected"
    end

    test "nodes subcommand shows no workers configured" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("nodes", %{})
        end)

      assert output =~ "No workers configured"
    end

    test "capabilities subcommand shows no capabilities" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("capabilities", %{})
        end)

      assert output =~ "No worker capabilities registered"
    end
  end

  describe "/pack cluster unknown subcommand" do
    test "shows available subcommands" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          PackCluster.handle_cluster("foobar", %{})
        end)

      assert output =~ "Unknown subcommand"
      assert output =~ "status"
      assert output =~ "nodes"
      assert output =~ "capabilities"
    end
  end

  describe "handle_cluster return value" do
    test "always returns {:continue, state}" do
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:continue, %{}} = PackCluster.handle_cluster("", %{})
        assert {:continue, %{a: 1}} = PackCluster.handle_cluster("status", %{a: 1})
        assert {:continue, %{}} = PackCluster.handle_cluster("nodes", %{})
      end)
    end
  end
end
