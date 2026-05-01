defmodule Mix.Tasks.PupEx.Worker do
  @shortdoc "Start a distributed pack worker node"

  @moduledoc """
  Start a headless worker node that connects to a leader for sub-agent dispatch.

  Boots a lightweight OTP supervision tree via
  `CodePuppyControl.Pack.Worker.Application.start_worker/1` — no web endpoint,
  no CLI, no plugin loader. The worker registers with the leader and waits for
  dispatched work.

  ## Usage

      # Short name + explicit cookie
      mix pup_ex.worker --sname pup_worker_01 --cookie secret --leader pup_leader@host

      # Fully-qualified name
      mix pup_ex.worker --name pup_worker_01@192.168.1.10 --cookie secret --leader pup_leader@host

      # Use config from puppy.cfg [worker] section (no flags needed)
      mix pup_ex.worker

      # Override max concurrent runs
      mix pup_ex.worker --sname worker_01 --cookie s3cr3t --leader leader@host -m 4

  ## Flags

    * `--sname` / `-s` — short node name (mutually exclusive with `--name`)
    * `--name` / `-n` — fully qualified node name (mutually exclusive with `--sname`)
    * `--cookie` / `-c` — Erlang distribution cookie
    * `--leader` / `-l` — leader node to connect to
    * `--max-concurrent-runs` / `-m` — max parallel sub-agent runs (default: 2)
    * `--help` / `-h` — print usage and exit

  ## Exit codes

    * 0 — clean shutdown (Ctrl+C or SIGTERM)
    * 1 — startup failure (bad args, distribution error, supervisor crash)

  ## References

    * Design doc §4.2: Worker Node
    * Design doc §7.3: Boot sequence (Worker)
  """

  use Mix.Task

  alias CodePuppyControl.Pack.Worker.Application, as: WorkerApp

  @switches [
    sname: :string,
    name: :string,
    cookie: :string,
    leader: :string,
    max_concurrent_runs: :integer,
    help: :boolean
  ]

  @aliases [s: :sname, n: :name, c: :cookie, l: :leader, m: :max_concurrent_runs, h: :help]

  @impl Mix.Task
  def run(argv) do
    case parse_args(argv) do
      {:ok, opts} ->
        start_worker(opts)

      {:error, message} ->
        Mix.shell().error(message)
        usage()
        System.halt(1)

      :help ->
        usage()
    end
  end

  # ── Arg Parsing ────────────────────────────────────────────────────────

  @doc false
  @spec parse_args([String.t()]) :: {:ok, keyword()} | {:error, String.t()} | :help
  def parse_args(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        if Keyword.get(opts, :help, false) do
          :help
        else
          validate_opts(opts)
        end

      {_opts, positional, []} ->
        {:error, "unexpected positional arguments: #{inspect(positional)}"}

      {_opts, _, invalid} ->
        {:error, "invalid flag(s): #{format_invalid(invalid)}"}
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────

  @doc false
  @spec validate_opts(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def validate_opts(opts) do
    with :ok <- validate_name_exclusivity(opts),
         :ok <- validate_max_concurrent_runs(opts) do
      {:ok, opts}
    end
  end

  defp validate_name_exclusivity(opts) do
    has_sname = Keyword.has_key?(opts, :sname)
    has_name = Keyword.has_key?(opts, :name)

    cond do
      has_sname and has_name ->
        {:error, "--sname and --name are mutually exclusive — pick one"}

      true ->
        :ok
    end
  end

  defp validate_max_concurrent_runs(opts) do
    case Keyword.get(opts, :max_concurrent_runs) do
      nil -> :ok
      n when is_integer(n) and n > 0 -> :ok
      n -> {:error, "--max-concurrent-runs must be a positive integer, got: #{inspect(n)}"}
    end
  end

  # ── Distribution Setup ─────────────────────────────────────────────────

  @doc false
  @spec start_distribution(keyword()) :: :ok | {:error, String.t()}
  def start_distribution(opts) do
    cond do
      Keyword.has_key?(opts, :sname) ->
        name = opts[:sname] |> String.to_atom()
        start_node(name, :shortnames)

      Keyword.has_key?(opts, :name) ->
        name = opts[:name] |> String.to_atom()
        start_node(name, :longnames)

      true ->
        # No name flags — distribution must already be configured
        # (e.g. via elixir --sname or puppy.cfg)
        if Node.alive?() do
          :ok
        else
          {:error, "Node is not distributed. Pass --sname or --name to enable distribution."}
        end
    end
  end

  defp start_node(name, mode) do
    if Node.alive?() do
      Mix.shell().info(
        "[worker] Node already alive as #{inspect(Node.self())} — skipping Node.start"
      )

      :ok
    else
      case Node.start(name, mode) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          {:error,
           "failed to start Erlang distribution (#{mode}) as #{inspect(name)}: #{inspect(reason)}"}
      end
    end
  end

  # ── Worker Startup ─────────────────────────────────────────────────────

  defp start_worker(opts) do
    case start_distribution(opts) do
      :ok ->
        :ok

      {:error, message} ->
        Mix.shell().error(message)
        System.halt(1)
    end

    case maybe_set_cookie(opts) do
      :ok ->
        :ok

      {:error, message} ->
        Mix.shell().error(message)
        System.halt(1)
    end

    worker_opts = build_worker_opts(opts)

    Mix.shell().info("[worker] Starting pack worker on #{inspect(Node.self())}...")

    case WorkerApp.start_worker(worker_opts) do
      {:ok, _pid} ->
        Mix.shell().info("[worker] Worker running. Press Ctrl+C to stop.")
        block_until_shutdown()

      {:error, reason} ->
        Mix.shell().error("[worker] Failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp maybe_set_cookie(opts) do
    case Keyword.get(opts, :cookie) do
      nil -> :ok
      cookie -> safe_set_cookie(cookie)
    end
  end

  defp safe_set_cookie(cookie_str) do
    try do
      Node.set_cookie(String.to_atom(cookie_str))
      :ok
    rescue
      _ -> {:error, "Failed to set distribution cookie (invalid value)"}
    end
  end

  @doc false
  @spec build_worker_opts(keyword()) :: keyword()
  def build_worker_opts(opts) do
    worker_opts = []

    worker_opts =
      case Keyword.get(opts, :leader) do
        nil -> worker_opts
        leader -> Keyword.put(worker_opts, :leader, String.to_atom(leader))
      end

    worker_opts =
      case Keyword.get(opts, :cookie) do
        nil -> worker_opts
        cookie -> Keyword.put(worker_opts, :cookie, cookie)
      end

    case Keyword.get(opts, :max_concurrent_runs) do
      nil -> worker_opts
      n -> Keyword.put(worker_opts, :max_concurrent_runs, n)
    end
  end

  # ── Process Blocking ───────────────────────────────────────────────────

  defp block_until_shutdown do
    # Trap exits so we can shut down cleanly on Ctrl+C / SIGTERM
    Process.flag(:trap_exit, true)

    receive do
      {:EXIT, _pid, reason} ->
        Mix.shell().info("[worker] Shutting down: #{inspect(reason)}")
    end
  end

  # ── Help Output ────────────────────────────────────────────────────────

  defp usage do
    Mix.shell().info("""

    Usage:
      mix pup_ex.worker [flags]

    Flags:
      --sname, -s   Short node name (mutually exclusive with --name)
      --name,  -n   Fully qualified node name (mutually exclusive with --sname)
      --cookie, -c  Erlang distribution cookie
      --leader, -l  Leader node to connect to
      --max-concurrent-runs, -m  Max parallel sub-agent runs (default: 2)
      --help, -h    Print this message

    Examples:
      mix pup_ex.worker --sname worker_01 --cookie s3cr3t --leader leader@host
      mix pup_ex.worker --name worker_01@10.0.0.5 --cookie s3cr3t --leader leader@host
      mix pup_ex.worker  # reads from puppy.cfg [worker] section
    """)
  end

  defp format_invalid(invalid) do
    Enum.map_join(invalid, ", ", fn
      {key, nil} -> key
      {key, val} -> "#{key}=#{val}"
    end)
  end
end
