defmodule CodePuppyControl.TUI.Screens.Config do
  @moduledoc """
  Configuration viewer/editor screen.

  Displays current configuration keys and values using Owl.Table, and
  supports basic editing via the `set KEY VALUE` command pattern.

  ## Commands

    * `set KEY VALUE` — update a config key
    * `get KEY`       — display the value of a config key
    * `keys`          — list all config keys
    * `q`             — return to the previous screen

  ## Architecture

  Reads via `CodePuppyControl.Config.Loader.get_cached/0` and writes via
  `CodePuppyControl.Config.Writer.set_value/2`. The screen refreshes its
  display after each mutation.
  """

  @behaviour CodePuppyControl.TUI.Screen

  alias CodePuppyControl.Config
  alias CodePuppyControl.Config.Loader

  # ── Types ──────────────────────────────────────────────────────────────────

  @type state :: %{
          status: :ok | {:error, String.t()},
          last_action: String.t() | nil
        }

  # ── Screen Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{status: :ok, last_action: nil}}
  end

  @impl true
  def render(state) do
    title = render_title()
    table = render_config_table()
    status = render_status(state)

    [title, table, status]
  end

  @impl true
  def handle_input("q", _state), do: :quit

  def handle_input("", state), do: {:ok, state}

  def handle_input("keys", state) do
    # Just re-render — the table already shows all keys
    {:ok, %{state | last_action: "Listing all keys", status: :ok}}
  end

  def handle_input("get " <> key, state) do
    key = String.trim(key)

    case Config.get_value(key) do
      nil ->
        {:ok, %{state | last_action: "Key not found: #{key}", status: {:error, "not found"}}}

      value ->
        {:ok, %{state | last_action: "#{key} = #{value}", status: :ok}}
    end
  end

  def handle_input("set " <> rest, state) do
    case parse_set_command(rest) do
      {:ok, key, value} ->
        try do
          Config.set_value(key, value)
          {:ok, %{state | last_action: "Set #{key} = #{value}", status: :ok}}
        catch
          kind, reason ->
            msg = "Failed to set #{key}: #{inspect({kind, reason})}"
            {:ok, %{state | last_action: msg, status: {:error, "write error"}}}
        end

      {:error, msg} ->
        {:ok, %{state | last_action: msg, status: {:error, "parse error"}}}
    end
  end

  def handle_input(input, state) do
    {:ok,
     %{
       state
       | last_action: "Unknown command: #{input}",
         status: {:error, "unknown command"}
     }}
  end

  # ── Rendering Helpers ──────────────────────────────────────────────────────

  defp render_title do
    Owl.Box.new(
      Owl.Data.tag(" ⚙️  Configuration ", [:bright, :yellow]),
      min_width: 60,
      border: :bottom,
      border_color: :yellow
    )
  end

  defp render_config_table do
    keys = Loader.keys()

    if keys == [] do
      Owl.Data.tag("\n  No configuration keys found.\n", :faint)
    else
      rows =
        Enum.map(keys, fn key ->
          value = Config.get_value(key) || ""
          # Truncate long values for display
          display_value =
            if byte_size(value) > 60, do: binary_part(value, 0, 57) <> "...", else: value

          %{
            "Key" => Owl.Data.tag(key, :cyan),
            " " => Owl.Data.tag(" = ", :faint),
            "Value" => display_value
          }
        end)

      ["\n", Owl.Table.new(rows, border_style: :solid, padding_x: 1), "\n"]
    end
  end

  defp render_status(%{status: :ok, last_action: nil}) do
    Owl.Data.tag("  Commands: set KEY VALUE | get KEY | keys | q\n", :faint)
  end

  defp render_status(%{status: :ok, last_action: action}) do
    [
      Owl.Data.tag("  ✔ #{action}\n", :green),
      Owl.Data.tag("  Commands: set KEY VALUE | get KEY | keys | q\n", :faint)
    ]
  end

  defp render_status(%{status: {:error, _reason}, last_action: action}) do
    [
      Owl.Data.tag("  ✖ #{action}\n", :red),
      Owl.Data.tag("  Commands: set KEY VALUE | get KEY | keys | q\n", :faint)
    ]
  end

  # ── Parsing ────────────────────────────────────────────────────────────────

  defp parse_set_command(rest) do
    rest = String.trim(rest)

    case String.split(rest, " ", parts: 2) do
      [key, value] when key != "" and value != "" ->
        {:ok, key, value}

      [key] when key != "" ->
        # Setting to empty string is allowed — means clearing the value
        {:ok, key, ""}

      _ ->
        {:error, "Usage: set KEY VALUE (got: #{inspect(rest)})"}
    end
  end
end
