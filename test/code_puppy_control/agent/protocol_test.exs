defmodule CodePuppyControl.Agent.ProtocolTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.Protocol

  defmodule TestAgent do
    use CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :test_agent

    @impl true
    def system_prompt(_context), do: "You are a test agent."

    @impl true
    def allowed_tools, do: [:test_tool]

    @impl true
    def model_preference, do: "test-model"
  end

  describe "Atom implementation" do
    test "name/1 dispatches to module callback" do
      assert Protocol.name(TestAgent) == :test_agent
    end

    test "system_prompt/2 dispatches to module callback" do
      assert Protocol.system_prompt(TestAgent, %{}) == "You are a test agent."
    end

    test "allowed_tools/1 dispatches to module callback" do
      assert Protocol.allowed_tools(TestAgent) == [:test_tool]
    end

    test "model_preference/1 dispatches to module callback" do
      assert Protocol.model_preference(TestAgent) == "test-model"
    end

    test "run/3 exists as a callback" do
      assert function_exported?(TestAgent, :run, 2)
    end
  end

  describe "get_system_prompt/0 convenience callback" do
    test "returns base prompt with empty context" do
      assert TestAgent.get_system_prompt() == "You are a test agent."
    end
  end

  describe "get_full_system_prompt/0 callback" do
    test "assembles prompt with platform info" do
      prompt = TestAgent.get_full_system_prompt()
      assert prompt =~ "You are a test agent."
      assert prompt =~ "Platform:"
    end
  end

  describe "fallback to Any" do
    test "raises for unsupported types" do
      try do
        Protocol.name("not an agent")
        flunk("Expected an error for unsupported protocol types")
      rescue
        e in Elixir.Protocol.UndefinedError ->
          assert Exception.message(e) =~ "not implemented for BitString"
      end
    end
  end
end
