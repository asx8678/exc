defmodule CodePuppyControl.TUI.Widgets.SessionBrowser do
  @moduledoc """
  Browse and select chat sessions.

  Lists sessions from `CodePuppyControl.Sessions` with metadata (message count,
  tokens, timestamps) and supports interactive selection, deletion, and preview.

  ## Usage

      # Interactive browse — user picks a session
      SessionBrowser.browse()

      # Just list sessions without prompting
      SessionBrowser.list_sessions()

      # Format a single session for display
      SessionBrowser.format_session(session_map)

  ## Architecture

  - `list_sessions/0` — wraps `Sessions.list_sessions_with_metadata/0`
  - `browse/1` — renders a table + action prompt, dispatches to
    select/delete/preview based on user input
  - `format_session/1` — pure function turning a session map into
    `Owl.Data.t()` fragments
  """

  alias CodePuppyControl.Sessions

  # ── Types ──────────────────────────────────────────────────────────────────

  @type session_map :: %{
          id: integer(),
          name: String.t(),
          message_count: non_neg_integer(),
          total_tokens: non_neg_integer(),
          auto_saved: boolean(),
          timestamp: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @type browse_result ::
          {:ok, String.t()}
          | {:delete, String.t()}
          | {:preview, String.t()}
          | :cancelled

  @type browse_opt ::
          {:action, :select | :delete | :preview}
          | {:filter, String.t()}

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Interactively browse sessions and choose an action.

  Returns:
    * `{:ok, name}`      — user selected a session
    * `{:delete, name}`  — user wants to delete a session
    * `{:preview, name}` — user wants to preview a session
    * `:cancelled`       — user aborted

  ## Options

    * `:action` — default action mode (default: `:select`)
    * `:filter` — substring filter on session name
  """
  @spec browse([browse_opt()]) :: browse_result()
  def browse(opts \\ []) do
    filter = Keyword.get(opts, :filter)

    case list_sessions(filter: filter) do
      {:ok, []} ->
        Owl.IO.puts(Owl.Data.tag("\n  No sessions found.\n", :yellow))
        :cancelled

      {:ok, sessions} ->
        render_session_table(sessions)
        prompt_action(sessions)
    end
  end

  @doc """
  List sessions with metadata, newest first.

  Returns `{:ok, [session_map]}` or `{:error, reason}`. Optionally filters
  by session name substring.

  ## Options

    * `:filter` — case-insensitive substring filter on session name
  """
  @spec list_sessions([{:filter, String.t()}]) :: {:ok, [session_map()]} | {:error, term()}
  def list_sessions(opts \\ []) do
    filter = Keyword.get(opts, :filter)

    case Sessions.list_sessions_with_metadata() do
      {:ok, sessions} ->
        filtered = maybe_filter_sessions(sessions, filter)
        {:ok, filtered}

      error ->
        error
    end
  end

  @doc """
  Format a session map into a human-readable Owl.Data fragment.

  Pure function — no I/O side effects. Useful for embedding session
  info into other screens.
  """
  @spec format_session(session_map()) :: Owl.Data.t()
  def format_session(session) do
    name = Owl.Data.tag(session.name, [:bright, :cyan])
    msgs = Owl.Data.tag(" #{session.message_count} msgs", :faint)
    tokens = format_tokens(session.total_tokens)
    saved = if session.auto_saved, do: Owl.Data.tag(" auto", :yellow), else: ""
    time = format_timestamp(session.timestamp || session.inserted_at)

    [name, msgs, tokens, saved, time]
  end

  # ── Private: Table Rendering ─────────────────────────────────────────────

  defp render_session_table(sessions) do
    header = render_header()

    rows =
      sessions
      |> Enum.with_index(1)
      |> Enum.map(&render_session_row/1)

    table = build_table(rows)

    Owl.IO.puts([header, "\n", table, "\n"])
  end

  defp render_header do
    Owl.Box.new(
      Owl.Data.tag(" 💬 Session Browser ", [:bright, :magenta]),
      min_width: 60,
      border: :bottom,
      border_color: :magenta
    )
  end

  @session_column_order %{
    "Session" => 0,
    "Messages" => 1,
    "Tokens" => 2,
    "Time" => 3,
    "Status" => 4
  }

  defp render_session_row({session, idx}) do
    name =
      if session.auto_saved do
        Owl.Data.tag(" #{idx}. #{session.name}", [:bright, :cyan])
      else
        Owl.Data.tag(" #{idx}. #{session.name}", :cyan)
      end

    msgs = Owl.Data.tag(" #{session.message_count} msgs", :faint)
    tokens = format_tokens(session.total_tokens)
    time = format_timestamp(session.timestamp || session.inserted_at)

    auto_badge =
      if session.auto_saved,
        do: Owl.Data.tag(" auto ", [:black, :yellow_background]),
        else: Owl.Data.tag("", :default)

    %{
      "Session" => name,
      "Messages" => msgs,
      "Tokens" => tokens,
      "Time" => time,
      "Status" => auto_badge
    }
  end

  defp format_tokens(0), do: Owl.Data.tag("0 tok", :faint)

  defp format_tokens(n) when n >= 1_000_000,
    do: Owl.Data.tag("#{Float.round(n / 1_000_000, 1)}M tok", :faint)

  defp format_tokens(n) when n >= 1_000,
    do: Owl.Data.tag("#{Float.round(n / 1_000, 1)}k tok", :faint)

  defp format_tokens(n),
    do: Owl.Data.tag("#{n} tok", :faint)

  defp format_timestamp(nil), do: ""

  defp format_timestamp(%DateTime{} = dt) do
    Owl.Data.tag(" " <> Calendar.strftime(dt, "%Y-%m-%d %H:%M"), :faint)
  end

  defp format_timestamp(bin) when is_binary(bin) do
    case DateTime.from_iso8601(bin) do
      {:ok, dt, _} -> format_timestamp(dt)
      _ -> Owl.Data.tag(" #{bin}", :faint)
    end
  end

  defp format_timestamp(other), do: Owl.Data.tag(" #{inspect(other)}", :faint)

  defp build_table(rows) do
    Owl.Table.new(
      rows,
      border_style: :solid,
      padding_x: 1,
      sort_columns: fn a, b ->
        Map.get(@session_column_order, a, 99) < Map.get(@session_column_order, b, 99)
      end
    )
  end

  # ── Private: Action Prompt ────────────────────────────────────────────────

  defp prompt_action(sessions) do
    Owl.IO.puts([
      Owl.Data.tag("\n  Actions: ", [:bright, :yellow]),
      Owl.Data.tag("number", :cyan),
      Owl.Data.tag(" = select  ", :faint),
      Owl.Data.tag("d NUM", :cyan),
      Owl.Data.tag(" = delete  ", :faint),
      Owl.Data.tag("p NUM", :cyan),
      Owl.Data.tag(" = preview  ", :faint),
      Owl.Data.tag("Enter", :cyan),
      Owl.Data.tag(" = cancel", :faint)
    ])

    case IO.gets("  > ") do
      :eof ->
        :cancelled

      {:error, _} ->
        :cancelled

      input ->
        parse_action(String.trim(input), sessions)
    end
  end

  defp parse_action("", _sessions), do: :cancelled

  defp parse_action("d " <> rest, sessions) do
    case resolve_session(String.trim(rest), sessions) do
      nil -> :cancelled
      session -> {:delete, session.name}
    end
  end

  defp parse_action("delete " <> rest, sessions) do
    case resolve_session(String.trim(rest), sessions) do
      nil -> :cancelled
      session -> {:delete, session.name}
    end
  end

  defp parse_action("p " <> rest, sessions) do
    case resolve_session(String.trim(rest), sessions) do
      nil -> :cancelled
      session -> {:preview, session.name}
    end
  end

  defp parse_action("preview " <> rest, sessions) do
    case resolve_session(String.trim(rest), sessions) do
      nil -> :cancelled
      session -> {:preview, session.name}
    end
  end

  defp parse_action(input, sessions) do
    case resolve_session(input, sessions) do
      nil -> :cancelled
      session -> {:ok, session.name}
    end
  end

  defp resolve_session(input, sessions) do
    cond do
      # Exact name match
      exact = Enum.find(sessions, &(&1.name == input)) ->
        exact

      # Numeric index
      match?({_, ""}, Integer.parse(input)) ->
        {num, ""} = Integer.parse(input)

        if num >= 1 and num <= length(sessions) do
          Enum.at(sessions, num - 1)
        else
          nil
        end

      # Fuzzy name match
      fuzzy = Enum.find(sessions, &String.contains?(&1.name, input)) ->
        fuzzy

      true ->
        nil
    end
  end

  # ── Private: Filtering ────────────────────────────────────────────────────

  defp maybe_filter_sessions(sessions, nil), do: sessions

  defp maybe_filter_sessions(sessions, filter) do
    downcased = String.downcase(filter)

    Enum.filter(sessions, fn session ->
      String.downcase(session.name) =~ downcased
    end)
  end
end
