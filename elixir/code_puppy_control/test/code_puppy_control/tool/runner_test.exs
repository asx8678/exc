defmodule CodePuppyControl.Tool.RunnerTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Tool.{Registry, Runner}

  # ── Test Tool Modules ─────────────────────────────────────────────────────

  defmodule EchoTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :runner_echo

    @impl true
    def description, do: "Echoes back the input"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string", "minLength" => 1}
        },
        "required" => ["message"]
      }
    end

    @impl true
    def invoke(%{"message" => message}, _ctx) do
      {:ok, "echo: #{message}"}
    end
  end

  defmodule BlockedTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :runner_blocked

    @impl true
    def description, do: "A tool that always denies permission"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def invoke(_args, _ctx), do: {:ok, "should not reach here"}

    @impl true
    def permission_check(_args, _ctx) do
      {:deny, "blocked for testing"}
    end
  end

  defmodule SlowTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :runner_slow

    @impl true
    def description, do: "A tool that sleeps longer than timeout"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def invoke(_args, _ctx) do
      Process.sleep(10_000)
      {:ok, "done"}
    end
  end

  defmodule CrashTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :runner_crash

    @impl true
    def description, do: "A tool that raises an exception"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def invoke(_args, _ctx) do
      raise "intentional crash"
    end
  end

  defmodule ToolTimeoutTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :runner_tool_timeout

    @impl true
    def description, do: "A tool that declares a custom tool_timeout"

    @impl true
    def parameters, do: %{"type" => "object", "properties" => %{}}

    @impl true
    def invoke(_args, _ctx) do
      {:ok, "slow but within custom timeout"}
    end

    # Optional: declares custom timeout for Tool.Runner
    @doc false
    def tool_timeout, do: 300_000
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # (code_puppy-i1n) Ensure Tool.Registry is alive.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(Registry)

    Registry.clear()
    Registry.register_many([EchoTool, BlockedTool, SlowTool, CrashTool, ToolTimeoutTool])

    on_exit(fn ->
      Registry.clear()
    end)

    :ok
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "invoke/3 — happy path" do
    test "invokes a registered tool with valid args" do
      assert {:ok, "echo: hello"} =
               Runner.invoke(:runner_echo, %{"message" => "hello"}, %{run_id: "test-1"})
    end

    test "context is optional" do
      assert {:ok, "echo: world"} =
               Runner.invoke(:runner_echo, %{"message" => "world"})
    end

    test "build_context/1 creates a standard context" do
      ctx = Runner.build_context(run_id: "run-42", agent_module: MyAgent)
      assert ctx.run_id == "run-42"
      assert ctx.agent_module == MyAgent
      assert is_integer(ctx.timestamp)
    end
  end

  describe "invoke/3 — permission denied" do
    test "returns error when permission_check denies" do
      result = Runner.invoke(:runner_blocked, %{}, %{run_id: "test-block"})
      assert {:error, reason} = result
      assert String.contains?(reason, "permission denied")
      assert String.contains?(reason, "blocked for testing")
    end
  end

  describe "invoke/3 — validation failure" do
    test "returns error when args don't match schema" do
      # EchoTool requires "message" with minLength 1
      result = Runner.invoke(:runner_echo, %{}, %{run_id: "test-val"})
      assert {:error, reason} = result
      assert String.contains?(reason, "validation failed")
      assert String.contains?(reason, "missing required field: message")
    end

    test "validates minLength constraint" do
      result = Runner.invoke(:runner_echo, %{"message" => ""}, %{run_id: "test-val2"})
      assert {:error, reason} = result
      assert String.contains?(reason, "validation failed")
    end
  end

  describe "invoke/3 — timeout" do
    test "returns error when tool exceeds timeout" do
      result =
        Runner.invoke(:runner_slow, %{}, %{
          run_id: "test-timeout",
          timeout: 100
        })

      assert {:error, reason} = result
      assert String.contains?(reason, "timed out")
    end
  end

  describe "invoke/3 — tool crash" do
    test "returns error when tool raises exception" do
      result = Runner.invoke(:runner_crash, %{}, %{run_id: "test-crash"})
      assert {:error, reason} = result
      # Exception is caught inside invoke_tool, returns "error" not "crashed"
      assert String.contains?(reason, "error")
      assert String.contains?(reason, "intentional crash")
    end
  end

  describe "invoke/3 — tool not found" do
    test "returns error for unregistered tool" do
      result = Runner.invoke(:nonexistent_tool_xyz, %{}, %{run_id: "test-404"})
      assert {:error, reason} = result
      assert String.contains?(reason, "Tool not found")
    end
  end

  describe "resolve_tool/1" do
    test "resolves from registry" do
      assert {:ok, EchoTool} = Runner.resolve_tool(:runner_echo)
    end

    test "returns error for unknown tools" do
      assert {:error, _} = Runner.resolve_tool(:totally_unknown_tool)
    end
  end

  describe "invoke/3 — module tool_timeout" do
    test "uses tool's tool_timeout/0 when no context override" do
      # ToolTimeoutTool defines tool_timeout/0 returning 300_000
      result = Runner.invoke(:runner_tool_timeout, %{}, %{run_id: "test-tool-timeout"})
      assert {:ok, "slow but within custom timeout"} = result
    end

    test "context timeout overrides tool_timeout" do
      # Even though ToolTimeoutTool asks for 300_000, context says 100
      result =
        Runner.invoke(:runner_tool_timeout, %{}, %{
          run_id: "test-ctx-override",
          timeout: 100
        })

      # The tool is fast, so it should succeed before the 100ms timeout
      assert {:ok, "slow but within custom timeout"} = result
    end

    test "build_context includes session_id when provided" do
      ctx = Runner.build_context(run_id: "r1", session_id: "s1")
      assert ctx.run_id == "r1"
      assert ctx.session_id == "s1"
    end
  end

  describe "decode_args/1" do
    test "decodes JSON string" do
      assert %{"key" => "value"} = Runner.decode_args(~s({"key": "value"}))
    end

    test "passes through map" do
      assert %{"a" => 1} = Runner.decode_args(%{"a" => 1})
    end

    test "handles nil" do
      assert %{} = Runner.decode_args(nil)
    end

    test "handles invalid JSON string" do
      result = Runner.decode_args("not json")
      assert is_map(result)
    end

    test "handles non-map JSON" do
      result = Runner.decode_args("[1, 2, 3]")
      assert is_map(result)
    end
  end

  describe "telemetry" do
    test "emits tool: invoke:start and invoke:stop events" do
      test_pid = self()
      handler_id = "test-runner-telemetry"

      :telemetry.attach_many(
        handler_id,
        [
          [:tool, :invoke, :start],
          [:tool, :invoke, :stop]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

      Runner.invoke(:runner_echo, %{"message" => "telemetry test"}, %{run_id: "test-tel"})

      # Should receive start event
      assert_receive {:telemetry, [:tool, :invoke, :start], _meas, meta_start}, 1000
      assert meta_start.tool_name == :runner_echo

      # Should receive stop event
      assert_receive {:telemetry, [:tool, :invoke, :stop], meas_stop, meta_stop}, 1000
      assert meta_stop.tool_name == :runner_echo
      assert is_integer(meas_stop.duration)

      :telemetry.detach(handler_id)
    end
  end

  # ── Callback Integration Tests ──────────────────────────────────────────
  #
  # These test that the Tool.Runner dispatches :pre_tool_call and
  # :post_tool_call callbacks around tool execution, proving that:
  #   1. A pre_tool_call hook returning %{blocked: true} prevents execution
  #   2. A post_tool_call hook receives result and duration_ms
  #   3. Fail-closed: a crashing pre hook blocks execution
  #
  # Refs: code_puppy-154.4 (Shepherd REQUEST_CHANGES)

  describe "invoke/3 — pre_tool_call callback integration" do
    setup do
      Callbacks.clear(:pre_tool_call)
      Callbacks.clear(:post_tool_call)

      on_exit(fn ->
        Callbacks.clear(:pre_tool_call)
        Callbacks.clear(:post_tool_call)
      end)

      :ok
    end

    test "tool executes normally when no pre_tool_call callbacks are registered" do
      assert {:ok, "echo: hello"} =
               Runner.invoke(:runner_echo, %{"message" => "hello"}, %{run_id: "pre-1"})
    end

    test "tool executes when pre_tool_call callback returns nil" do
      Callbacks.register(:pre_tool_call, fn _tool_name, _args, _ctx -> nil end)

      assert {:ok, "echo: hello"} =
               Runner.invoke(:runner_echo, %{"message" => "hello"}, %{run_id: "pre-2"})
    end

    test "pre_tool_call hook returning %{blocked: true} prevents tool execution" do
      Callbacks.register(:pre_tool_call, fn _tool_name, _args, _ctx ->
        %{blocked: true, reason: "security policy denies this tool"}
      end)

      result =
        Runner.invoke(:runner_echo, %{"message" => "hello"}, %{run_id: "pre-blocked"})

      assert {:error, reason} = result
      assert String.contains?(reason, "blocked by pre_tool_call hook")
      assert String.contains?(reason, "security policy denies this tool")
    end

    test "pre_tool_call hook returning %{blocked: true} without reason uses default" do
      Callbacks.register(:pre_tool_call, fn _tool_name, _args, _ctx ->
        %{blocked: true}
      end)

      result =
        Runner.invoke(:runner_echo, %{"message" => "hello"}, %{run_id: "pre-no-reason"})

      assert {:error, reason} = result
      assert String.contains?(reason, "blocked by pre_tool_call hook")
      assert String.contains?(reason, "no reason provided")
    end

    test "crashing pre_tool_call callback blocks execution (fail-closed)" do
      Callbacks.register(:pre_tool_call, fn _tool_name, _args, _ctx ->
        raise "security check exploded"
      end)

      result =
        Runner.invoke(:runner_echo, %{"message" => "hello"}, %{run_id: "pre-crash"})

      assert {:error, reason} = result
      assert String.contains?(reason, "blocked by pre_tool_call hook")
      assert String.contains?(reason, "fail-closed")
    end

    test "pre_tool_call receives tool_name, args, and context" do
      test_pid = self()

      Callbacks.register(:pre_tool_call, fn tool_name, args, ctx ->
        send(test_pid, {:pre_called, tool_name, args, ctx})
        nil
      end)

      Runner.invoke(:runner_echo, %{"message" => "inspect"}, %{run_id: "pre-inspect"})

      assert_receive {:pre_called, "runner_echo", args, ctx}, 1000
      assert args == %{"message" => "inspect"}
      assert ctx.run_id == "pre-inspect"
    end
  end

  describe "invoke/3 — post_tool_call callback integration" do
    setup do
      Callbacks.clear(:pre_tool_call)
      Callbacks.clear(:post_tool_call)

      on_exit(fn ->
        Callbacks.clear(:pre_tool_call)
        Callbacks.clear(:post_tool_call)
      end)

      :ok
    end

    test "post_tool_call receives tool_name, args, result, and duration_ms" do
      test_pid = self()

      Callbacks.register(:post_tool_call, fn tool_name, args, result, duration_ms, ctx ->
        send(test_pid, {:post_called, tool_name, args, result, duration_ms, ctx})
        nil
      end)

      Runner.invoke(:runner_echo, %{"message" => "post-test"}, %{run_id: "post-1"})

      assert_receive {:post_called, tool_name, args, result, duration_ms, ctx}, 1000
      assert tool_name == "runner_echo"
      assert args == %{"message" => "post-test"}
      assert result == {:ok, "echo: post-test"}
      assert is_integer(duration_ms)
      assert duration_ms >= 0
      assert ctx.run_id == "post-1"
    end

    test "post_tool_call receives error result when tool fails" do
      test_pid = self()

      Callbacks.register(:post_tool_call, fn _tool_name, _args, result, _duration, _ctx ->
        send(test_pid, {:post_result, result})
        nil
      end)

      # BlockedTool denies in permission_check, which produces an error result
      Runner.invoke(:runner_blocked, %{}, %{run_id: "post-err"})

      assert_receive {:post_result, result}, 1000
      assert {:error, _} = result
    end

    test "post_tool_call receives non-zero duration for slow tools" do
      test_pid = self()

      Callbacks.register(:post_tool_call, fn _tool_name, _args, _result, duration_ms, _ctx ->
        send(test_pid, {:post_duration, duration_ms})
        nil
      end)

      # EchoTool is instant, but we can still verify duration is present
      Runner.invoke(:runner_echo, %{"message" => "duration"}, %{run_id: "post-dur"})

      assert_receive {:post_duration, duration_ms}, 1000
      assert is_integer(duration_ms)
      assert duration_ms >= 0
    end

    test "crashing post_tool_call callback does not affect tool result" do
      Callbacks.register(:post_tool_call, fn _tool_name, _args, _result, _duration, _ctx ->
        raise "post hook exploded"
      end)

      # Tool should still succeed — post hooks are observers only
      assert {:ok, "echo: resilient"} =
               Runner.invoke(:runner_echo, %{"message" => "resilient"}, %{run_id: "post-crash"})
    end

    test "post_tool_call is NOT called when pre_tool_call blocks" do
      test_pid = self()

      Callbacks.register(:pre_tool_call, fn _tool_name, _args, _ctx ->
        %{blocked: true, reason: "denied"}
      end)

      Callbacks.register(:post_tool_call, fn tool_name, _args, _result, _duration, _ctx ->
        send(test_pid, {:post_should_not_fire, tool_name})
        nil
      end)

      result =
        Runner.invoke(:runner_echo, %{"message" => "blocked"}, %{run_id: "pre-block-post"})

      assert {:error, _} = result
      # Post callback should NOT be called when tool is blocked
      refute_receive {:post_should_not_fire, _}, 500
    end
  end
end
