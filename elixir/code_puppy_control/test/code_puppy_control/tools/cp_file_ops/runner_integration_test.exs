defmodule CodePuppyControl.Tools.CpFileOps.RunnerIntegrationTest do
  @moduledoc """
  Integration tests for CpFileOps through Tool.Runner with the
  two-layer permission stack.

  Layer 1: Tool permission_check/2 — hard gate (sensitive-path deny)
  Layer 2: FilePermission callback chain — policy gate (allow/deny/ask)

  Also covers PolicyEngine deny interactions.

  Refs: code_puppy-mmk.1
  """

  use ExUnit.Case

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.PolicyEngine
  alias CodePuppyControl.PolicyEngine.PolicyRule
  alias CodePuppyControl.Tool.{Registry, Runner}
  alias CodePuppyControl.Tools.CpFileOps.{CpListFiles, CpReadFile, CpGrep}

  @test_dir Path.join(
              System.tmp_dir!(),
              "cp_file_ops_runner_#{:erlang.unique_integer([:positive])}"
            )

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    File.write!(Path.join(@test_dir, "hello.txt"), "Hello World\nLine 2\nLine 3")

    on_exit(fn ->
      File.rm_rf!(@test_dir)
    end)

    Registry.clear()
    PolicyEngine.reset()
    Callbacks.clear(:file_permission)

    Registry.register(CpListFiles)
    Registry.register(CpReadFile)
    Registry.register(CpGrep)

    on_exit(fn ->
      Registry.clear()
    end)

    :ok
  end

  defp allow_all_policy do
    PolicyEngine.add_rule(%PolicyRule{
      tool_name: "*",
      decision: :allow,
      priority: 1,
      source: "cp_file_ops_test"
    })

    on_exit(fn ->
      PolicyEngine.remove_rules_by_source("cp_file_ops_test")
    end)
  end

  # ============================================================================
  # Layer 1: Tool permission_check (hard gate)
  # ============================================================================

  describe "Layer 1: hard gate blocks sensitive paths" do
    test "CpListFiles: hard gate blocks sensitive path even with allow-all policy" do
      allow_all_policy()

      result =
        Runner.invoke(
          :cp_list_files,
          %{"directory" => Path.join(System.user_home!(), ".ssh")},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "sensitive path blocked"
    end

    test "CpReadFile: hard gate blocks sensitive path even with allow-all policy" do
      allow_all_policy()

      result =
        Runner.invoke(
          :cp_read_file,
          %{"file_path" => Path.join(System.user_home!(), ".ssh/id_rsa")},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "sensitive path blocked"
    end

    test "CpGrep: hard gate blocks sensitive path even with allow-all policy" do
      allow_all_policy()

      result =
        Runner.invoke(
          :cp_grep,
          %{"directory" => "/etc", "search_string" => "password"},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "sensitive path blocked"
    end
  end

  # ============================================================================
  # Layer 2: FilePermission callback chain (policy gate)
  # ============================================================================

  describe "Layer 2: callback deny blocks safe paths" do
    test "CpListFiles: callback deny blocks safe path" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result = Runner.invoke(:cp_list_files, %{"directory" => @test_dir}, %{})
      assert {:error, reason} = result
      assert reason =~ "permission denied"
      assert reason =~ "blocked by security plugin"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "CpReadFile: callback deny blocks safe path" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(
          :cp_read_file,
          %{"file_path" => Path.join(@test_dir, "hello.txt")},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end

    test "CpGrep: callback deny blocks safe path" do
      allow_all_policy()

      deny_cb = fn _ctx, _path, _op, _, _, _ -> false end
      Callbacks.register(:file_permission, deny_cb)

      result =
        Runner.invoke(
          :cp_grep,
          %{"directory" => @test_dir, "search_string" => "def"},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "permission denied"

      Callbacks.unregister(:file_permission, deny_cb)
    end
  end

  # ============================================================================
  # Both layers pass → tool executes
  # ============================================================================

  describe "Both layers pass → tool executes" do
    test "CpListFiles: both layers pass → tool executes" do
      allow_all_policy()

      result = Runner.invoke(:cp_list_files, %{"directory" => @test_dir}, %{})
      assert {:ok, %{files: _}} = result
    end

    test "CpReadFile: both layers pass → tool executes" do
      allow_all_policy()

      result =
        Runner.invoke(
          :cp_read_file,
          %{"file_path" => Path.join(@test_dir, "hello.txt")},
          %{}
        )

      assert {:ok, _} = result
    end

    test "CpGrep: both layers pass → tool executes" do
      allow_all_policy()

      result =
        Runner.invoke(
          :cp_grep,
          %{"directory" => @test_dir, "search_string" => "Hello"},
          %{}
        )

      assert {:ok, %{matches: _}} = result
    end
  end

  # ============================================================================
  # Callback chain path verification
  # ============================================================================

  describe "FilePermission callback receives correct paths" do
    test "CpListFiles: FilePermission receives directory path" do
      allow_all_policy()

      test_pid = self()

      spy_cb = fn _ctx, path, _op, _, _, _ ->
        send(test_pid, {:file_perm_path, path})
        nil
      end

      Callbacks.register(:file_permission, spy_cb)

      Runner.invoke(:cp_list_files, %{"directory" => @test_dir}, %{})
      assert_received {:file_perm_path, @test_dir}

      Callbacks.unregister(:file_permission, spy_cb)
    end

    test "CpGrep: FilePermission receives directory path" do
      allow_all_policy()

      test_pid = self()

      spy_cb = fn _ctx, path, _op, _, _, _ ->
        send(test_pid, {:file_perm_path, path})
        nil
      end

      Callbacks.register(:file_permission, spy_cb)

      Runner.invoke(:cp_grep, %{"directory" => @test_dir, "search_string" => "x"}, %{})
      assert_received {:file_perm_path, @test_dir}

      Callbacks.unregister(:file_permission, spy_cb)
    end

    test "CpReadFile: FilePermission receives file_path" do
      allow_all_policy()

      file_path = Path.join(@test_dir, "hello.txt")
      test_pid = self()

      spy_cb = fn _ctx, path, _op, _, _, _ ->
        send(test_pid, {:file_perm_path, path})
        nil
      end

      Callbacks.register(:file_permission, spy_cb)

      Runner.invoke(:cp_read_file, %{"file_path" => file_path}, %{})
      assert_received {:file_perm_path, ^file_path}

      Callbacks.unregister(:file_permission, spy_cb)
    end
  end

  # ============================================================================
  # Default directory path propagation
  # ============================================================================

  describe "default directory path propagation" do
    test "CpListFiles: FilePermission receives \".\" when directory omitted" do
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

    test "CpGrep: FilePermission receives \".\" when directory omitted" do
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

  # ============================================================================
  # PolicyEngine deny
  # ============================================================================

  describe "PolicyEngine deny blocks safe paths" do
    test "CpListFiles: PolicyEngine deny blocks even for safe path" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "cp_list_files",
        decision: :deny,
        priority: 10,
        source: "cp_file_ops_test"
      })

      result = Runner.invoke(:cp_list_files, %{"directory" => @test_dir}, %{})
      assert {:error, reason} = result
      assert reason =~ "Denied by policy"
    end

    test "CpReadFile: PolicyEngine deny blocks even for safe path" do
      PolicyEngine.add_rule(%PolicyRule{
        tool_name: "cp_read_file",
        decision: :deny,
        priority: 10,
        source: "cp_file_ops_test"
      })

      result =
        Runner.invoke(
          :cp_read_file,
          %{"file_path" => Path.join(@test_dir, "hello.txt")},
          %{}
        )

      assert {:error, reason} = result
      assert reason =~ "Denied by policy"
    end
  end
end
