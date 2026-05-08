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
          :one_shot
          | :interactive_with_prompt
          | :continue_session
          | :interactive_default
          | :worker_mode
  def resolve_run_mode(opts) do
    case opts do
      %{worker: true} ->
        :worker_mode

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
    # Ensure the OTP app is started for full invocations.
    # On failure, print a clear fatal message and halt — do NOT enter
    # the REPL with a dead supervision tree (that causes confusing
    # crashes like missing ETS tables or dead supervisors).
    case Application.ensure_all_started(:code_puppy_control) do
      {:ok, _} ->
        :ok

      {:error, {app, reason}} ->
        IO.puts(:stderr, """
        FATAL: code_puppy_control application failed to start.
        Root cause: application #{inspect(app)} exited — #{inspect(reason)}

        This usually means a dependency (like erlexec) could not find its
        native port. If you are running as an escript or Burrito binary,
        ensure the native port files are bundled correctly.
        """)

        halt(1)
    end

    # Validate that core processes and ETS tables are alive before
    # entering interactive paths. If the app started but critical
    # processes died afterward (e.g. erlexec crashed), we catch it
    # here rather than letting the REPL crash with confusing errors.
    case resolve_run_mode(opts) do
      :worker_mode ->
        run_worker(opts)

      :one_shot ->
        validate_runtime_health!()
        run_single_prompt(opts)

      :interactive_with_prompt ->
        validate_runtime_health!()
        run_interactive(opts)

      :continue_session ->
        validate_runtime_health!()
        run_continue_session(opts)

      :interactive_default ->
        validate_runtime_health!()
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

  defp run_worker(opts) do
    # Start Erlang distribution if not already started
    node_name = opts[:sname] || opts[:name]

    if node_name do
      name_type = if opts[:sname], do: :shortnames, else: :longnames
      Node.start(String.to_atom(node_name), name_type)
    end

    # Set cookie if provided
    if opts[:cookie] do
      Node.set_cookie(String.to_atom(opts[:cookie]))
    end

    # Start the worker application
    IO.puts("Starting worker node: #{Node.self()}")
    IO.puts("Waiting for leader connection...")

    {:ok, _} =
      CodePuppyControl.Pack.Worker.Application.start_link(
        node_name: Node.self(),
        mode: :persistent
      )

    # Block until shutdown (worker runs indefinitely)
    Process.sleep(:infinity)
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

  @doc """
  Validates that core OTP processes and ETS tables required for REPL
  operation are alive. Prints a clear error and halts nonzero if any
  critical component is missing.

  This is called before entering interactive, continue, or one-shot
  paths. It is NOT called for `--help` / `--version` (which are fast
  paths that skip app startup entirely).

  ## Checks

    * `CodePuppyControl.Agent.State.Supervisor` — required for agent
      session state; if dead, `/agent` and the REPL crash with
      `no process`.
    * `:slash_commands` ETS table — required for slash command dispatch;
      if missing, `/agent` crashes with `ArgumentError`.

  """
  @spec validate_runtime_health!() :: :ok | no_return()
  def validate_runtime_health! do
    checks = [
      {"Agent.State.Supervisor", agent_state_supervisor_alive?()},
      {":slash_commands ETS table", slash_commands_table_alive?()}
    ]

    failures = for {name, false} <- checks, do: name

    if failures != [] do
      IO.puts(:stderr, """
      FATAL: core OTP components are not alive — cannot enter REPL.
      Missing: #{Enum.join(failures, ", ")}

      This indicates the application supervision tree is degraded.
      Check logs above for the root cause (e.g. erlexec startup failure).
      If running as an escript, ensure the native port files are bundled
      correctly.
      """)

      halt(1)
    end

    :ok
  end

  defp agent_state_supervisor_alive? do
    case Process.whereis(CodePuppyControl.Agent.State.Supervisor) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end

  defp slash_commands_table_alive? do
    try do
      :ets.info(:slash_commands) != :undefined
    rescue
      _ -> false
    end
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
      -h, --help            Show this help message and exit
      -v, -V, --version     Show version and exit
      -m, --model MODEL     Model to use (default: from config)
      -a, --agent AGENT     Agent to use (default: code-puppy)
      -c, --continue        Resume the most recent persisted session
      -p, --prompt PROMPT   Execute a single prompt and exit
      -i, --interactive     Run in interactive mode
      -w, --worker          Start as a headless pack worker node
          --sname SNAME     Short node name for Erlang distribution
          --name NAME       Full node name for Erlang distribution
          --cookie COOKIE   Erlang distribution cookie for cluster auth

    Examples:
      pup                           Start interactive mode
      pup "explain this code"        Run single prompt
      pup -m claude-sonnet -c       Resume latest session with a model override
      pup --worker --sname pup_worker_01 --cookie secret
                                    Start as worker node

    For more information: https://github.com/anthropics/code-puppy
    """
  end
end
