defmodule CodePuppyControl.Pack.ClusterStatus do
  @moduledoc """
  Aggregates cluster state from all pack subsystems into a single
  status snapshot. Used by the `/pack-cluster` command and telemetry
  dashboard.

  (Phase I.5 — code_puppy-yge.2)
  """

  alias CodePuppyControl.Pack.{Config, NamingService, LoadBalancer, NodeMonitor, TLS}

  # ── Types ────────────────────────────────────────────────────────────────

  @type node_status :: %{
          node: node(),
          status: :connected | :disconnected | :shutting_down | :unknown,
          capabilities: map() | nil,
          active_dispatches: non_neg_integer(),
          max_concurrent: pos_integer(),
          available_slots: integer(),
          active_runs: [String.t()],
          total_dispatches: non_neg_integer(),
          total_completions: non_neg_integer(),
          total_failures: non_neg_integer()
        }

  @type cluster_snapshot :: %{
          enabled: boolean(),
          tls_enabled: boolean(),
          local_node: node(),
          configured_workers: [node()],
          connected_workers: [node_status()],
          disconnected_workers: [node_status()],
          total_active_dispatches: non_neg_integer(),
          total_available_slots: non_neg_integer(),
          dispatch_style: atom()
        }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Returns a complete cluster status snapshot.
  """
  @spec snapshot() :: cluster_snapshot()
  def snapshot do
    config = Config.load()
    workers = Config.workers()

    # Gather per-node status from all subsystems
    node_statuses =
      Enum.map(workers, fn worker ->
        monitor_status = safe_node_monitor_status(worker)
        load_info = safe_load_info(worker)
        capabilities = safe_capabilities(worker)

        %{
          node: worker,
          status: get_status(monitor_status),
          capabilities: capabilities,
          active_dispatches: get_in_load(load_info, :active_dispatches, 0),
          max_concurrent: get_in_load(load_info, :max_concurrent, 4),
          available_slots: safe_available_slots(worker),
          active_runs: get_active_runs(monitor_status),
          total_dispatches: get_in_load(load_info, :total_dispatches, 0),
          total_completions: get_in_load(load_info, :total_completions, 0),
          total_failures: get_in_load(load_info, :total_failures, 0)
        }
      end)

    connected = Enum.filter(node_statuses, &(&1.status == :connected))
    disconnected = Enum.filter(node_statuses, &(&1.status != :connected))

    %{
      enabled: config.enabled == true,
      tls_enabled: TLS.enabled?(),
      local_node: Node.self(),
      configured_workers: workers,
      connected_workers: connected,
      disconnected_workers: disconnected,
      total_active_dispatches: Enum.sum(Enum.map(connected, & &1.active_dispatches)),
      total_available_slots: Enum.sum(Enum.map(connected, & &1.available_slots)),
      dispatch_style: Map.get(config, :dispatch_style, :async)
    }
  end

  @doc """
  Formats a cluster snapshot as a human-readable string.
  Suitable for terminal display.
  """
  @spec format(cluster_snapshot()) :: String.t()
  def format(snapshot) do
    lines = [
      "╔══════════════════════════════════════════════╗",
      "║          Pack Cluster Status                 ║",
      "╠══════════════════════════════════════════════╣",
      "║ Enabled:    #{pad_bool(snapshot.enabled)}                           ║",
      "║ TLS:        #{pad_bool(snapshot.tls_enabled)}                           ║",
      "║ Local Node: #{pad(inspect(snapshot.local_node), 32)}║",
      "║ Dispatch:   #{pad(to_string(snapshot.dispatch_style), 32)}║",
      "╠══════════════════════════════════════════════╣",
      "║ Connected Workers: #{pad(Integer.to_string(length(snapshot.connected_workers)), 25)}║",
      "║ Disconnected:      #{pad(Integer.to_string(length(snapshot.disconnected_workers)), 25)}║",
      "║ Active Dispatches:  #{pad(Integer.to_string(snapshot.total_active_dispatches), 24)}║",
      "║ Available Slots:    #{pad(Integer.to_string(snapshot.total_available_slots), 24)}║"
    ]

    worker_lines =
      Enum.flat_map(snapshot.connected_workers ++ snapshot.disconnected_workers, fn w ->
        status_icon =
          case w.status do
            :connected -> "🟢"
            :disconnected -> "🔴"
            :shutting_down -> "🟡"
            _ -> "⚪"
          end

        [
          "╠──────────────────────────────────────────────╣",
          "║ #{status_icon} #{pad(inspect(w.node), 42)}║",
          "║    Slots: #{pad("#{w.active_dispatches}/#{w.max_concurrent}", 34)}║",
          "║    Runs:  #{pad("#{w.total_dispatches} dispatched, #{w.total_completions} done, #{w.total_failures} failed", 34)}║"
        ]
      end)

    footer = [
      "╚══════════════════════════════════════════════╝"
    ]

    Enum.join(lines ++ worker_lines ++ footer, "\n")
  end

  @doc """
  Formats a compact one-line summary.
  """
  @spec summary(cluster_snapshot()) :: String.t()
  def summary(snapshot) do
    connected = length(snapshot.connected_workers)
    total = length(snapshot.configured_workers)
    tls = if snapshot.tls_enabled, do: " TLS", else: ""

    "Pack cluster: #{connected}/#{total} workers, " <>
      "#{snapshot.total_active_dispatches} active, " <>
      "#{snapshot.total_available_slots} slots#{tls}"
  end

  # ── Private: Safe Subsystem Access ──────────────────────────────────────

  defp safe_node_monitor_status(worker) do
    NodeMonitor.node_status(worker)
  catch
    :exit, _ -> nil
  end

  defp safe_load_info(worker) do
    snapshot = LoadBalancer.load_snapshot()
    Map.get(snapshot, worker)
  catch
    :exit, _ -> nil
  end

  defp safe_capabilities(worker) do
    NamingService.node_capabilities(worker)
  catch
    :exit, _ -> nil
  end

  defp safe_available_slots(worker) do
    LoadBalancer.available_slots(worker)
  catch
    :exit, _ -> 0
  end

  defp get_status(nil), do: :unknown
  defp get_status(%{status: status}), do: status
  defp get_status(_), do: :unknown

  defp get_in_load(nil, _key, default), do: default

  defp get_in_load(info, key, default) do
    Map.get(info, key, default)
  end

  defp get_active_runs(nil), do: []
  defp get_active_runs(%{active_runs: runs}), do: runs
  defp get_active_runs(_), do: []

  # ── Private: Formatting Helpers ─────────────────────────────────────────

  defp pad_bool(true), do: "yes"
  defp pad_bool(false), do: "no"

  defp pad(str, len) do
    # Truncate or pad to exactly `len` characters
    padded = String.pad_trailing(str, len)
    String.slice(padded, 0, len)
  end
end
