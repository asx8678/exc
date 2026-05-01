defmodule CodePuppyControl.Pack.Worker.Application do
  @moduledoc """
  OTP Application for distributed pack worker nodes.

  This is a **lightweight** supervision tree for headless worker nodes.
  It starts only the services needed to accept and execute sub-agent
  dispatches from a leader node.

  ## Difference from the main Application

  | Service | Main Application | Worker Application |
  |---------|-----------------|-------------------|
  | Phoenix Endpoint | ✅ | ❌ |
  | CLI / TUI / REPL | ✅ | ❌ |
  | Session Storage | ✅ | ❌ |
  | Plugin Loader | ✅ | ❌ |
  | Policy Engine | ✅ | ❌ |
  | Callbacks Registry | ✅ | ❌ |
  | Config Writer | ✅ | ❌ |
  | HTTP Client | ✅ | ✅ |
  | Model Registry | ✅ | ✅ |
  | PackParallelism | ✅ | ✅ |
  | SubAgentPool | ❌ | ✅ (NEW) |
  | PackWorker | ❌ | ✅ (NEW) |
  | Repo (SQLite) | ✅ | Optional scratch |

  ## Usage

  Workers are started with a named Erlang node:

      # Start a worker node
      elixir --sname pup_worker_01 --cookie secret_cookie \
        -S mix run --no-start -e "CodePuppyControl.Pack.Worker.Application.start_worker()"

  Or via a config file:

      # puppy.cfg on the worker
      [worker]
      node_name = pup_worker_01@worker-host
      cookie = secret_cookie
      leader = pup_leader@leader-host

  ## References

  - Design doc §4.2: Worker Node
  - Design doc §7.3: Boot sequence (Worker)
  - Design doc §12.1: Worker-side supervision tree
  """

  use Application

  require Logger

  @doc """
  Starts the worker node as a standalone OTP application.
  """
  @spec start_worker(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_worker(opts \\ []) do
    # Ensure the node is named
    node_name = Keyword.get(opts, :node_name)
    cookie = Keyword.get(opts, :cookie)

    with :ok <- ensure_node_name(node_name),
         :ok <- ensure_cookie(cookie) do
      # Start the worker supervision tree
      Application.put_env(:code_puppy_control, :pack_worker, true)

      children = [
        # HTTP client for LLM calls (only if sub-agents use LLMs)
        CodePuppyControl.HttpClient.child_spec(),
        # SQLite for scratch state (optional)
        CodePuppyControl.Repo,
        # Model registry (sub-agents need to know which models to use)
        CodePuppyControl.ModelFactory.ProviderRegistry,
        CodePuppyControl.ModelRegistry,
        # Concurrency limiter for pack runs
        CodePuppyControl.Plugins.PackParallelism.Supervisor,
        # Tool registry (sub-agents need tools)
        CodePuppyControl.Tool.Registry,
        # Sub-agent pool for executing dispatch requests
        CodePuppyControl.Pack.SubAgentPool,
        # Main PackWorker GenServer (entry point for leader dispatch)
        {CodePuppyControl.Pack.Worker, opts}
      ]

      opts = [strategy: :one_for_one, name: CodePuppyControl.Worker.Supervisor]
      Supervisor.start_link(children, opts)
    end
  end

  # ── Application Callback ──────────────────────────────────────────────────

  @impl true
  def start(_type, _args) do
    # Read config from application env
    opts = Application.get_env(:code_puppy_control, :pack_worker, [])

    case start_worker(opts) do
      {:ok, pid} ->
        Logger.info("PackWorker Application started on #{inspect(Node.self())}")
        {:ok, pid, opts}

      {:error, reason} ->
        Logger.error("PackWorker Application failed to start: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  # Assume already named
  defp ensure_node_name(nil), do: :ok

  defp ensure_node_name(name) when is_binary(name) or is_atom(name) do
    if Node.self() == :nonode@nohost do
      {:error, "Node not named. Start with --sname or --name, or set node_name in config"}
    else
      :ok
    end
  end

  defp ensure_cookie(nil), do: :ok

  defp ensure_cookie(cookie) when is_binary(cookie) do
    Node.set_cookie(String.to_atom(cookie))
    :ok
  end
end
