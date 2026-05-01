defmodule CodePuppyControl.Pack.Worker.Capabilities do
  @moduledoc """
  Auto-detects worker node capabilities for advertisement to the leader.

  Introspects the runtime environment to build a capabilities map
  compatible with `NamingService.register_node/2`.

  Each detection function falls back gracefully when its dependency
  (e.g. `AgentCatalogue`, `ModelRegistry`) is unavailable — the worker
  should always boot, even on a bare node.
  """

  @default_sub_agents [
    :code_puppy,
    :shepherd,
    :watchdog,
    :terrier,
    :retriever,
    :bloodhound
  ]

  @max_concurrent_cap 4

  @doc """
  Detect capabilities from the current runtime environment.

  Returns a map compatible with `NamingService.register_node/2`:

      %{
        sub_agents: [:code_puppy, :shepherd, :watchdog, ...],
        host_os: "darwin" | "linux" | "windows",
        max_concurrent_runs: pos_integer(),
        available_models: [String.t()],
        beam_version: String.t(),
        node_name: atom(),
        started_at: DateTime.t()
      }

  ## Overrides

  Any key can be pinned via the keyword list, bypassing auto-detection:

    * `:host_os` — atom or string (atoms are stringified)
    * `:sub_agents` — list of atoms
    * `:available_models` — list of model name strings
    * `:max_concurrent_runs` — positive integer

  Keys not listed above (`:beam_version`, `:node_name`, `:started_at`)
  are always detected from the runtime and cannot be overridden.
  """
  @spec detect(keyword()) :: map()
  def detect(overrides \\ []) do
    %{
      host_os: resolve_host_os(overrides),
      sub_agents: resolve_sub_agents(overrides),
      available_models: resolve_available_models(overrides),
      max_concurrent_runs: resolve_max_concurrent_runs(overrides),
      beam_version: beam_version(),
      node_name: Node.self(),
      started_at: DateTime.utc_now()
    }
  end

  # ── Host OS ──────────────────────────────────────────────────────────

  defp resolve_host_os(overrides) do
    case Keyword.get(overrides, :host_os) do
      nil -> os_from_system()
      os when is_atom(os) -> Atom.to_string(os)
      os when is_binary(os) -> os
    end
  end

  defp os_from_system do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:unix, :linux} -> "linux"
      {:win32, _} -> "windows"
      _ -> "unknown"
    end
  end

  # ── Sub-Agents ───────────────────────────────────────────────────────

  defp resolve_sub_agents(overrides) do
    case Keyword.get(overrides, :sub_agents) do
      agents when is_list(agents) -> agents
      _ -> discover_sub_agents()
    end
  end

  defp discover_sub_agents do
    agents =
      CodePuppyControl.Tools.AgentCatalogue.list_agents()
      |> Enum.map(fn info -> String.to_atom(info.name) end)

    if agents == [], do: @default_sub_agents, else: agents
  rescue
    _ -> @default_sub_agents
  catch
    :exit, _ -> @default_sub_agents
  end

  # ── Available Models ─────────────────────────────────────────────────

  defp resolve_available_models(overrides) do
    case Keyword.get(overrides, :available_models) do
      models when is_list(models) -> models
      _ -> discover_models()
    end
  end

  defp discover_models do
    CodePuppyControl.ModelRegistry.list_model_names()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # ── Max Concurrent Runs ──────────────────────────────────────────────

  defp resolve_max_concurrent_runs(overrides) do
    case Keyword.get(overrides, :max_concurrent_runs) do
      n when is_integer(n) and n > 0 -> n
      _ -> min(System.schedulers_online(), @max_concurrent_cap)
    end
  end

  # ── Static Runtime Info ──────────────────────────────────────────────

  defp beam_version do
    :erlang.system_info(:version) |> List.to_string()
  end
end
