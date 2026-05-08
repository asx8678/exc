defmodule CodePuppyControl.TUI.Screens.Help do
  @moduledoc """
  Help screen showing available commands and keyboard shortcuts.

  Displays a formatted table of commands and shortcuts, then waits
  for the user to press `q` or Enter to return to the previous screen.

  ## Navigation

    * `q` or Enter (`""`) → return to previous screen (`:quit` from Screen
      perspective — the App will pop the stack)
  """

  @behaviour CodePuppyControl.TUI.Screen

  # ── State ──────────────────────────────────────────────────────────────────

  @type state :: %{
          previous_screen: module() | nil
        }

  # ── Commands Data ─────────────────────────────────────────────────────────

  @commands [
    {"Chat Commands",
     [
       {"<text>", "Send a message to the current agent"},
       {"/help", "Show this help screen"},
       {"/config", "Open the configuration viewer/editor"},
       {"/model <name>", "Switch the active model"},
       {"/clear", "Clear conversation history"},
       {"/quit", "Exit Code Puppy"}
     ]},
    {"Navigation",
     [
       {"q", "Return to previous screen from any overlay"},
       {"Enter", "Confirm / return from overlay"},
       {"Ctrl+C", "Force quit the TUI"}
     ]},
    {"Config Screen",
     [
       {"set <KEY> <VALUE>", "Set a configuration key"},
       {"get <KEY>", "Display the value of a config key"},
       {"keys", "List all config keys"},
       {"q", "Return to chat screen"}
     ]}
  ]

  # ── Screen Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok, %{previous_screen: Map.get(opts, :previous_screen)}}
  end

  @impl true
  def render(_state) do
    title = render_title()
    sections = render_sections()
    footer = render_footer()

    [title, sections, footer]
  end

  @impl true
  def handle_input("q", _state), do: :quit

  def handle_input("", _state), do: :quit

  def handle_input(_input, state), do: {:ok, state}

  # ── Rendering Helpers ──────────────────────────────────────────────────────

  defp render_title do
    Owl.Box.new(
      Owl.Data.tag(" 🐶 Code Puppy — Help ", [:bright, :cyan]),
      min_width: 60,
      border: :bottom,
      border_color: :cyan
    )
  end

  defp render_sections do
    @commands
    |> Enum.map(&render_section/1)
    |> Enum.intersperse("\n")
  end

  defp render_section({section_title, items}) do
    header = Owl.Data.tag("\n  #{section_title}", [:bright, :yellow])

    table_rows =
      items
      |> Enum.map(fn {cmd, desc} ->
        [
          Owl.Data.tag("  #{cmd}", :cyan),
          Owl.Data.tag("  —  #{desc}", :white)
        ]
      end)

    table =
      table_rows
      |> Enum.map(fn [cmd, desc] ->
        %{"Command" => cmd, "Description" => desc}
      end)
      |> then(fn rows ->
        Owl.Table.new(rows, border_style: :solid, padding_x: 1)
      end)

    [header, "\n", table]
  end

  defp render_footer do
    Owl.Data.tag("\n  Press q or Enter to return\n", :faint)
  end
end
