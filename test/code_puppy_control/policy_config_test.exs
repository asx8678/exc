defmodule CodePuppyControl.PolicyConfigTest do
  @moduledoc """
  Tests for the PolicyConfig module.
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.{PolicyConfig, PolicyEngine}
  alias CodePuppyControl.PolicyEngine.PolicyRule.Allow

  describe "user_policy_path/0" do
    test "returns path in home directory" do
      path = PolicyConfig.user_policy_path()
      assert String.contains?(path, ".code_puppy")
      assert String.ends_with?(path, "policy.json")
    end
  end

  describe "project_policy_path/0" do
    test "returns path in current directory" do
      path = PolicyConfig.project_policy_path()
      assert String.contains?(path, ".code_puppy")
      assert String.ends_with?(path, "policy.json")
    end
  end

  describe "policy_file_exists?/1" do
    test "returns false for non-existent file" do
      refute PolicyConfig.policy_file_exists?("/nonexistent/path/policy.json")
    end

    test "returns true for existing file" do
      path = Path.join(System.tmp_dir!(), "existing_policy_#{:rand.uniform(9999)}.json")
      File.write!(path, "{}")

      try do
        assert PolicyConfig.policy_file_exists?(path)
      after
        File.rm(path)
      end
    end
  end

  describe "create_sample_policy/1" do
    test "creates sample policy file" do
      path = Path.join(System.tmp_dir!(), "sample_policy_#{:rand.uniform(9999)}.json")

      try do
        assert :ok = PolicyConfig.create_sample_policy(path)
        assert File.exists?(path)

        content = File.read!(path)
        decoded = Jason.decode!(content)
        assert is_list(decoded["rules"])
        assert length(decoded["rules"]) > 0
      after
        File.rm(path)
      end
    end

    test "returns error if file already exists" do
      path = Path.join(System.tmp_dir!(), "duplicate_policy_#{:rand.uniform(9999)}.json")
      File.write!(path, "{}")

      try do
        assert {:error, _} = PolicyConfig.create_sample_policy(path)
      after
        File.rm(path)
      end
    end

    test "creates parent directories if needed" do
      dir = Path.join(System.tmp_dir!(), "code_puppy_test_#{:rand.uniform(9999)}")
      path = Path.join(dir, "policy.json")

      try do
        assert :ok = PolicyConfig.create_sample_policy(path)
        assert File.exists?(path)
        assert File.dir?(dir)
      after
        File.rm(path)
        File.rmdir(dir)
      end
    end
  end

  describe "load_policy_rules/2" do
    test "loads rules from custom paths" do
      json = ~s'''
      {"rules": [{"tool_name": "test_tool", "decision": "allow", "priority": 10}]}
      '''

      user_path = Path.join(System.tmp_dir!(), "user_policy_#{:rand.uniform(9999)}.json")
      project_path = Path.join(System.tmp_dir!(), "project_policy_#{:rand.uniform(9999)}.json")
      File.write!(user_path, json)
      File.write!(project_path, "{\"rules\": []}")

      try do
        count =
          PolicyConfig.load_policy_rules(PolicyEngine.get_engine(),
            user_policy: user_path,
            project_policy: project_path
          )

        assert count == 1

        # Verify rule was loaded
        result = PolicyEngine.check("test_tool", %{})
        assert %Allow{} = result
      after
        File.rm(user_path)
        File.rm(project_path)
      end
    end

    test "counts total rules from both files" do
      user_json = ~s'''
      {"rules": [
        {"tool_name": "tool1", "decision": "allow", "priority": 5},
        {"tool_name": "tool2", "decision": "deny", "priority": 5}
      ]}
      '''

      project_json = ~s'''
      {"rules": [
        {"tool_name": "tool3", "decision": "ask_user", "priority": 10}
      ]}
      '''

      user_path = Path.join(System.tmp_dir!(), "user_policy_#{:rand.uniform(9999)}.json")
      project_path = Path.join(System.tmp_dir!(), "project_policy_#{:rand.uniform(9999)}.json")
      File.write!(user_path, user_json)
      File.write!(project_path, project_json)

      try do
        count =
          PolicyConfig.load_policy_rules(PolicyEngine.get_engine(),
            user_policy: user_path,
            project_policy: project_path
          )

        assert count == 3
      after
        File.rm(user_path)
        File.rm(project_path)
      end
    end

    test "handles missing files gracefully" do
      count =
        PolicyConfig.load_policy_rules(PolicyEngine.get_engine(),
          user_policy: "/nonexistent/path.json",
          project_policy: "/another/nonexistent/path.json"
        )

      assert count == 0
    end
  end

  describe "status/0" do
    test "returns status map" do
      status = PolicyConfig.status()

      assert is_map(status)
      assert Map.has_key?(status, :user_policy)
      assert Map.has_key?(status, :project_policy)
      assert Map.has_key?(status, :engine_running)

      assert is_boolean(status.user_policy.exists)
      assert is_boolean(status.project_policy.exists)
      assert is_boolean(status.engine_running)

      # Check that engine is running
      assert status.engine_running
    end

    test "status includes correct paths" do
      status = PolicyConfig.status()

      assert status.user_policy.path == PolicyConfig.user_policy_path()
      assert status.project_policy.path == PolicyConfig.project_policy_path()
    end
  end

  describe "integration with PolicyEngine" do
    test "rules from different sources can be distinguished" do
      user_json = ~s'''
      {"rules": [{"tool_name": "source_test", "decision": "allow", "priority": 5}]}
      '''

      user_path = Path.join(System.tmp_dir!(), "source_user_policy_#{:rand.uniform(9999)}.json")
      File.write!(user_path, user_json)

      try do
        PolicyConfig.load_policy_rules(PolicyEngine.get_engine(),
          user_policy: user_path,
          project_policy: "/nonexistent.json"
        )

        rules = PolicyEngine.list_rules()
        [rule] = rules

        # Rules loaded via load_policy_rules get "user" or "project" as source
        assert rule.source == "user"
      after
        File.rm(user_path)
      end
    end

    test "rules loaded directly from file preserve file path as source" do
      user_json = ~s'''
      {"rules": [{"tool_name": "path_source_test", "decision": "allow", "priority": 5}]}
      '''

      user_path = Path.join(System.tmp_dir!(), "path_source_policy_#{:rand.uniform(9999)}.json")
      File.write!(user_path, user_json)

      try do
        # Load directly via load_rules_from_file with nil source (defaults to path)
        PolicyEngine.load_rules_from_file(user_path, nil)

        rules = PolicyEngine.list_rules()
        # Find our rule
        rule = Enum.find(rules, &(&1.tool_name == "path_source_test"))

        assert rule != nil
        # When source is nil, it defaults to the file path
        assert rule.source == user_path
      after
        File.rm(user_path)
      end
    end
  end
end
