defmodule CodePuppyControl.Agent.LoopResponseSchemaTest do
  @moduledoc """
  Integration tests for the response_schema callback in Agent.Loop.

  Validates that:
  1. Agents WITHOUT response_schema work as before (no validation)
  2. Agents WITH response_schema + valid JSON pass validation
  3. Agents WITH response_schema + invalid JSON return validation errors
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.Loop

  # ---------------------------------------------------------------------------
  # Schema for validation tests
  # ---------------------------------------------------------------------------

  defmodule PlanSchema do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:summary, :string)
      field(:confidence, :float)
    end

    def changeset(struct, params) do
      struct
      |> cast(params, [:summary, :confidence])
      |> validate_required([:summary])
      |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    end
  end

  # ---------------------------------------------------------------------------
  # Agent WITHOUT response_schema (uses default → nil)
  # ---------------------------------------------------------------------------

  defmodule NoSchemaAgent do
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :no_schema_agent

    @impl true
    def system_prompt(_ctx), do: "You are a test agent."

    @impl true
    def allowed_tools, do: []

    @impl true
    def model_preference, do: "test-model"

    @impl true
    def on_tool_result(_tool, _result, state), do: {:cont, state}
  end

  # ---------------------------------------------------------------------------
  # Agent WITH response_schema
  # ---------------------------------------------------------------------------

  defmodule SchemaAgent do
    @behaviour CodePuppyControl.Agent.Behaviour

    @impl true
    def name, do: :schema_agent

    @impl true
    def system_prompt(_ctx), do: "Return JSON with summary and confidence."

    @impl true
    def allowed_tools, do: []

    @impl true
    def model_preference, do: "test-model"

    @impl true
    def response_schema, do: PlanSchema

    @impl true
    def on_tool_result(_tool, _result, state), do: {:cont, state}
  end

  # ---------------------------------------------------------------------------
  # Mock LLM — shared across tests, response set per-test
  # ---------------------------------------------------------------------------

  defmodule MockLLM do
    @behaviour CodePuppyControl.Agent.LLM

    def start_link do
      case Agent.start(fn -> %{} end, name: __MODULE__) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def set_response(response) do
      Agent.update(__MODULE__, fn _ -> %{response: response} end)
    end

    def stop do
      try do
        Agent.stop(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end

    @impl true
    def stream_chat(_messages, _tools, _opts, callback_fn) do
      response = Agent.get(__MODULE__, fn state -> state.response end)

      case response do
        %{text: text} when is_binary(text) ->
          callback_fn.({:text, text})

        %{text: text, tool_calls: tool_calls} when is_list(tool_calls) ->
          if text, do: callback_fn.({:text, text})

          for tc <- tool_calls do
            callback_fn.({:tool_call, tc.name, tc.arguments, tc.id})
          end

        _ ->
          :ok
      end

      callback_fn.({:done, :complete})
      {:ok, response}
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    {:ok, _pid} = MockLLM.start_link()
    on_exit(fn -> MockLLM.stop() end)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "agent WITHOUT response_schema" do
    test "text-only response completes normally without validation" do
      MockLLM.set_response(%{text: "Just plain text, no schema needed", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(NoSchemaAgent, [],
          llm_module: MockLLM,
          run_id: "no-schema-1"
        )

      assert :ok = Loop.run_until_done(pid, 5_000)

      state = Loop.get_state(pid)
      assert state.completed == true
      assert state.turn_number == 1

      GenServer.stop(pid)
    end

    test "non-JSON text does not cause errors without schema" do
      MockLLM.set_response(%{text: "garbage {{{ not json", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(NoSchemaAgent, [],
          llm_module: MockLLM,
          run_id: "no-schema-2"
        )

      # Should succeed — no schema means no validation
      assert :ok = Loop.run_until_done(pid, 5_000)

      GenServer.stop(pid)
    end
  end

  describe "agent WITH response_schema — valid JSON" do
    test "valid JSON passes validation and completes run" do
      json = ~s({"summary": "Refactor module", "confidence": 0.9})
      MockLLM.set_response(%{text: json, tool_calls: []})

      {:ok, pid} =
        Loop.start_link(SchemaAgent, [],
          llm_module: MockLLM,
          run_id: "schema-valid-1"
        )

      assert :ok = Loop.run_until_done(pid, 5_000)

      state = Loop.get_state(pid)
      assert state.completed == true

      GenServer.stop(pid)
    end

    test "JSON in code fence passes validation" do
      text = "```json\n{\"summary\": \"Fix bug\", \"confidence\": 0.7}\n```"
      MockLLM.set_response(%{text: text, tool_calls: []})

      {:ok, pid} =
        Loop.start_link(SchemaAgent, [],
          llm_module: MockLLM,
          run_id: "schema-valid-2"
        )

      assert :ok = Loop.run_until_done(pid, 5_000)

      state = Loop.get_state(pid)
      assert state.completed == true

      GenServer.stop(pid)
    end
  end

  describe "agent WITH response_schema — invalid JSON" do
    test "missing required field returns validation error" do
      json = ~s({"confidence": 0.5})
      MockLLM.set_response(%{text: json, tool_calls: []})

      {:ok, pid} =
        Loop.start_link(SchemaAgent, [],
          llm_module: MockLLM,
          run_id: "schema-invalid-1"
        )

      result = Loop.run_until_done(pid, 5_000)
      assert {:error, {:validation_failed, errors}} = result
      assert errors[:summary] != nil

      GenServer.stop(pid)
    end

    test "completely invalid JSON returns validation error" do
      MockLLM.set_response(%{text: "not json at all", tool_calls: []})

      {:ok, pid} =
        Loop.start_link(SchemaAgent, [],
          llm_module: MockLLM,
          run_id: "schema-invalid-2"
        )

      result = Loop.run_until_done(pid, 5_000)
      assert {:error, {:validation_failed, errors}} = result
      assert errors[:json] != nil

      GenServer.stop(pid)
    end

    test "out-of-range field returns validation error" do
      json = ~s({"summary": "Test", "confidence": 5.0})
      MockLLM.set_response(%{text: json, tool_calls: []})

      {:ok, pid} =
        Loop.start_link(SchemaAgent, [],
          llm_module: MockLLM,
          run_id: "schema-invalid-3"
        )

      result = Loop.run_until_done(pid, 5_000)
      assert {:error, {:validation_failed, errors}} = result
      assert errors[:confidence] != nil

      GenServer.stop(pid)
    end
  end
end
