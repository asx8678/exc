defmodule CodePuppyControl.CLI.SlashCommands.Commands.PackCluster do
  @moduledoc """
  Pack cluster slash command: /pack cluster [status|nodes|capabilities].

  Shows distributed pack cluster status, connected workers, and capabilities.

  (Phase I.2 — code_puppy-yge.2)
  """

  alias CodePuppyControl.Pack.{Config, NodeMonitor, NamingService}

  @doc """
  Handles `/pack cluster` — shows cluster status, node list, or capabilities.
  """
  @spec handle_cluster(String.t(), any()) :: {:continue, any()}
  def handle_cluster(subcmd, state) do
    case String.trim(subcmd) do
      "" -> show_status()
      "status" -> show_status()
      "nodes" -> show_nodes()
      "capabilities" -> show_capabilities()
      _ -> show_unknown(subcmd)
    end

    {:continue, state}
  end

  # ── Subcommands ──────────────────────────────────────────────────────────

  defp show_status do
    if Config.enabled?() do
      nodes = NodeMonitor.status()
      total = map_size(nodes)
      connected = Enum.count(nodes, fn {_n, info} -> info.status == :connected end)

      IO.puts("")
      IO.puts(IO.ANSI.bright() <> "    Pack Cluster" <> IO.ANSI.reset())
      IO.puts("")
      IO.puts("    Status:    #{IO.ANSI.green()}enabled#{IO.ANSI.reset()}")
      IO.puts("    Workers:   #{connected} connected / #{total} configured")
      IO.puts("    Self:      #{inspect(Node.self())}")
      IO.puts("    Cookie:    #{inspect(Node.get_cookie())}")
      IO.puts("")
      IO.puts("    #{IO.ANSI.faint()}Use /pack cluster nodes for details#{IO.ANSI.reset()}")

      IO.puts(
        "    #{IO.ANSI.faint()}Use /pack cluster capabilities for agent matrix#{IO.ANSI.reset()}"
      )

      IO.puts("")
    else
      IO.puts("")
      IO.puts(IO.ANSI.bright() <> "    Pack Cluster" <> IO.ANSI.reset())
      IO.puts("")
      IO.puts("    Status:    #{IO.ANSI.faint()}disabled#{IO.ANSI.reset()}")
      IO.puts("")

      IO.puts(
        "    #{IO.ANSI.faint()}Enable with: packs.distributed.enabled = true#{IO.ANSI.reset()}"
      )

      IO.puts("")
    end
  end

  defp show_nodes do
    if Config.enabled?() do
      nodes = NodeMonitor.status()

      IO.puts("")
      IO.puts(IO.ANSI.bright() <> "    Cluster Nodes" <> IO.ANSI.reset())
      IO.puts("")

      if map_size(nodes) == 0 do
        IO.puts("    #{IO.ANSI.faint()}No workers configured#{IO.ANSI.reset()}")
      else
        nodes
        |> Enum.sort_by(fn {node, _info} -> node end)
        |> Enum.each(fn {node, info} ->
          status_color = status_color(info.status)
          status_str = String.pad_trailing("#{info.status}", 14)

          IO.write("    #{status_color}#{status_str}#{IO.ANSI.reset()}")
          IO.write("#{IO.ANSI.cyan()}#{inspect(node)}#{IO.ANSI.reset()}")

          if info.connected_at do
            elapsed = System.monotonic_time(:millisecond) - info.connected_at
            IO.write(" (up #{format_duration(elapsed)})")
          end

          IO.puts("")

          if info.capabilities do
            agents = Map.get(info.capabilities, :sub_agent_names, [])
            os = Map.get(info.capabilities, :host_os, "unknown")

            IO.puts(
              "      #{IO.ANSI.faint()}os=#{os}  agents=#{inspect(agents)}#{IO.ANSI.reset()}"
            )
          end
        end)
      end

      IO.puts("")
    else
      show_disabled()
    end
  end

  defp show_capabilities do
    if Config.enabled?() do
      all_caps = NamingService.all_capabilities()

      IO.puts("")
      IO.puts(IO.ANSI.bright() <> "    Capability Matrix" <> IO.ANSI.reset())
      IO.puts("")

      if map_size(all_caps) == 0 do
        IO.puts("    #{IO.ANSI.faint()}No worker capabilities registered#{IO.ANSI.reset()}")
      else
        # Collect all unique sub-agent types across all workers
        all_agent_types =
          all_caps
          |> Enum.flat_map(fn {_node, caps} -> Map.get(caps, :sub_agent_names, []) end)
          |> Enum.uniq()
          |> Enum.sort()

        # Header row
        header = "    #{String.pad_trailing("Node", 28)}"
        columns = Enum.map(all_agent_types, &String.pad_trailing("#{&1}", 12))
        IO.puts(header <> Enum.join(columns))

        # Each worker row
        all_caps
        |> Enum.sort_by(fn {node, _caps} -> node end)
        |> Enum.each(fn {node, caps} ->
          node_str = String.pad_trailing("    #{inspect(node)}", 28)
          agents = Map.get(caps, :sub_agent_names, [])

          columns =
            Enum.map(all_agent_types, fn agent_type ->
              if agent_type in agents do
                "#{IO.ANSI.green()}✓#{IO.ANSI.reset()}          "
              else
                "✗          "
              end
            end)

          IO.puts(node_str <> Enum.join(columns))
        end)
      end

      IO.puts("")
    else
      show_disabled()
    end
  end

  defp show_unknown(subcmd) do
    IO.puts(
      IO.ANSI.yellow() <>
        "    Unknown subcommand: '#{subcmd}'" <> IO.ANSI.reset()
    )

    IO.puts("")
    IO.puts("    Available: status, nodes, capabilities")
    IO.puts("")
  end

  defp show_disabled do
    IO.puts(
      IO.ANSI.yellow() <>
        "    Pack cluster is disabled" <> IO.ANSI.reset()
    )

    IO.puts("")

    IO.puts(
      "    #{IO.ANSI.faint()}Enable with: packs.distributed.enabled = true#{IO.ANSI.reset()}"
    )

    IO.puts("")
  end

  # ── Formatting Helpers ──────────────────────────────────────────────────

  defp status_color(:connected), do: IO.ANSI.green()
  defp status_color(:connecting), do: IO.ANSI.yellow()
  defp status_color(:disconnected), do: IO.ANSI.red()
  defp status_color(_), do: IO.ANSI.faint()

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp format_duration(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m"
  defp format_duration(ms), do: "#{div(ms, 3_600_000)}h"
end
