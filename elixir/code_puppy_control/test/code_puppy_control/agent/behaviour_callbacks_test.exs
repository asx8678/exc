defmodule CodePuppyControl.Agent.BehaviourCallbacksTest do
  @moduledoc """
  Tests for the new Behaviour callbacks added in code_puppy-4s8.1.

  Validates that:
  - New optional callbacks (display_name, description, user_prompt,
    tools_config, on_before_run, on_after_run) have working defaults
  - Existing agents still compile and work with the extended behaviour
  - Custom implementations of new callbacks work correctly
  """
  use ExUnit.Case, async: true

  # A test agent that uses the default implementations
  defmodule DefaultAgent do
    use CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :default_test

    @impl true
    def system_prompt(_), do: "You are a test agent."

    @impl true
    def allowed_tools, do: []

    @impl true
    def model_preference, do: "claude-sonnet-4-20250514"
  end

  # A test agent that overrides some new callbacks
  defmodule CustomAgent do
    use CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :custom_test

    @impl true
    def system_prompt(_), do: "You are a custom agent."

    @impl true
    def allowed_tools, do: [:cp_read_file]

    @impl true
    def model_preference, do: "claude-sonnet-4-20250514"

    @impl true
    def display_name, do: "Custom Test Agent"

    @impl true
    def description, do: "A test agent with custom callbacks."

    @impl true
    def user_prompt, do: "Please help with:"

    @impl true
    def tools_config, do: %{cp_read_file: %{timeout: 10_000}}

    @impl true
    def on_before_run(context), do: {:ok, Map.put(context, :custom_flag, true)}

    @impl true
    def on_after_run(_context, _result), do: :ok
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Default implementations
  # ═══════════════════════════════════════════════════════════════════════

  describe "default display_name/0" do
    test "title-cases the atom name" do
      assert DefaultAgent.display_name() == "Default Test"
    end
  end

  describe "default description/0" do
    test "returns empty string" do
      assert DefaultAgent.description() == ""
    end
  end

  describe "default user_prompt/0" do
    test "returns nil" do
      assert DefaultAgent.user_prompt() == nil
    end
  end

  describe "default tools_config/0" do
    test "returns nil" do
      assert DefaultAgent.tools_config() == nil
    end
  end

  describe "default on_before_run/1" do
    test "returns {:ok, context} unchanged" do
      context = %{session_id: "s1"}
      assert DefaultAgent.on_before_run(context) == {:ok, context}
    end
  end

  describe "default on_after_run/2" do
    test "returns :ok" do
      assert DefaultAgent.on_after_run(%{}, %{}) == :ok
    end
  end

  describe "default response_schema/0" do
    test "returns nil" do
      assert DefaultAgent.response_schema() == nil
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Custom implementations
  # ═══════════════════════════════════════════════════════════════════════

  describe "custom display_name/0" do
    test "returns custom display name" do
      assert CustomAgent.display_name() == "Custom Test Agent"
    end
  end

  describe "custom description/0" do
    test "returns custom description" do
      assert CustomAgent.description() == "A test agent with custom callbacks."
    end
  end

  describe "custom user_prompt/0" do
    test "returns custom user prompt prefix" do
      assert CustomAgent.user_prompt() == "Please help with:"
    end
  end

  describe "custom tools_config/0" do
    test "returns tool configuration map" do
      assert CustomAgent.tools_config() == %{cp_read_file: %{timeout: 10_000}}
    end
  end

  describe "custom on_before_run/1" do
    test "modifies context" do
      {:ok, ctx} = CustomAgent.on_before_run(%{session_id: "s1"})
      assert ctx.custom_flag == true
      assert ctx.session_id == "s1"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # Existing agents still implement Behaviour
  # ═══════════════════════════════════════════════════════════════════════

  describe "existing agent compatibility" do
    test "CodePuppy agent implements Behaviour" do
      assert function_exported?(CodePuppyControl.Agents.CodePuppy, :name, 0)
      assert function_exported?(CodePuppyControl.Agents.CodePuppy, :system_prompt, 1)
      assert function_exported?(CodePuppyControl.Agents.CodePuppy, :allowed_tools, 0)
      assert function_exported?(CodePuppyControl.Agents.CodePuppy, :model_preference, 0)
    end

    test "CodePuppy agent has default new callbacks" do
      # These should use the default implementations from `use`
      assert is_binary(CodePuppyControl.Agents.CodePuppy.display_name())
      assert is_binary(CodePuppyControl.Agents.CodePuppy.description())
      assert CodePuppyControl.Agents.CodePuppy.user_prompt() == nil
      assert CodePuppyControl.Agents.CodePuppy.tools_config() == nil
    end

    test "CodeReviewer agent implements Behaviour" do
      assert function_exported?(CodePuppyControl.Agents.CodeReviewer, :name, 0)
      assert function_exported?(CodePuppyControl.Agents.CodeReviewer, :system_prompt, 1)
    end

    test "SecurityAuditor agent implements Behaviour" do
      assert function_exported?(CodePuppyControl.Agents.SecurityAuditor, :name, 0)
      assert function_exported?(CodePuppyControl.Agents.SecurityAuditor, :system_prompt, 1)
    end

    test "QaExpert agent implements Behaviour" do
      assert function_exported?(CodePuppyControl.Agents.QaExpert, :name, 0)
      assert function_exported?(CodePuppyControl.Agents.QaExpert, :system_prompt, 1)
    end

    test "Pack agents implement Behaviour" do
      assert function_exported?(CodePuppyControl.Agents.Pack.Retriever, :name, 0)
      assert function_exported?(CodePuppyControl.Agents.Pack.Shepherd, :name, 0)
      assert function_exported?(CodePuppyControl.Agents.Pack.Terrier, :name, 0)
      assert function_exported?(CodePuppyControl.Agents.Pack.Watchdog, :name, 0)
    end
  end
end
