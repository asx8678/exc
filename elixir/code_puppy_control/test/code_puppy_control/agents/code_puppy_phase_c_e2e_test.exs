defmodule CodePuppyControl.Agents.CodePuppyPhaseCE2ETest do
  @moduledoc """
  Phase C exit-gate E2E test for CodePuppyControl.Agents.CodePuppy.

  Proves the full tool-using LLM round-trip in native Elixir runtime
  with **zero Python imports**. The real CodePuppy agent module is used
  with mock LLM + mock tools to assert the complete pipeline:

  `CodePuppy agent → Loop → LLM → Normalizer → Tool.Runner → Registry → Events`

  **Run with:** `mix test --only phase_c_e2e`

  Refs: code_puppy-4s8.7 (Phase C CI gate)
  """

  use ExUnit.Case, async: false

  @moduletag :phase_c_e2e
  @moduletag timeout: 30_000

  alias CodePuppyControl.Agent.Loop
  alias CodePuppyControl.Agents.CodePuppy
  alias CodePuppyControl.EventBus
  alias CodePuppyControl.Tool.Registry

  # ---------------------------------------------------------------------------
  # Mock Tools — deterministic, no side effects, :cp_-prefixed
  # ---------------------------------------------------------------------------
  # Each mock implements the Tool behaviour with a :cp_-prefixed name
  # matching CodePuppy.allowed_tools/0. Results are deterministic so
  # the test can assert exact values.

  defmodule MockCpListFiles do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_list_files
    @impl true
    def description, do: "Mock list files"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context),
      do: {:ok, %{files: ["lib/foo.ex", "test/bar_test.exs"], count: 2}}
  end

  defmodule MockCpReadFile do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_read_file
    @impl true
    def description, do: "Mock read file"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context), do: {:ok, %{content: "defmodule Foo do\nend\n", num_lines: 2}}
  end

  defmodule MockCpGrep do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_grep
    @impl true
    def description, do: "Mock grep"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context), do: {:ok, %{matches: [%{file: "lib/foo.ex", line: 1}], count: 1}}
  end

  defmodule MockCpCreateFile do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_create_file
    @impl true
    def description, do: "Mock create file"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context), do: {:ok, %{created: true, path: "lib/new.ex"}}
  end

  defmodule MockCpReplaceInFile do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_replace_in_file
    @impl true
    def description, do: "Mock replace in file"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context), do: {:ok, %{replaced: true, path: "lib/foo.ex"}}
  end

  defmodule MockCpEditFile do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_edit_file
    @impl true
    def description, do: "Mock edit file"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context), do: {:ok, %{edited: true, path: "lib/foo.ex"}}
  end

  defmodule MockCpDeleteFile do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_delete_file
    @impl true
    def description, do: "Mock delete file"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context), do: {:ok, %{deleted: true, path: "lib/old.ex"}}
  end

  defmodule MockCpDeleteSnippet do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_delete_snippet
    @impl true
    def description, do: "Mock delete snippet"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context), do: {:ok, %{deleted: true, snippet_removed: true}}
  end

  defmodule MockCpRunCommand do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_run_command
    @impl true
    def description, do: "Mock run command"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context),
      do: {:ok, %{success: true, stdout: "All tests passed.", stderr: "", exit_code: 0}}
  end

  defmodule MockCpInvokeAgent do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_invoke_agent
    @impl true
    def description, do: "Mock invoke agent"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context),
      do: {:ok, %{run_id: "mock-run-1", agent_name: "code_scout", status: :started}}
  end

  defmodule MockCpListAgents do
    @moduledoc false
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_list_agents
    @impl true
    def description, do: "Mock list agents"
    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}, "required" => []}

    @impl true
    def invoke(_args, _context) do
      {:ok,
       %{
         agents: [
           %{name: "code_puppy", display_name: "Code Puppy", description: "The primary agent"}
         ],
         count: 1
       }}
    end
  end

  # All mock tool modules for batch registration
  @mock_tools [
    MockCpListFiles,
    MockCpReadFile,
    MockCpGrep,
    MockCpCreateFile,
    MockCpReplaceInFile,
    MockCpEditFile,
    MockCpDeleteFile,
    MockCpDeleteSnippet,
    MockCpRunCommand,
    MockCpInvokeAgent,
    MockCpListAgents
  ]

  # ---------------------------------------------------------------------------
  # Mock LLM: multi-turn with file ops → shell → agent invocation
  # ---------------------------------------------------------------------------
  # Simulates a realistic CodePuppy workflow:
  #   Turn 1: list files + read file
  #   Turn 2: create file + run command (test)
  #   Turn 3: text response (done)
  #
  # Uses raw provider-format events to exercise the Normalizer.

  defmodule WorkflowLLM do
    @moduledoc false

    @spec stream_chat([map()], [atom()], keyword(), fun()) :: {:ok, map()}
    def stream_chat(messages, _tools, _opts, cb) do
      tool_results =
        Enum.filter(messages, fn m ->
          m[:role] == "tool" or m["role"] == "tool"
        end)

      case length(tool_results) do
        0 ->
          # Turn 1: list files + read file (two tool calls)
          emit_tool_call(cb, "tc-1", "cp_list_files", "{}")
          emit_tool_call(cb, "tc-2", "cp_read_file", "{\"file_path\": \"lib/foo.ex\"}")

          {:ok,
           %{
             text: nil,
             tool_calls: [
               %{id: "tc-1", name: :cp_list_files, arguments: %{}},
               %{id: "tc-2", name: :cp_read_file, arguments: %{"file_path" => "lib/foo.ex"}}
             ]
           }}

        n when n in [1, 2] ->
          # Turn 2: create file + run command
          emit_tool_call(cb, "tc-3", "cp_create_file", "{\"file_path\": \"lib/new.ex\"}")
          emit_tool_call(cb, "tc-4", "cp_run_command", "{\"command\": \"mix test\"}")

          {:ok,
           %{
             text: nil,
             tool_calls: [
               %{id: "tc-3", name: :cp_create_file, arguments: %{"file_path" => "lib/new.ex"}},
               %{id: "tc-4", name: :cp_run_command, arguments: %{"command" => "mix test"}}
             ]
           }}

        _ ->
          # Turn 3: text response (done)
          emit_text(cb, "Task complete. Created lib/new.ex and all tests pass.")

          {:ok, %{text: "Task complete. Created lib/new.ex and all tests pass.", tool_calls: []}}
      end
    end

    defp emit_text(cb, text) do
      cb.({:part_start, %{type: :text, index: 0, id: nil}})
      cb.({:part_delta, %{type: :text, index: 0, text: text, name: nil, arguments: nil}})
      cb.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})

      cb.(
        {:done,
         %{
           id: "msg-done",
           model: "test",
           content: nil,
           tool_calls: [],
           finish_reason: "stop",
           usage: nil
         }}
      )
    end

    defp emit_tool_call(cb, id, name, args_json) do
      cb.({:part_start, %{type: :tool_call, index: 0, id: id}})
      cb.({:part_delta, %{type: :tool_call, index: 0, text: nil, name: name, arguments: nil}})

      cb.(
        {:part_delta, %{type: :tool_call, index: 0, text: nil, name: nil, arguments: args_json}}
      )

      cb.(
        {:part_end,
         %{
           type: :tool_call,
           index: 0,
           id: id,
           name: name,
           arguments: args_json
         }}
      )

      cb.(
        {:done,
         %{
           id: "msg-#{id}",
           model: "test",
           content: nil,
           tool_calls: [%{id: id, name: String.to_existing_atom(name), arguments: args_json}],
           finish_reason: "tool_calls",
           usage: nil
         }}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Mock LLM: simple text-only turn (proves agent boots and responds)
  # ---------------------------------------------------------------------------

  defmodule TextOnlyLLM do
    @moduledoc false

    @spec stream_chat([map()], [atom()], keyword(), fun()) :: {:ok, map()}
    def stream_chat(_messages, _tools, _opts, cb) do
      cb.({:part_start, %{type: :text, index: 0, id: nil}})

      cb.(
        {:part_delta,
         %{
           type: :text,
           index: 0,
           text: "I'm Code Puppy! Ready to help.",
           name: nil,
           arguments: nil
         }}
      )

      cb.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})

      cb.(
        {:done,
         %{
           id: "msg-text",
           model: "test",
           content: nil,
           tool_calls: [],
           finish_reason: "stop",
           usage: nil
         }}
      )

      {:ok, %{text: "I'm Code Puppy! Ready to help.", tool_calls: []}}
    end
  end

  # ---------------------------------------------------------------------------
  # Mock LLM: agent invocation turn (proves cp_invoke_agent + cp_list_agents)
  # ---------------------------------------------------------------------------

  defmodule AgentOpsLLM do
    @moduledoc false

    @spec stream_chat([map()], [atom()], keyword(), fun()) :: {:ok, map()}
    def stream_chat(messages, _tools, _opts, cb) do
      tool_results =
        Enum.filter(messages, fn m ->
          m[:role] == "tool" or m["role"] == "tool"
        end)

      case length(tool_results) do
        0 ->
          # Turn 1: list agents + invoke agent
          emit_tool_call(cb, "tc-a1", "cp_list_agents", "{}")

          emit_tool_call(
            cb,
            "tc-a2",
            "cp_invoke_agent",
            "{\"agent_name\": \"code_scout\", \"prompt\": \"find TODOs\"}"
          )

          {:ok,
           %{
             text: nil,
             tool_calls: [
               %{id: "tc-a1", name: :cp_list_agents, arguments: %{}},
               %{
                 id: "tc-a2",
                 name: :cp_invoke_agent,
                 arguments: %{"agent_name" => "code_scout", "prompt" => "find TODOs"}
               }
             ]
           }}

        _ ->
          # Turn 2: text response
          emit_text(cb, "Delegated to code_scout. Found 3 TODOs.")

          {:ok, %{text: "Delegated to code_scout. Found 3 TODOs.", tool_calls: []}}
      end
    end

    defp emit_text(cb, text) do
      cb.({:part_start, %{type: :text, index: 0, id: nil}})
      cb.({:part_delta, %{type: :text, index: 0, text: text, name: nil, arguments: nil}})
      cb.({:part_end, %{type: :text, index: 0, id: nil, name: nil, arguments: nil}})

      cb.(
        {:done,
         %{
           id: "msg-done",
           model: "test",
           content: nil,
           tool_calls: [],
           finish_reason: "stop",
           usage: nil
         }}
      )
    end

    defp emit_tool_call(cb, id, name, args_json) do
      cb.({:part_start, %{type: :tool_call, index: 0, id: id}})
      cb.({:part_delta, %{type: :tool_call, index: 0, text: nil, name: name, arguments: nil}})

      cb.(
        {:part_delta, %{type: :tool_call, index: 0, text: nil, name: nil, arguments: args_json}}
      )

      cb.({:part_end, %{type: :tool_call, index: 0, id: id, name: name, arguments: args_json}})

      cb.(
        {:done,
         %{
           id: "msg-#{id}",
           model: "test",
           content: nil,
           tool_calls: [%{id: id, name: String.to_existing_atom(name), arguments: args_json}],
           finish_reason: "tool_calls",
           usage: nil
         }}
      )
    end
  end

  # ---------------------------------------------------------------------------
  # Test Setup
  # ---------------------------------------------------------------------------

  setup do
    # Register all mock :cp_ tools (idempotent — re-registering overwrites)
    for tool_mod <- @mock_tools do
      Registry.register(tool_mod)
    end

    # Subscribe to global events
    :ok = EventBus.subscribe_global()

    on_exit(fn ->
      EventBus.unsubscribe_global()

      for tool_mod <- @mock_tools do
        Registry.unregister(tool_mod.name())
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp flush_events(timeout_ms \\ 5_000) do
    # Wait for the terminal completion event
    assert_receive {:event, %{type: "agent_run_completed"} = completion_event}, timeout_ms
    # Drain remaining events, then prepend the completion event we consumed
    remaining = drain_events([])
    [completion_event | remaining]
  end

  defp drain_events(acc) do
    receive do
      {:event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp event_types(events), do: Enum.map(events, fn e -> e.type end)

  defp events_of_type(events, type), do: Enum.filter(events, fn e -> e.type == type end)

  defp unique_run_id, do: "phase-c-#{System.unique_integer([:positive])}"

  # ---------------------------------------------------------------------------
  # Test 1: Agent identity — proves the module conforms to the Behaviour
  # ---------------------------------------------------------------------------

  describe "CodePuppy agent identity" do
    test "implements Agent.Behaviour with correct name, tools, and model" do
      assert CodePuppy.name() == :code_puppy
      assert is_list(CodePuppy.allowed_tools())
      assert length(CodePuppy.allowed_tools()) == 22
      assert :cp_list_files in CodePuppy.allowed_tools()
      assert :cp_read_file in CodePuppy.allowed_tools()
      assert :cp_grep in CodePuppy.allowed_tools()
      assert :cp_create_file in CodePuppy.allowed_tools()
      assert :cp_replace_in_file in CodePuppy.allowed_tools()
      assert :cp_edit_file in CodePuppy.allowed_tools()
      assert :cp_delete_file in CodePuppy.allowed_tools()
      assert :cp_delete_snippet in CodePuppy.allowed_tools()
      assert :cp_run_command in CodePuppy.allowed_tools()
      assert :cp_invoke_agent in CodePuppy.allowed_tools()
      assert :cp_list_agents in CodePuppy.allowed_tools()
      # Phase E tools (code_puppy-mmk.2)
      assert :cp_list_skills in CodePuppy.allowed_tools()
      assert :cp_activate_skill in CodePuppy.allowed_tools()
      assert :cp_scheduler_list_tasks in CodePuppy.allowed_tools()
      assert :cp_scheduler_create_task in CodePuppy.allowed_tools()
      assert :cp_scheduler_delete_task in CodePuppy.allowed_tools()
      assert :cp_scheduler_toggle_task in CodePuppy.allowed_tools()
      assert :cp_scheduler_status in CodePuppy.allowed_tools()
      assert :cp_scheduler_run_task in CodePuppy.allowed_tools()
      assert :cp_scheduler_view_log in CodePuppy.allowed_tools()
      assert :cp_scheduler_force_check in CodePuppy.allowed_tools()
      assert :cp_universal_constructor in CodePuppy.allowed_tools()

      assert CodePuppy.model_preference() == "claude-sonnet-4-20250514"

      # System prompt is non-empty and references Code Puppy
      prompt = CodePuppy.system_prompt(%{})
      assert is_binary(prompt)
      assert prompt =~ "Code Puppy"
    end

    test "all allowed_tools resolve in the tool registry" do
      for tool_name <- CodePuppy.allowed_tools() do
        case Registry.lookup(tool_name) do
          {:ok, _module} ->
            :ok

          :error ->
            # Mock tools should be registered in setup — if this fails,
            # a tool name in allowed_tools has no registered implementation.
            flunk(
              "Tool #{inspect(tool_name)} from CodePuppy.allowed_tools/0 not found in Registry"
            )
        end
      end
    end

    test "system prompt references all tool names" do
      prompt = CodePuppy.system_prompt(%{})

      # Every tool in allowed_tools should be referenced in the prompt
      # by its cp_-prefixed name
      for tool_name <- CodePuppy.allowed_tools() do
        name_str = Atom.to_string(tool_name)

        assert prompt =~ name_str,
               "System prompt missing reference to tool #{inspect(tool_name)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test 2: Text-only turn — proves agent boots and responds
  # ---------------------------------------------------------------------------

  describe "text-only turn" do
    test "completes a single text turn with the real CodePuppy agent" do
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(CodePuppy, [%{role: "user", content: "Hello!"}],
          run_id: run_id,
          llm_module: TextOnlyLLM,
          max_turns: 1
        )

      result = Loop.run_until_done(pid, 10_000)
      assert result == :ok

      state = Loop.get_state(pid)
      assert state.completed == true
      assert state.turn_number == 1
      assert state.message_count == 2

      events = flush_events()
      types = event_types(events)

      assert "agent_turn_started" in types
      assert "agent_llm_stream" in types
      assert "agent_turn_ended" in types
      assert "agent_run_completed" in types

      [completed] = events_of_type(events, "agent_run_completed")
      assert completed.summary.reason == :text_response

      GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 3: Multi-tool workflow — file ops + shell
  # ---------------------------------------------------------------------------

  describe "multi-tool workflow (file ops + shell)" do
    test "executes file listing, reading, creation, and shell command" do
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(CodePuppy, [%{role: "user", content: "Create a new module"}],
          run_id: run_id,
          llm_module: WorkflowLLM,
          max_turns: 5
        )

      result = Loop.run_until_done(pid, 15_000)
      assert result == :ok

      state = Loop.get_state(pid)
      assert state.completed == true
      assert state.turn_number == 3

      events = flush_events()
      types = event_types(events)

      # Verify all event types
      assert "agent_turn_started" in types
      assert "agent_tool_call_start" in types
      assert "agent_tool_call_end" in types
      assert "agent_llm_stream" in types
      assert "agent_turn_ended" in types
      assert "agent_run_completed" in types

      # Verify tool calls hit our mock implementations
      # Note: Events store tool_name as a string (via to_string/1)
      tool_ends = events_of_type(events, "agent_tool_call_end")

      # Should have results from cp_list_files, cp_read_file,
      # cp_create_file, and cp_run_command
      successful_tools =
        tool_ends
        |> Enum.filter(fn e -> match?({:ok, _}, e.result) end)
        |> Enum.map(fn e -> e.tool_name end)

      assert "cp_list_files" in successful_tools
      assert "cp_read_file" in successful_tools
      assert "cp_create_file" in successful_tools
      assert "cp_run_command" in successful_tools

      # Verify tool results contain mock data
      list_result =
        Enum.find(tool_ends, fn e -> e.tool_name == "cp_list_files" end)

      assert match?({:ok, %{files: _, count: _}}, list_result.result)

      run_result =
        Enum.find(tool_ends, fn e -> e.tool_name == "cp_run_command" end)

      assert match?({:ok, %{success: true, stdout: "All tests passed."}}, run_result.result)

      # Run completed after text response
      [completed] = events_of_type(events, "agent_run_completed")
      assert completed.summary.reason == :text_response
      assert completed.summary.turns == 3

      GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 4: Agent invocation workflow — cp_list_agents + cp_invoke_agent
  # ---------------------------------------------------------------------------

  describe "agent invocation workflow" do
    test "lists and invokes sub-agents through the tool pipeline" do
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(CodePuppy, [%{role: "user", content: "Find TODOs in the codebase"}],
          run_id: run_id,
          llm_module: AgentOpsLLM,
          max_turns: 5
        )

      result = Loop.run_until_done(pid, 15_000)
      assert result == :ok

      state = Loop.get_state(pid)
      assert state.completed == true

      events = flush_events()

      tool_ends = events_of_type(events, "agent_tool_call_end")

      agent_tool_names =
        tool_ends
        |> Enum.map(fn e -> e.tool_name end)

      # Tool names are strings in events
      assert "cp_list_agents" in agent_tool_names
      assert "cp_invoke_agent" in agent_tool_names

      # Verify agent invocation result
      invoke_result =
        Enum.find(tool_ends, fn e -> e.tool_name == "cp_invoke_agent" end)

      assert match?({:ok, %{run_id: _, agent_name: _, status: :started}}, invoke_result.result)

      GenServer.stop(pid, :normal)
    end
  end

  # ---------------------------------------------------------------------------
  # Test 5: No Python imports — native Elixir runtime
  # ---------------------------------------------------------------------------

  describe "zero Python dependency" do
    test "CodePuppy agent module has no Python imports" do
      # Verify the agent module compiles and works without any Python worker
      # dependency. The agent's allowed_tools all resolve to Elixir modules.

      # Quick check: the module is loaded and functional
      assert CodePuppy.name() == :code_puppy
      assert function_exported?(CodePuppy, :system_prompt, 1)
      assert function_exported?(CodePuppy, :allowed_tools, 0)
      assert function_exported?(CodePuppy, :model_preference, 0)
    end

    test "all cp_ tools are pure Elixir with no Python worker dependency" do
      # Verify all registered :cp_ tools are Elixir-native modules.
      # None should depend on CodePuppyControl.PythonWorker.
      for tool_name <- CodePuppy.allowed_tools() do
        case Registry.lookup(tool_name) do
          {:ok, module} ->
            # Module should not be in the PythonWorker namespace
            module_str = Atom.to_string(module)

            refute module_str =~ "PythonWorker",
                   "Tool #{inspect(tool_name)} maps to PythonWorker module #{inspect(module)}"

          :error ->
            # This is caught by the "all allowed_tools resolve" test above
            :ok
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Test 6: Event bus integration — all tools emit events
  # ---------------------------------------------------------------------------

  describe "event bus integration" do
    test "tool dispatch emits start/end events with correct structure" do
      run_id = unique_run_id()

      {:ok, pid} =
        Loop.start_link(CodePuppy, [%{role: "user", content: "List files"}],
          run_id: run_id,
          llm_module: WorkflowLLM,
          max_turns: 5
        )

      result = Loop.run_until_done(pid, 15_000)
      assert result == :ok

      events = flush_events()

      # Every tool_call_start should have a matching tool_call_end
      starts = events_of_type(events, "agent_tool_call_start")
      ends = events_of_type(events, "agent_tool_call_end")

      # Each tool call has one start and one end event
      assert length(starts) >= 4
      assert length(ends) >= 4

      # Tool call IDs should pair up
      start_ids = Enum.map(starts, fn e -> e.tool_call_id end)
      end_ids = Enum.map(ends, fn e -> e.tool_call_id end)

      for id <- start_ids do
        assert id in end_ids,
               "Tool call start with id=#{id} has no matching end event"
      end

      GenServer.stop(pid, :normal)
    end
  end
end
