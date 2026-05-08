defmodule CodePuppyControl.SessionStorageTest do
  @moduledoc """
  Tests for CodePuppyControl.SessionStorage.

  All tests use System.tmp_dir!/0 for isolation — never touches ~/.code_puppy/.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.SessionStorage

  # ---------------------------------------------------------------------------
  # Setup: temp directory per test
  # ---------------------------------------------------------------------------

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "session_storage_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, base_dir: tmp}
  end

  # ---------------------------------------------------------------------------
  # CRUD: Create / Save
  # ---------------------------------------------------------------------------

  describe "save_session/3" do
    test "creates a new session file", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "Hello"}]

      assert {:ok, meta} =
               SessionStorage.save_session("test-session", messages, base_dir: dir)

      assert meta.session_name == "test-session"
      assert meta.message_count == 1
      assert meta.total_tokens == 0
      assert File.exists?(Path.join(dir, "test-session.json"))
      assert File.exists?(Path.join(dir, "test-session_meta.json"))
    end

    test "overwrites existing session (upsert)", %{base_dir: dir} do
      messages_v1 = [%{"role" => "user", "content" => "v1"}]
      messages_v2 = [%{"role" => "user", "content" => "v2"}]

      assert {:ok, _} =
               SessionStorage.save_session("upsert-test", messages_v1, base_dir: dir)

      assert {:ok, meta} =
               SessionStorage.save_session("upsert-test", messages_v2, base_dir: dir)

      assert meta.message_count == 1

      assert {:ok, loaded} = SessionStorage.load_session("upsert-test", base_dir: dir)
      assert [%{"content" => "v2"}] = loaded.messages
    end

    test "preserves all options", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "test"}]

      assert {:ok, meta} =
               SessionStorage.save_session("opts-test", messages,
                 base_dir: dir,
                 compacted_hashes: ["abc123"],
                 total_tokens: 4096,
                 auto_saved: true,
                 timestamp: "2026-01-15T10:30:00Z"
               )

      assert meta.total_tokens == 4096
      assert meta.auto_saved == true
      assert meta.timestamp == "2026-01-15T10:30:00Z"
    end

    test "normalizes unsafe name characters", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "test"}]

      assert {:ok, _meta} =
               SessionStorage.save_session("My WEIRD Session!!!", messages, base_dir: dir)

      # The normalized name should be used for the file
      assert File.exists?(Path.join(dir, "my-weird-session.json"))
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD: Read / Load
  # ---------------------------------------------------------------------------

  describe "load_session/2" do
    test "loads an existing session", %{base_dir: dir} do
      messages = [
        %{"role" => "system", "content" => "You are helpful"},
        %{"role" => "user", "content" => "Hi"}
      ]

      {:ok, _} =
        SessionStorage.save_session("load-test", messages,
          base_dir: dir,
          compacted_hashes: ["hash1"]
        )

      assert {:ok, result} = SessionStorage.load_session("load-test", base_dir: dir)
      assert length(result.messages) == 2
      assert result.compacted_hashes == ["hash1"]
    end

    test "returns :not_found for missing session", %{base_dir: dir} do
      assert {:error, :not_found} = SessionStorage.load_session("nonexistent", base_dir: dir)
    end

    test "returns empty compacted_hashes when not provided", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "test"}]
      {:ok, _} = SessionStorage.save_session("no-hashes", messages, base_dir: dir)

      assert {:ok, result} = SessionStorage.load_session("no-hashes", base_dir: dir)
      assert result.compacted_hashes == []
    end
  end

  describe "load_session_full/2" do
    test "returns the full session data with format", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "test"}]

      {:ok, _} =
        SessionStorage.save_session("full-test", messages, base_dir: dir, total_tokens: 100)

      assert {:ok, data} = SessionStorage.load_session_full("full-test", base_dir: dir)
      assert data["format"] == "code-puppy-ex-v1"
      assert data["payload"]["messages"] == messages
      assert data["metadata"]["total_tokens"] == 100
    end

    test "returns :not_found for missing session", %{base_dir: dir} do
      assert {:error, :not_found} =
               SessionStorage.load_session_full("nonexistent", base_dir: dir)
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD: Update
  # ---------------------------------------------------------------------------

  describe "update_session/2" do
    test "updates metadata fields", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "test"}]

      {:ok, _} =
        SessionStorage.save_session("update-test", messages, base_dir: dir, total_tokens: 50)

      assert {:ok, meta} =
               SessionStorage.update_session("update-test",
                 total_tokens: 200,
                 auto_saved: true,
                 base_dir: dir
               )

      assert meta.total_tokens == 200
      assert meta.auto_saved == true
    end

    test "preserves unmodified fields", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "test"}]

      {:ok, _} =
        SessionStorage.save_session("preserve-test", messages,
          base_dir: dir,
          total_tokens: 50,
          timestamp: "2026-01-01T00:00:00Z"
        )

      assert {:ok, meta} =
               SessionStorage.update_session("preserve-test",
                 total_tokens: 999,
                 base_dir: dir
               )

      # timestamp should remain unchanged
      assert meta.timestamp == "2026-01-01T00:00:00Z"
      assert meta.total_tokens == 999
    end

    test "returns :not_found for missing session", %{base_dir: dir} do
      assert {:error, :not_found} =
               SessionStorage.update_session("nonexistent",
                 total_tokens: 100,
                 base_dir: dir
               )
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD: Delete
  # ---------------------------------------------------------------------------

  describe "delete_session/2" do
    test "deletes an existing session", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "test"}]

      {:ok, _} = SessionStorage.save_session("delete-me", messages, base_dir: dir)
      assert SessionStorage.session_exists?("delete-me", base_dir: dir)

      assert :ok = SessionStorage.delete_session("delete-me", base_dir: dir)
      refute SessionStorage.session_exists?("delete-me", base_dir: dir)
    end

    test "is idempotent for non-existent sessions", %{base_dir: dir} do
      assert :ok = SessionStorage.delete_session("never-existed", base_dir: dir)
    end

    test "removes both session and metadata files", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "test"}]

      {:ok, _} = SessionStorage.save_session("both-files", messages, base_dir: dir)

      session_path = Path.join(dir, "both-files.json")
      meta_path = Path.join(dir, "both-files_meta.json")

      assert File.exists?(session_path)
      assert File.exists?(meta_path)

      :ok = SessionStorage.delete_session("both-files", base_dir: dir)

      refute File.exists?(session_path)
      refute File.exists?(meta_path)
    end
  end

  # ---------------------------------------------------------------------------
  # Listing
  # ---------------------------------------------------------------------------

  describe "list_sessions/1" do
    test "returns empty list for empty directory", %{base_dir: dir} do
      assert {:ok, []} = SessionStorage.list_sessions(base_dir: dir)
    end

    test "returns sorted session names", %{base_dir: dir} do
      for name <- ["z-session", "a-session", "m-session"] do
        SessionStorage.save_session(name, [], base_dir: dir)
      end

      assert {:ok, names} = SessionStorage.list_sessions(base_dir: dir)
      assert names == ["a-session", "m-session", "z-session"]
    end

    test "only lists session files, not metadata files", %{base_dir: dir} do
      SessionStorage.save_session("only-sessions", [%{"r" => "u"}], base_dir: dir)

      assert {:ok, ["only-sessions"]} = SessionStorage.list_sessions(base_dir: dir)
    end
  end

  describe "list_sessions_with_metadata/1" do
    test "returns sessions sorted newest-first", %{base_dir: dir} do
      SessionStorage.save_session("old", [], base_dir: dir, timestamp: "2026-01-01T00:00:00Z")
      SessionStorage.save_session("new", [], base_dir: dir, timestamp: "2026-06-01T00:00:00Z")

      assert {:ok, [first, second]} = SessionStorage.list_sessions_with_metadata(base_dir: dir)
      assert first.session_name == "new"
      assert second.session_name == "old"
    end

    test "includes metadata fields", %{base_dir: dir} do
      SessionStorage.save_session("meta-test", [%{"r" => "u"}],
        base_dir: dir,
        total_tokens: 42,
        auto_saved: true
      )

      assert {:ok, [meta]} = SessionStorage.list_sessions_with_metadata(base_dir: dir)
      assert meta.total_tokens == 42
      assert meta.auto_saved == true
    end
  end

  # ---------------------------------------------------------------------------
  # Search
  # ---------------------------------------------------------------------------

  describe "search_sessions/1" do
    setup %{base_dir: dir} do
      # Create a mix of sessions for searching
      SessionStorage.save_session("alpha-review", [%{"r" => "u"}],
        base_dir: dir,
        total_tokens: 100,
        auto_saved: false,
        timestamp: "2026-01-01T00:00:00Z"
      )

      SessionStorage.save_session("beta-work", [%{"r" => "u"}],
        base_dir: dir,
        total_tokens: 500,
        auto_saved: true,
        timestamp: "2026-03-01T00:00:00Z"
      )

      SessionStorage.save_session("gamma-review", [%{"r" => "u"}],
        base_dir: dir,
        total_tokens: 9000,
        auto_saved: false,
        timestamp: "2026-06-01T00:00:00Z"
      )

      {:ok, base_dir: dir}
    end

    test "filters by name pattern (string)", %{base_dir: dir} do
      assert {:ok, results} =
               SessionStorage.search_sessions(name_pattern: "review", base_dir: dir)

      names = Enum.map(results, & &1.session_name)
      assert "alpha-review" in names
      assert "gamma-review" in names
      refute "beta-work" in names
    end

    test "filters by name pattern (regex)", %{base_dir: dir} do
      assert {:ok, results} =
               SessionStorage.search_sessions(name_pattern: ~r/^beta/, base_dir: dir)

      assert [%{session_name: "beta-work"}] = results
    end

    test "filters by auto_saved", %{base_dir: dir} do
      assert {:ok, results} = SessionStorage.search_sessions(auto_saved: true, base_dir: dir)
      assert [%{session_name: "beta-work"}] = results
    end

    test "filters by min_tokens", %{base_dir: dir} do
      assert {:ok, results} = SessionStorage.search_sessions(min_tokens: 200, base_dir: dir)
      names = Enum.map(results, & &1.session_name)
      assert "beta-work" in names
      assert "gamma-review" in names
      refute "alpha-review" in names
    end

    test "filters by max_tokens", %{base_dir: dir} do
      assert {:ok, results} = SessionStorage.search_sessions(max_tokens: 600, base_dir: dir)
      names = Enum.map(results, & &1.session_name)
      assert "alpha-review" in names
      assert "beta-work" in names
      refute "gamma-review" in names
    end

    test "filters by time range", %{base_dir: dir} do
      assert {:ok, results} =
               SessionStorage.search_sessions(
                 since: "2026-02-01T00:00:00Z",
                 until: "2026-05-01T00:00:00Z",
                 base_dir: dir
               )

      names = Enum.map(results, & &1.session_name)
      assert "beta-work" in names
      refute "alpha-review" in names
      refute "gamma-review" in names
    end

    test "combines multiple filters", %{base_dir: dir} do
      assert {:ok, results} =
               SessionStorage.search_sessions(
                 name_pattern: "review",
                 max_tokens: 500,
                 base_dir: dir
               )

      assert [%{session_name: "alpha-review"}] = results
    end

    test "respects limit", %{base_dir: dir} do
      assert {:ok, results} = SessionStorage.search_sessions(limit: 1, base_dir: dir)
      assert length(results) == 1
    end

    test "returns all sessions with no filters", %{base_dir: dir} do
      assert {:ok, results} = SessionStorage.search_sessions(base_dir: dir)
      assert length(results) == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup
  # ---------------------------------------------------------------------------

  describe "cleanup_sessions/2" do
    test "deletes oldest sessions beyond max", %{base_dir: dir} do
      # Create sessions with different timestamps
      SessionStorage.save_session("oldest", [], base_dir: dir, timestamp: "2026-01-01T00:00:00Z")
      SessionStorage.save_session("middle", [], base_dir: dir, timestamp: "2026-03-01T00:00:00Z")
      SessionStorage.save_session("newest", [], base_dir: dir, timestamp: "2026-06-01T00:00:00Z")

      assert {:ok, deleted} = SessionStorage.cleanup_sessions(2, base_dir: dir)
      assert "oldest" in deleted
      assert SessionStorage.session_exists?("newest", base_dir: dir)
      assert SessionStorage.session_exists?("middle", base_dir: dir)
      refute SessionStorage.session_exists?("oldest", base_dir: dir)
    end

    test "returns empty list when under max", %{base_dir: dir} do
      SessionStorage.save_session("only-one", [], base_dir: dir)
      assert {:ok, []} = SessionStorage.cleanup_sessions(10, base_dir: dir)
    end

    test "returns empty list for max 0", %{base_dir: dir} do
      assert {:ok, []} = SessionStorage.cleanup_sessions(0, base_dir: dir)
    end
  end

  # ---------------------------------------------------------------------------
  # Export
  # ---------------------------------------------------------------------------

  describe "export_session/2" do
    test "exports session as JSON string", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "export me"}]

      {:ok, _} =
        SessionStorage.save_session("export-test", messages,
          base_dir: dir,
          total_tokens: 42
        )

      assert {:ok, json} = SessionStorage.export_session("export-test", base_dir: dir)
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["format"] == "code-puppy-ex-v1"
      assert decoded["payload"]["messages"] == messages
      assert decoded["metadata"]["total_tokens"] == 42
    end

    test "exports session to file", %{base_dir: dir} do
      messages = [%{"role" => "user", "content" => "file export"}]
      output = Path.join([dir, "exports", "session.json"])

      {:ok, _} = SessionStorage.save_session("file-export", messages, base_dir: dir)

      assert {:ok, ^output} =
               SessionStorage.export_session("file-export",
                 base_dir: dir,
                 output_path: output
               )

      assert File.exists?(output)
      decoded = Jason.decode!(File.read!(output))
      assert decoded["format"] == "code-puppy-ex-v1"
    end

    test "returns :not_found for missing session", %{base_dir: dir} do
      assert {:error, :not_found} =
               SessionStorage.export_session("nonexistent", base_dir: dir)
    end
  end

  describe "export_all_sessions/1" do
    test "exports all sessions as JSON array", %{base_dir: dir} do
      SessionStorage.save_session("ex-a", [%{"r" => "u"}], base_dir: dir)
      SessionStorage.save_session("ex-b", [%{"r" => "u"}], base_dir: dir)

      assert {:ok, json} = SessionStorage.export_all_sessions(base_dir: dir)
      decoded = Jason.decode!(json)
      assert is_list(decoded)
      assert length(decoded) == 2
    end

    test "exports to file", %{base_dir: dir} do
      SessionStorage.save_session("ex-file", [%{"r" => "u"}], base_dir: dir)
      output = Path.join(dir, "all_exports.json")

      assert {:ok, ^output} =
               SessionStorage.export_all_sessions(base_dir: dir, output_path: output)

      assert File.exists?(output)
    end
  end

  # ---------------------------------------------------------------------------
  # Utility
  # ---------------------------------------------------------------------------

  describe "session_exists?/2" do
    test "returns true for existing session", %{base_dir: dir} do
      SessionStorage.save_session("exists-check", [], base_dir: dir)
      assert SessionStorage.session_exists?("exists-check", base_dir: dir)
    end

    test "returns false for missing session", %{base_dir: dir} do
      refute SessionStorage.session_exists?("no-such-session", base_dir: dir)
    end
  end

  describe "count_sessions/1" do
    test "returns correct count", %{base_dir: dir} do
      assert SessionStorage.count_sessions(base_dir: dir) == 0

      SessionStorage.save_session("count-1", [], base_dir: dir)
      assert SessionStorage.count_sessions(base_dir: dir) == 1

      SessionStorage.save_session("count-2", [], base_dir: dir)
      assert SessionStorage.count_sessions(base_dir: dir) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # Lazy base_dir default regression (code_puppy-dku)
  # ---------------------------------------------------------------------------

  describe "lazy base_dir default — explicit :base_dir skips base_dir/0" do
    # (code_puppy-dku) Regression tests for the eager-default bug:
    # Keyword.get(opts, :base_dir, base_dir()) evaluates base_dir()/0
    # even when :base_dir is present, causing synchronous raises when
    # env is invalid.  With the fix (resolve_base_dir/1 using
    # Keyword.fetch/2), explicit :base_dir never calls base_dir()/0.

    test "save_session/3 with explicit base_dir skips base_dir/0" do
      # Set an invalid PUP_SESSION_DIR so base_dir()/0 would raise.
      # With the lazy fix, passing base_dir: explicitly should NOT
      # call base_dir()/0 at all.
      tmp =
        Path.join(
          System.tmp_dir!(),
          "lazy_default_save_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      original = System.get_env("PUP_SESSION_DIR")
      # Point to a path that would fail validate_storage_dir! if called
      System.put_env("PUP_SESSION_DIR", "/etc/forbidden_sessions")

      on_exit(fn ->
        if original,
          do: System.put_env("PUP_SESSION_DIR", original),
          else: System.delete_env("PUP_SESSION_DIR")
      end)

      # Should NOT raise — base_dir()/0 is never called
      messages = [%{"role" => "user", "content" => "lazy default test"}]
      assert {:ok, _} = SessionStorage.save_session("lazy-test", messages, base_dir: tmp)
    end

    test "load_session/2 with explicit base_dir skips base_dir/0" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "lazy_default_load_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      original = System.get_env("PUP_SESSION_DIR")
      System.put_env("PUP_SESSION_DIR", "/etc/forbidden_sessions")

      on_exit(fn ->
        if original,
          do: System.put_env("PUP_SESSION_DIR", original),
          else: System.delete_env("PUP_SESSION_DIR")
      end)

      # Should NOT raise — base_dir()/0 is never called
      assert {:error, :not_found} = SessionStorage.load_session("nope", base_dir: tmp)
    end

    test "delete_session/2 with explicit base_dir skips base_dir/0" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "lazy_default_delete_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      original = System.get_env("PUP_SESSION_DIR")
      System.put_env("PUP_SESSION_DIR", "/etc/forbidden_sessions")

      on_exit(fn ->
        if original,
          do: System.put_env("PUP_SESSION_DIR", original),
          else: System.delete_env("PUP_SESSION_DIR")
      end)

      assert :ok = SessionStorage.delete_session("nope", base_dir: tmp)
    end

    test "session_exists?/2 with explicit base_dir skips base_dir/0" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "lazy_default_exists_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      original = System.get_env("PUP_SESSION_DIR")
      System.put_env("PUP_SESSION_DIR", "/etc/forbidden_sessions")

      on_exit(fn ->
        if original,
          do: System.put_env("PUP_SESSION_DIR", original),
          else: System.delete_env("PUP_SESSION_DIR")
      end)

      refute SessionStorage.session_exists?("nope", base_dir: tmp)
    end

    test "list_sessions/1 with explicit base_dir skips base_dir/0" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "lazy_default_list_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      original = System.get_env("PUP_SESSION_DIR")
      System.put_env("PUP_SESSION_DIR", "/etc/forbidden_sessions")

      on_exit(fn ->
        if original,
          do: System.put_env("PUP_SESSION_DIR", original),
          else: System.delete_env("PUP_SESSION_DIR")
      end)

      assert {:ok, []} = SessionStorage.list_sessions(base_dir: tmp)
    end
  end

  # ---------------------------------------------------------------------------
  # Isolation guard
  # ---------------------------------------------------------------------------

  describe "isolation guard" do
    test "base_dir/0 rejects paths outside ~/.code_puppy_ex/" do
      # Temporarily set env var to the forbidden Python path
      original = System.get_env("PUP_SESSION_DIR")
      System.put_env("PUP_SESSION_DIR", Path.expand("~/.code_puppy/sessions"))

      on_exit(fn ->
        if original do
          System.put_env("PUP_SESSION_DIR", original)
        else
          System.delete_env("PUP_SESSION_DIR")
        end
      end)

      assert_raise ArgumentError, ~r/outside ~\/\.code_puppy_ex\//, fn ->
        SessionStorage.base_dir()
      end
    end

    test "PUP_TEST_SESSION_ROOT is ignored without :allow_test_session_root" do
      # (code_puppy-dku) PUP_TEST_SESSION_ROOT must be gated to test-only
      # config.  When :allow_test_session_root is false (simulating prod),
      # setting PUP_TEST_SESSION_ROOT should NOT expand allowed roots.
      tmp =
        Path.join(System.tmp_dir!(), "pup_test_root_gate_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp)

      original_dir = System.get_env("PUP_SESSION_DIR")
      original_root = System.get_env("PUP_TEST_SESSION_ROOT")
      original_flag = Application.get_env(:code_puppy_control, :allow_test_session_root)

      # Simulate production: flag is false/unset
      Application.put_env(:code_puppy_control, :allow_test_session_root, false)
      System.put_env("PUP_SESSION_DIR", Path.join(tmp, "sessions"))
      System.put_env("PUP_TEST_SESSION_ROOT", tmp)

      on_exit(fn ->
        if original_dir,
          do: System.put_env("PUP_SESSION_DIR", original_dir),
          else: System.delete_env("PUP_SESSION_DIR")

        if original_root,
          do: System.put_env("PUP_TEST_SESSION_ROOT", original_root),
          else: System.delete_env("PUP_TEST_SESSION_ROOT")

        if original_flag != nil,
          do: Application.put_env(:code_puppy_control, :allow_test_session_root, original_flag),
          else: Application.delete_env(:code_puppy_control, :allow_test_session_root)

        File.rm_rf(tmp)
      end)

      # Should still reject — PUP_TEST_SESSION_ROOT is ignored when flag is false
      assert_raise ArgumentError, ~r/outside ~\/\.code_puppy_ex\//, fn ->
        SessionStorage.base_dir()
      end

      # Now enable the flag (simulating test env)
      Application.put_env(:code_puppy_control, :allow_test_session_root, true)

      # Now it should succeed — PUP_TEST_SESSION_ROOT is honoured
      assert SessionStorage.base_dir() == Path.expand(Path.join(tmp, "sessions"))
    end

    test "path-boundary check rejects sibling prefix escapes" do
      # (code_puppy-dku) /tmp/root2 must not match /tmp/root.
      # This tests the path_under_root? guard that replaced
      # String.starts_with?/2.
      tmp_a = Path.join(System.tmp_dir!(), "pup_root_a_#{System.unique_integer([:positive])}")

      tmp_b =
        Path.join(System.tmp_dir!(), "pup_root_a_sibling_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_a)
      File.mkdir_p!(tmp_b)

      original_dir = System.get_env("PUP_SESSION_DIR")
      original_root = System.get_env("PUP_TEST_SESSION_ROOT")
      original_flag = Application.get_env(:code_puppy_control, :allow_test_session_root)

      # Set test root to tmp_a
      Application.put_env(:code_puppy_control, :allow_test_session_root, true)
      System.put_env("PUP_TEST_SESSION_ROOT", tmp_a)

      # Point session dir under tmp_b (a different sibling)
      # Use a path that starts with tmp_a's string but is NOT a descendant
      sibling_session_dir = Path.join(tmp_b, "sessions")
      System.put_env("PUP_SESSION_DIR", sibling_session_dir)

      on_exit(fn ->
        if original_dir,
          do: System.put_env("PUP_SESSION_DIR", original_dir),
          else: System.delete_env("PUP_SESSION_DIR")

        if original_root,
          do: System.put_env("PUP_TEST_SESSION_ROOT", original_root),
          else: System.delete_env("PUP_TEST_SESSION_ROOT")

        if original_flag != nil,
          do: Application.put_env(:code_puppy_control, :allow_test_session_root, original_flag),
          else: Application.delete_env(:code_puppy_control, :allow_test_session_root)

        File.rm_rf(tmp_a)
        File.rm_rf(tmp_b)
      end)

      # Should reject — sibling path is NOT under the allowed root
      # even though its string representation may share a prefix
      assert_raise ArgumentError, ~r/outside ~\/\.code_puppy_ex\//, fn ->
        SessionStorage.base_dir()
      end
    end
  end
end
