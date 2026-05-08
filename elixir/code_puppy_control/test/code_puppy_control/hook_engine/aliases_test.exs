defmodule CodePuppyControl.HookEngine.AliasesTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.HookEngine.Aliases

  setup do
    # Reset cache before each test to ensure clean state
    Aliases.reset_cache()
    :ok
  end

  describe "get_aliases/1" do
    test "returns alias set for known provider tool" do
      aliases = Aliases.get_aliases("Bash")
      assert MapSet.member?(aliases, "Bash")
      assert MapSet.member?(aliases, "agent_run_shell_command")
    end

    test "returns alias set for internal tool name" do
      aliases = Aliases.get_aliases("agent_run_shell_command")
      assert MapSet.member?(aliases, "Bash")
      assert MapSet.member?(aliases, "agent_run_shell_command")
    end

    test "returns self-only set for unknown tool" do
      aliases = Aliases.get_aliases("totally_unknown_tool")
      assert MapSet.size(aliases) == 1
      assert MapSet.member?(aliases, "totally_unknown_tool")
    end

    test "case-insensitive lookup" do
      aliases = Aliases.get_aliases("bash")
      assert MapSet.member?(aliases, "Bash")
      assert MapSet.member?(aliases, "agent_run_shell_command")
    end

    test "Read maps to read_file" do
      aliases = Aliases.get_aliases("Read")
      assert MapSet.member?(aliases, "read_file")
    end

    test "Edit maps to replace_in_file" do
      aliases = Aliases.get_aliases("Edit")
      assert MapSet.member?(aliases, "replace_in_file")
    end

    test "Write maps to create_file" do
      aliases = Aliases.get_aliases("Write")
      assert MapSet.member?(aliases, "create_file")
    end
  end

  describe "resolve_internal_name/1" do
    test "resolves Bash to agent_run_shell_command" do
      assert Aliases.resolve_internal_name("Bash") == "agent_run_shell_command"
    end

    test "resolves Read to read_file" do
      assert Aliases.resolve_internal_name("Read") == "read_file"
    end

    test "returns nil for unknown tool" do
      assert Aliases.resolve_internal_name("unknown") == nil
    end

    test "case-insensitive" do
      assert Aliases.resolve_internal_name("bash") == "agent_run_shell_command"
    end
  end

  describe "internal_to_provider_map/0" do
    test "maps internal names to provider names" do
      map = Aliases.internal_to_provider_map()
      assert Map.has_key?(map, "agent_run_shell_command")
      assert "Bash" in map["agent_run_shell_command"]
    end
  end

  describe "provider_aliases/0" do
    test "returns claude aliases" do
      aliases = Aliases.provider_aliases()
      assert Map.has_key?(aliases, :claude)
      assert map_size(aliases.claude) > 0
    end

    test "includes placeholder providers" do
      aliases = Aliases.provider_aliases()
      assert Map.has_key?(aliases, :gemini)
      assert Map.has_key?(aliases, :codex)
      assert Map.has_key?(aliases, :swarm)
    end
  end
end
