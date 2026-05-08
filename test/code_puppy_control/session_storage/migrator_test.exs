defmodule CodePuppyControl.SessionStorage.MigratorTest do
  @moduledoc """
  Tests for CodePuppyControl.SessionStorage.Migrator.

  All tests use temp directories — never touches ~/.code_puppy/ or ~/.code_puppy_ex/.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.SessionStorage
  alias CodePuppyControl.SessionStorage.Migrator

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    uid = System.unique_integer([:positive])
    source_dir = Path.join(System.tmp_dir!(), "migrator_source_#{uid}")
    autosave_dir = Path.join(System.tmp_dir!(), "migrator_autosave_#{uid}")
    dest_dir = Path.join(System.tmp_dir!(), "migrator_dest_#{uid}")
    File.mkdir_p!(source_dir)
    File.mkdir_p!(autosave_dir)
    File.mkdir_p!(dest_dir)

    on_exit(fn ->
      File.rm_rf!(source_dir)
      File.rm_rf!(autosave_dir)
      File.rm_rf!(dest_dir)
    end)

    {:ok, source_dir: source_dir, autosave_dir: autosave_dir, dest_dir: dest_dir}
  end

  # ---------------------------------------------------------------------------
  # Helper: Create Python-format session files
  # ---------------------------------------------------------------------------

  defp create_py_subagent_session(dir, name, messages, metadata \\ %{}) do
    payload = %{
      "format" => "pydantic-ai-json-v2",
      "payload" => messages,
      "metadata" =>
        Map.merge(
          %{
            "session_id" => name,
            "agent_name" => "test-agent",
            "created_at" => "2026-01-15T10:00:00Z",
            "updated_at" => "2026-01-15T10:30:00Z",
            "message_count" => length(messages)
          },
          metadata
        )
    }

    File.write!(Path.join(dir, "#{name}.msgpack"), Jason.encode!(payload))
  end

  defp create_py_json_hmac_session(dir, name, messages, compacted_hashes \\ []) do
    payload = %{
      "messages" => messages,
      "compacted_hashes" => compacted_hashes
    }

    json_bytes = Jason.encode!(payload)
    magic = "JSONV\x01\x00\x00"
    fake_hmac = :binary.copy(<<0>>, 32)
    data = magic <> fake_hmac <> json_bytes

    File.write!(Path.join(dir, "#{name}.pkl"), data)
  end

  defp create_ex_session(dir, name, messages) do
    {:ok, _} = SessionStorage.save_session(name, messages, base_dir: dir)
  end

  defp migrate(src, dest, autosave, extra \\ []) do
    Migrator.migrate([source_dir: src, source_autosave_dir: autosave, dest_dir: dest] ++ extra)
  end

  # ---------------------------------------------------------------------------
  # Migration Tests
  # ---------------------------------------------------------------------------

  describe "migrate/1 — pydantic-ai-json-v2 format" do
    test "migrates Python subagent sessions", ctx do
      messages = [
        %{"kind" => "request", "parts" => [%{"content" => "Hello"}]},
        %{"kind" => "response", "parts" => [%{"content" => "Hi there"}]}
      ]

      create_py_subagent_session(ctx.source_dir, "-work", messages)

      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)

      assert "work" in result.migrated
      assert result.failed == []
      assert result.total_source == 1

      assert {:ok, loaded} = SessionStorage.load_session("-work", base_dir: ctx.dest_dir)
      assert length(loaded.messages) == 2
    end

    test "migrates multiple sessions", ctx do
      create_py_subagent_session(ctx.source_dir, "session-a", [%{"r" => "u"}])
      create_py_subagent_session(ctx.source_dir, "session-b", [%{"r" => "u"}, %{"r" => "a"}])

      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert length(result.migrated) == 2
      assert "session-a" in result.migrated
      assert "session-b" in result.migrated
    end
  end

  describe "migrate/1 — JSON+HMAC format" do
    test "migrates Python autosave sessions", ctx do
      messages = [%{"role" => "user", "content" => "autosave test"}]
      create_py_json_hmac_session(ctx.autosave_dir, "auto-save-1", messages, ["hash1"])

      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert "auto-save-1" in result.migrated

      assert {:ok, loaded} = SessionStorage.load_session("auto-save-1", base_dir: ctx.dest_dir)
      assert loaded.messages == messages
      assert loaded.compacted_hashes == ["hash1"]
    end
  end

  describe "migrate/1 — idempotency" do
    test "skips already-migrated sessions by default", ctx do
      create_py_subagent_session(ctx.source_dir, "existing", [%{"r" => "u"}])
      create_ex_session(ctx.dest_dir, "existing", [%{"r" => "old"}])

      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert result.migrated == []
      assert "existing" in result.skipped

      # The existing session should NOT be overwritten
      assert {:ok, loaded} = SessionStorage.load_session("existing", base_dir: ctx.dest_dir)
      assert [%{"r" => "old"}] = loaded.messages
    end

    test "overwrites existing sessions when overwrite: true", ctx do
      create_py_subagent_session(ctx.source_dir, "overwrite-me", [%{"r" => "new"}])
      create_ex_session(ctx.dest_dir, "overwrite-me", [%{"r" => "old"}])

      assert {:ok, result} =
               migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir, overwrite: true)

      assert "overwrite-me" in result.migrated

      assert {:ok, loaded} =
               SessionStorage.load_session("overwrite-me", base_dir: ctx.dest_dir)

      assert [%{"r" => "new"}] = loaded.messages
    end

    test "is safe to run multiple times", ctx do
      create_py_subagent_session(ctx.source_dir, "idempotent", [%{"r" => "u"}])

      assert {:ok, r1} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert "idempotent" in r1.migrated

      assert {:ok, r2} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert "idempotent" in r2.skipped
      assert r2.migrated == []
    end
  end

  describe "migrate/1 — dry run" do
    test "does not write files in dry_run mode", ctx do
      create_py_subagent_session(ctx.source_dir, "dry-run-test", [%{"r" => "u"}])

      assert {:ok, result} =
               migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir, dry_run: true)

      assert "dry-run-test" in result.migrated
      refute SessionStorage.session_exists?("dry-run-test", base_dir: ctx.dest_dir)
    end
  end

  describe "migrate/1 — error handling" do
    test "reports failed sessions without crashing", ctx do
      File.write!(Path.join(ctx.source_dir, "broken.msgpack"), "this is not valid json {{{")

      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert length(result.failed) == 1
      {name, _reason} = hd(result.failed)
      assert name == "broken"
    end

    test "handles mixed success and failure", ctx do
      create_py_subagent_session(ctx.source_dir, "good-session", [%{"r" => "u"}])
      File.write!(Path.join(ctx.source_dir, "bad-session.msgpack"), "not json!!!")

      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert "good-session" in result.migrated
      assert length(result.failed) == 1
    end
  end

  describe "migrate/1 — empty directories" do
    test "handles empty source directory", ctx do
      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert result.migrated == []
      assert result.total_source == 0
    end

    test "handles non-existent source directory", ctx do
      fake_path = "/tmp/nonexistent_#{System.unique_integer([:positive])}"

      assert {:ok, result} =
               Migrator.migrate(
                 source_dir: fake_path,
                 source_autosave_dir: ctx.autosave_dir,
                 dest_dir: ctx.dest_dir
               )

      assert result.migrated == []
      assert result.total_source == 0
    end
  end

  describe "migrate/1 — multiple source directories" do
    test "migrates from both subagent and autosave directories", ctx do
      create_py_subagent_session(ctx.source_dir, "sub-session", [%{"r" => "u"}])
      create_py_json_hmac_session(ctx.autosave_dir, "auto-session", [%{"r" => "u"}])

      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert "sub-session" in result.migrated
      assert "auto-session" in result.migrated
      assert result.total_source == 2
    end
  end

  describe "migrate/1 — already Elixir format" do
    test "handles files already in Elixir format", ctx do
      create_ex_session(ctx.source_dir, "elixir-native", [%{"r" => "u"}])

      assert {:ok, result} = migrate(ctx.source_dir, ctx.dest_dir, ctx.autosave_dir)
      assert "elixir-native" in result.migrated
    end
  end
end
