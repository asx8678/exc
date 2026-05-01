defmodule CodePuppyControl.CLI.SlashCommands.Commands.Pack do
  @moduledoc """
  Pack slash command: /pack [pack_name | cluster [subcommand]].

  Shows current model pack and available packs, or switches to a named pack.
  Also provides `/pack cluster` for distributed cluster status.
  """

  alias CodePuppyControl.Config.Distributed, as: DistributedConfig
  alias CodePuppyControl.ModelPacks
  alias CodePuppyControl.Pack.NamingService

  @doc """
  Handles `/pack` — shows current pack and available packs.

  Handles `/pack <name>` — switches to the named pack and shows confirmation.
  """
  @spec handle_pack(String.t(), any()) :: {:continue, any()}
  def handle_pack(line, state) do
    case extract_args(line) |> String.trim() do
      "" ->
        show_current_pack()

      "cluster" ->
        show_cluster_status()

      "cluster " <> rest ->
        handle_cluster_subcommand(String.trim(rest))

      args ->
        pack_name = String.downcase(args)

        if String.contains?(pack_name, " ") do
          print_usage()
        else
          switch_pack(pack_name)
        end
    end

    {:continue, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp show_current_pack do
    current = ModelPacks.get_current_pack()
    packs = ModelPacks.list_packs()

    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "    Model Pack" <> IO.ANSI.reset())
    IO.puts("")
    IO.puts("    Current pack: #{IO.ANSI.cyan()}#{current.name}#{IO.ANSI.reset()}")
    IO.puts("    #{IO.ANSI.faint()}#{current.description}#{IO.ANSI.reset()}")
    IO.puts("")

    if map_size(current.roles) > 0 do
      IO.puts("    Current role configuration:")

      current.roles
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.each(fn {role_name, role_config} ->
        chain = format_chain(role_config)
        marker = if role_name == current.default_role, do: "→ ", else: "  "

        IO.puts(
          "    #{marker}#{IO.ANSI.cyan()}#{String.pad_trailing(role_name, 12)}#{IO.ANSI.reset()} #{chain}"
        )
      end)

      IO.puts("")
    end

    IO.puts("    Available packs:")

    Enum.each(packs, fn pack ->
      marker = if pack.name == current.name, do: "→ ", else: "  "

      IO.puts(
        "    #{marker}#{IO.ANSI.cyan()}#{String.pad_trailing(pack.name, 12)}#{IO.ANSI.reset()} " <>
          "#{IO.ANSI.faint()}#{pack.description}#{IO.ANSI.reset()}"
      )
    end)

    IO.puts("")
    IO.puts("    #{IO.ANSI.faint()}Use /pack <name> to switch packs#{IO.ANSI.reset()}")
    IO.puts("")
  end

  defp switch_pack(pack_name) do
    case ModelPacks.set_current_pack(pack_name) do
      :ok ->
        pack = ModelPacks.get_pack(pack_name)

        IO.puts("")
        IO.puts("    Switched to pack: #{IO.ANSI.cyan()}#{pack.name}#{IO.ANSI.reset()}")
        IO.puts("    #{IO.ANSI.faint()}#{pack.description}#{IO.ANSI.reset()}")
        IO.puts("")

        if map_size(pack.roles) > 0 do
          IO.puts("    Role configuration:")

          pack.roles
          |> Enum.sort_by(fn {name, _} -> name end)
          |> Enum.each(fn {role_name, role_config} ->
            chain = format_chain(role_config)

            IO.puts(
              "      #{IO.ANSI.cyan()}#{String.pad_trailing(role_name, 12)}#{IO.ANSI.reset()} #{chain}"
            )
          end)

          IO.puts("")
        end

      {:error, :not_found} ->
        available = ModelPacks.list_packs() |> Enum.map(& &1.name) |> Enum.join(", ")

        IO.puts(
          IO.ANSI.red() <>
            "    Unknown pack: '#{pack_name}'. Available: #{available}" <>
            IO.ANSI.reset()
        )
    end
  end

  defp print_usage do
    IO.puts(
      IO.ANSI.yellow() <>
        "    Usage: /pack [pack_name | cluster]" <> IO.ANSI.reset()
    )

    IO.puts(
      "    #{IO.ANSI.faint()}Use /pack without arguments to see current pack#{IO.ANSI.reset()}"
    )

    IO.puts(
      "    #{IO.ANSI.faint()}Use /pack cluster for distributed status#{IO.ANSI.reset()}"
    )
  end

  # ── Cluster Subcommand ──────────────────────────────────────────────────

  defp handle_cluster_subcommand("workers"), do: show_cluster_workers()
  defp handle_cluster_subcommand("config"), do: show_cluster_config()

  defp handle_cluster_subcommand(unknown) do
    IO.puts("")

    IO.puts(
      IO.ANSI.yellow() <>
        "    Unknown cluster subcommand: '#{unknown}'" <>
        IO.ANSI.reset()
    )

    IO.puts("    #{IO.ANSI.faint()}Available: /pack cluster [workers | config]#{IO.ANSI.reset()}")
    IO.puts("")
  end

  defp show_cluster_status do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "    \u{1F43A} Pack Cluster Status" <> IO.ANSI.reset())
    IO.puts("")

    dist_status = if Node.alive?(), do: "enabled", else: "disabled (not started)"
    IO.puts("    Distribution: #{IO.ANSI.cyan()}#{dist_status}#{IO.ANSI.reset()}")

    if Node.alive?() do
      IO.puts("    Node: #{IO.ANSI.cyan()}#{Node.self()}#{IO.ANSI.reset()}")
      IO.puts("    Cookie: #{IO.ANSI.faint()}●●●●●● (hidden)#{IO.ANSI.reset()}")
    end

    IO.puts("")
    render_worker_table()
    IO.puts("")
  end

  defp show_cluster_workers do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "    \u{1F43A} Pack Workers" <> IO.ANSI.reset())
    IO.puts("")

    case safe_list_nodes() do
      {:ok, []} ->
        IO.puts("    #{IO.ANSI.faint()}No workers connected.#{IO.ANSI.reset()}")

      {:ok, nodes} ->
        Enum.each(nodes, fn node ->
          caps = safe_node_capabilities(node)
          render_worker_detail(node, caps)
        end)

      {:error, reason} ->
        IO.puts(
          "    #{IO.ANSI.yellow()}NamingService unavailable: #{reason}#{IO.ANSI.reset()}"
        )
    end

    IO.puts("")
  end

  defp show_cluster_config do
    IO.puts("")
    IO.puts(IO.ANSI.bright() <> "    \u{1F43A} Distributed Config" <> IO.ANSI.reset())
    IO.puts("")

    enabled = DistributedConfig.enabled?()
    workers = DistributedConfig.workers()
    heartbeat = DistributedConfig.heartbeat_interval()
    disconnect = DistributedConfig.disconnect_timeout()
    connect = DistributedConfig.connect_timeout()

    IO.puts("    enabled:             #{IO.ANSI.cyan()}#{enabled}#{IO.ANSI.reset()}")
    IO.puts("    workers:             #{IO.ANSI.cyan()}#{format_workers_config(workers)}#{IO.ANSI.reset()}")
    IO.puts("    heartbeat_interval:  #{IO.ANSI.cyan()}#{heartbeat}ms#{IO.ANSI.reset()}")
    IO.puts("    disconnect_timeout:  #{IO.ANSI.cyan()}#{disconnect}ms#{IO.ANSI.reset()}")
    IO.puts("    connect_timeout:     #{IO.ANSI.cyan()}#{connect}ms#{IO.ANSI.reset()}")
    IO.puts("")
    IO.puts("    #{IO.ANSI.faint()}Source: puppy.cfg [packs.distributed] or PUP_DISTRIBUTED_* env#{IO.ANSI.reset()}")
    IO.puts("")
  end

  defp render_worker_table do
    case safe_list_nodes() do
      {:ok, []} ->
        IO.puts("    #{IO.ANSI.faint()}No workers connected.#{IO.ANSI.reset()}")

      {:ok, nodes} ->
        rows = Enum.map(nodes, &build_worker_row/1)
        render_table(rows)

      {:error, reason} ->
        IO.puts(
          "    #{IO.ANSI.yellow()}NamingService unavailable: #{reason}#{IO.ANSI.reset()}"
        )
    end
  end

  defp build_worker_row(node) do
    caps = safe_node_capabilities(node)
    os = Map.get(caps, :host_os, "unknown")

    max_runs = Map.get(caps, :max_concurrent_runs, "?")
    # We don't have live slot usage, so just show max
    slots = "0/#{max_runs}"

    models =
      caps
      |> Map.get(:available_models, [])
      |> Enum.join(", ")
      |> case do
        "" -> "-"
        m -> m
      end

    %{node: Atom.to_string(node), os: to_string(os), slots: slots, models: models}
  end

  defp render_table(rows) do
    # Calculate column widths
    headers = %{node: "Node", os: "OS", slots: "Slots", models: "Models"}

    widths = %{
      node: max_width(rows, :node, headers.node),
      os: max_width(rows, :os, headers.os),
      slots: max_width(rows, :slots, headers.slots),
      models: max_width(rows, :models, headers.models)
    }

    # Top border
    IO.puts("    \u250C#{bar(widths.node)}\u252C#{bar(widths.os)}\u252C#{bar(widths.slots)}\u252C#{bar(widths.models)}\u2510")
    # Header row
    IO.puts("    \u2502#{cell(headers.node, widths.node)}\u2502#{cell(headers.os, widths.os)}\u2502#{cell(headers.slots, widths.slots)}\u2502#{cell(headers.models, widths.models)}\u2502")
    # Separator
    IO.puts("    \u251C#{bar(widths.node)}\u253C#{bar(widths.os)}\u253C#{bar(widths.slots)}\u253C#{bar(widths.models)}\u2524")

    # Data rows
    Enum.each(rows, fn row ->
      IO.puts("    \u2502#{cell(row.node, widths.node)}\u2502#{cell(row.os, widths.os)}\u2502#{cell(row.slots, widths.slots)}\u2502#{cell(row.models, widths.models)}\u2502")
    end)

    # Bottom border
    IO.puts("    \u2514#{bar(widths.node)}\u2534#{bar(widths.os)}\u2534#{bar(widths.slots)}\u2534#{bar(widths.models)}\u2518")
  end

  defp render_worker_detail(node, caps) do
    node_str = Atom.to_string(node)
    os = Map.get(caps, :host_os, "unknown")
    agents = Map.get(caps, :sub_agents, []) |> Enum.map(&to_string/1) |> Enum.join(", ")
    models = Map.get(caps, :available_models, []) |> Enum.join(", ")
    max_runs = Map.get(caps, :max_concurrent_runs, "?")

    IO.puts("    #{IO.ANSI.cyan()}#{node_str}#{IO.ANSI.reset()}")
    IO.puts("      OS:         #{os}")
    IO.puts("      Agents:     #{if agents == "", do: "-", else: agents}")
    IO.puts("      Models:     #{if models == "", do: "-", else: models}")
    IO.puts("      Max slots:  #{max_runs}")
    IO.puts("")
  end

  # ── Cluster Helpers ─────────────────────────────────────────────────────

  defp safe_list_nodes do
    {:ok, NamingService.list_nodes()}
  rescue
    _ -> {:error, "not started"}
  catch
    :exit, _ -> {:error, "not started"}
  end

  defp safe_node_capabilities(node) do
    NamingService.node_capabilities(node) || %{}
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp format_workers_config([]), do: "(none)"
  defp format_workers_config(workers), do: Enum.join(workers, ", ")

  defp max_width(rows, key, header) do
    row_max = rows |> Enum.map(&String.length(Map.get(&1, key, ""))) |> Enum.max(fn -> 0 end)
    max(row_max, String.length(header)) + 2
  end

  defp bar(width), do: String.duplicate("\u2500", width)
  defp cell(text, width), do: " " <> String.pad_trailing(text, width - 1)

  defp format_chain(role_config) do
    primary = role_config.primary
    fallbacks = role_config.fallbacks || []

    if fallbacks == [] do
      primary
    else
      # Show at most 2 fallbacks inline, like the Python version
      {shown, extra} =
        case fallbacks do
          [a, b | rest] -> {[a, b], length(rest)}
          list -> {list, 0}
        end

      chain = Enum.join([primary | shown], " → ")

      if extra > 0 do
        "#{chain} (+#{extra} more)"
      else
        chain
      end
    end
  end

  @spec extract_args(String.t()) :: String.t()
  defp extract_args("/" <> rest) do
    case String.split(rest, " ", parts: 2) do
      [_name] -> ""
      [_name, args] -> args
    end
  end

  defp extract_args(_line), do: ""
end
