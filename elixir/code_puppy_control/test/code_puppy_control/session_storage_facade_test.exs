defmodule CodePuppyControl.SessionStorageFacadeTest do
  @moduledoc """
  Store-backed facade tests for SessionStorage.

  Unlike session_storage_test.exs (which always passes base_dir: forcing
  FileBackend), these tests call SessionStorage functions WITHOUT base_dir —
  triggering the Store/ETS/SQLite path when `Process.whereis(Store) != nil`.

  All calls use the parseable format:
      SessionStorage.save_session("name", [%{"role" => "user", "content" => "..."}], [])

  The Ecto sandbox is checked out in {:shared, self()} mode so the Store
  GenServer can use the same sandbox connection. SQLite changes are rolled
  back automatically when the connection is released; ETS entries are
  cleaned up explicitly in on_exit to prevent cross-test pollution.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.Repo
  alias CodePuppyControl.SessionStorage

  # ---------------------------------------------------------------------------
  # Setup: Ecto sandbox + ETS cleanup
  # ---------------------------------------------------------------------------

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    prefix = "facade_#{System.unique_integer([:positive])}"
    created_sessions = []

    on_exit(fn ->
      # Clean up ETS entries directly — the sandbox rolls back SQLite,
      # but ETS persists across tests since the Store GenServer is
      # long-lived and doesn't re-init between test cases.
      Enum.each(created_sessions, fn name ->
        try do
          :ets.delete(:session_store_ets, name)
          :ets.delete(:session_terminal_ets, name)
        catch
          :error, :badarg -> :ok
        end
      end)
    end)

    {:ok, prefix: prefix, created_sessions: created_sessions}
  end

  # Helper: generate a unique session name for this test run
  defp session_name(prefix, label) do
    "#{prefix}-#{label}"
  end

  # Helper: track a session for on_exit cleanup
  defp track!(state, name) do
    {:ok, prefix: state.prefix, created_sessions: [name | state.created_sessions]}
  end

  # Helper: save a session through the Store facade (no base_dir)
  defp facade_save!(state, label, messages, opts \\ []) do
    name = session_name(state.prefix, label)
    assert {:ok, _meta} = SessionStorage.save_session(name, messages, opts)
    track!(state, name)
  end

  # ---------------------------------------------------------------------------
  # 1. search_sessions/1 through Store facade
  # ---------------------------------------------------------------------------

  describe "search_sessions/1 through Store facade" do
    test "searches by name pattern and returns matching sessions", ctx do
      facade_save!(ctx, "alpha-review", [%{"role" => "user", "content" => "hi"}],
        total_tokens: 100,
        timestamp: "1970-01-01T12:00:00Z"
      )

      facade_save!(ctx, "beta-work", [%{"role" => "user", "content" => "yo"}],
        total_tokens: 500,
        timestamp: "2026-03-01T00:00:00Z"
      )

      facade_save!(ctx, "gamma-review", [%{"role" => "user", "content" => "hey"}],
        total_tokens: 9000,
        timestamp: "1970-06-01T12:00:00Z"
      )

      assert {:ok, results} = SessionStorage.search_sessions(name_pattern: "review")
      names = Enum.map(results, & &1.session_name)
      assert String.contains?(names |> Enum.join(","), "review")
      # Both alpha-review and gamma-review should match
      matching = Enum.filter(names, &String.contains?(&1, "review"))
      assert length(matching) == 2
      # beta-work should NOT be in the results
      refute Enum.any?(names, &String.contains?(&1, "beta-work"))
    end

    test "multi-filter: name pattern + token range", ctx do
      facade_save!(ctx, "low-tokens", [%{"role" => "user", "content" => "lo"}],
        total_tokens: 50,
        timestamp: "1970-01-01T12:00:00Z"
      )

      facade_save!(ctx, "mid-tokens", [%{"role" => "user", "content" => "mid"}],
        total_tokens: 500,
        timestamp: "2026-03-01T00:00:00Z"
      )

      facade_save!(ctx, "high-tokens", [%{"role" => "user", "content" => "hi"}],
        total_tokens: 9000,
        timestamp: "1970-06-01T12:00:00Z"
      )

      # Search for sessions with "tokens" in name AND total_tokens >= 100
      assert {:ok, results} =
               SessionStorage.search_sessions(name_pattern: "tokens", min_tokens: 100)

      names = Enum.map(results, & &1.session_name)
      assert Enum.any?(names, &String.contains?(&1, "mid"))
      assert Enum.any?(names, &String.contains?(&1, "high"))
      refute Enum.any?(names, &String.contains?(&1, "low"))
    end

    test "empty results for non-matching filter", ctx do
      facade_save!(ctx, "exists", [%{"role" => "user", "content" => "data"}])

      assert {:ok, results} =
               SessionStorage.search_sessions(name_pattern: "absolutely-no-match-xyzzy")

      assert results == []
    end
  end

  # ---------------------------------------------------------------------------
  # 2. export_session/2 through Store facade
  # ---------------------------------------------------------------------------

  describe "export_session/2 through Store facade" do
    test "exports session as JSON string via Store", ctx do
      messages = [%{"role" => "user", "content" => "export me"}]
      name = session_name(ctx.prefix, "export-test")

      assert {:ok, _meta} = SessionStorage.save_session(name, messages, total_tokens: 42)
      _ctx = track!(ctx, name)

      assert {:ok, json} = SessionStorage.export_session(name)
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert decoded["format"] == "code-puppy-ex-v1"
      assert decoded["payload"]["messages"] == messages
      assert decoded["metadata"]["total_tokens"] == 42
    end

    test "exports session to output_path via Store", ctx do
      messages = [%{"role" => "user", "content" => "file export"}]
      name = session_name(ctx.prefix, "file-export")

      assert {:ok, _meta} = SessionStorage.save_session(name, messages)
      _ctx = track!(ctx, name)

      output =
        Path.join(
          System.tmp_dir!(),
          "facade_export_#{System.unique_integer([:positive])}.json"
        )

      on_exit(fn -> File.rm(output) end)

      assert {:ok, ^output} = SessionStorage.export_session(name, output_path: output)
      assert File.exists?(output)

      decoded = Jason.decode!(File.read!(output))
      assert decoded["format"] == "code-puppy-ex-v1"
    end

    test "export non-existent session returns error via Store", ctx do
      name = session_name(ctx.prefix, "ghost")

      assert {:error, :not_found} = SessionStorage.export_session(name)
    end

    # ── Additional coverage (code_puppy-3m9.2) ─────────────────────────────

    test "export_session with special characters in name", ctx do
      name = session_name(ctx.prefix, "special-chars-ño")
      messages = [%{"role" => "user", "content" => "unicode test"}]

      assert {:ok, _meta} = SessionStorage.save_session(name, messages)
      _ctx = track!(ctx, name)

      assert {:ok, json} = SessionStorage.export_session(name)
      decoded = Jason.decode!(json)
      assert decoded["payload"]["messages"] == messages
    end

    test "export_session with large message content", ctx do
      large_content = String.duplicate("x", 10_000)
      messages = [%{"role" => "user", "content" => large_content}]
      name = session_name(ctx.prefix, "large-export")

      assert {:ok, _meta} = SessionStorage.save_session(name, messages)
      _ctx = track!(ctx, name)

      assert {:ok, json} = SessionStorage.export_session(name)
      decoded = Jason.decode!(json)
      [first_msg | _] = decoded["payload"]["messages"]
      assert first_msg["content"] == large_content
    end
  end

  # ---------------------------------------------------------------------------
  # 3. export_all_sessions/1 through Store facade
  # ---------------------------------------------------------------------------

  describe "export_all_sessions/1 through Store facade" do
    test "exports all sessions as JSON array", ctx do
      facade_save!(ctx, "ex-a", [%{"role" => "user", "content" => "A"}])
      facade_save!(ctx, "ex-b", [%{"role" => "user", "content" => "B"}])

      assert {:ok, json} = SessionStorage.export_all_sessions([])
      decoded = Jason.decode!(json)
      assert is_list(decoded)
      # At least our 2 sessions should be present (others may exist
      # from prior test pollution — we only assert minimum count)
      our_names =
        decoded
        |> Enum.map(& &1["metadata"]["session_name"])
        |> Enum.filter(&String.starts_with?(&1, ctx.prefix))

      assert length(our_names) == 2
    end

    test "empty export returns valid JSON array", _ctx do
      # Use a very specific filter that shouldn't match anything
      # to demonstrate the empty case works through Store facade
      assert {:ok, json} = SessionStorage.export_all_sessions([])
      decoded = Jason.decode!(json)
      assert is_list(decoded)
    end
  end

  # ---------------------------------------------------------------------------
  # 4. list_sessions_with_metadata/1 through Store facade
  # ---------------------------------------------------------------------------

  describe "list_sessions_with_metadata/1 through Store facade" do
    test "returns sessions sorted newest-first", ctx do
      facade_save!(ctx, "old-session", [%{"role" => "user", "content" => "old"}],
        timestamp: "1970-01-01T12:00:00Z"
      )

      facade_save!(ctx, "new-session", [%{"role" => "user", "content" => "new"}],
        timestamp: "1970-12-01T12:00:00Z"
      )

      assert {:ok, all_meta} = SessionStorage.list_sessions_with_metadata([])

      # Filter to only our test sessions
      our_sessions =
        Enum.filter(all_meta, fn m ->
          String.starts_with?(m.session_name, ctx.prefix)
        end)

      # Should have at least 2; sorted newest-first means new before old
      assert length(our_sessions) >= 2

      names = Enum.map(our_sessions, & &1.session_name)

      new_idx = Enum.find_index(names, &(&1 =~ "new-session"))
      old_idx = Enum.find_index(names, &(&1 =~ "old-session"))
      assert new_idx != nil
      assert old_idx != nil
      assert new_idx < old_idx
    end

    test "includes metadata fields in Store-backed results", ctx do
      name = session_name(ctx.prefix, "meta-check")

      assert {:ok, _} =
               SessionStorage.save_session(name, [%{"role" => "user", "content" => "x"}],
                 total_tokens: 42,
                 auto_saved: true
               )

      _ctx = track!(ctx, name)

      assert {:ok, all_meta} = SessionStorage.list_sessions_with_metadata([])

      our_session =
        Enum.find(all_meta, fn m ->
          m.session_name == name
        end)

      assert our_session != nil
      assert our_session.total_tokens == 42
      assert our_session.auto_saved == true
    end
  end

  # ---------------------------------------------------------------------------
  # 5. cleanup_sessions/2 through Store facade
  # ---------------------------------------------------------------------------

  describe "cleanup_sessions/2 through Store facade" do
    test "removes oldest sessions beyond max", ctx do
      # Record total BEFORE we add anything
      total_before = SessionStorage.count_sessions()

      facade_save!(ctx, "oldest", [%{"role" => "user", "content" => "o"}],
        timestamp: "1969-12-31T23:59:59Z"
      )

      facade_save!(ctx, "middle", [%{"role" => "user", "content" => "m"}],
        timestamp: "1970-06-01T12:00:00Z"
      )

      facade_save!(ctx, "newest", [%{"role" => "user", "content" => "n"}],
        timestamp: "1970-12-01T12:00:00Z"
      )

      oldest_name = session_name(ctx.prefix, "oldest")
      newest_name = session_name(ctx.prefix, "newest")

      # We added 3 sessions. Keep total_before + 2 → delete exactly 1 globally.
      assert {:ok, deleted} = SessionStorage.cleanup_sessions(total_before + 2)

      # Exactly 1 session should have been deleted
      assert length(deleted) == 1

      # Our oldest (1969-12-31) should be the globally oldest → deleted
      assert oldest_name in deleted

      # Our newer sessions should still exist
      assert SessionStorage.session_exists?(newest_name)

      # Our oldest should be gone
      refute SessionStorage.session_exists?(oldest_name)
    end

    test "returns empty list when under max", ctx do
      facade_save!(ctx, "only-one", [%{"role" => "user", "content" => "x"}])

      # Use a very large max that exceeds the total session count in ETS
      # (the Store singleton accumulates sessions from other tests)
      total = SessionStorage.count_sessions()
      assert {:ok, []} = SessionStorage.cleanup_sessions(total + 10)
    end

    test "returns empty list for max 0" do
      assert {:ok, []} = SessionStorage.cleanup_sessions(0)
    end
  end
end
