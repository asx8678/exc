defmodule CodePuppyControl.Runtime.Limits do
  @moduledoc """
  Centralized runtime concurrency and process caps for the control plane.

  Every DynamicSupervisor `max_children`, `Task.async_stream` concurrency,
  and Finch pool sizing decision should route through this module instead of
  hard-coding values.

  ## Limits

  | Key | :laptop | :desktop | :server | Env Var |
  |-----|---------|----------|---------|---------|
  | `max_mcp_servers` | 12 | 24 | 48 | `PUP_MAX_MCP_SERVERS` |
  | `max_mcp_clients` | 12 | 24 | 48 | `PUP_MAX_MCP_CLIENTS` |
  | `max_runs` | 12 | 24 | 48 | `PUP_MAX_RUNS` |
  | `max_agent_states` | 256 | 512 | 1024 | `PUP_MAX_AGENT_STATES` |
  | `max_pty_sessions` | 6 | 12 | 24 | `PUP_MAX_PTY_SESSIONS` |
  | `cpu_concurrency` | 4 | 8 | schedulers | `PUP_CPU_CONCURRENCY` |
  | `io_concurrency` | 3 | 6 | 12 | `PUP_IO_CONCURRENCY` |
  | `finch_pool_count` | 4 | 8 | schedulers | `PUP_FINCH_POOL_COUNT` |
  | `finch_pool_size` | 25 | 50 | 50 | `PUP_FINCH_POOL_SIZE` |

  ## Resolution Order (highest priority first)

  1. Per-key env var (e.g. `PUP_MAX_MCP_SERVERS`) — parsed as integer, must be >= 1
  2. `Application.get_env(:code_puppy_control, :limits, [])` keyword list
  3. Profile defaults (selected by `PUP_PROFILE`, default `:laptop`)

  See CONTRIBUTING.md for naming conventions and extension guidelines.
  """

  require Logger

  # ── Types ────────────────────────────────────────────────────────────────

  @type profile :: :laptop | :desktop | :server
  @type limit_key ::
          :max_mcp_servers
          | :max_mcp_clients
          | :max_runs
          | :max_agent_states
          | :max_pty_sessions
          | :cpu_concurrency
          | :io_concurrency
          | :finch_pool_count
          | :finch_pool_size

  # ── Profile Presets ──────────────────────────────────────────────────────

  # `nil` means "resolve at runtime via System.schedulers_online()"
  @profile_defaults %{
    laptop: %{
      max_mcp_servers: 12,
      max_mcp_clients: 12,
      max_runs: 12,
      max_agent_states: 256,
      max_pty_sessions: 6,
      cpu_concurrency: 4,
      io_concurrency: 3,
      finch_pool_count: 4,
      finch_pool_size: 25
    },
    desktop: %{
      max_mcp_servers: 24,
      max_mcp_clients: 24,
      max_runs: 24,
      max_agent_states: 512,
      max_pty_sessions: 12,
      cpu_concurrency: 8,
      io_concurrency: 6,
      finch_pool_count: 8,
      finch_pool_size: 50
    },
    server: %{
      max_mcp_servers: 48,
      max_mcp_clients: 48,
      max_runs: 48,
      max_agent_states: 1024,
      max_pty_sessions: 24,
      cpu_concurrency: nil,
      io_concurrency: 12,
      finch_pool_count: nil,
      finch_pool_size: 50
    }
  }

  # ── Env var → key mapping ────────────────────────────────────────────────

  @env_var_map %{
    max_mcp_servers: "PUP_MAX_MCP_SERVERS",
    max_mcp_clients: "PUP_MAX_MCP_CLIENTS",
    max_runs: "PUP_MAX_RUNS",
    max_agent_states: "PUP_MAX_AGENT_STATES",
    max_pty_sessions: "PUP_MAX_PTY_SESSIONS",
    cpu_concurrency: "PUP_CPU_CONCURRENCY",
    io_concurrency: "PUP_IO_CONCURRENCY",
    finch_pool_count: "PUP_FINCH_POOL_COUNT",
    finch_pool_size: "PUP_FINCH_POOL_SIZE"
  }

  # ── Public API ───────────────────────────────────────────────────────────

  @doc "Returns the current profile atom (`:laptop`, `:desktop`, or `:server`)."
  @spec profile() :: profile()
  def profile do
    case System.get_env("PUP_PROFILE") do
      "desktop" -> :desktop
      "server" -> :server
      _ -> :laptop
    end
  end

  @doc "Returns the maximum number of MCP server processes."
  @spec max_mcp_servers() :: pos_integer()
  def max_mcp_servers, do: resolve(:max_mcp_servers)

  @doc "Returns the maximum number of MCP client processes."
  @spec max_mcp_clients() :: pos_integer()
  def max_mcp_clients, do: resolve(:max_mcp_clients)

  @doc "Returns the maximum number of concurrent runs."
  @spec max_runs() :: pos_integer()
  def max_runs, do: resolve(:max_runs)

  @doc "Returns the maximum number of agent state processes."
  @spec max_agent_states() :: pos_integer()
  def max_agent_states, do: resolve(:max_agent_states)

  @doc "Returns the maximum number of PTY sessions."
  @spec max_pty_sessions() :: pos_integer()
  def max_pty_sessions, do: resolve(:max_pty_sessions)

  @doc """
  Returns the CPU concurrency limit.

  Use for `Task.async_stream` of CPU-bound work (parsing, symbol extraction).
  """
  @spec cpu_concurrency() :: pos_integer()
  def cpu_concurrency, do: resolve(:cpu_concurrency)

  @doc """
  Returns the I/O concurrency limit.

  Use for `Task.async_stream` of I/O-bound work (file reads, directory walks).
  """
  @spec io_concurrency() :: pos_integer()
  def io_concurrency, do: resolve(:io_concurrency)

  @doc "Returns the Finch pool count (number of connection pools per host)."
  @spec finch_pool_count() :: pos_integer()
  def finch_pool_count, do: resolve(:finch_pool_count)

  @doc "Returns the Finch pool size (connections per pool)."
  @spec finch_pool_size() :: pos_integer()
  def finch_pool_size, do: resolve(:finch_pool_size)

  @doc """
  Returns a map of every limit key to its current resolved value.

  Includes the `:profile` key for introspection. Useful for the
  `/health/runtime` endpoint.
  """
  @spec all() :: %{profile: profile()} | %{limit_key() => pos_integer()}
  def all do
    limits =
      @env_var_map
      |> Map.keys()
      |> Map.new(fn key -> {key, resolve(key)} end)

    Map.put(limits, :profile, profile())
  end

  @doc """
  Pretty-prints a table of all current limits to stdout.

  Designed for use in `IEx` sessions:
      iex> CodePuppyControl.Runtime.Limits.report()
  """
  @spec report() :: :ok
  def report do
    current_profile = profile()
    app_env = Application.get_env(:code_puppy_control, :limits, [])

    rows =
      @env_var_map
      |> Enum.sort_by(fn {key, _var} -> Atom.to_string(key) end)
      |> Enum.map(fn {key, var} ->
        value = resolve(key)
        profile_default = profile_default_value(key, current_profile)
        source = source_label(key, var, app_env)

        %{
          "Key" => Atom.to_string(key),
          "Value" => to_string(value),
          "Source" => "#{source}: #{profile_default}",
          "Env Var" => var
        }
      end)

    table = Owl.Table.new(rows)
    Owl.IO.puts(table)
    :ok
  end

  # ── Resolution Logic ─────────────────────────────────────────────────────

  # Resolution order:
  #   1. Per-key env var (parsed as integer, must be >= 1)
  #   2. Application config (:code_puppy_control, :limits)
  #   3. Profile defaults (nil → System.schedulers_online())
  @spec resolve(limit_key()) :: pos_integer()
  defp resolve(key) do
    var_name = Map.fetch!(@env_var_map, key)

    # 1. Env var
    case parse_env_int(var_name) do
      {:ok, n} when n >= 1 ->
        n

      {:ok, n} ->
        Logger.warning("#{var_name}=#{n} is < 1, falling through to next source")
        resolve_from_app_config_or_profile(key)

      :error ->
        resolve_from_app_config_or_profile(key)
    end
  end

  @spec resolve_from_app_config_or_profile(limit_key()) :: pos_integer()
  defp resolve_from_app_config_or_profile(key) do
    env = Application.get_env(:code_puppy_control, :limits, [])

    # 2. Application config
    case Keyword.get(env, key) do
      nil ->
        # 3. Profile defaults
        resolve_profile_default(key)

      value when is_integer(value) and value >= 1 ->
        value

      value ->
        Logger.warning(
          "Application config :limits #{key}: #{inspect(value)} is invalid, using profile default"
        )

        resolve_profile_default(key)
    end
  end

  @spec resolve_profile_default(limit_key()) :: pos_integer()
  defp resolve_profile_default(key) do
    current_profile = profile()
    defaults = Map.fetch!(@profile_defaults, current_profile)
    value = Map.fetch!(defaults, key)
    resolve_dynamic_default(value)
  end

  # nil means "use System.schedulers_online()" (server profile for cpu/finch)
  @spec resolve_dynamic_default(pos_integer() | nil) :: pos_integer()
  defp resolve_dynamic_default(nil), do: System.schedulers_online()
  defp resolve_dynamic_default(n) when is_integer(n), do: n

  @spec profile_default_value(limit_key(), profile()) :: String.t()
  defp profile_default_value(key, current_profile) do
    defaults = Map.fetch!(@profile_defaults, current_profile)
    value = Map.fetch!(defaults, key)

    case value do
      nil -> "schedulers"
      n -> to_string(n)
    end
  end

  @spec source_label(limit_key(), String.t(), keyword()) :: String.t()
  defp source_label(key, var_name, app_env) do
    cond do
      System.get_env(var_name) != nil ->
        "env"

      Keyword.has_key?(app_env, key) ->
        "app"

      true ->
        "profile"
    end
  end

  @spec parse_env_int(String.t()) :: {:ok, integer()} | :error
  defp parse_env_int(var_name) do
    case System.get_env(var_name) do
      nil ->
        :error

      value ->
        case Integer.parse(value) do
          {n, ""} ->
            {:ok, n}

          _ ->
            Logger.warning(
              "#{var_name}=#{inspect(value)} is not a valid integer, falling through"
            )

            :error
        end
    end
  end
end
