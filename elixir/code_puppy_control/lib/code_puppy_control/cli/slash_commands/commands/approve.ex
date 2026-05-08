defmodule CodePuppyControl.CLI.SlashCommands.Commands.Approve do
  @moduledoc """
  Approve slash command: /approve [list|last|clear].

  Manages one-shot approvals for file operations that require user
  confirmation (when the `PolicyEngine` returns `%AskUser{}`).

  ## Usage

    /approve            — show pending requests (alias for /approve list)
    /approve list       — list all pending approval requests
    /approve last       — approve the most recent pending request (one-shot)
    /approve clear      — clear all pending requests and approvals
  """

  alias CodePuppyControl.Approvals

  @doc """
  Handles `/approve` — manage file operation approvals.

  The REPL `state` is expected to be a map with a `:session_id` key.
  `/approve list` and `/approve last` filter to the current session
  when a session_id is available; otherwise they operate globally.
  """
  @spec handle_approve(String.t(), any()) :: {:continue, any()}
  def handle_approve(line, state) do
    session_id = extract_session_id(state)

    case extract_args(line) |> String.trim() do
      "" ->
        show_list(session_id)

      args ->
        parts = String.split(args, ~r/\s+/, trim: true)
        subcmd = hd(parts)

        case subcmd do
          "list" -> show_list(session_id)
          "last" -> do_approve_last(session_id)
          "clear" -> do_clear()
          _ -> print_usage()
        end
    end

    {:continue, state}
  end

  # ── Subcommand handlers ────────────────────────────────────────────────

  defp show_list(session_id) do
    pending = Approvals.list_pending(session_id)

    if pending == [] do
      IO.puts(IO.ANSI.faint() <> "    No pending approval requests" <> IO.ANSI.reset())
    else
      IO.puts("")

      IO.puts(
        IO.ANSI.bright() <>
          IO.ANSI.magenta() <> "    Pending Approval Requests" <> IO.ANSI.reset()
      )

      IO.puts("")

      pending
      |> Enum.with_index(1)
      |> Enum.each(fn {req, idx} ->
        prompt_str = if req.prompt, do: " — #{req.prompt}", else: ""
        fp_prefix = Approvals.Request.fingerprint_prefix(req)

        fp_display =
          if fp_prefix != "", do: " #{IO.ANSI.faint()}[#{fp_prefix}]#{IO.ANSI.reset()}", else: ""

        IO.puts(
          "    #{IO.ANSI.cyan()}#{idx}.#{IO.ANSI.reset()} " <>
            "#{IO.ANSI.bright()}#{req.operation}#{IO.ANSI.reset()} " <>
            "#{IO.ANSI.faint()}#{req.tool_name}#{IO.ANSI.reset()} " <>
            "#{req.file_path}#{fp_display}#{prompt_str}"
        )
      end)

      IO.puts("")

      IO.puts(
        IO.ANSI.faint() <>
          "    Use /approve last to approve the most recent request" <> IO.ANSI.reset()
      )

      IO.puts("")
    end
  end

  defp do_approve_last(session_id) do
    case Approvals.approve_last(session_id) do
      :ok ->
        IO.puts(
          IO.ANSI.green() <>
            "    ✓ Approved the most recent pending request (one-shot)" <>
            IO.ANSI.reset()
        )

      {:error, :none_pending} ->
        IO.puts(
          IO.ANSI.faint() <> "    No pending approval requests to approve" <> IO.ANSI.reset()
        )
    end
  end

  defp do_clear do
    Approvals.clear()

    IO.puts(
      IO.ANSI.green() <> "    Cleared all pending requests and approvals" <> IO.ANSI.reset()
    )
  end

  # ── Usage helpers ───────────────────────────────────────────────────────

  defp print_usage do
    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        "    Usage: /approve [list|last|clear]" <>
        IO.ANSI.reset()
    )

    IO.puts("")
  end

  @spec extract_args(String.t()) :: String.t()
  defp extract_args("/" <> rest) do
    case String.split(rest, " ", parts: 2) do
      [_name] -> ""
      [_name, args] -> args
    end
  end

  defp extract_args(_line), do: ""

  # Extracts session_id from the REPL state map.  Returns nil when
  # the state is not a map or does not carry a session_id — in that
  # case `/approve list` and `/approve last` operate globally.
  @spec extract_session_id(any()) :: String.t() | nil
  defp extract_session_id(%{session_id: sid}) when is_binary(sid) and sid != "", do: sid
  defp extract_session_id(_), do: nil
end
