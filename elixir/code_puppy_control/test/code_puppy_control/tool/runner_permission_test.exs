defmodule CodePuppyControl.Tool.RunnerPermissionTest do
  @moduledoc """
  Tests for Tool.Runner permission integration with FilePermission callback chain.

  Covers:
  - File tools go through FilePermission callback chain
  - cp_* mutation wrappers go through FilePermission callback chain
  - Non-file tools skip FilePermission chain
  - FilePermission deny blocks tool invocation
  - FilePermission allow passes through to tool invocation
  - Callback denial produces proper error message
  - Bypass is impossible: callbacks cannot be skipped for file tools
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule
  alias CodePuppyControl.Tool.{Registry, Runner}

  # ── Test Tool Modules ─────────────────────────────────────────────────────

  defmodule TestFileTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :create_file

    @impl true
    def description, do: "Test file creation tool"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        "required" => ["file_path", "content"]
      }
    end

    @impl true
    def permission_check(args, _context) do
      case args do
        %{"file_path" => ""} -> {:deny, "empty path"}
        _ -> :ok
      end
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{path: args["file_path"], created: true}}
    end
  end

  defmodule TestCpCreateFile do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_create_file

    @impl true
    def description, do: "Test cp_create_file wrapper"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        "required" => ["file_path"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{path: args["file_path"], created: true}}
    end
  end

  defmodule TestCpReplaceInFile do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_replace_in_file

    @impl true
    def description, do: "Test cp_replace_in_file wrapper"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "old_str" => %{"type" => "string"},
          "new_str" => %{"type" => "string"}
        },
        "required" => ["file_path"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{path: args["file_path"], replaced: true}}
    end
  end

  defmodule TestCpDeleteFile do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_delete_file

    @impl true
    def description, do: "Test cp_delete_file wrapper"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"}
        },
        "required" => ["file_path"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{path: args["file_path"], deleted: true}}
    end
  end

  defmodule TestCpDeleteSnippet do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_delete_snippet

    @impl true
    def description, do: "Test cp_delete_snippet wrapper"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "snippet" => %{"type" => "string"}
        },
        "required" => ["file_path"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{path: args["file_path"], snippet_deleted: true}}
    end
  end

  defmodule TestNonFileTool do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :non_file_tool

    @impl true
    def description, do: "A tool that is not file-related"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "message" => %{"type" => "string"}
        },
        "required" => ["message"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{message: args["message"]}}
    end
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    # (code_puppy-i1n) Ensure Callbacks.Registry is alive.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Callbacks.Registry
    )

    Registry.clear()
    PolicyEngine.reset()
    Callbacks.clear(:file_permission)

    Registry.register(TestFileTool)
    Registry.register(TestCpCreateFile)
    Registry.register(TestCpReplaceInFile)
    Registry.register(TestCpDeleteFile)
    Registry.register(TestCpDeleteSnippet)
    Registry.register(TestNonFileTool)

    on_exit(fn ->
      Registry.clear()
    end)

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp allow_all_policy do
    PolicyEngine.add_rule(%PolicyRule{
      tool_name: "*",
      decision: :allow,
      priority: 1,
      source: "test_auto"
    })

    on_exit(fn ->
      PolicyEngine.remove_rules_by_source("test_auto")
    end)
  end

  # ── Tests: unprefixed file tools ──────────────────────────────────────────

  describe "file tool permission integration" do
    test "file tool goes through FilePermission callback chain" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "create_file",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:create_file, %{"file_path" => "test.txt", "content" => "hi"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "file tool allowed when policy and callbacks both allow" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "create_file",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      result = Runner.invoke(:create_file, %{"file_path" => "test.txt", "content" => "hi"}, %{})
      assert {:ok, _} = result
    end

    test "PolicyEngine deny blocks file tool regardless of callbacks" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "create_file",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      result = Runner.invoke(:create_file, %{"file_path" => "test.txt", "content" => "hi"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "Denied by policy"
    end
  end

  # ── Tests: cp_* mutation wrappers ─────────────────────────────────────────

  describe "cp_* file mutation wrappers — FilePermission chain" do
    test "cp_create_file goes through FilePermission callback chain" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:cp_create_file, %{"file_path" => "new.txt", "content" => "hi"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "cp_create_file allowed when policy and callbacks both allow" do
      allow_all_policy()

      result = Runner.invoke(:cp_create_file, %{"file_path" => "new.txt", "content" => "hi"}, %{})
      assert {:ok, %{created: true}} = result
    end

    test "cp_replace_in_file goes through FilePermission callback chain" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(
          :cp_replace_in_file,
          %{"file_path" => "edit.txt", "old_str" => "foo", "new_str" => "bar"},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "cp_replace_in_file allowed when policy and callbacks both allow" do
      allow_all_policy()

      result =
        Runner.invoke(
          :cp_replace_in_file,
          %{"file_path" => "edit.txt", "old_str" => "foo", "new_str" => "bar"},
          %{}
        )

      assert {:ok, %{replaced: true}} = result
    end

    test "cp_delete_file goes through FilePermission callback chain" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:cp_delete_file, %{"file_path" => "rm.txt"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "cp_delete_file allowed when policy and callbacks both allow" do
      allow_all_policy()

      result = Runner.invoke(:cp_delete_file, %{"file_path" => "rm.txt"}, %{})
      assert {:ok, %{deleted: true}} = result
    end

    test "cp_delete_snippet goes through FilePermission callback chain" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(
          :cp_delete_snippet,
          %{"file_path" => "snippet.txt", "snippet" => "old"},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "cp_delete_snippet allowed when policy and callbacks both allow" do
      allow_all_policy()

      result =
        Runner.invoke(
          :cp_delete_snippet,
          %{"file_path" => "snippet.txt", "snippet" => "old"},
          %{}
        )

      assert {:ok, %{snippet_deleted: true}} = result
    end
  end

  # ── Tests: bypass impossibility ───────────────────────────────────────────

  describe "bypass impossibility — cp_* tools cannot skip FilePermission" do
    test "cp_create_file: callback deny blocks even when tool has no permission_check" do
      allow_all_policy()

      # TestCpCreateFile has no permission_check override (uses default :ok)
      # but the FilePermission callback chain still blocks it
      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(:cp_create_file, %{"file_path" => "bypass.txt", "content" => "x"}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "cp_replace_in_file: callback deny blocks even when tool has no permission_check" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(
          :cp_replace_in_file,
          %{"file_path" => "bypass.txt", "old_str" => "a", "new_str" => "b"},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "cp_delete_file: callback deny blocks even when tool has no permission_check" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:cp_delete_file, %{"file_path" => "bypass.txt"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "cp_delete_snippet: callback deny blocks even when tool has no permission_check" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(:cp_delete_snippet, %{"file_path" => "bypass.txt", "snippet" => "x"}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end
  end

  # ── Tests: non-file tools ─────────────────────────────────────────────────

  describe "non-file tool permission integration" do
    test "non-file tool skips FilePermission callback chain" do
      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:non_file_tool, %{"message" => "hello"}, %{})
      assert {:ok, _} = result

      Callbacks.unregister(:file_permission, deny_cb)
    end
  end

  describe "file tool with empty file_path" do
    test "skips FilePermission chain when no file_path in args" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "create_file",
        decision: :allow,
        priority: 10,
        source: "test"
      })

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:create_file, %{"file_path" => "", "content" => "hi"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end
  end
end
