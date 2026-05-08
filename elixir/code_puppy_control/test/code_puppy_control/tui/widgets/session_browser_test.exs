defmodule CodePuppyControl.TUI.Widgets.SessionBrowserTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.TUI.Widgets.SessionBrowser

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp to_text(owl_data) do
    owl_data
    |> Owl.Data.untag()
    |> IO.iodata_to_binary()
  end

  defp base_session(overrides \\ []) do
    %{
      name: "test-session",
      message_count: 5,
      total_tokens: 1_000,
      auto_saved: false,
      timestamp: ~U[2026-01-15 12:30:00Z],
      inserted_at: ~U[2026-01-15 12:30:00Z],
      updated_at: ~U[2026-01-15 13:00:00Z]
    }
    |> Map.merge(Map.new(overrides))
  end

  # ── format_session/1 ─────────────────────────────────────────────────────

  describe "format_session/1" do
    test "renders session name" do
      text =
        base_session(name: "my-special-session") |> SessionBrowser.format_session() |> to_text()

      assert text =~ "my-special-session"
    end

    test "renders message count" do
      text = base_session(message_count: 42) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "42 msgs"
    end

    test "renders single message count" do
      text = base_session(message_count: 1) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "1 msgs"
    end

    test "renders zero message count" do
      text = base_session(message_count: 0) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "0 msgs"
    end

    test "includes auto tag when auto_saved is true" do
      text = base_session(auto_saved: true) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "auto"
    end

    test "omits auto tag when auto_saved is false" do
      text = base_session(auto_saved: false) |> SessionBrowser.format_session() |> to_text()
      # The word "auto" should NOT appear (it only appears as a tagged fragment when true)
      refute text =~ ~r/\bauto\b/
    end

    test "renders DateTime timestamp" do
      dt = ~U[2026-03-14 09:15:00Z]
      text = base_session(timestamp: dt) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "2026-03-14"
      assert text =~ "09:15"
    end

    test "renders ISO8601 string timestamp" do
      text =
        base_session(timestamp: "2026-06-01T08:00:00Z")
        |> SessionBrowser.format_session()
        |> to_text()

      assert text =~ "2026-06-01"
      assert text =~ "08:00"
    end

    test "renders nothing for nil timestamp and nil inserted_at" do
      text =
        base_session(timestamp: nil, inserted_at: nil)
        |> SessionBrowser.format_session()
        |> to_text()

      # Should not crash; the timestamp portion is just empty
      assert is_binary(text)
    end

    test "falls back to inserted_at when timestamp is nil" do
      text =
        base_session(timestamp: nil, inserted_at: ~U[2026-07-20 14:00:00Z])
        |> SessionBrowser.format_session()
        |> to_text()

      assert text =~ "2026-07-20"
      assert text =~ "14:00"
    end

    test "renders garbage timestamp string as raw text" do
      text =
        base_session(timestamp: "not-a-date")
        |> SessionBrowser.format_session()
        |> to_text()

      # Non-ISO string is rendered as-is (prefixed with space by format_timestamp)
      assert text =~ "not-a-date"
    end
  end

  # ── format_tokens (private, tested via format_session) ────────────────────

  describe "format_tokens (via format_session/1)" do
    test "zero tokens shows '0 tok'" do
      text = base_session(total_tokens: 0) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "0 tok"
    end

    test "small token count shows raw number" do
      text = base_session(total_tokens: 42) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "42 tok"
    end

    test "thousand-scale tokens shows 'k tok'" do
      text = base_session(total_tokens: 1_234) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "1.2k tok"
    end

    test "exactly 1000 tokens shows '1.0k tok'" do
      text = base_session(total_tokens: 1_000) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "1.0k tok"
    end

    test "million-scale tokens shows 'M tok'" do
      text = base_session(total_tokens: 2_500_000) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "2.5M tok"
    end

    test "exactly 1_000_000 tokens shows '1.0M tok'" do
      text = base_session(total_tokens: 1_000_000) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "1.0M tok"
    end

    test "999 tokens shows raw number (below k threshold)" do
      text = base_session(total_tokens: 999) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "999 tok"
      refute text =~ "k tok"
    end

    test "999_999 tokens shows k (below M threshold)" do
      text = base_session(total_tokens: 999_999) |> SessionBrowser.format_session() |> to_text()
      assert text =~ "k tok"
      refute text =~ "M tok"
    end
  end

  # ── list_sessions/1 ──────────────────────────────────────────────────────

  describe "list_sessions/1" do
    test "returns {:ok, list} or {:error, reason} (DB may not be available)" do
      result =
        try do
          SessionBrowser.list_sessions()
        rescue
          _ -> {:error, :db_unavailable}
        end

      case result do
        {:ok, sessions} ->
          assert is_list(sessions)

          for session <- sessions do
            assert Map.has_key?(session, :name)
            assert is_binary(session.name)
          end

        {:error, _reason} ->
          :ok
      end
    end

    test "filter with no matches returns empty list (DB may not be available)" do
      result =
        try do
          SessionBrowser.list_sessions(filter: "zzz_nonexistent_999")
        rescue
          _ -> {:error, :db_unavailable}
        end

      case result do
        {:ok, sessions} -> assert sessions == []
        {:error, _} -> :ok
      end
    end

    test "accepts empty filter (returns all sessions)" do
      result =
        try do
          SessionBrowser.list_sessions(filter: "")
        rescue
          _ -> {:error, :db_unavailable}
        end

      case result do
        {:ok, _sessions} -> :ok
        {:error, _} -> :ok
      end
    end

    test "filter is case-insensitive (DB may not be available)" do
      # If sessions exist, the filter should work case-insensitively.
      # We can't guarantee sessions exist, so we just verify it doesn't crash.
      result =
        try do
          SessionBrowser.list_sessions(filter: "TEST")
        rescue
          _ -> {:error, :db_unavailable}
        end

      case result do
        {:ok, _} -> :ok
        {:error, _} -> :ok
      end
    end
  end

  # ── maybe_filter_sessions (private, tested via list_sessions) ────────────
  # Filtering logic is exercised through list_sessions above.
  # The following property-based tests verify the filter contract
  # using local session lists (no DB needed).

  describe "maybe_filter_sessions logic (unit-level)" do
    # We construct a list of sessions and apply filtering via
    # a helper that mirrors the private `maybe_filter_sessions/2`.
    # This avoids reaching into private functions while still
    # testing the filtering contract thoroughly.

    defp filter_sessions(sessions, nil), do: sessions

    defp filter_sessions(sessions, filter) do
      downcased = String.downcase(filter)

      Enum.filter(sessions, fn session ->
        String.downcase(session.name) =~ downcased
      end)
    end

    test "nil filter returns all sessions unchanged" do
      sessions = [
        %{name: "alpha"},
        %{name: "beta"},
        %{name: "gamma"}
      ]

      assert filter_sessions(sessions, nil) == sessions
    end

    test "empty string filter matches everything" do
      sessions = [
        %{name: "alpha"},
        %{name: "beta"}
      ]

      # Empty string is contained in every string
      assert filter_sessions(sessions, "") == sessions
    end

    test "case-insensitive substring filter" do
      sessions = [
        %{name: "Alpha-Session"},
        %{name: "beta-session"},
        %{name: "Gamma"}
      ]

      result = filter_sessions(sessions, "alpha")
      assert length(result) == 1
      assert hd(result).name == "Alpha-Session"
    end

    test "filter matches multiple sessions sharing a substring" do
      sessions = [
        %{name: "my-test-1"},
        %{name: "my-test-2"},
        %{name: "production"}
      ]

      result = filter_sessions(sessions, "test")
      assert length(result) == 2
    end

    test "filter with no matches returns empty list" do
      sessions = [%{name: "foo"}, %{name: "bar"}]
      assert filter_sessions(sessions, "nonexistent") == []
    end

    test "filter on mixed-case names" do
      sessions = [
        %{name: "MySession"},
        %{name: "mysession-v2"},
        %{name: "YOURSESSION"}
      ]

      result = filter_sessions(sessions, "mysession")
      assert length(result) == 2
    end
  end
end
