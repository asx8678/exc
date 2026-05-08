defmodule CodePuppyControl.CLI.SlashCommands.Commands.Session do
  @moduledoc """
  Session slash commands: /compact, /truncate.

  These commands manage conversation history via Agent.State
  and the Compaction pipeline.
  """

  alias CodePuppyControl.Agent.State, as: AgentState
  alias CodePuppyControl.Compaction
  alias CodePuppyControl.REPL.Loop

  # Roles considered "system/instructions" — preserved by /truncate
  @system_roles ~w(system instructions)

  @doc """
  Handles `/compact` — compacts conversation history.

  Runs the Compaction pipeline (filter → truncate tool args → split)
  on the current session's message history and writes the result back
  via `Agent.State.set_messages/3`.

  Prints a warning if no history exists, or a success summary with
  before/after message counts and compaction stats.
  """
  @spec handle_compact(String.t(), any()) :: {:continue, any()}
  def handle_compact(_line, state) do
    with {:ok, session_id} <- fetch_session_id(state),
         {:ok, agent_key} <- resolve_agent_key(state) do
      do_compact(session_id, agent_key, state)
    else
      {:error, :no_session} ->
        IO.puts(
          IO.ANSI.red() <>
            "No active session — cannot compact." <>
            IO.ANSI.reset()
        )

        {:continue, state}

      {:error, reason} ->
        IO.puts(
          IO.ANSI.red() <>
            "Cannot resolve agent key: #{inspect(reason)}" <>
            IO.ANSI.reset()
        )

        {:continue, state}
    end
  end

  @doc """
  Handles `/truncate <N>` — truncates conversation to last N messages.

  If the first message is a system/instructions-style message, it is
  preserved alongside the last N-1 messages. If the history starts with
  user/assistant messages (no system preamble), the last N messages
  are kept without special treatment.

  Mirrors Python's `/truncate` behavior from session_commands.py.
  """
  @spec handle_truncate(String.t(), any()) :: {:continue, any()}
  def handle_truncate(line, state) do
    args = extract_args(line)

    cond do
      args == "" ->
        IO.puts(
          IO.ANSI.red() <>
            "Usage: /truncate <N>" <>
            IO.ANSI.reset()
        )

        {:continue, state}

      true ->
        case Integer.parse(String.trim(args)) do
          {n, ""} when n > 0 ->
            do_truncate(state, n)

          _ ->
            IO.puts(
              IO.ANSI.red() <>
                "Invalid number: #{args}. Usage: /truncate <N>" <>
                IO.ANSI.reset()
            )

            {:continue, state}
        end
    end
  end

  # ── Private: compact implementation ───────────────────────────────────

  defp do_compact(session_id, agent_key, state) do
    messages = AgentState.get_messages(session_id, agent_key)

    if messages == [] do
      IO.puts(
        IO.ANSI.yellow() <>
          "⚠️  No history to compact yet. Ask me something first!" <>
          IO.ANSI.reset()
      )

      {:continue, state}
    else
      before_count = length(messages)

      case Compaction.compact(messages) do
        {:ok, compacted, stats} ->
          AgentState.set_messages(session_id, agent_key, compacted)
          after_count = length(compacted)

          IO.puts(
            IO.ANSI.green() <>
              "✨ Compacted: #{before_count} → #{after_count} messages " <>
              "(dropped=#{stats.dropped_by_filter}, " <>
              "truncated=#{stats.truncated_count}, " <>
              "summarize_candidates=#{stats.summarize_count})" <>
              IO.ANSI.reset()
          )

          {:continue, state}

        error ->
          IO.puts(
            IO.ANSI.red() <>
              "Compaction failed: #{inspect(error)}" <>
              IO.ANSI.reset()
          )

          {:continue, state}
      end
    end
  end

  # ── Private: truncate implementation ──────────────────────────────────

  defp do_truncate(state, n) do
    with {:ok, session_id} <- fetch_session_id(state),
         {:ok, agent_key} <- resolve_agent_key(state) do
      do_truncate_with_keys(session_id, agent_key, state, n)
    else
      {:error, :no_session} ->
        IO.puts(
          IO.ANSI.red() <>
            "No active session — cannot truncate." <>
            IO.ANSI.reset()
        )

        {:continue, state}

      {:error, reason} ->
        IO.puts(
          IO.ANSI.red() <>
            "Cannot resolve agent key: #{inspect(reason)}" <>
            IO.ANSI.reset()
        )

        {:continue, state}
    end
  end

  defp do_truncate_with_keys(session_id, agent_key, state, n) do
    messages = AgentState.get_messages(session_id, agent_key)

    if messages == [] do
      IO.puts(
        IO.ANSI.yellow() <>
          "⚠️  No history to truncate yet. Ask me something first!" <>
          IO.ANSI.reset()
      )

      {:continue, state}
    else
      current_count = length(messages)

      if current_count <= n do
        IO.puts(
          IO.ANSI.yellow() <>
            "History already has #{current_count} messages, " <>
            "which is ≤ #{n}. Nothing to truncate." <>
            IO.ANSI.reset()
        )

        {:continue, state}
      else
        {truncated, label} = build_truncated(messages, n)

        AgentState.set_messages(session_id, agent_key, truncated)

        IO.puts(
          IO.ANSI.green() <>
            "✂️  Truncated: #{current_count} → #{length(truncated)} messages (#{label})" <>
            IO.ANSI.reset()
        )

        {:continue, state}
      end
    end
  end

  # Build the truncated message list. If the first message is a
  # system/instructions message, preserve it + last (n-1); otherwise
  # just keep the last n messages.
  @spec build_truncated([map()], pos_integer()) :: {[map()], String.t()}
  defp build_truncated(messages, n) do
    first = hd(messages)

    if is_system_message?(first) do
      truncated =
        if n > 1 do
          [first | Enum.take(messages, -(n - 1))]
        else
          [first]
        end

      {truncated, "keeping system message and #{min(n - 1, length(messages) - 1)} most recent"}
    else
      {Enum.take(messages, -n), "keeping #{n} most recent"}
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec is_system_message?(map()) :: boolean()
  defp is_system_message?(%{"role" => role}), do: role in @system_roles
  defp is_system_message?(_), do: false

  @spec extract_args(String.t()) :: String.t()
  defp extract_args("/" <> rest) do
    case String.split(rest, " ", parts: 2) do
      [_name] -> ""
      [_name, args] -> args
    end
  end

  defp extract_args(_line), do: ""

  @spec fetch_session_id(any()) :: {:ok, String.t()} | {:error, :no_session}
  defp fetch_session_id(state) when is_map(state) do
    case Map.get(state, :session_id) do
      nil -> {:error, :no_session}
      sid -> {:ok, sid}
    end
  end

  defp fetch_session_id(_), do: {:error, :no_session}

  @spec resolve_agent_key(any()) :: {:ok, String.t()} | {:error, term()}
  defp resolve_agent_key(state) when is_map(state) do
    display_name = Map.get(state, :agent, "code-puppy")

    case Loop.resolve_agent_key(display_name) do
      {:ok, key} -> {:ok, key}
      # Fallback: agent not in catalogue (e.g. test agents). Use the
      # display name directly so that Agent.State auto-start still works.
      {:error, _} -> {:ok, display_name}
    end
  end

  defp resolve_agent_key(_), do: {:error, :no_state}
end
