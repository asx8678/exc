defmodule CodePuppyControl.Agents.HeliosTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agents.Helios

  describe "helios agent" do
    test "name/0 returns :helios" do
      assert Helios.name() == :helios
    end

    test "display_name/0 returns 'Helios ☀️'" do
      assert Helios.display_name() == "Helios ☀️"
    end

    test "description/0 returns the description" do
      assert Helios.description() =~ "Universal Constructor"
    end

    test "system_prompt/1 returns a non-empty string" do
      prompt = Helios.system_prompt(%{})
      assert is_binary(prompt)
      assert prompt =~ "Helios"
      assert prompt =~ "Universal Constructor"
    end

    test "allowed_tools/0 returns the list of tools" do
      tools = Helios.allowed_tools()
      assert is_list(tools)
      assert :cp_universal_constructor in tools
      assert :cp_list_files in tools
      assert :cp_read_file in tools
      assert :cp_grep in tools
      assert :cp_create_file in tools
      assert :cp_replace_in_file in tools
      assert :cp_delete_snippet in tools
      assert :cp_delete_file in tools
      assert :cp_run_command in tools
    end

    test "model_preference/0 returns a model string" do
      assert Helios.model_preference() =~ "claude-sonnet"
    end

    test "user_prompt/0 returns the greeting" do
      assert Helios.user_prompt() =~ "This is what I was made for"
    end

    test "agent is discoverable by catalogue" do
      # This test verifies that the agent module can be discovered
      # by the agent catalogue system
      assert function_exported?(Helios, :name, 0)
      assert function_exported?(Helios, :display_name, 0)
      assert function_exported?(Helios, :description, 0)
      assert function_exported?(Helios, :system_prompt, 1)
      assert function_exported?(Helios, :allowed_tools, 0)
      assert function_exported?(Helios, :model_preference, 0)
      assert function_exported?(Helios, :user_prompt, 0)
    end
  end
end
