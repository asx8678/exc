defmodule CodePuppyControl.TUI.Widgets.AgentSelector do
  @moduledoc """
  Interactive agent selection widget.

  Presents the user with a list of available agents from the AgentCatalogue,
  and returns the selected agent slug (kebab-case) for REPL state.

  ## Usage

      # Simple interactive selection
      AgentSelector.select()

      # With options
      AgentSelector.select(default: "code-puppy", label: "Pick an agent")

      # Just list agents without prompting
      AgentSelector.list_agents()

  ## Architecture

  - `list_agents/0` — queries `AgentCatalogue.list_agents/0` and enriches
    each entry with a kebab-case slug for REPL state compatibility.
  - `select/1` — renders a table of agents, then uses `Owl.IO.select/2`
    for interactive picking. Falls back to `IO.gets/1` when Owl isn't
    available (e.g. piped input).

  ## Slug Convention

  AgentCatalogue stores names in snake_case (e.g. `"code_puppy"`). The REPL
  state uses kebab-case (e.g. `"code-puppy"`). This widget converts between
  the two: display names are human-friendly (`"Code Puppy"`), and the
  returned slug is kebab-case for REPL compatibility.
  """

  alias CodePuppyControl.Tools.AgentCatalogue

  # ── Types ──────────────────────────────────────────────────────────────────

  @type agent_entry :: %{
          name: String.t(),
          slug: String.t(),
          display_name: String.t(),
          description: String.t(),
          module: module() | nil
        }

  @type select_opt ::
          {:filter, String.t()}
          | {:default, String.t()}
          | {:label, String.t()}

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Interactively select an agent from the available list.

  Returns `{:ok, agent_slug}` on selection or `:cancelled` if the user
  aborts (empty input, Ctrl+D, etc.).

  ## Options

    * `:filter`  — substring filter on agent name or display name (default: no filter)
    * `:default` — pre-selected agent slug (highlighted in display)
    * `:label`   — prompt label (default: "Select an agent")
  """
  @spec select([select_opt()]) :: {:ok, String.t()} | :cancelled
  def select(opts \\ []) do
    filter = Keyword.get(opts, :filter)
    default = Keyword.get(opts, :default)
    label = Keyword.get(opts, :label, "Select an agent")

    case list_agents(filter: filter) do
      [] ->
        Owl.IO.puts(Owl.Data.tag("\n  No agents available.\n", :red))
        :cancelled

      agents ->
        render_agent_table(agents, default)

        slugs = Enum.map(agents, & &1.slug)

        if default && default in slugs do
          Owl.IO.puts([
            Owl.Data.tag("\n  Default: ", [:faint]),
            Owl.Data.tag(default, [:bright, :green])
          ])
        end

        case interactive_select(agents, slugs, label) do
          nil -> :cancelled
          slug -> {:ok, slug}
        end
    end
  end

  @doc """
  List available agents with enriched metadata.

  Returns a list of `agent_entry` maps sorted by name. Each entry includes
  the catalogue name (snake_case), a kebab-case slug for REPL state,
  a human-friendly display name, and a description.

  ## Options

    * `:filter` — substring filter on name or display name (case-insensitive)
  """
  @spec list_agents([{:filter, String.t()}]) :: [agent_entry()]
  def list_agents(opts \\ []) do
    filter = Keyword.get(opts, :filter)

    AgentCatalogue.list_agents()
    |> Enum.map(&enrich_agent/1)
    |> maybe_filter(filter)
  end

  # ── Private: Enrich ──────────────────────────────────────────────────────

  defp enrich_agent(%AgentCatalogue.AgentInfo{} = info) do
    %{
      name: info.name,
      slug: to_slug(info.name),
      display_name: info.display_name,
      description: info.description,
      module: info.module
    }
  end

  # Convert snake_case catalogue name to kebab-case REPL slug.
  # "code_puppy" → "code-puppy", "pack_leader" → "pack-leader"
  @spec to_slug(String.t()) :: String.t()
  defp to_slug(name) when is_binary(name) do
    String.replace(name, "_", "-")
  end

  defp maybe_filter(agents, nil), do: agents

  defp maybe_filter(agents, filter) do
    downcased = String.downcase(filter)

    Enum.filter(agents, fn agent ->
      String.downcase(agent.name) =~ downcased or
        String.downcase(agent.slug) =~ downcased or
        String.downcase(agent.display_name) =~ downcased
    end)
  end

  # ── Private: Table Rendering ─────────────────────────────────────────────

  defp render_agent_table(agents, default) do
    header = render_header()

    rows =
      agents
      |> Enum.with_index(1)
      |> Enum.map(fn {agent, idx} -> render_agent_row(agent, idx, default) end)

    table = build_table(rows)

    Owl.IO.puts([header, "\n", table, "\n"])
  end

  defp render_header do
    Owl.Box.new(
      Owl.Data.tag(" 🐕 Agent Selector ", [:bright, :cyan]),
      min_width: 60,
      border: :bottom,
      border_color: :cyan
    )
  end

  defp render_agent_row(agent, idx, default) do
    default_marker = if agent.slug == default, do: " ★", else: ""

    name_part =
      if agent.slug == default do
        Owl.Data.tag(" #{idx}. #{agent.display_name}#{default_marker}", [:bright, :green])
      else
        Owl.Data.tag(" #{idx}. #{agent.display_name}", :cyan)
      end

    slug_part = Owl.Data.tag(" (#{agent.slug})", :faint)
    desc_part = Owl.Data.tag(" — #{agent.description}", :faint)

    [name_part, slug_part, desc_part]
  end

  defp build_table(rows) do
    if function_exported?(Owl.Table, :new, 1) and
         not Application.get_env(:code_puppy_control, :force_build_table_fallback, false) do
      Owl.Table.new(rows)
    else
      # Fallback: extract plain text from Owl.Data tags
      rows
      |> Enum.map(fn row ->
        plain =
          row
          |> Enum.map(fn
            %Owl.Tag{data: data} -> data
            other -> to_string(other)
          end)
          |> Enum.join("")

        ["  ", plain, "\n"]
      end)
    end
  end

  # ── Private: Interactive Selection ────────────────────────────────────────

  defp interactive_select(agents, slugs, label) do
    if function_exported?(Owl.IO, :select, 2) and
         not Application.get_env(:code_puppy_control, :force_fallback_select, false) do
      owl_select(agents, slugs, label)
    else
      fallback_select(agents, slugs, label)
    end
  end

  defp owl_select(agents, slugs, label) do
    # Owl.IO.select works with display strings; we map the selection back
    # to the agent slug.
    display_items = Enum.map(agents, & &1.display_name)

    try do
      case Owl.IO.select(display_items, label: Owl.Data.tag(" #{label}", [:bright, :yellow])) do
        nil -> nil
        selected_display -> slug_for_display(agents, selected_display)
      end
    rescue
      _ -> fallback_select(agents, slugs, label)
    end
  end

  defp fallback_select(agents, slugs, label) do
    Owl.IO.puts(
      Owl.Data.tag("\n  #{label} (enter number or name, blank to cancel):", [:bright, :yellow])
    )

    case IO.gets("  > ") do
      :eof ->
        nil

      {:error, _} ->
        nil

      input ->
        trimmed = String.trim(input)

        cond do
          trimmed == "" -> nil
          trimmed in slugs -> trimmed
          true -> parse_selection(trimmed, agents, slugs)
        end
    end
  end

  defp parse_selection(input, agents, slugs) do
    case Integer.parse(input) do
      {num, ""} when num >= 1 and num <= length(slugs) ->
        Enum.at(slugs, num - 1)

      _ ->
        # Try fuzzy match on display name, slug, or catalogue name
        downcased = String.downcase(input)

        Enum.find_value(agents, fn agent ->
          if String.downcase(agent.display_name) =~ downcased or
               String.downcase(agent.slug) =~ downcased or
               String.downcase(agent.name) =~ downcased do
            agent.slug
          end
        end)
    end
  end

  defp slug_for_display(agents, display_name) do
    case Enum.find(agents, &(&1.display_name == display_name)) do
      nil -> nil
      agent -> agent.slug
    end
  end
end
