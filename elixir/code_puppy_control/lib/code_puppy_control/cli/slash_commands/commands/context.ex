defmodule CodePuppyControl.CLI.SlashCommands.Commands.Context do
  @moduledoc """
  Context slash commands: /model, /agent, /sessions, /tui.

  These commands interact with the REPL's agent/model/session context.
  Handlers delegate to the existing implementation in `REPL.Loop` to
  minimize churn; the logic can be fully extracted in a future ticket.
  """

  alias CodePuppyControl.REPL.Loop

  @doc """
  Handles `/model [name]` — shows or switches the current model.

  Without an argument, triggers interactive model selection (or falls back
  to showing the current model). With an argument, switches directly.
  """
  @spec handle_model(String.t(), Loop.t()) :: {:continue, Loop.t()} | {:halt, Loop.t()}
  def handle_model(line, state) do
    args = extract_args(line)
    # Delegate to Loop's existing handler
    Loop.handle_model_command(args, state)
  end

  @doc """
  Handles `/agent [name]` — interactively select or directly switch the current agent.

  Without an argument, triggers interactive agent selection (or falls back
  to showing the current agent). With an argument, switches directly.
  """
  @spec handle_agent(String.t(), Loop.t()) :: {:continue, Loop.t()}
  def handle_agent(line, state) do
    args = extract_args(line)
    # Delegate to Loop's existing handler
    Loop.handle_agent_command(args, state)
  end

  @doc """
  Handles `/sessions [filter]` — browses and switches sessions.
  """
  @spec handle_sessions(String.t(), Loop.t()) :: {:continue, Loop.t()}
  def handle_sessions(line, state) do
    args = extract_args(line)
    # Delegate to Loop's existing handler
    Loop.handle_sessions_command(args, state)
  end

  @doc """
  Handles `/tui` — launches the full TUI interface.
  """
  @spec handle_tui(String.t(), Loop.t()) :: {:continue, Loop.t()}
  def handle_tui(_line, state) do
    # Delegate to Loop's existing handler
    Loop.handle_tui_command(state)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  @spec extract_args(String.t()) :: String.t()
  defp extract_args("/" <> rest) do
    case String.split(rest, " ", parts: 2) do
      [_name] -> ""
      [_name, args] -> args
    end
  end

  defp extract_args(_line), do: ""
end
