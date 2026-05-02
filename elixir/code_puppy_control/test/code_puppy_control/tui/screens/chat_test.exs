defmodule CodePuppyControl.TUI.Screens.ChatTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.TUI.Screens.Chat

  # Mock agent for tests — avoids needing a real LLM
  defmodule MockAgent do
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :mock_agent

    @impl true
    def system_prompt(_ctx), do: "You are a mock test agent."

    @impl true
    def allowed_tools, do: []

    @impl true
    def model_preference, do: "mock-model"
  end

  describe "init/1" do
    test "creates default state with generated session_id" do
      {:ok, state} = Chat.init(%{})

      assert is_binary(state.session_id)
      assert byte_size(state.session_id) == 16
      assert state.agent == CodePuppyControl.Agents.CodePuppy
      assert state.model != nil
      assert state.messages == []
      assert state.renderer_pid == nil
      assert state.status == :idle
    end

    test "accepts custom options" do
      {:ok, state} =
        Chat.init(%{
          session_id: "custom-123",
          agent: MyAgent,
          model: "gpt-4"
        })

      assert state.session_id == "custom-123"
      assert state.agent == MyAgent
      assert state.model == "gpt-4"
    end
  end

  describe "render/1" do
    test "renders header and empty state prompt" do
      {:ok, state} = Chat.init(%{})
      rendered = Chat.render(state)

      # Should be an iolist — verify it doesn't crash
      assert is_list(rendered) or is_binary(rendered)
    end

    test "renders messages in history" do
      state = %{
        session_id: "test",
        agent: CodePuppyControl.Agent.Behaviour,
        model: "test-model",
        messages: [
          %{role: :user, content: "Hello"},
          %{role: :assistant, content: "Hi there"}
        ],
        renderer_pid: nil,
        status: :idle
      }

      rendered = Chat.render(state)
      assert is_list(rendered) or is_binary(rendered)
    end
  end

  describe "handle_input/2" do
    setup do
      {:ok, state} = Chat.init(%{session_id: "test-session"})
      {:ok, state: state}
    end

    test "/help switches to Help screen", %{state: state} do
      assert {:switch, CodePuppyControl.TUI.Screens.Help, %{}} ==
               Chat.handle_input("/help", state)
    end

    test "/config switches to Config screen", %{state: state} do
      assert {:switch, CodePuppyControl.TUI.Screens.Config, %{}} ==
               Chat.handle_input("/config", state)
    end

    test "/quit exits", %{state: state} do
      assert :quit == Chat.handle_input("/quit", state)
    end

    test "/clear empties messages", %{state: state} do
      state = %{state | messages: [%{role: :user, content: "old"}]}
      {:ok, new_state} = Chat.handle_input("/clear", state)
      assert new_state.messages == []
    end

    test "/model switches the model", %{state: state} do
      {:ok, new_state} = Chat.handle_input("/model gpt-4o", state)
      assert new_state.model == "gpt-4o"
    end

    test "empty input is a no-op", %{state: state} do
      assert {:ok, ^state} = Chat.handle_input("", state)
    end

    test "regular text starts agent loop and returns error without LLM", %{state: state} do
      # Use MockAgent — no real LLM configured, so we expect an error
      state = %{state | agent: MockAgent}
      {:ok, new_state} = Chat.handle_input("Hello agent!", state)

      # Should have user message + assistant error response
      assert length(new_state.messages) == 2
      assert Enum.at(new_state.messages, 0).role == :user
      assert Enum.at(new_state.messages, 0).content == "Hello agent!"
      assert Enum.at(new_state.messages, 1).role == :assistant
      # Error message contains "Error" since no LLM is configured
      assert String.contains?(Enum.at(new_state.messages, 1).content, "Error")
      # Status should be idle after completion
      assert new_state.status == :idle
    end

    test "input is ignored while streaming", %{state: state} do
      streaming = %{state | status: :streaming}
      {:ok, new_state} = Chat.handle_input("ignored", streaming)
      # Messages should not change
      assert new_state.messages == state.messages
    end
  end

  describe "cleanup/1" do
    test "cleanup with nil renderer_pid is safe" do
      state = %{renderer_pid: nil}
      assert :ok == Chat.cleanup(state)
    end
  end
end
