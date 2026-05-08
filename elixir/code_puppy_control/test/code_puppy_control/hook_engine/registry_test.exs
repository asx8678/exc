defmodule CodePuppyControl.HookEngine.RegistryTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.HookEngine.Models
  alias Models.{HookConfig, HookRegistry}
  alias CodePuppyControl.HookEngine.Registry

  describe "build_from_config/1" do
    test "builds empty registry from empty config" do
      reg = Registry.build_from_config(%{})
      assert reg.entries == %{}
      assert reg.executed_once == MapSet.new()
      assert reg.registered_ids == MapSet.new()
    end

    test "builds registry from valid config" do
      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{"type" => "command", "command" => "./check.sh"}
            ]
          }
        ]
      }

      reg = Registry.build_from_config(config)
      hooks = Registry.get_hooks_for_event(reg, "PreToolUse")
      assert length(hooks) == 1
      assert hd(hooks).matcher == "Bash"
      assert hd(hooks).command == "./check.sh"
    end

    test "deduplicates hooks with same auto-generated ID" do
      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{"type" => "command", "command" => "./check.sh"},
              %{"type" => "command", "command" => "./check.sh"}
            ]
          }
        ]
      }

      reg = Registry.build_from_config(config)
      hooks = Registry.get_hooks_for_event(reg, "PreToolUse")
      # Same matcher + type + command → same auto-ID → dedup
      assert length(hooks) == 1
    end

    test "deduplicates hooks with same explicit ID across event types" do
      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "*",
            "hooks" => [
              %{"type" => "command", "command" => "./a.sh", "id" => "shared-id"}
            ]
          }
        ],
        "PostToolUse" => [
          %{
            "matcher" => "*",
            "hooks" => [
              %{"type" => "command", "command" => "./b.sh", "id" => "shared-id"}
            ]
          }
        ]
      }

      reg = Registry.build_from_config(config)
      # Dedup: total should be 1 (first-registered wins)
      # Map iteration order is not guaranteed, so check total, not per-event
      assert Registry.count_hooks(reg) == 1
      assert MapSet.size(reg.registered_ids) == 1
    end

    test "skips hooks with invalid config" do
      config = %{
        "PreToolUse" => [
          %{
            "matcher" => "Bash",
            "hooks" => [
              %{"type" => "command", "command" => "./check.sh"},
              %{"type" => "command", "command" => ""}
            ]
          }
        ]
      }

      reg = Registry.build_from_config(config)
      hooks = Registry.get_hooks_for_event(reg, "PreToolUse")
      # Only the valid command hook survives; empty command is skipped
      assert length(hooks) == 1
      assert hd(hooks).command == "./check.sh"
    end

    test "skips keys starting with _" do
      config = %{
        "_comment" => "This is a comment",
        "PreToolUse" => [
          %{"matcher" => "*", "hooks" => [%{"type" => "command", "command" => "echo"}]}
        ]
      }

      reg = Registry.build_from_config(config)
      assert Registry.count_hooks(reg) == 1
    end
  end

  describe "add_hook/3 (deduplication)" do
    test "adds a hook successfully" do
      reg = %HookRegistry{}
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo hi")
      {reg, result} = Registry.add_hook(reg, "PreToolUse", hook)
      assert result == :ok
      assert Registry.count_hooks(reg, "PreToolUse") == 1
    end

    test "rejects duplicate hook by ID" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo hi", id: "dup-id")
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", hook)
      {_reg, result} = Registry.add_hook(reg, "PreToolUse", hook)
      assert result == :duplicate
      assert Registry.count_hooks(reg, "PreToolUse") == 1
    end

    test "rejects duplicate across different event types" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo hi", id: "cross-id")
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", hook)
      {_reg, result} = Registry.add_hook(reg, "PostToolUse", hook)
      assert result == :duplicate
    end
  end

  describe "remove_hook/3" do
    test "removes a hook and returns true" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo hi")
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", hook)
      {reg, found} = Registry.remove_hook(reg, "PreToolUse", hook.id)
      assert found == true
      assert Registry.count_hooks(reg, "PreToolUse") == 0
    end

    test "returns false for non-existent hook" do
      reg = %HookRegistry{}
      {_reg, found} = Registry.remove_hook(reg, "PreToolUse", "no-such-id")
      assert found == false
    end
  end

  describe "get_hooks_for_event/2" do
    test "filters out disabled hooks" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo", enabled: false)
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", hook)
      hooks = Registry.get_hooks_for_event(reg, "PreToolUse")
      assert hooks == []
    end

    test "filters out already-executed once hooks" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo", once: true)
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", hook)
      reg = Registry.mark_hook_executed(reg, hook.id)
      hooks = Registry.get_hooks_for_event(reg, "PreToolUse")
      assert hooks == []
    end

    test "includes enabled non-once hooks" do
      hook = HookConfig.new(matcher: "*", type: :command, command: "echo")
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", hook)
      hooks = Registry.get_hooks_for_event(reg, "PreToolUse")
      assert length(hooks) == 1
    end
  end

  describe "once hooks" do
    test "mark_hook_executed adds to executed set" do
      reg = %HookRegistry{}
      reg = Registry.mark_hook_executed(reg, "hook-1")
      assert MapSet.member?(reg.executed_once, "hook-1")
    end

    test "reset_once_hooks clears executed set" do
      reg = %HookRegistry{}
      reg = Registry.mark_hook_executed(reg, "hook-1")
      reg = Registry.reset_once_hooks(reg)
      assert MapSet.size(reg.executed_once) == 0
    end
  end

  describe "count_hooks/2" do
    test "counts total across all event types" do
      h1 = HookConfig.new(matcher: "*", type: :command, command: "echo 1")
      h2 = HookConfig.new(matcher: "*", type: :command, command: "echo 2")
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", h1)
      {reg, :ok} = Registry.add_hook(reg, "PostToolUse", h2)
      assert Registry.count_hooks(reg) == 2
    end

    test "counts hooks for specific event type" do
      h1 = HookConfig.new(matcher: "*", type: :command, command: "echo 1")
      h2 = HookConfig.new(matcher: "*", type: :command, command: "echo 2")
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", h1)
      {reg, :ok} = Registry.add_hook(reg, "PostToolUse", h2)
      assert Registry.count_hooks(reg, "PreToolUse") == 1
      assert Registry.count_hooks(reg, "PostToolUse") == 1
    end
  end

  describe "get_stats/1" do
    test "returns correct stats" do
      h1 = HookConfig.new(matcher: "*", type: :command, command: "echo 1")
      h2 = HookConfig.new(matcher: "*", type: :command, command: "echo 2", enabled: false)
      reg = %HookRegistry{}
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", h1)
      {reg, :ok} = Registry.add_hook(reg, "PreToolUse", h2)

      stats = Registry.get_stats(reg)
      assert stats.total_hooks == 2
      assert stats.enabled_hooks == 1
      assert stats.disabled_hooks == 1
    end
  end
end
