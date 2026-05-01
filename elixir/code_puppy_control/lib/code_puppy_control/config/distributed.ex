defmodule CodePuppyControl.Config.Distributed do
  @moduledoc """
  Distributed pack configuration from `puppy.cfg`.

  Reads the `[packs.distributed]` section for remote worker cluster settings.
  Falls back to defaults when the config key is missing.

  ## Config keys in `puppy.cfg`

  ```ini
  [packs.distributed]
  enabled = false
  workers = worker1@host1,worker2@host2
  heartbeat_interval = 15000
  disconnect_timeout = 30000
  connect_timeout = 5000
  ```

  ## Precedence

  1. Application env (`:code_puppy_control, :distributed_packs`)
  2. `puppy.cfg` section `[packs.distributed]`
  3. Hard-coded defaults documented below
  """

  alias CodePuppyControl.Config.Loader

  @section "packs.distributed"

  @doc """
  Returns `true` if distributed pack support is enabled.

  Precedence:
  1. `PUP_DISTRIBUTED_ENABLED` env var
  2. `puppy.cfg` section `[packs.distributed]`
  3. Default: `false`
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("PUP_DISTRIBUTED_ENABLED") do
      val when val in ~w(true 1 yes) ->
        true

      val when val in ~w(false 0 no) ->
        false

      _ ->
        get("enabled", "false") |> truthy?()
    end
  end

  @doc """
  Returns the list of configured worker node name strings.

  Precedence:
  1. `PUP_DISTRIBUTED_WORKERS` env var (comma-separated)
  2. `puppy.cfg` section `[packs.distributed]`
  3. Default: `[]`

  Accepts comma-separated values in config, e.g. `worker1@host1,worker2@host2`.
  """
  @spec workers() :: [String.t()]
  def workers do
    case System.get_env("PUP_DISTRIBUTED_WORKERS") do
      nil ->
        get("workers", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      "" ->
        []

      str when is_binary(str) ->
        str
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
    end
  end

  @doc """
  Returns the heartbeat interval in milliseconds.

  Precedence:
  1. `PUP_DISTRIBUTED_HEARTBEAT_INTERVAL` env var
  2. `puppy.cfg` section `[packs.distributed]`
  3. Default: `15000`
  """
  @spec heartbeat_interval() :: pos_integer()
  def heartbeat_interval do
    case env_int("PUP_DISTRIBUTED_HEARTBEAT_INTERVAL") do
      {:ok, val} when val > 0 -> val
      _ -> get_int("heartbeat_interval", 15_000)
    end
  end

  @doc """
  Returns the disconnect timeout (grace period) in milliseconds.

  Precedence:
  1. `PUP_DISTRIBUTED_DISCONNECT_TIMEOUT` env var
  2. `puppy.cfg` section `[packs.distributed]`
  3. Default: `30000`
  """
  @spec disconnect_timeout() :: pos_integer()
  def disconnect_timeout do
    case env_int("PUP_DISTRIBUTED_DISCONNECT_TIMEOUT") do
      {:ok, val} when val > 0 -> val
      _ -> get_int("disconnect_timeout", 30_000)
    end
  end

  @doc """
  Returns the connect timeout in milliseconds.

  Precedence:
  1. `PUP_DISTRIBUTED_CONNECT_TIMEOUT` env var
  2. `puppy.cfg` section `[packs.distributed]`
  3. Default: `5000`
  """
  @spec connect_timeout() :: pos_integer()
  def connect_timeout do
    case env_int("PUP_DISTRIBUTED_CONNECT_TIMEOUT") do
      {:ok, val} when val > 0 -> val
      _ -> get_int("connect_timeout", 5_000)
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @truthy_values MapSet.new(["1", "true", "yes", "on"])

  defp get(key, default) do
    case Loader.get_value(@section, key) do
      nil -> default
      val -> String.trim(val)
    end
  end

  defp truthy?(val) when is_binary(val) do
    String.downcase(String.trim(val)) in @truthy_values
  end

  defp truthy?(val), do: !!val

  defp env_int(var) do
    case System.get_env(var) do
      nil ->
        :error

      "" ->
        :error

      str ->
        case Integer.parse(String.trim(str)) do
          {n, _} when n > 0 -> {:ok, n}
          _ -> :error
        end
    end
  end

  defp get_int(key, default) do
    case Loader.get_value(@section, key) do
      nil ->
        default

      val ->
        case Integer.parse(String.trim(val)) do
          {n, _} when n > 0 -> n
          _ -> default
        end
    end
  end
end
