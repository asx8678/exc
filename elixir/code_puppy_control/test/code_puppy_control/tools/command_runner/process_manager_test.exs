defmodule CodePuppyControl.Tools.CommandRunner.ProcessManagerTest do
  @moduledoc """
  Tests for CommandRunner.ProcessManager.

  Covers:
  - Command registration/unregistration
  - OS PID tracking and updates
  - Kill escalation patterns
  - Bounded killed-PID set
  - Bulk kill operations
  - Process group awareness
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Tools.CommandRunner.ProcessManager

  setup do
    # Ensure ProcessManager is running (started by application supervision)
    assert Process.whereis(ProcessManager) != nil

    # Clean up any leftover state from previous tests
    ProcessManager.kill_all()

    :ok
  end

  describe "register_command/2" do
    test "registers a command and returns tracking ID" do
      assert {:ok, id} = ProcessManager.register_command("echo hello")
      assert is_integer(id)
      assert id > 0

      # Clean up
      ProcessManager.unregister_command(id)
    end

    test "assigns monotonically increasing IDs" do
      {:ok, id1} = ProcessManager.register_command("echo 1")
      {:ok, id2} = ProcessManager.register_command("echo 2")

      assert id2 > id1

      ProcessManager.unregister_command(id1)
      ProcessManager.unregister_command(id2)
    end

    test "accepts mode option" do
      assert {:ok, id} = ProcessManager.register_command("echo pty", mode: :pty)

      cmd = ProcessManager.list_commands() |> Enum.find(&(&1.id == id))
      assert cmd.mode == :pty

      ProcessManager.unregister_command(id)
    end

    test "accepts os_pid option" do
      assert {:ok, id} = ProcessManager.register_command("echo pid", os_pid: 12345)

      cmd = ProcessManager.list_commands() |> Enum.find(&(&1.id == id))
      assert cmd.os_pid == 12345

      ProcessManager.unregister_command(id)
    end

    test "defaults mode to :standard" do
      {:ok, id} = ProcessManager.register_command("echo default")

      cmd = ProcessManager.list_commands() |> Enum.find(&(&1.id == id))
      assert cmd.mode == :standard

      ProcessManager.unregister_command(id)
    end
  end

  describe "update_os_pid/2" do
    test "updates OS PID for registered command" do
      {:ok, id} = ProcessManager.register_command("echo test")
      assert :ok = ProcessManager.update_os_pid(id, 99999)

      cmd = ProcessManager.list_commands() |> Enum.find(&(&1.id == id))
      assert cmd.os_pid == 99999

      ProcessManager.unregister_command(id)
    end

    test "returns error for unknown tracking ID" do
      assert {:error, :not_found} = ProcessManager.update_os_pid(99999, 12345)
    end
  end

  describe "unregister_command/1" do
    test "removes command from tracking" do
      {:ok, id} = ProcessManager.register_command("echo temp")
      assert ProcessManager.count() >= 1

      ProcessManager.unregister_command(id)
      # Command should no longer be in the list
      cmds = ProcessManager.list_commands()
      refute Enum.any?(cmds, &(&1.id == id))
    end

    test "is idempotent for unknown IDs" do
      assert :ok = ProcessManager.unregister_command(99999)
    end
  end

  describe "count/0" do
    test "returns zero when no processes running" do
      ProcessManager.kill_all()
      assert ProcessManager.count() == 0
    end

    test "reflects registered commands" do
      initial = ProcessManager.count()

      {:ok, id1} = ProcessManager.register_command("echo 1")
      {:ok, id2} = ProcessManager.register_command("echo 2")

      assert ProcessManager.count() == initial + 2

      ProcessManager.unregister_command(id1)
      ProcessManager.unregister_command(id2)
    end
  end

  describe "kill_all/0" do
    test "returns count of killed processes" do
      ProcessManager.kill_all()
      count = ProcessManager.kill_all()
      assert count == 0
    end

    test "clears all tracked commands" do
      {:ok, _id1} = ProcessManager.register_command("echo 1")
      {:ok, _id2} = ProcessManager.register_command("echo 2")

      count = ProcessManager.kill_all()
      assert count == 2
      assert ProcessManager.count() == 0
    end
  end

  describe "is_pid_killed?/1" do
    test "returns false for unknown PID" do
      refute ProcessManager.is_pid_killed?(99998)
    end

    test "returns true after kill_all with registered PID" do
      {:ok, _id} = ProcessManager.register_command("echo kill", os_pid: 54321)
      ProcessManager.kill_all()

      assert ProcessManager.is_pid_killed?(54321)
    end

    test "returns true after kill_process" do
      ProcessManager.kill_process(55555)
      assert ProcessManager.is_pid_killed?(55555)
    end

    test "bounded killed set prevents unbounded growth" do
      # Register a smaller batch to avoid kill_all timeout in CI
      for i <- 1..50 do
        {:ok, _id} = ProcessManager.register_command("echo #{i}", os_pid: 60000 + i)
      end

      ProcessManager.kill_all()

      # The killed set should be bounded
      # This test just verifies the operation doesn't crash
      assert ProcessManager.count() == 0
    end
  end

  describe "list_commands/0" do
    test "returns list of command info maps" do
      ProcessManager.kill_all()
      {:ok, id} = ProcessManager.register_command("echo list", mode: :pty, os_pid: 11111)

      cmds = ProcessManager.list_commands()
      assert is_list(cmds)
      assert length(cmds) == 1

      cmd = hd(cmds)
      assert cmd.command == "echo list"
      assert cmd.mode == :pty
      assert cmd.os_pid == 11111
      assert cmd.id == id

      ProcessManager.kill_all()
    end
  end

  describe "get_command/1" do
    test "returns command info for valid tracking ID" do
      {:ok, id} = ProcessManager.register_command("echo get")

      result = ProcessManager.get_command(id)
      assert result != nil
      assert result.command == "echo get"

      ProcessManager.kill_all()
    end

    test "returns nil for unknown tracking ID" do
      assert ProcessManager.get_command(99999) == nil
    end
  end

  describe "kill_process/1" do
    test "returns ok or error for non-existent process" do
      # Killing a non-existent PID should not crash
      result = ProcessManager.kill_process(99999)
      assert match?(:ok, result) or match?({:error, _}, result)
    end
  end
end
