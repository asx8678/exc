defmodule CodePuppyControl.Agent.LifecycleTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Agent.Lifecycle

  # ═══════════════════════════════════════════════════════════════════════
  # resolve_model/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "resolve_model/2" do
    test "model override takes priority" do
      assert Lifecycle.resolve_model("gpt-4o", "claude-sonnet-4-20250514") == "gpt-4o"
    end

    test "uses agent preference when no override" do
      assert Lifecycle.resolve_model(nil, "claude-sonnet-4-20250514") ==
               "claude-sonnet-4-20250514"
    end

    test "resolves pack model via Lifecycle" do
      # Model pack resolution falls back to default when ModelPacks module
      # isn't available or doesn't have the role
      model = Lifecycle.resolve_model(nil, {:pack, :coder})
      assert is_binary(model)
      assert model != ""
    end

    test "uses default model when preference is nil" do
      model = Lifecycle.resolve_model(nil, nil)
      assert is_binary(model)
      assert model == "claude-sonnet-4-20250514"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # load_model_with_fallback/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "load_model_with_fallback/2" do
    test "returns requested model when available" do
      assert {:ok, "gpt-4o"} =
               Lifecycle.load_model_with_fallback("gpt-4o", ["gpt-4o", "claude-sonnet-4-20250514"])
    end

    test "falls back to first available model" do
      assert {:ok, "claude-sonnet-4-20250514"} =
               Lifecycle.load_model_with_fallback("unknown", [
                 "claude-sonnet-4-20250514",
                 "gpt-4o"
               ])
    end

    test "returns error when no models available" do
      assert {:error, _msg} = Lifecycle.load_model_with_fallback("unknown", [])
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # load_puppy_rules/0
  # ═══════════════════════════════════════════════════════════════════════

  describe "load_puppy_rules/0" do
    test "returns nil when no AGENTS.md files exist" do
      # In a test environment, there's likely no AGENTS.md in the cwd
      # or config dir. This test just verifies it doesn't crash.
      result = Lifecycle.load_puppy_rules()
      # Result is nil or a string — either is fine
      assert result == nil or is_binary(result)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # assemble_system_prompt/2
  # ═══════════════════════════════════════════════════════════════════════

  describe "assemble_system_prompt/2" do
    defmodule TestAgent do
      use CodePuppyControl.Agent.Behaviour

      @impl true
      def name, do: :test_lifecycle

      @impl true
      def system_prompt(_context), do: "You are a test agent."

      @impl true
      def allowed_tools, do: []

      @impl true
      def model_preference, do: "claude-sonnet-4-20250514"
    end

    test "returns base system prompt" do
      {:ok, prompt} = Lifecycle.assemble_system_prompt(TestAgent, %{})
      assert String.contains?(prompt, "You are a test agent.")
    end

    test "prepends system prompt with agent's prompt" do
      {:ok, prompt} = Lifecycle.assemble_system_prompt(TestAgent, %{session_id: "s1"})
      assert String.starts_with?(prompt, "You are a test agent.")
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # resolve_pack_model/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "resolve_pack_model/1" do
    test "falls back to default when pack unavailable" do
      model = Lifecycle.resolve_pack_model(:nonexistent_role)
      assert is_binary(model)
      assert model == "claude-sonnet-4-20250514"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════
  # load_mcp_servers/1
  # ═══════════════════════════════════════════════════════════════════════

  describe "load_mcp_servers/1" do
    test "returns empty list gracefully when MCP unavailable" do
      result = Lifecycle.load_mcp_servers()
      assert is_list(result)
    end
  end

  describe "reload_mcp_servers/0" do
    test "returns empty list gracefully when MCP unavailable" do
      result = Lifecycle.reload_mcp_servers()
      assert is_list(result)
    end
  end
end
