defmodule CodePuppyControl.CLI.SlashCommands.Commands.AutosaveLoad do
  @moduledoc """
  Autosave load slash command: /autosave_load (alias: /resume).

  Loads the most recent autosaved session into the current REPL state.
  If multiple autosaves exist, displays a numbered list and loads the
  most recent one by default, or lets the user pick via a text prompt.

  Ports the Python /autosave_load command from
  code_puppy/command_line/session_commands.py.
  """

  alias CodePuppyControl.Agent.State, as: AgentState
  alias CodePuppyControl.REPL.Loop
  alias CodePuppyControl.RuntimeState
  alias CodePuppyControl.SessionStorage

  @doc """
  Handles `/autosave_load` — loads the most recent autosaved session.

  If no autosaves exist, prints a friendly message.
  If one autosave exists, loads it directly.
  If multiple autosaves exist, shows a numbered list and loads the most
  recent by default, or lets the user pick by number.

  ## Options (for testing)

    * `:base_dir` — override the session storage directory
  """
  @spec handle_autosave_load(String.t(), any(), keyword()) :: {:continue, any()}
  def handle_autosave_load(_line, state, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir)

    case fetch_autosaves(base_dir: base_dir) do
      {:ok, []} ->
        IO.puts("")
        IO.puts("    #{IO.ANSI.yellow()}⚠️  No autosaved sessions found.#{IO.ANSI.reset()}")

        IO.puts(
          "    #{IO.ANSI.faint()}Start a conversation and it will be auto-saved.#{IO.ANSI.reset()}"
        )

        IO.puts("")

        {:continue, state}

      {:ok, [autosave]} ->
        load_single_autosave(autosave, state, base_dir: base_dir)

      {:ok, autosaves} ->
        choose_and_load(autosaves, state, base_dir: base_dir)

      {:error, reason} ->
        IO.puts(
          IO.ANSI.red() <>
            "    Error listing sessions: #{inspect(reason)}" <>
            IO.ANSI.reset()
        )

        {:continue, state}
    end
  end

  # ── Private: fetch autosaved sessions ─────────────────────────────────

  @spec fetch_autosaves(keyword()) :: {:ok, [map()]} | {:error, term()}
  defp fetch_autosaves(opts) do
    list_opts = if opts[:base_dir], do: [base_dir: opts[:base_dir]], else: []

    case SessionStorage.list_sessions_with_metadata(list_opts) do
      {:ok, sessions} ->
        autosaves =
          sessions
          |> Enum.filter(&(&1.auto_saved == true))

        {:ok, autosaves}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private: load a single autosave ───────────────────────────────────

  defp load_single_autosave(autosave, state, opts) do
    session_name = autosave.session_name

    IO.puts("")
    IO.puts("    #{IO.ANSI.cyan()}📂 Loading autosave:#{IO.ANSI.reset()} #{session_name}")

    case do_load_session(session_name, state, opts) do
      {:ok, new_state} ->
        print_load_success(autosave)
        {:continue, new_state}

      {:error, reason} ->
        print_load_error(session_name, reason)
        {:continue, state}
    end
  end

  # ── Private: choose from multiple autosaves ───────────────────────────

  defp choose_and_load(autosaves, state, opts) do
    IO.puts("")
    IO.puts("    #{IO.ANSI.bright()}📂 Multiple autosaved sessions found:#{IO.ANSI.reset()}")
    IO.puts("")

    autosaves
    |> Enum.with_index(1)
    |> Enum.each(fn {autosave, idx} ->
      marker = if idx == 1, do: "→ ", else: "  "
      ts = format_timestamp(autosave.timestamp)
      msg_count = autosave.message_count || 0

      IO.puts(
        "    #{marker}#{IO.ANSI.cyan()}#{idx}.#{IO.ANSI.reset()} " <>
          "#{session_name_display(autosave.session_name)} " <>
          "#{IO.ANSI.faint()}(#{msg_count} messages, #{ts})#{IO.ANSI.reset()}"
      )
    end)

    IO.puts("")

    IO.puts(
      "    #{IO.ANSI.faint()}Enter number to load (default: 1, most recent), or press Enter to cancel:#{IO.ANSI.reset()}"
    )

    IO.write("    > ")

    case IO.gets("") do
      :eof ->
        IO.puts("    Cancelled.")
        {:continue, state}

      {:error, _reason} ->
        IO.puts("    Cancelled.")
        {:continue, state}

      input ->
        trimmed = String.trim(input)

        cond do
          trimmed == "" ->
            # Empty input — cancelled
            IO.puts("    Cancelled.")
            {:continue, state}

          true ->
            case Integer.parse(trimmed) do
              {n, ""} when n >= 1 and n <= length(autosaves) ->
                chosen = Enum.at(autosaves, n - 1)
                session_name = chosen.session_name

                IO.puts(
                  "    #{IO.ANSI.cyan()}📂 Loading autosave:#{IO.ANSI.reset()} #{session_name}"
                )

                case do_load_session(session_name, state, opts) do
                  {:ok, new_state} ->
                    print_load_success(chosen)
                    {:continue, new_state}

                  {:error, reason} ->
                    print_load_error(session_name, reason)
                    {:continue, state}
                end

              _ ->
                IO.puts(
                  IO.ANSI.red() <>
                    "    Invalid selection. Cancelled." <>
                    IO.ANSI.reset()
                )

                {:continue, state}
            end
        end
    end
  end

  # ── Private: load session data into agent state ────────────────────────

  defp do_load_session(session_name, state, opts) do
    load_opts = if opts[:base_dir], do: [base_dir: opts[:base_dir]], else: []

    with {:ok, session_data} <- SessionStorage.load_session(session_name, load_opts),
         {:ok, agent_key} <- resolve_agent_key(state) do
      messages = Map.get(session_data, :messages, [])

      # Determine session_id for AgentState: use the autosave session name
      # so the messages are stored under the correct key
      session_id = session_name

      # Write messages into AgentState
      AgentState.set_messages(session_id, agent_key, messages)

      # Update RuntimeState to track this as the current autosave
      RuntimeState.set_current_autosave_from_session_name(session_name)

      # Return updated REPL state with the new session_id
      new_state = update_state_session_id(state, session_id)

      {:ok, new_state}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private: helpers ───────────────────────────────────────────────────

  defp update_state_session_id(state, session_id) when is_map(state) do
    Map.put(state, :session_id, session_id)
  end

  defp resolve_agent_key(state) when is_map(state) do
    display_name = Map.get(state, :agent, "code-puppy")

    case Loop.resolve_agent_key(display_name) do
      {:ok, key} -> {:ok, key}
      # Fallback for test agents not in catalogue
      {:error, _} -> {:ok, display_name}
    end
  end

  defp resolve_agent_key(_), do: {:ok, "code-puppy"}

  defp session_name_display(name) do
    # Strip the "auto_session_" prefix for cleaner display
    String.replace_prefix(name, "auto_session_", "")
  end

  defp format_timestamp(nil), do: "unknown time"

  defp format_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} ->
        Calendar.strftime(dt, "%Y-%m-%d %H:%M")

      _ ->
        # Try just returning the raw string if it's not ISO8601
        String.slice(ts, 0, 16)
    end
  end

  defp format_timestamp(_), do: "unknown time"

  defp print_load_success(autosave) do
    msg_count = autosave.message_count || 0
    ts = format_timestamp(autosave.timestamp)

    IO.puts("    #{IO.ANSI.green()}✅ Loaded #{msg_count} messages from #{ts}#{IO.ANSI.reset()}")

    IO.puts("")
  end

  defp print_load_error(session_name, reason) do
    IO.puts(
      IO.ANSI.red() <>
        "    Failed to load session '#{session_name}': #{inspect(reason)}" <>
        IO.ANSI.reset()
    )

    IO.puts("")
  end
end
