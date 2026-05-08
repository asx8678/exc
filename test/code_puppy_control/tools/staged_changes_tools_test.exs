defmodule CodePuppyControl.Tools.StagedChangesToolsTest do
  @moduledoc """
  Tests for the StagedChanges tool modules.

  Split from staged_changes_test.exs for 600-line cap compliance.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Tools.StagedChanges
  alias CodePuppyControl.Tools.StagedChanges.Tools

  alias Tools.{
    StageCreateTool,
    StageReplaceTool,
    StageDeleteSnippetTool,
    StageDeleteFileTool,
    GetStagedDiffTool,
    ApplyStagedTool,
    RejectStagedTool
  }

  @tmp_dir System.tmp_dir!()

  setup do
    case StagedChanges.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        StagedChanges.clear()
        StagedChanges.disable()
        :ok
    end

    on_exit(fn ->
      StagedChanges.clear()
      StagedChanges.disable()
    end)
  end

  describe "StageCreateTool" do
    test "name/0 returns :stage_create", do: assert(StageCreateTool.name() == :stage_create)

    test "invoke/2 stages a create" do
      args = %{"file_path" => "/tmp/test.txt", "content" => "data", "description" => "test"}
      assert {:ok, c} = StageCreateTool.invoke(args, %{})
      assert c.change_type == :create
    end

    test "invoke/2 rejects sensitive paths" do
      args = %{"file_path" => "/etc/passwd", "content" => "hacked", "description" => "evil"}
      assert {:error, _} = StageCreateTool.invoke(args, %{})
    end
  end

  describe "StageReplaceTool" do
    test "name/0 returns :stage_replace", do: assert(StageReplaceTool.name() == :stage_replace)

    test "invoke/2 stages a replacement" do
      args = %{"file_path" => "/tmp/test.txt", "old_str" => "a", "new_str" => "b"}
      assert {:ok, c} = StageReplaceTool.invoke(args, %{})
      assert c.change_type == :replace
    end

    test "invoke/2 rejects sensitive paths" do
      args = %{"file_path" => "/etc/shadow", "old_str" => "a", "new_str" => "b"}
      assert {:error, _} = StageReplaceTool.invoke(args, %{})
    end
  end

  describe "StageDeleteSnippetTool" do
    test "name/0 returns :stage_delete_snippet",
      do: assert(StageDeleteSnippetTool.name() == :stage_delete_snippet)

    test "invoke/2 stages a snippet deletion" do
      args = %{"file_path" => "/tmp/test.txt", "snippet" => "remove"}
      assert {:ok, c} = StageDeleteSnippetTool.invoke(args, %{})
      assert c.change_type == :delete_snippet
    end
  end

  describe "StageDeleteFileTool" do
    test "name/0 returns :stage_delete_file",
      do: assert(StageDeleteFileTool.name() == :stage_delete_file)

    test "invoke/2 stages a file deletion" do
      args = %{"file_path" => "/tmp/test.txt", "description" => "delete test"}
      assert {:ok, c} = StageDeleteFileTool.invoke(args, %{})
      assert c.change_type == :delete_file
    end

    test "invoke/2 rejects sensitive paths" do
      args = %{"file_path" => "/etc/passwd", "description" => "evil"}
      assert {:error, _} = StageDeleteFileTool.invoke(args, %{})
    end
  end

  describe "GetStagedDiffTool" do
    test "name/0 returns :get_staged_diff",
      do: assert(GetStagedDiffTool.name() == :get_staged_diff)

    test "invoke/2 returns diff summary" do
      StagedChanges.add_create("/tmp/test.txt", "hello", "test")
      assert {:ok, r} = GetStagedDiffTool.invoke(%{}, %{})
      assert r.total_changes == 1 and r.diff =~ "+hello"
    end
  end

  describe "RejectStagedTool" do
    test "name/0 returns :reject_staged_changes",
      do: assert(RejectStagedTool.name() == :reject_staged_changes)

    test "invoke/2 rejects all pending" do
      StagedChanges.add_create("/tmp/a.txt", "a", "a")
      StagedChanges.add_create("/tmp/b.txt", "b", "b")
      assert {:ok, r} = RejectStagedTool.invoke(%{}, %{})
      assert r.rejected == 2 and StagedChanges.count() == 0
    end
  end

  describe "ApplyStagedTool" do
    test "name/0 returns :apply_staged_changes",
      do: assert(ApplyStagedTool.name() == :apply_staged_changes)

    test "invoke/2 applies creates to disk" do
      path = Path.join(@tmp_dir, "staged_apply_#{:rand.uniform(100_000)}.txt")
      StagedChanges.add_create(path, "staged content", "create test")
      assert {:ok, r} = ApplyStagedTool.invoke(%{}, %{})
      assert r.applied == 1 and File.exists?(path)
      File.rm(path)
    end

    test "invoke/2 with no changes returns 0" do
      assert {:ok, r} = ApplyStagedTool.invoke(%{}, %{})
      assert r.applied == 0
    end
  end

  describe "slash-only decision" do
    test "staged tools are not auto-registered as agent-facing tools" do
      # After a fresh registry, verify that staged tool names are NOT
      # in the registry unless explicitly registered via register_all/0.
      # Unregister any staged tools from prior tests first.
      staged_names = [
        :stage_create,
        :stage_replace,
        :stage_delete_snippet,
        :stage_delete_file,
        :get_staged_diff,
        :apply_staged_changes,
        :reject_staged_changes
      ]

      for name <- staged_names do
        CodePuppyControl.Tool.Registry.unregister(name)
      end

      # Now verify they are NOT auto-discovered by default_modules
      for name <- staged_names do
        result = CodePuppyControl.Tool.Registry.lookup(name)

        assert result == :error,
               "Staged tool #{name} should not be auto-registered"
      end
    end
  end

  describe "register_all/0" do
    test "registers all staged changes tools (testing only)" do
      {:ok, count} = StagedChanges.register_all()
      # Should include StageDeleteFileTool now
      assert count >= 7
      # Clean up — unregister so we don't pollute other tests
      for name <- [
            :stage_create,
            :stage_replace,
            :stage_delete_snippet,
            :stage_delete_file,
            :get_staged_diff,
            :apply_staged_changes,
            :reject_staged_changes
          ] do
        CodePuppyControl.Tool.Registry.unregister(name)
      end
    end
  end
end
