defmodule CodePuppyControl.Pack.Worker.Application do
  @moduledoc """
  OTP Application for distributed pack worker nodes.

  This is a **lightweight** supervision tree for headless worker nodes.
  It starts only the services needed to accept and execute sub-agent
  dispatches from a leader node — no web endpoint, no CLI, no plugin loader.

  ## Difference from the main Application

  | Service                  | Main Application | Worker Application |
  |--------------------------|------------------|--------------------|
  | Phoenix Endpoint         | ✅               | ❌                 |
  | CLI / TUI / REPL         | ✅               | ❌                 |
  | Session Storage          | ✅               | ❌                 |
  | Plugin Loader            | ✅               | ❌                 |
  | Policy Engine            | ✅               | ❌                 |
  | Callbacks Registry       | ✅               | ❌                 |
  | Config Writer            | ✅               | ❌                 |
  | Oban / CronScheduler     | ✅               | ❌                 |
  | Repo (SQLite)            | ✅               | ❌                 |
  | HTTP Client (Finch)      | ✅               | ✅                 |
  | PubSub                   | ✅               | ✅                 |
  | Pack Registries          | ✅               | ✅                 |
  | NamingService            | ✅               | ✅                 |
  | Model Registry           | ✅               | ✅                 |
  | Pack Worker GenServer    | ❌               | ✅                 |
  | NodeMonitor              | ✅               | ✅                 |
  | Concurrency Supervisor   | ✅               | ✅                 |

  Telemetry events (`CodePuppyControl.Telemetry.DistributedPack`) are
  available on worker nodes via the normal `:telemetry.execute/3` path —
  they're pure functions, not supervised processes.

  ## Usage

  Workers are started with a named Erlang node:

      # Start a worker node
      elixir --sname pup_worker_01 --cookie secret_cookie \\
        -S mix run --no-start -e \\
        "CodePuppyControl.Pack.Worker.Application.start_worker(leader: :pup_leader@host)"

  Or via `puppy.cfg` on the worker:

      [worker]
      leader = pup_leader@leader-host
      max_concurrent_runs = 4

  ## References

  - Design doc §4.2: Worker Node
  - Design doc §7.3: Boot sequence (Worker)
  - Design doc §12.1: Worker-side supervision tree
  """

  use Application

  require Logger

  alias CodePuppyControl.Config.Loader, as: ConfigLoader

  @worker_mode_key :pack_worker_mode
  @worker_config_section "worker"
  @required_apps [:logger, :phoenix_pubsub, :finch, :telemetry]
  @passthrough_opts [:connect_fn, :monitor_fn]

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Returns whether the current node is running in worker mode.

  Checks the `:pack_worker_mode` application env flag, which is set
  to `true` by `start_worker/1` before the supervision tree starts.

  ## Examples

      iex> CodePuppyControl.Pack.Worker.Application.worker_mode?()
      false
  """
  @spec worker_mode?() :: boolean()
  def worker_mode? do
    Application.get_env(:code_puppy_control, @worker_mode_key, false)
  end

  @doc """
  Returns the child specs for the worker supervision tree.

  This is intentionally public so tests can assert on the children list
  without starting real processes. Accepts the same options as
  `start_worker/1`.

  ## Examples

      iex> children = CodePuppyControl.Pack.Worker.Application.children(leader: :leader@host)
      iex> length(children) >= 8
      true
  """
  @spec children(keyword()) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def children(opts \\ []) do
    config = worker_config(opts)

    [
      # Finch HTTP pool for LLM API calls
      CodePuppyControl.HttpClient.child_spec(),
      # PubSub for internal event distribution
      {Phoenix.PubSub, name: CodePuppyControl.PubSub},
      # Registry tables for RemoteNodeProxy / RemoteNodeSupervisor
      {CodePuppyControl.Pack.Registries, []},
      # ETS-backed capability index
      CodePuppyControl.Pack.NamingService,
      # Model configuration registry (ETS-backed)
      CodePuppyControl.ModelRegistry,
      # Main worker GenServer — accepts dispatch from leader
      {CodePuppyControl.Pack.Worker, worker_genserver_opts(config)},
      # Monitors leader connection, handles reconnection
      {CodePuppyControl.Pack.NodeMonitor, node_monitor_opts(config)},
      # ETS-backed concurrency limiter (file_ops, api_calls, tool_calls)
      CodePuppyControl.Concurrency.Supervisor
    ]
  end

  @doc """
  Starts a worker node as a standalone OTP supervision tree.

  This is the main entry point for headless worker nodes. It:

  1. Resolves config from `opts`, then `[worker]` section of `puppy.cfg`,
     then defaults
  2. Validates that a leader node is specified
  3. Sets the worker mode flag
  4. Starts the lightweight supervision tree
  5. Attempts to connect to the leader node (non-blocking)

  ## Options

    * `:leader` — leader node name (atom or string). **Required** unless
      configured in `puppy.cfg`.
    * `:cookie` — Erlang cookie (string). Optional — sets the cookie if
      provided.
    * `:max_concurrent_runs` — max parallel sub-agent runs. Default: `2`.
    * `:available_models` — list of model identifiers. Default: `[]`.

  ## Returns

    * `{:ok, pid}` — supervision tree started and leader connection attempted
    * `{:error, reason}` — validation failed or supervision tree crashed

  ## Examples

      {:ok, pid} = Worker.Application.start_worker(leader: :pup_leader@host)
      {:error, :missing_leader} = Worker.Application.start_worker([])
  """
  @spec start_worker(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_worker(opts \\ []) do
    config = worker_config(opts)

    with :ok <- validate_config(config),
         :ok <- ensure_required_apps_started(),
         :ok <- maybe_set_cookie(config) do
      Application.put_env(:code_puppy_control, @worker_mode_key, true)

      children_list = children(config)
      sup_opts = [strategy: :one_for_one, name: __MODULE__.Supervisor]

      case Supervisor.start_link(children_list, sup_opts) do
        {:ok, pid} ->
          Logger.info(
            "[Worker.Application] started on #{inspect(Node.self())} " <>
              "with leader=#{inspect(config[:leader])}"
          )

          attempt_leader_connect(config)
          {:ok, pid}

        {:error, reason} = error ->
          Logger.error("[Worker.Application] failed to start: #{inspect(reason)}")
          Application.put_env(:code_puppy_control, @worker_mode_key, false)
          error
      end
    end
  end

  @doc """
  Resolves worker configuration from explicit opts, `puppy.cfg`, and defaults.

  Precedence (highest to lowest):
  1. Explicit keyword opts
  2. `[worker]` section in `puppy.cfg`
  3. Hardcoded defaults

  ## Examples

      iex> config = Worker.Application.worker_config(leader: :my_leader@host)
      iex> config[:leader]
      :my_leader@host
  """
  @spec worker_config(keyword()) :: keyword()
  def worker_config(opts \\ []) do
    base = [
      leader: resolve_leader(opts),
      cookie: resolve_cookie(opts),
      max_concurrent_runs: resolve_int(opts, :max_concurrent_runs, "max_concurrent_runs", 2)
    ]

    # Only add available_models if explicitly provided — let Capabilities.detect/1
    # auto-discover from ModelRegistry when omitted.
    base =
      case Keyword.get(opts, :available_models) do
        nil -> base
        models -> Keyword.put(base, :available_models, models)
      end

    base ++ Keyword.take(opts, @passthrough_opts)
  end

  # ── Application Callback ────────────────────────────────────────────────

  @impl true
  def start(_type, _args) do
    opts = Application.get_env(:code_puppy_control, :pack_worker_opts, [])

    case start_worker(opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stop(_state) do
    Application.put_env(:code_puppy_control, @worker_mode_key, false)
    Logger.info("[Worker.Application] stopped on #{inspect(Node.self())}")
    :ok
  end

  # ── Private: Config Resolution ──────────────────────────────────────────

  defp resolve_leader(opts) do
    case Keyword.get(opts, :leader) do
      nil -> cfg_atom("leader")
      val when is_atom(val) -> val
      val when is_binary(val) -> String.to_atom(String.trim(val))
      _other -> nil
    end
  end

  defp resolve_cookie(opts) do
    case Keyword.get(opts, :cookie) do
      nil -> cfg_string("cookie")
      val when is_atom(val) -> val
      val when is_binary(val) -> val
      _other -> nil
    end
  end

  defp resolve_int(opts, key, cfg_key, default) do
    case Keyword.get(opts, key) do
      nil ->
        case cfg_string(cfg_key) do
          nil ->
            default

          str ->
            case Integer.parse(str) do
              {n, _} when n > 0 -> n
              _ -> default
            end
        end

      val when is_integer(val) and val > 0 ->
        val

      _ ->
        default
    end
  end

  defp cfg_string(key) do
    ConfigLoader.get_value(@worker_config_section, key)
  end

  defp cfg_atom(key) do
    case cfg_string(key) do
      nil -> nil
      "" -> nil
      str -> String.to_atom(String.trim(str))
    end
  end

  # ── Private: Validation ─────────────────────────────────────────────────

  @doc """
  Validates a resolved worker config.

  Returns `:ok` if the config is valid, or `{:error, reason}` if not.
  Public so tests can assert on validation without starting the tree.
  """
  @spec validate_config(keyword()) :: :ok | {:error, term()}
  def validate_config(config) do
    cond do
      is_nil(config[:leader]) ->
        {:error, :missing_leader}

      not is_atom(config[:leader]) ->
        {:error, {:invalid_leader, config[:leader]}}

      true ->
        :ok
    end
  end

  @spec maybe_set_cookie(keyword()) :: :ok
  defp maybe_set_cookie(config) do
    case config[:cookie] do
      nil ->
        :ok

      cookie when is_binary(cookie) ->
        Node.set_cookie(String.to_atom(cookie))
        :ok

      cookie when is_atom(cookie) ->
        Node.set_cookie(cookie)
        :ok
    end
  end

  # ── Private: Child Spec Helpers ─────────────────────────────────────────

  defp worker_genserver_opts(config) do
    [
      name: :pack_worker,
      max_concurrent_runs: config[:max_concurrent_runs],
      available_models: config[:available_models]
    ]
  end

  defp node_monitor_opts(config) do
    leader = config[:leader]

    base_opts = [
      enabled: not is_nil(leader),
      # Worker-side NodeMonitor watches the leader, not a list of workers
      workers: if(leader, do: [Atom.to_string(leader)], else: [])
    ]

    # Allow test injection of mock functions
    Keyword.merge(base_opts, Keyword.take(config, [:connect_fn, :monitor_fn]))
  end

  # ── Dependency Boot ─────────────────────────────────────────────────────

  @doc false
  @spec ensure_required_apps_started() :: :ok | {:error, term()}
  def ensure_required_apps_started do
    Enum.reduce_while(@required_apps, :ok, fn app, :ok ->
      case Application.ensure_all_started(app) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:dependency_start_failed, app, reason}}}
      end
    end)
  end

  # ── Private: Leader Connection ──────────────────────────────────────────

  defp attempt_leader_connect(config) do
    leader = config[:leader]

    if leader do
      # Non-blocking — spawned so the supervision tree isn't held up
      Task.start(fn ->
        case Node.connect(leader) do
          true ->
            Logger.info("[Worker.Application] connected to leader #{inspect(leader)}")

          false ->
            Logger.warning(
              "[Worker.Application] could not connect to leader #{inspect(leader)} — " <>
                "NodeMonitor will retry on heartbeat"
            )

          :ignored ->
            Logger.warning(
              "[Worker.Application] Node.connect/1 returned :ignored for #{inspect(leader)} — " <>
                "is this node distributed? Start with --sname or --name"
            )
        end
      end)
    end

    :ok
  end
end
