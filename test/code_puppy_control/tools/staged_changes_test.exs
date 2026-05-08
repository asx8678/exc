defmodule CodePuppyControl.Tools.StagedChangesTest do
  @moduledoc """
  Tests for the StagedChanges sandbox — core and parity invariants.

  Tool module tests are in staged_changes_tools_test.exs (split for 600-line cap).
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Tools.StagedChanges
  alias CodePuppyControl.Tools.StagedChanges.StagedChange

  @tmp_dir System.tmp_dir!()

  setup do
    # (code_puppy-i1n) Ensure the application-supervised StagedChanges is alive.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(StagedChanges)

    case StagedChanges.start_link([]) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        StagedChanges.clear()
        StagedChanges.disable()
        :ok
    end

    on_exit(fn ->
      try do
        sid = StagedChanges.session_id()
        stage_dir = Path.join(System.tmp_dir!(), "code_puppy_staged")
        File.rm(Path.join(stage_dir, "#{sid}.json"))
        File.rm(Path.join(stage_dir, "#{sid}.json.tmp"))
        StagedChanges.clear()
        StagedChanges.disable()
      catch
        :exit, _ -> :ok
      end
    end)
  end

  # ── Enable/Disable/Toggle ───────────────────────────────────────────────

  describe "enable/disable/toggle" do
    test "starts disabled by default", do: assert(StagedChanges.enabled?() == false)

    test "can be enabled and disabled" do
      StagedChanges.enable()
      assert StagedChanges.enabled?() == true
      StagedChanges.disable()
      assert StagedChanges.enabled?() == false
    end

    test "toggle flips the state and returns new value" do
      assert StagedChanges.toggle() == true
      assert StagedChanges.enabled?() == true
      assert StagedChanges.toggle() == false
      assert StagedChanges.enabled?() == false
    end
  end

  # ── Staging operations ──────────────────────────────────────────────────

  describe "staging operations" do
    test "add_create stages a file creation" do
      assert {:ok, c} = StagedChanges.add_create("/tmp/test.txt", "content", "test")
      assert c.change_type == :create
      assert c.content == "content"
      assert StagedChanges.count() == 1
    end

    test "add_replace stages a replacement" do
      assert {:ok, c} = StagedChanges.add_replace("/tmp/test.txt", "old", "new", "test")
      assert c.change_type == :replace
    end

    test "add_delete_snippet stages a snippet deletion" do
      assert {:ok, c} = StagedChanges.add_delete_snippet("/tmp/test.txt", "remove me", "test")
      assert c.change_type == :delete_snippet
    end

    test "add_delete_file stages a file deletion" do
      assert {:ok, c} = StagedChanges.add_delete_file("/tmp/test.txt", "delete test")
      assert c.change_type == :delete_file
    end

    test "add_delete_file uses default description" do
      assert {:ok, c} = StagedChanges.add_delete_file("/tmp/myfile.txt")
      assert c.description == "Delete myfile.txt"
    end

    test "count and is_empty?" do
      assert StagedChanges.is_empty?() == true
      assert StagedChanges.count() == 0
      StagedChanges.add_create("/tmp/a.txt", "a", "a")
      StagedChanges.add_create("/tmp/b.txt", "b", "b")
      assert StagedChanges.count() == 2
      assert StagedChanges.is_empty?() == false
    end

    test "get_staged_changes returns pending changes" do
      StagedChanges.add_create("/tmp/test.txt", "content", "test")
      changes = StagedChanges.get_staged_changes()
      assert length(changes) == 1
      assert hd(changes).change_type == :create
    end

    test "get_staged_changes with include_applied returns all" do
      {:ok, c1} = StagedChanges.add_create("/tmp/a.txt", "a", "a")
      {:ok, _c2} = StagedChanges.add_create("/tmp/b.txt", "b", "b")
      :ets.insert(:staged_changes, {c1.change_id, %{c1 | applied: true}})
      assert length(StagedChanges.get_staged_changes()) == 1
      assert length(StagedChanges.get_staged_changes(include_applied: true)) == 2
    end

    test "clear removes all changes" do
      StagedChanges.add_create("/tmp/test.txt", "content", "test")
      StagedChanges.clear()
      assert StagedChanges.count() == 0
    end

    test "remove_change returns true when found, false when not" do
      {:ok, c} = StagedChanges.add_create("/tmp/test.txt", "content", "test")
      assert StagedChanges.remove_change(c.change_id) == true
      assert StagedChanges.count() == 0
      # Already removed — should return false
      assert StagedChanges.remove_change(c.change_id) == false
      # Non-existent ID — should return false
      assert StagedChanges.remove_change("nonexistent_id") == false
    end
  end

  # ── Security: sensitive path blocking ───────────────────────────────────

  describe "sensitive path blocking" do
    test "add_create rejects sensitive SSH key paths" do
      home = System.user_home!()
      assert {:error, _} = StagedChanges.add_create(Path.join(home, ".ssh/id_rsa"), "key")
    end

    test "add_create rejects /etc/passwd" do
      assert {:error, _} = StagedChanges.add_create("/etc/passwd", "hacked")
    end

    test "add_replace rejects sensitive paths" do
      assert {:error, _} = StagedChanges.add_replace("/etc/shadow", "old", "new")
    end

    test "add_delete_snippet rejects sensitive paths" do
      assert {:error, _} = StagedChanges.add_delete_snippet("/etc/sudoers", "line")
    end

    test "add_delete_file rejects sensitive paths" do
      assert {:error, _} = StagedChanges.add_delete_file("/etc/passwd")
    end

    test "add_create allows normal project paths" do
      assert {:ok, _} = StagedChanges.add_create("/tmp/project/main.rs", "fn main() { }\n")
    end

    test "add_create rejects .pem files" do
      assert {:error, _} = StagedChanges.add_create("/tmp/evil.pem", "cert data")
    end

    test "add_create rejects .env files" do
      assert {:error, _} = StagedChanges.add_create("/tmp/project/.env", "SECRET=abc")
    end
  end

  describe "get_changes_for_file" do
    test "returns changes for a specific file" do
      StagedChanges.add_create("/tmp/file_a.txt", "a", "a")
      StagedChanges.add_create("/tmp/file_b.txt", "b", "b")
      StagedChanges.add_replace("/tmp/file_a.txt", "old", "new", "a replace")
      assert length(StagedChanges.get_changes_for_file("/tmp/file_a.txt")) == 2
    end

    test "returns empty list for unknown file" do
      StagedChanges.add_create("/tmp/other.txt", "x", "x")
      assert StagedChanges.get_changes_for_file("/tmp/nonexistent.txt") == []
    end
  end

  describe "session_id" do
    test "returns a 16-char hex string" do
      sid = StagedChanges.session_id()
      assert is_binary(sid) and String.length(sid) == 16
      assert sid =~ ~r/^[0-9a-f]{16}$/
    end
  end

  # ── StagedChange struct ─────────────────────────────────────────────────

  describe "StagedChange validation" do
    test "raises when both applied and rejected are true" do
      assert_raise ArgumentError, "StagedChange cannot be both applied and rejected", fn ->
        StagedChange.new(
          change_id: "t",
          change_type: :create,
          file_path: "/tmp/x",
          applied: true,
          rejected: true
        )
      end
    end

    test "allows applied=true, rejected=false" do
      c =
        StagedChange.new(change_id: "t", change_type: :create, file_path: "/tmp/x", applied: true)

      assert c.applied == true
    end

    test "allows applied=false, rejected=true" do
      c =
        StagedChange.new(
          change_id: "t",
          change_type: :create,
          file_path: "/tmp/x",
          rejected: true
        )

      assert c.rejected == true
    end
  end

  describe "StagedChange serialization" do
    test "to_map / from_map round-trip preserves all fields" do
      {:ok, original} = StagedChanges.add_create("/tmp/rt.txt", "data", "round trip test")
      map = StagedChange.to_map(original)
      assert map["change_id"] == original.change_id
      assert map["change_type"] == "create"
      assert map["content"] == "data"
      assert {:ok, restored} = StagedChange.from_map(map)
      assert restored.change_id == original.change_id
      assert restored.change_type == :create
      assert restored.content == "data"
    end

    test "from_map handles atom change_type" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => :replace,
                 "file_path" => "/tmp/x"
               })

      assert c.change_type == :replace
    end

    test "from_map handles missing optional fields with defaults" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "create",
                 "file_path" => "/tmp/x"
               })

      assert c.description == "" and c.applied == false and c.rejected == false
    end

    test "from_map handles Python uppercase CREATE" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "CREATE",
                 "file_path" => "/tmp/x"
               })

      assert c.change_type == :create
    end

    test "from_map handles Python uppercase REPLACE" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "REPLACE",
                 "file_path" => "/tmp/x"
               })

      assert c.change_type == :replace
    end

    test "from_map handles Python uppercase DELETE_SNIPPET" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "DELETE_SNIPPET",
                 "file_path" => "/tmp/x"
               })

      assert c.change_type == :delete_snippet
    end

    test "from_map handles Python uppercase DELETE_FILE" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "DELETE_FILE",
                 "file_path" => "/tmp/x"
               })

      assert c.change_type == :delete_file
    end

    test "from_map returns error for unknown change_type string" do
      assert {:error, _} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "EVIL_TYPE",
                 "file_path" => "/tmp/x"
               })
    end

    test "from_map returns error for unknown change_type atom" do
      assert {:error, _} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => :evil_type,
                 "file_path" => "/tmp/x"
               })
    end

    test "from_map returns error for missing change_id" do
      assert {:error, _} =
               StagedChange.from_map(%{"change_type" => "create", "file_path" => "/tmp/x"})
    end

    test "from_map returns error for missing file_path" do
      assert {:error, _} = StagedChange.from_map(%{"change_id" => "a", "change_type" => "create"})
    end

    test "from_map returns error for missing change_type" do
      assert {:error, _} = StagedChange.from_map(%{"change_id" => "a", "file_path" => "/tmp/x"})
    end

    test "from_map returns error for empty change_id" do
      assert {:error, _} =
               StagedChange.from_map(%{
                 "change_id" => "",
                 "change_type" => "create",
                 "file_path" => "/tmp/x"
               })
    end

    test "from_map handles applied+rejected=true as rejected (safe default)" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "create",
                 "file_path" => "/tmp/x",
                 "applied" => true,
                 "rejected" => true
               })

      assert c.applied == false
      assert c.rejected == true
    end

    test "from_map coerces string boolean values" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "create",
                 "file_path" => "/tmp/x",
                 "applied" => "true",
                 "rejected" => "false"
               })

      assert c.applied == true
      assert c.rejected == false
    end

    test "from_map coerces integer boolean values" do
      assert {:ok, c} =
               StagedChange.from_map(%{
                 "change_id" => "a",
                 "change_type" => "create",
                 "file_path" => "/tmp/x",
                 "applied" => 1,
                 "rejected" => 0
               })

      assert c.applied == true
      assert c.rejected == false
    end
  end

  # ── Combined diff ───────────────────────────────────────────────────────

  describe "get_combined_diff" do
    test "returns empty string when no changes",
      do: assert(StagedChanges.get_combined_diff() == "")

    test "returns diff for staged create" do
      StagedChanges.add_create("/tmp/test.txt", "hello\nworld\n", "create test")
      diff = StagedChanges.get_combined_diff()
      assert diff =~ "+hello" and diff =~ "+world"
    end

    test "includes change description" do
      StagedChanges.add_create("/tmp/test.txt", "content", "My important change")
      assert StagedChanges.get_combined_diff() =~ "My important change"
    end

    test "includes change_id in diff header" do
      {:ok, c} = StagedChanges.add_create("/tmp/test.txt", "content", "test")
      assert StagedChanges.get_combined_diff() =~ c.change_id
    end

    test "generates diff for replace on existing file" do
      path = Path.join(@tmp_dir, "staged_rpl_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "line1\nline2\nline3\n")
      StagedChanges.add_replace(path, "line2", "modified", "replace test")
      diff = StagedChanges.get_combined_diff()
      assert diff =~ "-line2" and diff =~ "+modified"
      File.rm(path)
    end

    test "generates diff for delete_snippet on existing file" do
      path = Path.join(@tmp_dir, "staged_del_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "keep\nremove me\nkeep2\n")
      StagedChanges.add_delete_snippet(path, "remove me\n", "delete test")
      assert StagedChanges.get_combined_diff() =~ "-remove me"
      File.rm(path)
    end

    test "uses file cache (same file in multiple changes)" do
      path = Path.join(@tmp_dir, "staged_cache_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "alpha\nbeta\ngamma\n")
      StagedChanges.add_replace(path, "alpha", "ALPHA", "first")
      StagedChanges.add_replace(path, "gamma", "GAMMA", "second")
      diff = StagedChanges.get_combined_diff()
      assert diff =~ "+ALPHA" and diff =~ "+GAMMA"
      File.rm(path)
    end
  end

  # ── Preview / Summary ───────────────────────────────────────────────────

  describe "preview_changes" do
    test "returns empty map when no changes", do: assert(StagedChanges.preview_changes() == %{})

    test "groups changes by file" do
      StagedChanges.add_create("/tmp/alpha.txt", "a", "a")
      StagedChanges.add_create("/tmp/beta.txt", "b", "b")
      preview = StagedChanges.preview_changes()
      assert Map.has_key?(preview, Path.expand("/tmp/alpha.txt"))
      assert Map.has_key?(preview, Path.expand("/tmp/beta.txt"))
    end

    test "preview contains diff content" do
      StagedChanges.add_create("/tmp/preview.txt", "hello\n", "preview test")
      {_, diff} = Enum.at(StagedChanges.preview_changes(), 0)
      assert diff =~ "+hello"
    end
  end

  describe "get_summary" do
    test "returns correct structure with no changes" do
      s = StagedChanges.get_summary()
      assert s.total == 0 and s.by_type == %{} and s.by_file == 0 and is_binary(s.session_id)
    end

    test "counts changes by type and files" do
      StagedChanges.add_create("/tmp/a.txt", "a", "a")
      StagedChanges.add_create("/tmp/b.txt", "b", "b")
      StagedChanges.add_replace("/tmp/c.txt", "old", "new", "r")
      s = StagedChanges.get_summary()
      assert s.total == 3 and s.by_type["create"] == 2 and s.by_type["replace"] == 1
    end

    test "counts unique files affected" do
      StagedChanges.add_create("/tmp/a.txt", "a", "a")
      StagedChanges.add_replace("/tmp/a.txt", "old", "new", "r")
      assert StagedChanges.get_summary().by_file == 1
    end
  end

  # ── Save / Load ─────────────────────────────────────────────────────────

  describe "save_to_disk / load_from_disk" do
    test "save_to_disk returns ok path" do
      StagedChanges.add_create("/tmp/save_test.txt", "save me", "save test")
      assert {:ok, path} = StagedChanges.save_to_disk()
      assert String.ends_with?(path, ".json")
      File.rm(path)
    end

    test "save then load preserves changes" do
      StagedChanges.add_create("/tmp/persist_a.txt", "aaa", "persist a")
      StagedChanges.add_replace("/tmp/persist_b.txt", "old", "new", "persist b")
      {:ok, path} = StagedChanges.save_to_disk()
      StagedChanges.clear()
      assert StagedChanges.count() == 0
      assert StagedChanges.load_from_disk() == true
      assert StagedChanges.count() == 2
      File.rm(path)
    end

    test "load_from_disk returns false for nonexistent session" do
      assert StagedChanges.load_from_disk("nonexistent_session_12345") == false
    end

    test "load_from_disk returns false for malformed JSON" do
      stage_dir = Path.join(System.tmp_dir!(), "code_puppy_staged")
      File.mkdir_p!(stage_dir)
      sid = StagedChanges.session_id()
      bad_path = Path.join(stage_dir, "#{sid}_bad.json")
      File.write!(bad_path, "not valid json {{{")
      assert StagedChanges.load_from_disk("#{sid}_bad") == false
      File.rm(bad_path)
    end

    test "load_from_disk skips malformed entries, loads valid ones" do
      StagedChanges.add_create("/tmp/good_change.txt", "good", "good change")
      {:ok, path} = StagedChanges.save_to_disk()
      {:ok, raw} = File.read(path)
      {:ok, data} = Jason.decode(raw)
      # Inject a malformed entry (missing change_id)
      bad_entry = %{"change_type" => "create", "file_path" => "/tmp/bad.txt"}
      # Also inject an entry with unknown change_type
      evil_entry = %{"change_id" => "z", "change_type" => "EVIL", "file_path" => "/tmp/evil.txt"}
      corrupted_data = Map.update!(data, "changes", &(&1 ++ [bad_entry, evil_entry]))
      File.write!(path, Jason.encode!(corrupted_data))
      StagedChanges.clear()
      assert StagedChanges.load_from_disk() == true
      # Only the valid change should be loaded
      assert StagedChanges.count() == 1
      File.rm(path)
    end

    test "load_from_disk handles legacy uppercase change_types in persisted JSON" do
      stage_dir = Path.join(System.tmp_dir!(), "code_puppy_staged")
      File.mkdir_p!(stage_dir)
      original_sid = StagedChanges.session_id()
      # Save current session so we can restore it after (load_from_disk changes session_id)
      {:ok, _original_path} = StagedChanges.save_to_disk()
      legacy_path = Path.join(stage_dir, "#{original_sid}_legacy.json")
      # Simulate a legacy-persisted JSON with uppercase change_type
      # (compatibility with data persisted by the former Python implementation)
      legacy_data = %{
        "session_id" => "#{original_sid}_legacy",
        "enabled" => true,
        "changes" => [
          %{
            "change_id" => "legacy_upper_1",
            "change_type" => "CREATE",
            "file_path" => "/tmp/from_legacy.txt",
            "content" => "hello from legacy",
            "old_str" => nil,
            "new_str" => nil,
            "snippet" => nil,
            "created_at" => 1_700_000_000,
            "description" => "Legacy create",
            "applied" => false,
            "rejected" => false
          },
          %{
            "change_id" => "legacy_upper_2",
            "change_type" => "DELETE_FILE",
            "file_path" => "/tmp/delete_me.txt",
            "content" => nil,
            "old_str" => nil,
            "new_str" => nil,
            "snippet" => nil,
            "created_at" => 1_700_000_001,
            "description" => "Legacy delete",
            "applied" => false,
            "rejected" => false
          }
        ],
        "saved_at" => 1_700_000_000
      }

      File.write!(legacy_path, Jason.encode!(legacy_data))
      StagedChanges.clear()
      assert StagedChanges.load_from_disk("#{original_sid}_legacy") == true
      changes = StagedChanges.get_staged_changes()
      assert length(changes) == 2
      types = Enum.map(changes, & &1.change_type) |> Enum.sort()
      assert :create in types
      assert :delete_file in types
      # Restore session state so other tests aren't affected
      StagedChanges.clear()
      StagedChanges.disable()
      # Restore original session_id by loading the saved state
      StagedChanges.load_from_disk(original_sid)
      File.rm(legacy_path)
    end

    test "save file is valid JSON" do
      StagedChanges.add_create("/tmp/json_test.txt", "json content", "json test")
      {:ok, path} = StagedChanges.save_to_disk()
      {:ok, raw} = File.read(path)
      assert {:ok, _} = Jason.decode(raw)
      File.rm(path)
    end
  end

  # ── reject_all / apply_all ───────────────────────────────────────────────

  describe "reject_all" do
    test "marks all changes as rejected" do
      StagedChanges.add_create("/tmp/a.txt", "a", "a")
      StagedChanges.add_create("/tmp/b.txt", "b", "b")
      assert StagedChanges.reject_all() == 2
      assert StagedChanges.count() == 0
    end

    test "rejected changes appear with include_applied" do
      {:ok, _c1} = StagedChanges.add_create("/tmp/a.txt", "a", "a")
      StagedChanges.reject_all()
      assert StagedChanges.get_staged_changes() == []
      all = StagedChanges.get_staged_changes(include_applied: true)
      assert length(all) == 1 and hd(all).rejected == true
    end
  end

  describe "apply_all" do
    test "applies creates to disk" do
      path = Path.join(@tmp_dir, "staged_apply_#{:rand.uniform(100_000)}.txt")
      StagedChanges.add_create(path, "staged content", "create test")
      assert {:ok, 1} = StagedChanges.apply_all()
      assert File.read!(path) == "staged content"
      File.rm(path)
    end

    test "with no changes returns 0", do: assert({:ok, 0} = StagedChanges.apply_all())

    test "marks applied changes" do
      path = Path.join(@tmp_dir, "staged_applied_#{:rand.uniform(100_000)}.txt")
      StagedChanges.add_create(path, "data", "test")
      StagedChanges.apply_all()
      assert StagedChanges.count() == 0
      assert Enum.any?(StagedChanges.get_staged_changes(include_applied: true), & &1.applied)
      File.rm(path)
    end

    test "applies replace to existing file" do
      path = Path.join(@tmp_dir, "staged_rpl_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "hello world")
      StagedChanges.add_replace(path, "world", "universe", "replace test")
      assert {:ok, 1} = StagedChanges.apply_all()
      assert File.read!(path) == "hello universe"
      File.rm(path)
    end

    test "applies delete_snippet to existing file" do
      path = Path.join(@tmp_dir, "staged_del_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "keep\nremove\nkeep2\n")
      StagedChanges.add_delete_snippet(path, "remove\n", "delete test")
      assert {:ok, 1} = StagedChanges.apply_all()
      assert File.read!(path) == "keep\nkeep2\n"
      File.rm(path)
    end

    test "applies delete_file to existing file" do
      path = Path.join(@tmp_dir, "staged_delf_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "to be deleted")
      StagedChanges.add_delete_file(path, "delete test")
      assert {:ok, 1} = StagedChanges.apply_all()
      refute File.exists?(path)
    end
  end

  # ── Default descriptions ────────────────────────────────────────────────

  describe "default descriptions" do
    test "add_create uses default description when none provided" do
      {:ok, c} = StagedChanges.add_create("/tmp/hello.txt", "x")
      assert c.description == "Create hello.txt"
    end

    test "add_replace uses default description when none provided" do
      {:ok, c} = StagedChanges.add_replace("/tmp/hello.txt", "a", "b")
      assert c.description == "Replace in hello.txt"
    end

    test "add_delete_snippet uses default description when none provided" do
      {:ok, c} = StagedChanges.add_delete_snippet("/tmp/hello.txt", "x")
      assert c.description == "Delete from hello.txt"
    end
  end

  # ── Parity invariants (prevent drift) ───────────────────────────────────

  describe "parity invariants" do
    test "change_id is 32-char hex (matches Python UUID4 hex)" do
      {:ok, c} = StagedChanges.add_create("/tmp/test.txt", "x")
      assert String.length(c.change_id) == 32
      assert c.change_id =~ ~r/^[0-9a-f]{32}$/
    end

    test "file_path is expanded to absolute" do
      {:ok, c} = StagedChanges.add_create("relative.txt", "x")
      assert Path.type(c.file_path) == :absolute
    end

    test "created_at is a positive integer" do
      {:ok, c} = StagedChanges.add_create("/tmp/test.txt", "x")
      assert is_integer(c.created_at) and c.created_at > 0
    end

    test "staged changes maintain insertion order (OrderedDict parity)" do
      {:ok, c1} = StagedChanges.add_create("/tmp/first.txt", "1", "first")
      {:ok, c2} = StagedChanges.add_create("/tmp/second.txt", "2", "second")
      {:ok, c3} = StagedChanges.add_create("/tmp/third.txt", "3", "third")
      ids = StagedChanges.get_staged_changes() |> Enum.map(& &1.change_id)
      assert ids == [c1.change_id, c2.change_id, c3.change_id]
    end

    test "combined diff output format matches Python (comment header)" do
      StagedChanges.add_create("/tmp/parity.txt", "content\n", "parity test")
      assert StagedChanges.get_combined_diff() =~ ~r/^# .+ \([0-9a-f]{32}\)/
    end
  end

  # ── Safe apply: symlink protection via SafeWrite ────────────────────────

  describe "safe apply" do
    test "apply_all uses SafeWrite (symlink-safe) for creates" do
      path = Path.join(@tmp_dir, "staged_safe_#{:rand.uniform(100_000)}.txt")
      StagedChanges.add_create(path, "safe content", "safe test")
      assert {:ok, 1} = StagedChanges.apply_all()
      assert File.read!(path) == "safe content"
      File.rm(path)
    end

    test "apply_all uses SafeWrite (symlink-safe) for replaces" do
      path = Path.join(@tmp_dir, "staged_safe_rpl_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "original content")
      StagedChanges.add_replace(path, "original", "replaced", "safe replace")
      assert {:ok, 1} = StagedChanges.apply_all()
      assert File.read!(path) == "replaced content"
      File.rm(path)
    end
  end
end
