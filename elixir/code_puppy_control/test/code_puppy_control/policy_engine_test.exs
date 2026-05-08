defmodule CodePuppyControl.PolicyEngineTest do
  @moduledoc """
  Tests for the PolicyEngine.
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule
  alias CodePuppyControl.PolicyEngine.PolicyRule.{Allow, Deny, AskUser}

  describe "start_link/0" do
    test "starts the PolicyEngine GenServer" do
      # Reset to ensure clean state
      PolicyEngine.reset()
      assert PolicyEngine.running?()
    end
  end

  describe "check/2" do
    test "returns default (ask_user) when no rules match" do
      result = PolicyEngine.check("unknown_tool", %{})
      assert %AskUser{} = result
    end

    test "matches simple allow rule" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "read_file",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      result = PolicyEngine.check("read_file", %{"path" => "/tmp/test.txt"})
      assert %Allow{} = result
    end

    test "matches simple deny rule" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "delete_file",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      result = PolicyEngine.check("delete_file", %{"path" => "/tmp/test.txt"})
      assert %Deny{reason: reason} = result
      assert reason =~ "Denied by policy"
    end

    test "matches ask_user rule" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :ask_user,
        priority: 10,
        source: "test"
      })

      result = PolicyEngine.check("run_shell_command", %{"command" => "ls"})
      assert %AskUser{prompt: prompt} = result
      assert prompt =~ "user approval"
    end

    test "respects priority ordering" do
      # Lower priority rule (allows)
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "test_tool",
        decision: :allow,
        priority: 5,
        source: "test"
      })

      # Higher priority rule (denies)
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "test_tool",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      result = PolicyEngine.check("test_tool", %{})
      assert %Deny{} = result
    end

    test "wildcard * matches any tool" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "*",
        decision: :deny,
        priority: 1,
        source: "test"
      })

      result = PolicyEngine.check("any_tool", %{})
      assert %Deny{} = result
    end
  end

  describe "check_explicit/2" do
    test "returns nil when no explicit rule matches" do
      result = PolicyEngine.check_explicit("unknown_tool", %{})
      assert result == nil
    end

    test "returns decision when rule matches" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "read_file",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      result = PolicyEngine.check_explicit("read_file", %{})
      assert %Allow{} = result
    end
  end

  describe "command_pattern matching" do
    test "matches command with regex pattern" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        command_pattern: "^git\\s+",
        source: "test"
      })

      # Should match
      result = PolicyEngine.check("run_shell_command", %{"command" => "git status"})
      assert %Allow{} = result

      # Should not match
      result = PolicyEngine.check("run_shell_command", %{"command" => "rm -rf /"})
      assert %AskUser{} = result
    end

    test "handles invalid regex gracefully" do
      # Add rule with invalid regex - should compile as nil
      rule = %PolicyRule{
        tool_name: "test",
        decision: :allow,
        priority: 10,
        command_pattern: "[invalid(",
        source: "test"
      }

      # Should not crash
      PolicyEngine.add_rule(rule)

      # Rule should match (pattern is nil due to compilation failure)
      result = PolicyEngine.check("test", %{})
      assert %Allow{} = result
    end
  end

  describe "args_pattern matching" do
    test "matches args with regex pattern" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "read_file",
        decision: :deny,
        priority: 10,
        args_pattern: "\\/etc\\/",
        source: "test"
      })

      # Should match /etc in args
      result = PolicyEngine.check("read_file", %{"path" => "/etc/passwd"})
      assert %Deny{} = result

      # Should not match other paths
      result = PolicyEngine.check("read_file", %{"path" => "/tmp/file.txt"})
      assert %AskUser{} = result
    end
  end

  describe "check_shell_command/2" do
    test "handles simple command" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        command_pattern: "^ls\\b",
        source: "test"
      })

      result = PolicyEngine.check_shell_command("ls -la", nil)
      assert %Allow{} = result
    end

    test "handles compound commands with &&" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        command_pattern: "^ls\\b",
        source: "test"
      })

      # Both parts are 'ls', should allow
      result = PolicyEngine.check_shell_command("ls && ls", nil)
      assert %Allow{} = result
    end

    test "deny wins in compound commands" do
      # Allow ls
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        command_pattern: "^ls\\b",
        source: "test"
      })

      # Deny rm
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :deny,
        priority: 10,
        command_pattern: "^rm\\b",
        source: "test"
      })

      # Compound with both - deny wins
      result = PolicyEngine.check_shell_command("ls && rm file", nil)
      assert %Deny{} = result
    end

    test "ask_user beats allow in compound commands" do
      # Allow ls
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        command_pattern: "^ls\\b",
        source: "test"
      })

      # Ask for cat
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :ask_user,
        priority: 10,
        command_pattern: "^cat\\b",
        source: "test"
      })

      result = PolicyEngine.check_shell_command("ls && cat file", nil)
      assert %AskUser{} = result
    end
  end

  describe "check_shell_command_explicit/2" do
    test "returns nil when no explicit rule matches" do
      result = PolicyEngine.check_shell_command_explicit("unknown_command", nil)
      assert result == nil
    end

    test "returns decision when rule matches" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "run_shell_command",
        decision: :allow,
        priority: 10,
        command_pattern: "^echo\\b",
        source: "test"
      })

      result = PolicyEngine.check_shell_command_explicit("echo hello", nil)
      assert %Allow{} = result
    end
  end

  describe "rule management" do
    test "adds single rule" do
      :ok =
        PolicyEngine.add_rule(%PolicyRule{
          tool_name: "test",
          decision: :allow,
          priority: 1,
          source: "test"
        })

      rules = PolicyEngine.list_rules()
      assert length(rules) == 1
    end

    test "adds multiple rules" do
      rules = [
        %PolicyRule{tool_name: "test1", decision: :allow, priority: 1, source: "test"},
        %PolicyRule{tool_name: "test2", decision: :deny, priority: 2, source: "test"}
      ]

      :ok = PolicyEngine.add_rules(rules)
      all_rules = PolicyEngine.list_rules()
      assert length(all_rules) == 2
    end

    test "rules are sorted by priority" do
      :ok =
        PolicyEngine.add_rule(%PolicyRule{
          tool_name: "low",
          decision: :allow,
          priority: 1,
          source: "test"
        })

      :ok =
        PolicyEngine.add_rule(%PolicyRule{
          tool_name: "high",
          decision: :deny,
          priority: 10,
          source: "test"
        })

      [first, second] = PolicyEngine.list_rules()
      assert first.priority == 10
      assert second.priority == 1
    end

    test "removes rules by source" do
      :ok =
        PolicyEngine.add_rule(%PolicyRule{
          tool_name: "keep",
          decision: :allow,
          priority: 1,
          source: "keep"
        })

      :ok =
        PolicyEngine.add_rule(%PolicyRule{
          tool_name: "remove",
          decision: :deny,
          priority: 1,
          source: "remove"
        })

      :ok = PolicyEngine.remove_rules_by_source("remove")

      rules = PolicyEngine.list_rules()
      assert length(rules) == 1
      assert hd(rules).source == "keep"
    end
  end

  describe "JSON rule loading" do
    test "loads rules from JSON file" do
      json = ~s'''
      {
        "rules": [
          {"tool_name": "read_file", "decision": "allow", "priority": 10},
          {"tool_name": "delete_file", "decision": "deny", "priority": 20}
        ]
      }
      '''

      path = Path.join(System.tmp_dir!(), "test_policy_#{:rand.uniform(9999)}.json")
      File.write!(path, json)

      try do
        count = PolicyEngine.load_rules_from_file(path, "test")
        assert count == 2

        # Verify rules loaded
        result = PolicyEngine.check("read_file", %{"path" => "/tmp/test.txt"})
        assert %Allow{} = result
      after
        File.rm(path)
      end
    end

    test "handles missing file gracefully" do
      count = PolicyEngine.load_rules_from_file("/nonexistent/path/policy.json", "test")
      assert count == 0
    end

    test "handles invalid JSON gracefully" do
      path = Path.join(System.tmp_dir!(), "invalid_policy_#{:rand.uniform(9999)}.json")
      File.write!(path, "not valid json {")

      try do
        count = PolicyEngine.load_rules_from_file(path, "test")
        assert count == 0
      after
        File.rm(path)
      end
    end

    test "handles list format JSON" do
      json = ~s'''
      [
        {"tool_name": "test", "decision": "allow", "priority": 5}
      ]
      '''

      path = Path.join(System.tmp_dir!(), "list_policy_#{:rand.uniform(9999)}.json")
      File.write!(path, json)

      try do
        count = PolicyEngine.load_rules_from_file(path, "test")
        assert count == 1
      after
        File.rm(path)
      end
    end
  end

  describe "load_default_rules/0" do
    test "returns 0 when default files don't exist" do
      # Default files likely don't exist in test environment
      count = PolicyEngine.load_default_rules()
      assert is_integer(count)
      assert count >= 0
    end
  end

  describe "reset/0" do
    test "clears all rules and resets state" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "test",
        decision: :allow,
        priority: 1,
        source: "test"
      })

      # Verify rule exists
      assert length(PolicyEngine.list_rules()) == 1

      # Reset
      :ok = PolicyEngine.reset()

      # Verify cleared
      assert length(PolicyEngine.list_rules()) == 0
    end
  end

  describe "PolicyRule.new/1" do
    test "creates rule with compiled patterns" do
      rule =
        PolicyRule.new(
          tool_name: "test",
          decision: :allow,
          priority: 10,
          command_pattern: "^git\\s+",
          source: "test"
        )

      assert rule.tool_name == "test"
      assert rule.decision == :allow
      assert rule.priority == 10
      assert rule._compiled_command != nil
      assert Regex.match?(rule._compiled_command, "git status")
    end

    test "handles nil patterns" do
      rule =
        PolicyRule.new(
          tool_name: "test",
          decision: :allow,
          priority: 10,
          source: "test"
        )

      assert rule._compiled_command == nil
      assert rule._compiled_args == nil
    end
  end
end
