defmodule CodePuppyControl.Tools.StagedChangesRobustnessTest do
  @moduledoc """
  Robustness tests for StagedChanges — Shepherd REQUEST_CHANGES for code-puppy-ctj.5.

  Covers:
  1. StagedChange.from_map/1 catch-all for non-map input
  2. load_from_disk/1 with malformed "changes" values (string/number/map/nil)
  3. delete_file apply path safety (FileLock, dir/symlink refusal, path revalidation)
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Tools.StagedChanges
  alias CodePuppyControl.Tools.StagedChanges.StagedChange
  alias CodePuppyControl.Tools.StagedChanges.Applier

  @tmp_dir System.tmp_dir!()
  @stage_dir Path.join(System.tmp_dir!(), "code_puppy_staged")

  setup do
    case StagedChanges.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        StagedChanges.clear()
        StagedChanges.disable()
        :ok
    end

    # Save original session state so we can restore after tests
    # (load_from_disk changes the GenServer's session_id, breaking
    # other tests that expect the init-generated 16-char hex)
    original_sid = StagedChanges.session_id()
    {:ok, original_path} = StagedChanges.save_to_disk()

    on_exit(fn ->
      # Restore original session state
      StagedChanges.load_from_disk(original_sid)
      File.rm(original_path)
      # Clean up any corrupted test files
      File.rm(Path.join(@stage_dir, "corrupted_changes_test.json"))
      StagedChanges.clear()
      StagedChanges.disable()
    end)

    :ok
  end

  # ── StagedChange.from_map/1 non-map catch-all ───────────────────────────

  describe "StagedChange.from_map/1 non-map input" do
    test "returns error for string input" do
      assert {:error, reason} = StagedChange.from_map("not a map")
      assert reason =~ "expected map"
    end

    test "returns error for nil input" do
      assert {:error, reason} = StagedChange.from_map(nil)
      assert reason =~ "expected map"
    end

    test "returns error for integer input" do
      assert {:error, reason} = StagedChange.from_map(42)
      assert reason =~ "expected map"
    end

    test "returns error for list input" do
      assert {:error, reason} = StagedChange.from_map([1, 2, 3])
      assert reason =~ "expected map"
    end

    test "returns error for atom input" do
      assert {:error, reason} = StagedChange.from_map(:not_a_map)
      assert reason =~ "expected map"
    end

    test "returns error for float input" do
      assert {:error, reason} = StagedChange.from_map(3.14)
      assert reason =~ "expected map"
    end
  end

  # ── load_from_disk with malformed "changes" values ───────────────────────

  describe "load_from_disk with malformed changes field" do
    test "returns true (graceful) when changes is a string" do
      write_corrupted_changes("not a list but a string")
      assert StagedChanges.load_from_disk("corrupted_changes_test") == true
      assert StagedChanges.count() == 0
    end

    test "returns true (graceful) when changes is a number" do
      write_corrupted_changes(42)
      assert StagedChanges.load_from_disk("corrupted_changes_test") == true
      assert StagedChanges.count() == 0
    end

    test "returns true (graceful) when changes is a map instead of list" do
      write_corrupted_changes(%{"bad" => "structure"})
      assert StagedChanges.load_from_disk("corrupted_changes_test") == true
      assert StagedChanges.count() == 0
    end

    test "returns true (graceful) when changes is nil" do
      write_corrupted_changes(nil)
      assert StagedChanges.load_from_disk("corrupted_changes_test") == true
      assert StagedChanges.count() == 0
    end

    test "skips non-map entries in changes list, loads valid ones" do
      mixed_changes = [
        %{
          "change_id" => "valid_1",
          "change_type" => "create",
          "file_path" => "/tmp/valid.txt",
          "content" => "hello"
        },
        "this is not a map",
        42,
        nil,
        %{
          "change_id" => "valid_2",
          "change_type" => "REPLACE",
          "file_path" => "/tmp/valid2.txt",
          "old_str" => "a",
          "new_str" => "b"
        }
      ]

      write_corrupted_changes(mixed_changes)
      assert StagedChanges.load_from_disk("corrupted_changes_test") == true
      assert StagedChanges.count() == 2
    end

    test "returns true when changes is an empty list" do
      write_corrupted_changes([])
      assert StagedChanges.load_from_disk("corrupted_changes_test") == true
      assert StagedChanges.count() == 0
    end
  end

  # ── delete_file apply path safety ───────────────────────────────────────

  describe "Applier.apply_change delete_file safety" do
    test "refuses to delete a directory" do
      dir_path = Path.join(@tmp_dir, "staged_dir_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir_path)

      change = %StagedChange{
        change_id: "test_dir_delete",
        change_type: :delete_file,
        file_path: dir_path,
        content: nil,
        old_str: nil,
        new_str: nil,
        snippet: nil,
        description: "try deleting dir",
        created_at: System.system_time(:microsecond),
        applied: false,
        rejected: false
      }

      assert {:error, reason} = Applier.apply_change(change)
      assert reason =~ "directory" or reason =~ "Cannot delete"
      # Directory should still exist
      assert File.dir?(dir_path)
      File.rm_rf!(dir_path)
    end

    test "refuses to delete a symlink" do
      real_path = Path.join(@tmp_dir, "staged_symlink_real_#{:rand.uniform(100_000)}.txt")
      link_path = Path.join(@tmp_dir, "staged_symlink_link_#{:rand.uniform(100_000)}.txt")
      File.write!(real_path, "real content")
      File.ln_s!(real_path, link_path)

      change = %StagedChange{
        change_id: "test_symlink_delete",
        change_type: :delete_file,
        file_path: link_path,
        content: nil,
        old_str: nil,
        new_str: nil,
        snippet: nil,
        description: "try deleting symlink",
        created_at: System.system_time(:microsecond),
        applied: false,
        rejected: false
      }

      assert {:error, reason} = Applier.apply_change(change)
      assert reason =~ "symlink"
      # Symlink should still exist
      assert File.lstat!(link_path).type == :symlink
      File.rm(link_path)
      File.rm(real_path)
    end

    test "succeeds for normal file deletion" do
      path = Path.join(@tmp_dir, "staged_safe_del_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "to be deleted")

      change = %StagedChange{
        change_id: "test_normal_delete",
        change_type: :delete_file,
        file_path: path,
        content: nil,
        old_str: nil,
        new_str: nil,
        snippet: nil,
        description: "normal delete",
        created_at: System.system_time(:microsecond),
        applied: false,
        rejected: false
      }

      assert :ok = Applier.apply_change(change)
      refute File.exists?(path)
    end

    test "returns ok for already-deleted file" do
      path = Path.join(@tmp_dir, "staged_nondelexist_#{:rand.uniform(100_000)}.txt")
      # File doesn't exist at all

      change = %StagedChange{
        change_id: "test_already_deleted",
        change_type: :delete_file,
        file_path: path,
        content: nil,
        old_str: nil,
        new_str: nil,
        snippet: nil,
        description: "already gone",
        created_at: System.system_time(:microsecond),
        applied: false,
        rejected: false
      }

      assert :ok = Applier.apply_change(change)
    end

    test "rejects sensitive path in apply" do
      change = %StagedChange{
        change_id: "test_evil_delete",
        change_type: :delete_file,
        file_path: "/etc/passwd",
        content: nil,
        old_str: nil,
        new_str: nil,
        snippet: nil,
        description: "evil delete",
        created_at: System.system_time(:microsecond),
        applied: false,
        rejected: false
      }

      assert {:error, reason} = Applier.apply_change(change)
      assert reason =~ "validation" or reason =~ "Path"
    end

    test "uses FileLock for delete_file (concurrency serialization)" do
      # This is a behavioral test — if FileLock is working, concurrent deletes
      # on the same file should be serialized and not crash.
      path = Path.join(@tmp_dir, "staged_lock_del_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "locked delete test")

      change = %StagedChange{
        change_id: "test_lock_delete",
        change_type: :delete_file,
        file_path: path,
        content: nil,
        old_str: nil,
        new_str: nil,
        snippet: nil,
        description: "lock test",
        created_at: System.system_time(:microsecond),
        applied: false,
        rejected: false
      }

      # Run multiple concurrent applies — should not crash
      tasks =
        for _ <- 1..5 do
          Task.async(fn -> Applier.apply_change(change) end)
        end

      results = Task.await_many(tasks, 5000)

      # At least one should succeed (the first one to get the lock)
      # Others may return :ok (file already gone) or error
      assert Enum.any?(results, &(&1 == :ok))
    end
  end

  describe "apply_all delete_file integration" do
    test "apply_all uses safe delete (refuses directories)" do
      dir_path = Path.join(@tmp_dir, "staged_dir_int_#{:rand.uniform(100_000)}")
      File.mkdir_p!(dir_path)

      assert {:ok, _} = StagedChanges.add_delete_file(dir_path, "dir delete")
      assert {:error, _} = StagedChanges.apply_all()
      # Directory should still exist
      assert File.dir?(dir_path)
      File.rm_rf!(dir_path)
    end

    test "apply_all uses safe delete (refuses symlinks)" do
      real_path = Path.join(@tmp_dir, "staged_sym_int_real_#{:rand.uniform(100_000)}.txt")
      link_path = Path.join(@tmp_dir, "staged_sym_int_link_#{:rand.uniform(100_000)}.txt")
      File.write!(real_path, "real")
      File.ln_s!(real_path, link_path)

      assert {:ok, _} = StagedChanges.add_delete_file(link_path, "symlink delete")
      assert {:error, _} = StagedChanges.apply_all()
      # Symlink should still exist
      assert File.lstat!(link_path).type == :symlink
      File.rm(link_path)
      File.rm(real_path)
    end

    test "apply_all succeeds for normal file deletion" do
      path = Path.join(@tmp_dir, "staged_del_int_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "delete me")

      assert {:ok, _} = StagedChanges.add_delete_file(path, "normal delete")
      assert {:ok, 1} = StagedChanges.apply_all()
      refute File.exists?(path)
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp write_corrupted_changes(changes_value) do
    File.mkdir_p!(@stage_dir)

    data = %{
      "session_id" => "corrupted_changes_test",
      "enabled" => false,
      "changes" => changes_value,
      "saved_at" => System.system_time(:second)
    }

    path = Path.join(@stage_dir, "corrupted_changes_test.json")
    File.write!(path, Jason.encode!(data))
    path
  end
end
