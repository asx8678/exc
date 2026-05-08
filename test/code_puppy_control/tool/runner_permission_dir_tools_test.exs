defmodule CodePuppyControl.Tool.RunnerPermissionDirToolsTest do
  @moduledoc """
  Tests for Tool.Runner permission integration with directory-oriented and
  additional file tools.

  Covers:
  - cp_list_files: directory arg → FilePermission.check receives directory path
  - cp_grep: directory arg → FilePermission.check receives directory path
  - cp_edit_file: file_path arg → FilePermission.check receives file path
  - cp_read_file: file_path arg → FilePermission.check receives file path
  - Denial, allow, and bypass-impossibility for each tool
  - file_target_from_args/2 helper correctness
  """

  use CodePuppyControl.StatefulCase

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule
  alias CodePuppyControl.Tool.{Registry, Runner}

  # ── Test Tool Modules ─────────────────────────────────────────────────────

  defmodule TestCpListFiles do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_list_files

    @impl true
    def description, do: "Test cp_list_files wrapper"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "directory" => %{"type" => "string"},
          "recursive" => %{"type" => "boolean"}
        },
        "required" => []
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{directory: args["directory"], files: []}}
    end
  end

  defmodule TestCpGrep do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_grep

    @impl true
    def description, do: "Test cp_grep wrapper"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "search_string" => %{"type" => "string"},
          "directory" => %{"type" => "string"}
        },
        "required" => ["search_string"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{directory: args["directory"], matches: []}}
    end
  end

  defmodule TestCpEditFile do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_edit_file

    @impl true
    def description, do: "Test cp_edit_file wrapper"

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{"type" => "string"},
          "replacements" => %{"type" => "array"}
        },
        "required" => ["file_path"]
      }
    end

    @impl true
    def invoke(args, _context) do
      {:ok, %{path: args["file_path"], edited: true}}
    end
  end

  defmodule TestCpReadFile do
    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_read_file

    @impl true
    def description, do: "Test cp_read_file wrapper"

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
      {:ok, %{path: args["file_path"], content: "file contents"}}
    end
  end

  # ── Setup ─────────────────────────────────────────────────────────────────

  setup do
    Registry.clear()
    PolicyEngine.reset()
    Callbacks.clear(:file_permission)

    Registry.register(TestCpListFiles)
    Registry.register(TestCpGrep)
    Registry.register(TestCpEditFile)
    Registry.register(TestCpReadFile)

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

  # ── Tests: file_target_from_args helper ────────────────────────────────────

  describe "file_target_from_args/2 — path extraction" do
    test "directory-oriented tool extracts directory arg" do
      assert Runner.file_target_from_args(:cp_list_files, %{"directory" => "lib/"}) == "lib/"
    end

    test "directory-oriented tool with :grep atom extracts directory arg" do
      assert Runner.file_target_from_args(:cp_grep, %{
               "directory" => "src/",
               "search_string" => "TODO"
             }) == "src/"
    end

    test "unprefixed directory tools also extract directory arg" do
      assert Runner.file_target_from_args(:list_files, %{"directory" => "."}) == "."
      assert Runner.file_target_from_args(:grep, %{"directory" => "/tmp"}) == "/tmp"
    end

    test "directory tool with no directory key returns \".\" (cwd default)" do
      assert Runner.file_target_from_args(:cp_list_files, %{"recursive" => true}) == "."
      assert Runner.file_target_from_args(:cp_grep, %{"search_string" => "TODO"}) == "."
    end

    test "file-oriented tool extracts file_path arg" do
      assert Runner.file_target_from_args(:cp_edit_file, %{"file_path" => "lib/foo.ex"}) ==
               "lib/foo.ex"
    end

    test "file-oriented tool falls back to path arg" do
      assert Runner.file_target_from_args(:cp_read_file, %{"path" => "lib/bar.ex"}) ==
               "lib/bar.ex"
    end

    test "file-oriented tool prefers file_path over path" do
      assert Runner.file_target_from_args(:cp_edit_file, %{
               "file_path" => "a.ex",
               "path" => "b.ex"
             }) == "a.ex"
    end

    test "file-oriented tool with no path keys returns empty string" do
      assert Runner.file_target_from_args(:cp_edit_file, %{}) == ""
    end

    test "cp_create_file extracts file_path" do
      assert Runner.file_target_from_args(:cp_create_file, %{"file_path" => "new.txt"}) ==
               "new.txt"
    end

    test "unprefixed create_file extracts file_path" do
      assert Runner.file_target_from_args(:create_file, %{"file_path" => "new.txt"}) == "new.txt"
    end
  end

  # ── Tests: cp_list_files permission gating ────────────────────────────────

  describe "cp_list_files — FilePermission chain" do
    test "denied when callback blocks" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:cp_list_files, %{"directory" => "lib/"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "allowed when policy and callbacks both allow" do
      allow_all_policy()

      result = Runner.invoke(:cp_list_files, %{"directory" => "lib/"}, %{})
      assert {:ok, _} = result
    end

    test "PolicyEngine deny blocks cp_list_files" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "cp_list_files",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      result = Runner.invoke(:cp_list_files, %{"directory" => "lib/"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "Denied by policy"
    end

    test "bypass impossibility: callback deny blocks even without permission_check" do
      allow_all_policy()

      # TestCpListFiles has no permission_check override (uses default :ok)
      # but the FilePermission callback chain still blocks it
      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:cp_list_files, %{"directory" => "lib/"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "denied when callback blocks and directory arg is omitted (defaults to cwd)" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      # No directory arg → file_target_from_args returns "." → FilePermission still fires
      result = Runner.invoke(:cp_list_files, %{}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "FilePermission receives \".\" when cp_list_files has no directory arg" do
      allow_all_policy()

      test_pid = self()

      spy_cb = fn _ctx, path, _op, _, _, _ ->
        send(test_pid, {:file_perm_path, path})
        nil
      end

      Callbacks.register(:file_permission, spy_cb)

      Runner.invoke(:cp_list_files, %{}, %{})
      assert_received {:file_perm_path, "."}

      Callbacks.unregister(:file_permission, spy_cb)
    end

    test "directory path is actually sent to FilePermission.check" do
      allow_all_policy()

      test_pid = self()

      spy_cb = fn _ctx, path, _op, _, _, _ ->
        send(test_pid, {:file_perm_path, path})
        nil
      end

      Callbacks.register(:file_permission, spy_cb)

      Runner.invoke(:cp_list_files, %{"directory" => "lib/"}, %{})
      assert_received {:file_perm_path, "lib/"}

      Callbacks.unregister(:file_permission, spy_cb)
    end
  end

  # ── Tests: cp_grep permission gating ──────────────────────────────────────

  describe "cp_grep — FilePermission chain" do
    test "denied when callback blocks" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(:cp_grep, %{"directory" => "src/", "search_string" => "TODO"}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "allowed when policy and callbacks both allow" do
      allow_all_policy()

      result =
        Runner.invoke(:cp_grep, %{"directory" => "src/", "search_string" => "TODO"}, %{})

      assert {:ok, _} = result
    end

    test "PolicyEngine deny blocks cp_grep" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "cp_grep",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      result =
        Runner.invoke(:cp_grep, %{"directory" => "src/", "search_string" => "TODO"}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "Denied by policy"
    end

    test "bypass impossibility: callback deny blocks even without permission_check" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(:cp_grep, %{"directory" => "src/", "search_string" => "TODO"}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "denied when callback blocks and directory arg is omitted (defaults to cwd)" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      # No directory arg → file_target_from_args returns "." → FilePermission still fires
      result = Runner.invoke(:cp_grep, %{"search_string" => "TODO"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "directory path is actually sent to FilePermission.check" do
      allow_all_policy()

      test_pid = self()

      spy_cb = fn _ctx, path, _op, _, _, _ ->
        send(test_pid, {:file_perm_path, path})
        nil
      end

      Callbacks.register(:file_permission, spy_cb)

      Runner.invoke(:cp_grep, %{"directory" => "src/", "search_string" => "TODO"}, %{})
      assert_received {:file_perm_path, "src/"}

      Callbacks.unregister(:file_permission, spy_cb)
    end

    test "FilePermission receives \".\" when cp_grep has no directory arg" do
      allow_all_policy()

      test_pid = self()

      spy_cb = fn _ctx, path, _op, _, _, _ ->
        send(test_pid, {:file_perm_path, path})
        nil
      end

      Callbacks.register(:file_permission, spy_cb)

      Runner.invoke(:cp_grep, %{"search_string" => "TODO"}, %{})
      assert_received {:file_perm_path, "."}

      Callbacks.unregister(:file_permission, spy_cb)
    end
  end

  # ── Tests: cp_edit_file permission gating ──────────────────────────────────

  describe "cp_edit_file — FilePermission chain" do
    test "denied when callback blocks" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(:cp_edit_file, %{"file_path" => "edit.ex", "replacements" => []}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "allowed when policy and callbacks both allow" do
      allow_all_policy()

      result =
        Runner.invoke(:cp_edit_file, %{"file_path" => "edit.ex", "replacements" => []}, %{})

      assert {:ok, %{edited: true}} = result
    end

    test "PolicyEngine deny blocks cp_edit_file" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "cp_edit_file",
        decision: :deny,
        priority: 10,
        source: "test"
      })

      result =
        Runner.invoke(:cp_edit_file, %{"file_path" => "edit.ex", "replacements" => []}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "Denied by policy"
    end

    test "bypass impossibility: callback deny blocks even without permission_check" do
      allow_all_policy()

      # TestCpEditFile has no permission_check override (uses default :ok)
      # but the FilePermission callback chain still blocks it
      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(:cp_edit_file, %{"file_path" => "edit.ex", "replacements" => []}, %{})

      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "file_path is actually sent to FilePermission.check" do
      allow_all_policy()

      test_pid = self()

      spy_cb = fn _ctx, path, _op, _, _, _ ->
        send(test_pid, {:file_perm_path, path})
        nil
      end

      Callbacks.register(:file_permission, spy_cb)

      Runner.invoke(:cp_edit_file, %{"file_path" => "edit.ex"}, %{})
      assert_received {:file_perm_path, "edit.ex"}

      Callbacks.unregister(:file_permission, spy_cb)
    end
  end

  # ── Tests: cp_read_file permission gating ─────────────────────────────────

  describe "cp_read_file — FilePermission chain" do
    test "denied when callback blocks" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:cp_read_file, %{"file_path" => "read.ex"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "allowed when policy and callbacks both allow" do
      allow_all_policy()

      result = Runner.invoke(:cp_read_file, %{"file_path" => "read.ex"}, %{})
      assert {:ok, _} = result
    end

    test "bypass impossibility: callback deny blocks even without permission_check" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:cp_read_file, %{"file_path" => "read.ex"}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end
  end
end
