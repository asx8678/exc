defmodule CodePuppyControl.CLI.SlashCommands.Commands.Agents do
  @moduledoc """
  Agent management slash commands: /agents

  Allows listing agents, viewing/setting model pins, and managing agent configuration.
  Uses the same ModelSelector widget as /model for consistent UX.
  """

  alias CodePuppyControl.Tools.AgentCatalogue
  alias CodePuppyControl.AgentModelPinning
  alias CodePuppyControl.TUI.Widgets.ModelSelector

  @doc """
  Handles `/agents [subcommand] [args]`

  Subcommands:
    - (none)        — List all agents with their pinned models
    - pin <agent>   — Interactively pin a model to an agent
    - unpin <agent> — Remove the model pin for an agent
    - list          — Same as no subcommand
  """
  @spec handle_agents(String.t(), map()) :: {:continue, map()}
  def handle_agents(line, state) do
    args = extract_args(line)

    case parse_subcommand(args) do
      {:list} ->
        list_agents_with_pins()
        {:continue, state}

      {:pin, agent_name} ->
        pin_model_to_agent(agent_name)
        {:continue, state}

      {:unpin, agent_name} ->
        unpin_agent(agent_name)
        {:continue, state}

      {:help} ->
        show_help()
        {:continue, state}

      {:error, msg} ->
        Owl.IO.puts(Owl.Data.tag("Error: #{msg}", :red))
        {:continue, state}
    end
  end

  # ── Subcommand Handlers ──────────────────────────────────────────────────

  defp list_agents_with_pins do
    agents = AgentCatalogue.list_agents()
    pins = AgentModelPinning.list_pins()

    Owl.IO.puts(Owl.Data.tag("\n 🐕 Agents & Model Pins\n", [:bright, :cyan]))

    if Enum.empty?(agents) do
      Owl.IO.puts(Owl.Data.tag("  No agents registered.", :faint))
    else
      Enum.each(agents, fn agent ->
        pin = Map.get(pins, to_string(agent.name))
        render_agent_row(agent, pin)
      end)
    end

    Owl.IO.puts("")
    Owl.IO.puts(Owl.Data.tag("  Use /agents pin <name> to pin a model", :faint))
    Owl.IO.puts(Owl.Data.tag("  Use /agents unpin <name> to remove a pin\n", :faint))
  end

  defp render_agent_row(agent, nil) do
    name = Owl.Data.tag("  #{agent.display_name}", :cyan)
    status = Owl.Data.tag(" (no pin)", :faint)
    Owl.IO.puts([name, status])
  end

  defp render_agent_row(agent, pinned_model) do
    name = Owl.Data.tag("  #{agent.display_name}", :cyan)
    arrow = Owl.Data.tag(" → ", :faint)
    model = Owl.Data.tag(pinned_model, [:bright, :green])
    Owl.IO.puts([name, arrow, model])
  end

  defp pin_model_to_agent(agent_name) do
    case find_agent(agent_name) do
      nil ->
        Owl.IO.puts(Owl.Data.tag("\n  Agent '#{agent_name}' not found.\n", :red))
        suggest_agents(agent_name)

      agent ->
        current_pin = AgentModelPinning.get_pinned_model(to_string(agent.name))

        Owl.IO.puts(
          Owl.Data.tag("\n  Pinning model for: #{agent.display_name}", [:bright, :cyan])
        )

        if current_pin do
          Owl.IO.puts(Owl.Data.tag("  Current pin: #{current_pin}\n", :faint))
        end

        case ModelSelector.select(default: current_pin, label: "Select model to pin") do
          {:ok, model_name} ->
            :ok = AgentModelPinning.set_pinned_model(to_string(agent.name), model_name)

            Owl.IO.puts(
              Owl.Data.tag("\n  ✓ Pinned #{agent.display_name} → #{model_name}\n", :green)
            )

          :cancelled ->
            Owl.IO.puts(Owl.Data.tag("\n  Cancelled.\n", :faint))
        end
    end
  end

  defp unpin_agent(agent_name) do
    case find_agent(agent_name) do
      nil ->
        Owl.IO.puts(Owl.Data.tag("\n  Agent '#{agent_name}' not found.\n", :red))
        suggest_agents(agent_name)

      agent ->
        agent_key = to_string(agent.name)

        case AgentModelPinning.get_pinned_model(agent_key) do
          nil ->
            Owl.IO.puts(Owl.Data.tag("\n  #{agent.display_name} has no pinned model.\n", :faint))

          model ->
            :ok = AgentModelPinning.clear_pinned_model(agent_key)

            Owl.IO.puts(
              Owl.Data.tag("\n  ✓ Unpinned #{agent.display_name} (was: #{model})\n", :green)
            )
        end
    end
  end

  defp show_help do
    Owl.IO.puts([
      "\n      ",
      Owl.Data.tag("/agents", [:bright, :cyan]),
      " — Agent management\n\n      ",
      Owl.Data.tag("Usage:", :bright),
      "\n        /agents              List all agents with their pinned models\n" <>
        "        /agents list         Same as above\n" <>
        "        /agents pin <name>   Pin a model to an agent (interactive)\n" <>
        "        /agents unpin <name> Remove a model pin\n\n      ",
      Owl.Data.tag("Examples:", :bright),
      "\n        /agents pin code-puppy    Select a model to pin to code-puppy\n" <>
        "        /agents unpin code-scout  Remove code-scout's model pin\n\n    "
    ])
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp extract_args("/agents" <> rest), do: String.trim(rest)
  defp extract_args(line), do: String.trim(line)

  defp parse_subcommand(""), do: {:list}
  defp parse_subcommand("list"), do: {:list}
  defp parse_subcommand("help"), do: {:help}
  defp parse_subcommand("-h"), do: {:help}
  defp parse_subcommand("--help"), do: {:help}

  defp parse_subcommand("pin " <> agent) do
    agent = String.trim(agent)

    if agent == "",
      do: {:error, "Missing agent name. Usage: /agents pin <name>"},
      else: {:pin, agent}
  end

  defp parse_subcommand("pin"), do: {:error, "Missing agent name. Usage: /agents pin <name>"}

  defp parse_subcommand("unpin " <> agent) do
    agent = String.trim(agent)

    if agent == "",
      do: {:error, "Missing agent name. Usage: /agents unpin <name>"},
      else: {:unpin, agent}
  end

  defp parse_subcommand("unpin"), do: {:error, "Missing agent name. Usage: /agents unpin <name>"}

  defp parse_subcommand(unknown), do: {:error, "Unknown subcommand: #{unknown}. Try /agents help"}

  defp find_agent(name) do
    name_lower = String.downcase(name)

    AgentCatalogue.list_agents()
    |> Enum.find(fn agent ->
      String.downcase(to_string(agent.name)) == name_lower or
        String.downcase(agent.display_name) == name_lower or
        String.downcase(String.replace(agent.display_name, " ", "-")) == name_lower
    end)
  end

  defp suggest_agents(input) do
    input_lower = String.downcase(input)

    matches =
      AgentCatalogue.list_agents()
      |> Enum.filter(fn agent ->
        String.downcase(to_string(agent.name)) =~ input_lower or
          String.downcase(agent.display_name) =~ input_lower
      end)
      |> Enum.take(3)

    unless Enum.empty?(matches) do
      Owl.IO.puts(Owl.Data.tag("  Did you mean?", :faint))

      Enum.each(matches, fn agent ->
        Owl.IO.puts(Owl.Data.tag("    • #{agent.name}", :cyan))
      end)

      Owl.IO.puts("")
    end
  end
end
