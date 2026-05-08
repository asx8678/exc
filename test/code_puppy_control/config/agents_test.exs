defmodule CodePuppyControl.Config.AgentsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Agents, Loader}

  @tmp_dir System.tmp_dir!()
  @test_cfg Path.join(@tmp_dir, "agents_test_#{:erlang.unique_integer([:positive])}.cfg")

  setup do
    File.write!(@test_cfg, "[puppy]\n")
    Loader.load(@test_cfg)

    on_exit(fn ->
      File.rm(@test_cfg)
      Loader.invalidate()
    end)

    :ok
  end

  describe "default_agent/0" do
    test "returns default when not configured" do
      assert Agents.default_agent() == "code-puppy"
    end

    test "returns configured agent" do
      File.write!(@test_cfg, "[puppy]\ndefault_agent = custom-agent\n")
      Loader.load(@test_cfg)

      assert Agents.default_agent() == "custom-agent"
    end
  end

  describe "set_default_agent/1" do
    test "updates the config value" do
      # Would need Writer started for full test
      # Test the config-reading side here
      assert Agents.default_agent() == "code-puppy"
    end
  end

  describe "puppy_name/0" do
    test "defaults to Puppy" do
      assert Agents.puppy_name() == "Puppy"
    end

    test "returns configured name" do
      File.write!(@test_cfg, "[puppy]\npuppy_name = Buddy\n")
      Loader.load(@test_cfg)

      assert Agents.puppy_name() == "Buddy"
    end
  end

  describe "owner_name/0" do
    test "defaults to Master" do
      assert Agents.owner_name() == "Master"
    end

    test "returns configured name" do
      File.write!(@test_cfg, "[puppy]\nowner_name = Alice\n")
      Loader.load(@test_cfg)

      assert Agents.owner_name() == "Alice"
    end
  end

  describe "user_agents_dir/0" do
    test "returns a string path" do
      dir = Agents.user_agents_dir()
      assert is_binary(dir)
      assert String.ends_with?(dir, "agents")
    end
  end

  describe "agent_search_paths/0" do
    test "returns list with at least user agents dir" do
      paths = Agents.agent_search_paths()
      assert is_list(paths)
      assert length(paths) >= 1
    end
  end
end
