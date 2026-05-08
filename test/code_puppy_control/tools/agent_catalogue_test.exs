defmodule CodePuppyControl.Tools.AgentCatalogueTest do
  @moduledoc """
  Tests for the AgentCatalogue module.

  Covers:
  - Agent registration
  - Agent listing
  - Agent info retrieval
  - Agent unregistration
  - Batch registration
  - Catalogue clearing
  """

  use ExUnit.Case

  alias CodePuppyControl.Tools.AgentCatalogue

  # Setup to ensure clean state for each test
  setup do
    # Clear the catalogue before each test
    :ok = AgentCatalogue.clear_catalogue()
    :ok
  end

  describe "register_agent/3" do
    test "registers a new agent" do
      assert :ok =
               AgentCatalogue.register_agent("elixir-dev", "Elixir Developer", "Elixir expert")
    end

    test "overwrites existing agent registration" do
      AgentCatalogue.register_agent("test-agent", "Old Name", "Old description")
      AgentCatalogue.register_agent("test-agent", "New Name", "New description")

      {:ok, info} = AgentCatalogue.get_agent_info("test-agent")
      assert info.display_name == "New Name"
      assert info.description == "New description"
    end
  end

  describe "list_agents/0" do
    test "returns empty list when no agents registered" do
      assert [] = AgentCatalogue.list_agents()
    end

    test "returns list of registered agents" do
      AgentCatalogue.register_agent("agent-1", "Agent One", "Description one")
      AgentCatalogue.register_agent("agent-2", "Agent Two", "Description two")

      agents = AgentCatalogue.list_agents()
      assert length(agents) == 2

      names = Enum.map(agents, fn a -> a.name end)
      assert "agent-1" in names
      assert "agent-2" in names
    end

    test "returns agents sorted by name" do
      AgentCatalogue.register_agent("charlie-agent", "Charlie", "Desc")
      AgentCatalogue.register_agent("alpha-agent", "Alpha", "Desc")
      AgentCatalogue.register_agent("bravo-agent", "Bravo", "Desc")

      agents = AgentCatalogue.list_agents()
      names = Enum.map(agents, fn a -> a.name end)
      assert names == ["alpha-agent", "bravo-agent", "charlie-agent"]
    end
  end

  describe "get_agent_info/1" do
    test "returns agent info for existing agent" do
      AgentCatalogue.register_agent("elixir-dev", "Elixir Developer", "Elixir/OTP expert")

      assert {:ok, info} = AgentCatalogue.get_agent_info("elixir-dev")
      assert info.name == "elixir-dev"
      assert info.display_name == "Elixir Developer"
      assert info.description == "Elixir/OTP expert"
    end

    test "returns :not_found for unregistered agent" do
      assert :not_found = AgentCatalogue.get_agent_info("non-existent")
    end
  end

  describe "unregister_agent/1" do
    test "removes a registered agent" do
      AgentCatalogue.register_agent("test-agent", "Test", "Description")
      assert :ok = AgentCatalogue.unregister_agent("test-agent")
      assert :not_found = AgentCatalogue.get_agent_info("test-agent")
    end

    test "succeeds even if agent doesn't exist" do
      assert :ok = AgentCatalogue.unregister_agent("never-registered")
    end
  end

  describe "clear_catalogue/0" do
    test "removes all registered agents" do
      AgentCatalogue.register_agent("agent-1", "Agent One", "Desc")
      AgentCatalogue.register_agent("agent-2", "Agent Two", "Desc")

      assert :ok = AgentCatalogue.clear_catalogue()

      assert [] = AgentCatalogue.list_agents()
      assert :not_found = AgentCatalogue.get_agent_info("agent-1")
      assert :not_found = AgentCatalogue.get_agent_info("agent-2")
    end
  end

  describe "register_agents/1" do
    test "registers multiple agents at once" do
      agents = [
        {"agent-1", "Agent One", "First agent"},
        {"agent-2", "Agent Two", "Second agent"},
        {"agent-3", "Agent Three", "Third agent"}
      ]

      assert {:ok, 3} = AgentCatalogue.register_agents(agents)

      assert length(AgentCatalogue.list_agents()) == 3
    end

    test "returns count of registered agents" do
      agents = [
        {"agent-a", "Agent A", "Desc A"},
        {"agent-b", "Agent B", "Desc B"}
      ]

      assert {:ok, 2} = AgentCatalogue.register_agents(agents)
    end

    test "handles empty list" do
      assert {:ok, 0} = AgentCatalogue.register_agents([])
    end
  end

  describe "AgentInfo struct" do
    alias CodePuppyControl.Tools.AgentCatalogue.AgentInfo

    test "can be created with new/3" do
      info = AgentInfo.new("my-agent", "My Agent", "Does things")
      assert info.name == "my-agent"
      assert info.display_name == "My Agent"
      assert info.description == "Does things"
    end

    test "is JSON encodable" do
      info = AgentInfo.new("test-agent", "Test", "Description")
      json = Jason.encode!(info)
      assert is_binary(json)
      assert json =~ "test-agent"
      assert json =~ "Test"
      assert json =~ "Description"
    end
  end

  describe "discover_agent_modules/0" do
    test "discovers agent modules in the Agents namespace" do
      results = AgentCatalogue.discover_agent_modules()

      assert length(results) >= 8

      names = Enum.map(results, fn {_mod, name, _display, _desc} -> name end)

      # Core agents
      assert :code_puppy in names
      assert :pack_leader in names
      assert :code_reviewer in names
      assert :code_scout in names
      assert :security_auditor in names
      assert :qa_expert in names
      assert :qa_kitten in names
      assert :python_programmer in names

      # Pack sub-agents
      assert :retriever in names
      assert :shepherd in names
      assert :terrier in names
      assert :watchdog in names
    end

    test "each discovered module has correct structure" do
      for {mod, name, display_name, description} <- AgentCatalogue.discover_agent_modules() do
        assert is_atom(mod)
        assert is_atom(name)
        assert is_binary(display_name)
        assert is_binary(description)
        assert String.length(display_name) > 0
        assert String.length(description) > 0

        # The module should actually implement the callbacks
        assert function_exported?(mod, :name, 0)
        assert function_exported?(mod, :system_prompt, 1)
        assert mod.name() == name
      end
    end

    test "derives display names correctly from atom" do
      results = AgentCatalogue.discover_agent_modules()
      result_map = Map.new(results, fn {_mod, name, display, _desc} -> {name, display} end)

      assert result_map[:code_puppy] == "Code Puppy"
      assert result_map[:pack_leader] == "Pack Leader"
      assert result_map[:qa_expert] == "QA Expert"
      assert result_map[:code_reviewer] == "Code Reviewer"
      assert result_map[:python_programmer] == "Python Programmer"
      assert result_map[:security_auditor] == "Security Auditor"
    end

    test "descriptions are extracted from moduledoc" do
      results = AgentCatalogue.discover_agent_modules()
      result_map = Map.new(results, fn {_mod, name, _display, desc} -> {name, desc} end)

      # Code Puppy: "The Code Puppy — a helpful, friendly AI coding assistant."
      assert result_map[:code_puppy] =~ "helpful"
      assert result_map[:code_puppy] =~ "AI"

      # Pack Leader: "The Pack Leader — orchestration agent that coordinates..."
      assert result_map[:pack_leader] =~ "Orchestration"

      # QA Expert preserves "QA" acronym
      assert result_map[:qa_expert] =~ "QA"
    end
  end

  describe "get_agent_module/1" do
    alias CodePuppyControl.Tools.AgentCatalogue.AgentInfo

    setup do
      # Clear catalogue and re-register a known agent with a module
      # (auto-discovered agents are cleared by the shared setup, so we
      # manually insert one for testing)
      AgentCatalogue.clear_catalogue()

      info =
        AgentInfo.new("test_mod_agent", "Test Agent", "Test", CodePuppyControl.Agents.CodePuppy)

      :ets.insert(:agent_catalogue, {"test_mod_agent", info})

      :ok
    end

    test "returns module for atom name" do
      assert {:ok, CodePuppyControl.Agents.CodePuppy} =
               AgentCatalogue.get_agent_module(:test_mod_agent)
    end

    test "returns module for string name" do
      assert {:ok, CodePuppyControl.Agents.CodePuppy} =
               AgentCatalogue.get_agent_module("test_mod_agent")
    end

    test "returns :not_found for unknown agent" do
      assert :not_found = AgentCatalogue.get_agent_module(:nonexistent_agent)
      assert :not_found = AgentCatalogue.get_agent_module("nonexistent_agent")
    end

    test "returns error for manually registered agent without module" do
      AgentCatalogue.register_agent("manual_agent", "Manual", "No module here")

      assert {:error, :no_module} = AgentCatalogue.get_agent_module(:manual_agent)
    end
  end

  describe "get_agent_info/1 with atom" do
    test "accepts atom name and looks up by string" do
      # Register with underscored string (matching to_string(:atom_test))
      AgentCatalogue.register_agent("atom_test", "Atom Test", "Atom lookup test")

      assert {:ok, info} = AgentCatalogue.get_agent_info(:atom_test)
      assert info.name == "atom_test"
    end
  end

  describe "AgentInfo with module field" do
    alias CodePuppyControl.Tools.AgentCatalogue.AgentInfo

    test "can be created with module" do
      info =
        AgentInfo.new("mod-agent", "Mod Agent", "Has module", CodePuppyControl.Agents.CodePuppy)

      assert info.module == CodePuppyControl.Agents.CodePuppy
    end

    test "module defaults to nil" do
      info = AgentInfo.new("no-mod-agent", "No Mod Agent", "No module")
      assert info.module == nil
    end

    test "is JSON encodable even with module" do
      info =
        AgentInfo.new("json-agent", "JSON Agent", "JSON test", CodePuppyControl.Agents.CodePuppy)

      json = Jason.encode!(info)
      assert is_binary(json)
      assert json =~ "json-agent"
      assert json =~ "JSON Agent"
    end
  end
end
