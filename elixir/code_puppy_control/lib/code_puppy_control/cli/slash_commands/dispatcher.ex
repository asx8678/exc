defmodule CodePuppyControl.CLI.SlashCommands.Dispatcher do
  @moduledoc """
  Pure, stateless dispatch logic for slash commands.

  Given a raw input line and REPL state, dispatches to the appropriate
  command handler via the Registry. Falls through to plugin `:custom_command`
  callbacks when no built-in command matches (first-responder semantics).
  Does not own any process state.
  """

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.CLI.SlashCommands.Registry

  @doc """
  Dispatches a slash command line to the registered handler.

  Resolution order:
  1. Built-in Registry command (exact or alias match)
  2. Plugin `:custom_command` callbacks (first non-nil responder wins)

  Returns `{:ok, handler_result}` on success, or an error tuple for
  non-slash input or unknown commands. Handler exceptions propagate —
  the REPL loop wraps this in try/rescue if needed.
  """
  @spec dispatch(String.t(), repl_state :: any()) ::
          {:ok, result :: any()} | {:error, :not_a_slash_command | :unknown_command}
  def dispatch(line, repl_state) when is_binary(line) do
    if not is_slash_command?(line) do
      {:error, :not_a_slash_command}
    else
      # Strip leading "/"
      stripped = String.slice(line, 1..-1//1)

      # Split on whitespace; first token is command name
      name =
        stripped
        |> String.split(" ", parts: 2)
        |> hd()

      if name == "" do
        {:error, :unknown_command}
      else
        case Registry.get(name) do
          {:ok, cmd_info} ->
            result = cmd_info.handler.(line, repl_state)
            {:ok, result}

          {:error, :not_found} ->
            dispatch_plugin_command(line, name)
        end
      end
    end
  end

  @doc """
  Returns true if the input line starts with `/` (slash command).
  """
  @spec is_slash_command?(String.t()) :: boolean()
  def is_slash_command?("/" <> _), do: true
  def is_slash_command?(_), do: false

  # ── Plugin Fallback ──────────────────────────────────────────────

  # When no built-in command matches, fall through to plugin
  # `:custom_command` callbacks with first-responder semantics:
  # the first callback returning a non-nil value wins.
  #
  # Callback return values (per CONTRIBUTING.md):
  #   true       → command handled, return {:ok, :handled}
  #   String.t() → command handled, return {:ok, string}
  #   nil        → not handled, try next callback
  #
  # Uses `Callbacks.trigger_raw/2` to get ordered results without
  # merging, then picks the first non-nil, non-error result.

  @spec dispatch_plugin_command(String.t(), String.t()) ::
          {:ok, :handled | String.t()} | {:error, :unknown_command}
  defp dispatch_plugin_command(command, name) do
    results = Callbacks.trigger_raw(:custom_command, [command, name])

    case find_first_responder(results) do
      {:ok, true} -> {:ok, :handled}
      {:ok, result} -> {:ok, result}
      :unhandled -> {:error, :unknown_command}
    end
  end

  @spec find_first_responder([term()]) :: {:ok, term()} | :unhandled
  defp find_first_responder(results) do
    Enum.find_value(results, :unhandled, fn
      nil -> nil
      :callback_failed -> nil
      value -> {:ok, value}
    end)
  end
end
