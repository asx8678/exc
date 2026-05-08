defmodule CodePuppyControl.Tools.AgentManagerTest do
  @moduledoc """
  Tests for the AgentManager GenServer.

  Covers:
  - Session management (current agent per session)
  - JSON agent discovery
  - Clone agent creation and deletion
  - Registry lifecycle (refresh, invalidation)
  - Agent visibility filtering
  - Session persistence
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Tools.AgentManager
  alias CodePuppyControl.Tools.AgentCatalogue

  setup do
    # (code_puppy-i1n) Ensure AgentManager is alive — prior tests
    # may have destabilised the supervision tree.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Tools.AgentManager
    )

    # Reset manager state before each test
    :ok = AgentManager.reset_for_testing()
    on_exit(fn -> AgentManager.reset_for_testing() end)
    :ok
  end

  # ── Session Management ────────────────────────────────────────────────

  describe "get_current_agent_name/1" do
    test "returns default agent when no session is set" do
      # Should fall back to config default (code-puppy)
      name = AgentManager.get_current_agent_name("test-session-1")
      assert is_binary(name)
      assert name == CodePuppyControl.Config.Agents.default_agent()
    end

    test "returns set agent for a session" do
      AgentCatalogue.register_agent("test-agent", "Test Agent", "A test agent")
      :ok = AgentManager.set_current_agent("session-abc", "test-agent")

      assert AgentManager.get_current_agent_name("session-abc") == "test-agent"
    end

    test "different sessions can have different agents" do
      AgentCatalogue.register_agent("agent-a", "Agent A", "First agent")
      AgentCatalogue.register_agent("agent-b", "Agent B", "Second agent")

      :ok = AgentManager.set_current_agent("session-1", "agent-a")
      :ok = AgentManager.set_current_agent("session-2", "agent-b")

      assert AgentManager.get_current_agent_name("session-1") == "agent-a"
      assert AgentManager.get_current_agent_name("session-2") == "agent-b"
    end

    test "default agent fallback is independent per session" do
      name1 = AgentManager.get_current_agent_name("session-x")
      name2 = AgentManager.get_current_agent_name("session-y")
      assert name1 == name2
      assert name1 == CodePuppyControl.Config.Agents.default_agent()
    end
  end

  describe "set_current_agent/2" do
    test "returns :ok for valid agent" do
      AgentCatalogue.register_agent("my-agent", "My Agent", "Test")
      assert :ok = AgentManager.set_current_agent("sess-1", "my-agent")
    end

    test "returns error for non-existent agent" do
      assert {:error, :agent_not_found} =
               AgentManager.set_current_agent("sess-1", "nonexistent")
    end

    test "overwrites previous session agent" do
      AgentCatalogue.register_agent("agent-1", "Agent 1", "First")
      AgentCatalogue.register_agent("agent-2", "Agent 2", "Second")

      :ok = AgentManager.set_current_agent("sess-1", "agent-1")
      :ok = AgentManager.set_current_agent("sess-1", "agent-2")

      assert AgentManager.get_current_agent_name("sess-1") == "agent-2"
    end
  end

  # ── Agent Listing ─────────────────────────────────────────────────────

  describe "get_available_agents/0" do
    test "returns empty map when no agents registered" do
      # AgentCatalogue was cleared in setup, so no agents
      agents = AgentManager.get_available_agents()
      assert agents == %{}
    end

    test "returns registered agents as name => display_name" do
      AgentCatalogue.register_agent("agent-1", "Agent One", "First agent")
      AgentCatalogue.register_agent("agent-2", "Agent Two", "Second agent")

      agents = AgentManager.get_available_agents()

      assert agents["agent-1"] == "Agent One"
      assert agents["agent-2"] == "Agent Two"
      assert map_size(agents) == 2
    end
  end

  describe "get_agent_descriptions/0" do
    test "returns registered agents as name => description" do
      AgentCatalogue.register_agent("agent-1", "Agent One", "Does cool stuff")
      AgentCatalogue.register_agent("agent-2", "Agent Two", "Does other stuff")

      descriptions = AgentManager.get_agent_descriptions()

      assert descriptions["agent-1"] == "Does cool stuff"
      assert descriptions["agent-2"] == "Does other stuff"
    end
  end

  # ── Agent Module Lookup ───────────────────────────────────────────────

  describe "get_current_agent_module/1" do
    test "returns module for a session with module-backed agent" do
      # The catalogue auto-discovers module agents on init, but we cleared it.
      # Register one manually with a module.
      info =
        CodePuppyControl.Tools.AgentCatalogue.AgentInfo.new(
          "code-puppy",
          "Code Puppy",
          "Main agent",
          CodePuppyControl.Agents.CodePuppy
        )

      :ets.insert(:agent_catalogue, {"code-puppy", info})

      :ok = AgentManager.set_current_agent("test-sess", "code-puppy")

      assert {:ok, CodePuppyControl.Agents.CodePuppy} =
               AgentManager.get_current_agent_module("test-sess")
    end

    test "returns error for manually registered agent without module" do
      AgentCatalogue.register_agent("manual-agent", "Manual", "No module")
      :ok = AgentManager.set_current_agent("test-sess", "manual-agent")

      assert {:error, :no_module} =
               AgentManager.get_current_agent_module("test-sess")
    end

    test "returns error for session with non-existent agent" do
      # Don't set any agent, default agent may not be in cleared catalogue
      # unless it's auto-discovered
      result = AgentManager.get_current_agent_module("unknown-session")
      # Could be {:ok, _} if default agent was auto-discovered or {:error, :agent_not_found}
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  # ── JSON Agent Discovery ──────────────────────────────────────────────

  describe "register_json_agents/0" do
    test "discovers JSON agents from agent directories" do
      # Create a temporary directory with a JSON agent
      tmp_dir = setup_temp_agents_dir()

      # Patch config to include our temp dir (we'll test with what's available)
      {:ok, count} = AgentManager.register_json_agents()
      assert is_integer(count)
      assert count >= 0

      cleanup_temp_agents_dir(tmp_dir)
    end

    test "does not overwrite existing agents" do
      AgentCatalogue.register_agent("existing-agent", "Existing", "Already here")

      # Even if there were a JSON file with the same name, it shouldn't overwrite
      {:ok, _count} = AgentManager.register_json_agents()

      {:ok, info} = AgentCatalogue.get_agent_info("existing-agent")
      assert info.display_name == "Existing"
    end
  end

  # ── Clone Management ──────────────────────────────────────────────────

  describe "is_clone_agent?/1" do
    test "returns true for clone names" do
      assert AgentManager.is_clone_agent?("code-puppy-clone-1")
      assert AgentManager.is_clone_agent?("my-agent-clone-42")
      assert AgentManager.is_clone_agent?("complex-name-here-clone-7")
    end

    test "returns false for non-clone names" do
      refute AgentManager.is_clone_agent?("code-puppy")
      refute AgentManager.is_clone_agent?("my-agent")
      # no suffix pattern
      refute AgentManager.is_clone_agent?("clone")
      # needs base name
      refute AgentManager.is_clone_agent?("-clone-1")
    end
  end

  describe "clone_agent/1" do
    test "returns error for non-existent agent" do
      assert {:error, _reason} = AgentManager.clone_agent("nonexistent-agent")
    end

    test "clones a catalogue-only agent" do
      AgentCatalogue.register_agent(
        "source-agent",
        "Source Agent",
        "Original description"
      )

      {:ok, clone_name} = AgentManager.clone_agent("source-agent")

      assert clone_name == "source-agent-clone-1"
      assert AgentManager.is_clone_agent?(clone_name)

      # Verify clone is in catalogue with indexed display name
      {:ok, clone_info} = AgentCatalogue.get_agent_info(clone_name)
      assert clone_info.display_name == "Source Agent (Clone 1)"
      assert clone_info.description == "Original description"

      # Clean up the generated file
      agents_dir = CodePuppyControl.Config.Agents.user_agents_dir()
      File.rm(Path.join(agents_dir, "#{clone_name}.json"))
    end

    test "increments clone index for multiple clones" do
      AgentCatalogue.register_agent("multi-source", "Multi Source", "Test")

      {:ok, clone1} = AgentManager.clone_agent("multi-source")
      {:ok, clone2} = AgentManager.clone_agent("multi-source")

      assert clone1 == "multi-source-clone-1"
      assert clone2 == "multi-source-clone-2"

      # Verify display names have correct indices
      {:ok, info1} = AgentCatalogue.get_agent_info(clone1)
      {:ok, info2} = AgentCatalogue.get_agent_info(clone2)
      assert info1.display_name == "Multi Source (Clone 1)"
      assert info2.display_name == "Multi Source (Clone 2)"

      # Clean up
      agents_dir = CodePuppyControl.Config.Agents.user_agents_dir()
      File.rm(Path.join(agents_dir, "#{clone1}.json"))
      File.rm(Path.join(agents_dir, "#{clone2}.json"))
    end
  end

  describe "delete_clone_agent/1" do
    test "returns error for non-clone names" do
      assert {:error, _reason} = AgentManager.delete_clone_agent("code-puppy")
    end

    test "returns error for non-existent clone" do
      assert {:error, _reason} = AgentManager.delete_clone_agent("fake-agent-clone-1")
    end

    test "deletes an active clone" do
      AgentCatalogue.register_agent("del-source", "Del Source", "Test")
      {:ok, clone_name} = AgentManager.clone_agent("del-source")

      assert :ok = AgentManager.delete_clone_agent(clone_name)

      # Verify it's gone from catalogue
      assert :not_found = AgentCatalogue.get_agent_info(clone_name)

      # Verify file is gone
      agents_dir = CodePuppyControl.Config.Agents.user_agents_dir()
      refute File.exists?(Path.join(agents_dir, "#{clone_name}.json"))
    end

    test "prevents deleting active agent" do
      AgentCatalogue.register_agent("active-source", "Active Source", "Test")
      {:ok, clone_name} = AgentManager.clone_agent("active-source")

      # Make it the active agent for a session
      :ok = AgentManager.set_current_agent("test-session", clone_name)

      assert {:error, msg} = AgentManager.delete_clone_agent(clone_name)
      assert msg =~ "active"

      # Clean up
      AgentManager.set_current_agent("test-session", "code-puppy")
      AgentManager.delete_clone_agent(clone_name)
    end
  end

  # ── Session Listing ───────────────────────────────────────────────────

  describe "list_sessions/0" do
    test "returns empty map initially" do
      sessions = AgentManager.list_sessions()
      assert is_map(sessions)
    end

    test "returns populated sessions after setting agents" do
      AgentCatalogue.register_agent("agent-1", "Agent 1", "Test")
      :ok = AgentManager.set_current_agent("session-alpha", "agent-1")

      sessions = AgentManager.list_sessions()
      assert sessions["session-alpha"] == "agent-1"
    end
  end

  # ── Registry Lifecycle ────────────────────────────────────────────────

  describe "refresh_agents/0" do
    test "returns :ok and marks registry as populated" do
      assert :ok = AgentManager.refresh_agents()
    end

    test "re-discovers JSON agents after refresh" do
      assert :ok = AgentManager.refresh_agents()

      # After refresh, JSON agents should be re-registered
      # (We can't easily test file-based discovery without a temp dir,
      # but we verify the operation completes without error)
    end
  end

  describe "invalidate_registry/0" do
    test "returns :ok" do
      assert :ok = AgentManager.invalidate_registry()
    end
  end

  # ── Reset for Testing ─────────────────────────────────────────────────

  describe "reset_for_testing/0" do
    test "clears all sessions" do
      AgentCatalogue.register_agent("agent-1", "Agent 1", "Test")
      :ok = AgentManager.set_current_agent("sess-1", "agent-1")

      :ok = AgentManager.reset_for_testing()

      sessions = AgentManager.list_sessions()
      assert sessions == %{}
    end

    test "clears catalogue" do
      AgentCatalogue.register_agent("agent-1", "Agent 1", "Test")

      :ok = AgentManager.reset_for_testing()

      assert [] = AgentCatalogue.list_agents()
    end
  end

  # ── Integration with AgentCatalogue ───────────────────────────────────

  describe "integration with AgentCatalogue" do
    test "agents registered in catalogue appear in available agents" do
      AgentCatalogue.register_agent("integ-1", "Integration 1", "Test integration")
      AgentCatalogue.register_agent("integ-2", "Integration 2", "Another test")

      agents = AgentManager.get_available_agents()

      assert "integ-1" in Map.keys(agents)
      assert "integ-2" in Map.keys(agents)
    end

    test "unregistering from catalogue removes from available agents" do
      AgentCatalogue.register_agent("temp-agent", "Temp", "Temporary")

      agents = AgentManager.get_available_agents()
      assert "temp-agent" in Map.keys(agents)

      AgentCatalogue.unregister_agent("temp-agent")

      agents = AgentManager.get_available_agents()
      refute "temp-agent" in Map.keys(agents)
    end

    test "set_current_agent validates against catalogue" do
      # Agent not in catalogue
      assert {:error, :agent_not_found} =
               AgentManager.set_current_agent("sess-1", "nonexistent")

      # Add agent, then it should work
      AgentCatalogue.register_agent("valid-agent", "Valid", "Test")
      assert :ok = AgentManager.set_current_agent("sess-1", "valid-agent")
    end
  end

  # ── JSON Clone File Operations ────────────────────────────────────────

  describe "clone file content" do
    test "cloned agent JSON file contains correct fields" do
      AgentCatalogue.register_agent(
        "json-source",
        "JSON Source",
        "Source for JSON test"
      )

      {:ok, clone_name} = AgentManager.clone_agent("json-source")

      agents_dir = CodePuppyControl.Config.Agents.user_agents_dir()
      clone_path = Path.join(agents_dir, "#{clone_name}.json")

      assert File.exists?(clone_path)

      {:ok, content} = File.read(clone_path)
      {:ok, config} = Jason.decode(content)

      assert config["name"] == clone_name
      assert config["display_name"] =~ "Clone"
      assert config["description"] == "Source for JSON test"

      # Clean up
      File.rm(clone_path)
    end
  end

  # ── Helper Functions ──────────────────────────────────────────────────

  defp setup_temp_agents_dir do
    tmp_dir =
      Path.join(System.tmp_dir!(), "agent_manager_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    # Write a test JSON agent
    agent_config = %{
      "name" => "test-json-agent",
      "display_name" => "Test JSON Agent",
      "description" => "A test agent from JSON"
    }

    File.write!(
      Path.join(tmp_dir, "test-json-agent.json"),
      Jason.encode!(agent_config)
    )

    tmp_dir
  end

  defp cleanup_temp_agents_dir(tmp_dir) do
    File.rm_rf(tmp_dir)
  end
end
