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

  Default: `false`
  """
  @spec enabled?() :: boolean()
  def enabled? do
    get("enabled", "false") |> truthy?()
  end

  @doc """
  Returns the list of configured worker node name strings.

  Accepts comma-separated values in config, e.g. `worker1@host1,worker2@host2`.

  Default: `[]`
  """
  @spec workers() :: [String.t()]
  def workers do
    get("workers", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end

  @doc """
  Returns the heartbeat interval in milliseconds.

  Default: `15000`
  """
  @spec heartbeat_interval() :: pos_integer()
  def heartbeat_interval, do: get_int("heartbeat_interval", 15_000)

  @doc """
  Returns the disconnect timeout (grace period) in milliseconds.

  Default: `30000`
  """
  @spec disconnect_timeout() :: pos_integer()
  def disconnect_timeout, do: get_int("disconnect_timeout", 30_000)

  @doc """
  Returns the connect timeout in milliseconds.

  Default: `5000`
  """
  @spec connect_timeout() :: pos_integer()
  def connect_timeout, do: get_int("connect_timeout", 5_000)

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
