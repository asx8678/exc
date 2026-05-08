defmodule CodePuppyControl.Plugins.SchedulerTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.{Callbacks, Plugins}
  alias CodePuppyControl.Plugins.Scheduler

  setup do
    Callbacks.clear()
    :ok
  end

  describe "name/0" do
    test "returns string identifier" do
      assert Scheduler.name() == "scheduler"
    end
  end

  describe "description/0" do
    test "returns a non-empty description" do
      assert is_binary(Scheduler.description())
      assert Scheduler.description() != ""
    end
  end

  describe "register/0" do
    test "registers custom_command and custom_command_help callbacks" do
      assert :ok = Scheduler.register()
      assert Callbacks.count_callbacks(:custom_command) >= 1
      assert Callbacks.count_callbacks(:custom_command_help) >= 1
    end
  end

  describe "command_help/0" do
    test "returns help entries for scheduler commands" do
      help = Scheduler.command_help()
      assert is_list(help)
      assert length(help) == 3
      commands = Enum.map(help, fn {cmd, _desc} -> cmd end)
      assert "/scheduler" in commands
      assert "/sched" in commands
      assert "/cron" in commands
    end
  end

  describe "handle_command/2" do
    test "returns nil for unknown command name" do
      assert Scheduler.handle_command("/foo", "foo") == nil
    end

    test "handles /scheduler command" do
      result = Scheduler.handle_command("/scheduler", "scheduler")
      assert is_binary(result) or result == true
    end

    test "handles /sched alias" do
      result = Scheduler.handle_command("/sched", "sched")
      assert is_binary(result) or result == true
    end

    test "handles /cron alias" do
      result = Scheduler.handle_command("/cron", "cron")
      assert is_binary(result) or result == true
    end

    test "handles /scheduler list subcommand" do
      result = Scheduler.handle_command("/scheduler list", "scheduler")
      assert is_binary(result) or result == true
    end

    test "handles /scheduler run without id" do
      result = Scheduler.handle_command("/scheduler run", "scheduler")
      assert is_binary(result)
      assert result =~ "Usage" or result =~ "task_id"
    end
  end

  describe "loading via Plugins API" do
    test "can be loaded through the plugin system" do
      Plugins.load_plugin(Scheduler)
      assert Callbacks.count_callbacks(:custom_command) >= 1
    end
  end
end
