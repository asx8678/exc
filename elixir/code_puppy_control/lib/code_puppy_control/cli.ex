defmodule CodePuppyControl.CLI do
  @moduledoc """
  Elixir CLI entry point for `pup` / `code-puppy` commands.

  Preserves command-line compatibility with the Python implementation
  in `code_puppy.cli_runner`. Fast-path --help/--version avoid starting
  the full OTP application.

  ## Usage

      pup [OPTIONS] [PROMPT]
      code-puppy [OPTIONS] [PROMPT]

  ## Options

    * `-h`, `--help` - Show help and exit
    * `-v`, `-V`, `--version` - Show version and exit
    * `-m`, `--model MODEL` - Model to use (default: from config)
    * `-a`, `--agent AGENT` - Agent to use (default: code-puppy)
    * `-c`, `--continue` - Resume the most recent persisted session
    * `-p`, `--prompt PROMPT` - Execute a single prompt and exit
    * `-i`, `--interactive` - Run in interactive mode
    * `--bridge-mode` - Force Python runtime (sets `PUP_RUNTIME=python` for the session)
    This delegates all capabilities to the Python bridge, effectively
    running the Elixir CLI as a thin frontend. See `RuntimeSelector` (code_puppy-bwt).
  """

  alias CodePuppyControl.CLI.Parser
  alias CodePuppyControl.CLI.SessionResume

  @version Mix.Project.config()[:version]

  @doc """
  Main entry point invoked by the escript wrapper.
  """
  @spec main([String.t()]) :: no_return()
  def main(args) do
    case Parser.parse(args) do
      {:help, _opts} ->
        IO.puts(help_text())
        halt(0)

      {:version, _opts} ->
        IO.puts("code-puppy #{@version}")
        halt(0)

      {:ok, opts} ->
        run(opts)

      {:error, message} ->
        IO.puts(:stderr, "Error: #{message}")
        IO.puts(:stderr, "Try 'pup --help' for usage information.")
        halt(1)
    end
  end

  @doc """
  Determine the run mode from parsed CLI opts.

  Returns an atom tag describing which execution path `run/1` will
  take, without starting the OTP supervision tree or calling
  `System.halt/1`.  Extracted for testability — the routing
  logic is pure and deterministic.

  ## Returns

    * `:one_shot`               — Non-interactive prompt (`-p TEXT` / positional)
    * `:interactive_with_prompt` — Interactive mode with an initial prompt (`-p TEXT -i`)
    * `:continue_session`       — Restore newest persisted session (`-c`) before REPL
    * `:interactive_default`     — Plain interactive REPL (no prompt / empty prompt)
  """
  @spec resolve_run_mode(map()) ::
          :one_shot | :interactive_with_prompt | :continue_session | :interactive_default
  def resolve_run_mode(opts) do
    case opts do
      %{continue: true} ->
        :continue_session

      %{prompt: prompt, interactive: true} when is_binary(prompt) and prompt != "" ->
        :interactive_with_prompt

      %{prompt: prompt} when is_binary(prompt) and prompt != "" ->
        :one_shot

      _ ->
        :interactive_default
    end
  end

  @doc """
  Run the application with parsed options.

  Starts the OTP supervision tree (unless --help/--version) and
  delegates to the interactive loop or single-prompt runner.
  """
  @spec run(map()) :: no_return()
  def run(opts) do
    # --bridge-mode forces PUP_RUNTIME=python for this session,
    # so RuntimeSelector delegates all capabilities to the Python bridge.
    if opts[:bridge_mode] do
      System.put_env("PUP_RUNTIME", "python")
    end

    # Ensure the OTP app is started for full invocations
    Application.ensure_all_started(:code_puppy_control)

    case resolve_run_mode(opts) do
      :one_shot ->
        run_single_prompt(opts)

      :interactive_with_prompt ->
        run_interactive(opts)

      :continue_session ->
        run_continue_session(opts)

      :interactive_default ->
        run_interactive(opts)
    end

    halt(0)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp run_continue_session(opts) do
    case SessionResume.restore_latest(opts) do
      {:ok, resumed_opts} ->
        run_interactive(resumed_opts)

      {:fresh, fresh_opts, :no_sessions} ->
        IO.puts("No previous session found, starting fresh.")
        run_interactive(fresh_opts)

      {:fresh, fresh_opts, _reason} ->
        IO.puts("Could not restore previous session, starting fresh.")
        run_interactive(fresh_opts)
    end
  end

  defp run_interactive(opts) do
    module = repl_loop_module()
    module.run(opts)
  end

  defp run_single_prompt(opts) do
    case CodePuppyControl.REPL.OneShot.run(opts) do
      :ok ->
        :ok

      :error ->
        halt(1)
    end
  end

  defp repl_loop_module do
    Application.get_env(:code_puppy_control, :cli_repl_loop_module, CodePuppyControl.REPL.Loop)
  end

  @spec halt(non_neg_integer()) :: no_return()
  defp halt(status) do
    halt_fun = Application.get_env(:code_puppy_control, :cli_halt_fun, &System.halt/1)
    halt_fun.(status)
    exit({:halt_returned, status})
  end

  @doc """
  Generate help text matching the Python CLI format exactly.
  """
  @spec help_text() :: String.t()
  def help_text do
    """
    code-puppy #{@version} - AI-powered coding assistant

    Usage: pup [OPTIONS] [PROMPT]

    Options:
      -h, --help Show this help message and exit
      -v, -V, --version Show version and exit
      -m, --model MODEL Model to use (default: from config)
      -a, --agent AGENT Agent to use (default: code-puppy)
      -c, --continue Resume the most recent persisted session
      -p, --prompt PROMPT Execute a single prompt and exit
      -i, --interactive Run in interactive mode
      --bridge-mode Force Python runtime (sets PUP_RUNTIME=python for this session)

    Examples:
      pup Start interactive mode
      pup "explain this code" Run single prompt
      pup -m claude-sonnet -c       Resume latest session with a model override

    For more information: https://github.com/anthropics/code-puppy
    """
  end
end
