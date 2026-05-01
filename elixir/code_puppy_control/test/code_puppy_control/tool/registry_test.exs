defmodule CodePuppyControl.Tool.RegistryTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Tool.Registry

  # ── Test Tool Modules ─────────────────────────────────────────────────────

  defmodule TestToolAlpha do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :test_tool_alpha

    @impl true
    def description, do: "A test tool for registry testing (alpha)"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "input" => %{"type" => "string"}
        },
        "required" => ["input"]
      }
    end

    @impl true
    def invoke(%{"input" => input}, _ctx) do
      {:ok, "alpha: #{input}"}
    end
  end

  defmodule TestToolBeta do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :test_tool_beta

    @impl true
    def description, do: "A test tool for registry testing (beta)"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "value" => %{"type" => "integer"}
        }
      }
    end

    @impl true
    def invoke(%{"value" => value}, _ctx) do
      {:ok, value * 2}
    end
  end

  defmodule TestToolGamma do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :test_tool_gamma

    @impl true
    def description, do: "Gamma tool for for_agent testing"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def invoke(_args, _ctx), do: {:ok, "gamma"}
  end

  # Agent that only allows alpha and beta
  defmodule TestAgentLimited do
    def allowed_tools, do: [:test_tool_alpha, :test_tool_beta]
  end

  # Agent that has no allowed_tools (allows all)
  defmodule TestAgentAll do
    # no allowed_tools/0 function
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # (code_puppy-i1n) Ensure Tool.Registry is alive.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(Registry)

    # Clear registry and register only our test tools
    Registry.clear()
    Registry.register_many([TestToolAlpha, TestToolBeta, TestToolGamma])

    on_exit(fn ->
      Registry.clear()
    end)

    :ok
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "register/1" do
    test "registers a single tool module" do
      Registry.clear()
      assert :ok = Registry.register(TestToolAlpha)
      assert Registry.registered?(:test_tool_alpha)
    end

    test "overwrites existing registration with same name" do
      assert :ok = Registry.register(TestToolAlpha)
      # Re-register should not fail
      assert :ok = Registry.register(TestToolAlpha)
      assert Registry.registered?(:test_tool_alpha)
    end
  end

  describe "register_many/1" do
    test "registers multiple tools at once" do
      Registry.clear()
      assert {:ok, 3} = Registry.register_many([TestToolAlpha, TestToolBeta, TestToolGamma])
      assert Registry.count() == 3
    end

    test "returns count of successfully registered tools" do
      Registry.clear()
      assert {:ok, 2} = Registry.register_many([TestToolAlpha, TestToolBeta])
    end

    test "handles empty list" do
      assert {:ok, 0} = Registry.register_many([])
    end
  end

  describe "lookup/1" do
    test "returns module for registered tool" do
      assert {:ok, TestToolAlpha} = Registry.lookup(:test_tool_alpha)
      assert {:ok, TestToolBeta} = Registry.lookup(:test_tool_beta)
    end

    test "returns :error for unregistered tool" do
      assert :error = Registry.lookup(:nonexistent_tool)
    end
  end

  describe "all/0" do
    test "returns list of all registered tools as maps" do
      tools = Registry.all()
      assert is_list(tools)
      # At least our 3 test tools
      assert length(tools) >= 3

      names = Enum.map(tools, & &1.name)
      assert "test_tool_alpha" in names
      assert "test_tool_beta" in names
      assert "test_tool_gamma" in names
    end

    test "each entry has name, description, parameters" do
      tools = Registry.all()
      alpha = Enum.find(tools, &(&1.name == "test_tool_alpha"))

      assert alpha.name == "test_tool_alpha"
      assert alpha.description == "A test tool for registry testing (alpha)"
      assert is_map(alpha.parameters)
    end

    test "sorted by name" do
      tools = Registry.all()
      names = Enum.map(tools, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "for_agent/1" do
    test "filters tools by agent's allowed_tools" do
      tools = Registry.for_agent(TestAgentLimited)
      names = Enum.map(tools, & &1.name)

      assert "test_tool_alpha" in names
      assert "test_tool_beta" in names
      refute "test_tool_gamma" in names
    end

    test "returns all tools when agent has no allowed_tools/0" do
      tools = Registry.for_agent(TestAgentAll)
      names = Enum.map(tools, & &1.name)

      assert "test_tool_alpha" in names
      assert "test_tool_beta" in names
      assert "test_tool_gamma" in names
    end
  end

  describe "unregister/1" do
    test "removes a tool from the registry" do
      assert Registry.registered?(:test_tool_alpha)
      :ok = Registry.unregister(:test_tool_alpha)
      refute Registry.registered?(:test_tool_alpha)
    end

    test "is idempotent" do
      :ok = Registry.unregister(:test_tool_alpha)
      :ok = Registry.unregister(:test_tool_alpha)
      refute Registry.registered?(:test_tool_alpha)
    end
  end

  describe "clear/0" do
    test "removes all tools" do
      :ok = Registry.clear()
      assert Registry.count() == 0
    end
  end

  describe "count/0" do
    test "returns number of registered tools" do
      count = Registry.count()
      assert count >= 3
    end
  end

  describe "registered?/1" do
    test "returns true for registered tools" do
      assert Registry.registered?(:test_tool_alpha)
    end

    test "returns false for unregistered tools" do
      refute Registry.registered?(:nonexistent_tool)
    end
  end

  describe "list_modules/0" do
    test "returns list of registered modules" do
      modules = Registry.list_modules()
      assert TestToolAlpha in modules
      assert TestToolBeta in modules
      assert TestToolGamma in modules
    end
  end

  describe "start_link/1" do
    test "returns already_started when the registry is already supervised" do
      existing = Process.whereis(Registry)

      assert {:error, {:already_started, ^existing}} = Registry.start_link()
    end
  end

  describe "ToolEntry.from_module/1" do
    test "produces expected struct from TestToolAlpha" do
      entry = Registry.ToolEntry.from_module(TestToolAlpha)

      assert entry.name == :test_tool_alpha
      assert entry.module == TestToolAlpha
      assert entry.description == "A test tool for registry testing (alpha)"
      assert is_map(entry.parameters)
      assert entry.parameters["type"] == "object"
    end

    test "produces expected struct with all four fields correctly populated" do
      entry = Registry.ToolEntry.from_module(TestToolBeta)

      # Verify all four enforced fields are present
      assert %Registry.ToolEntry{
               name: :test_tool_beta,
               module: TestToolBeta,
               description: "A test tool for registry testing (beta)",
               parameters: params
             } = entry

      assert is_map(params)
    end
  end

  describe "handle_info/2" do
    test "handles unexpected messages without crashing" do
      registry_pid = Process.whereis(Registry)
      ref = Process.monitor(registry_pid)

      send(registry_pid, :random_msg)

      # Synchronization point: waits for the server to handle prior messages
      assert %{table: _} = :sys.get_state(registry_pid)
      refute_receive {:DOWN, ^ref, :process, ^registry_pid, _}, 50
    end

    test "handles multiple unexpected messages without crashing" do
      registry_pid = Process.whereis(Registry)
      ref = Process.monitor(registry_pid)

      send(registry_pid, :msg_one)
      send(registry_pid, :msg_two)
      send(registry_pid, {:tuple_msg, "data"})

      assert %{table: _} = :sys.get_state(registry_pid)
      refute_receive {:DOWN, ^ref, :process, ^registry_pid, _}, 50
    end
  end
end
