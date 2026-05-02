defmodule CodePuppyControl.TUI.Widgets.ModelSelector do
  @moduledoc """
  Interactive model selection widget.

  Presents the user with a list of available models from the ModelRegistry,
  filtered by credential availability, and returns the selected model name.

  ## Usage

      # Simple interactive selection
      ModelSelector.select()

      # With options
      ModelSelector.select(filter: "claude", default: "gpt-5")

      # Just list models without prompting
      ModelSelector.list_models()

  ## Architecture

  - `list_models/0` — queries `ModelFactory.list_available/0` and enriches
    each entry with metadata from `ModelRegistry.get_config/1`.
  - `select/1` — renders a table of models, then prompts for selection
    via `IO.gets/1`-based input (number, exact name, or fuzzy match).
  """

  alias CodePuppyControl.ModelFactory
  alias CodePuppyControl.ModelRegistry

  # ── Types ──────────────────────────────────────────────────────────────────

  @type model_info :: %{
          name: String.t(),
          provider_type: String.t(),
          provider_module: module(),
          context_length: non_neg_integer() | nil,
          display_name: String.t()
        }

  @type select_opt ::
          {:filter, String.t()}
          | {:default, String.t()}
          | {:label, String.t()}

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Interactively select a model from the available list.

  Returns `{:ok, model_name}` on selection or `:cancelled` if the user
  aborts (empty input, Ctrl+D, etc.).

  ## Options

    * `:filter`  — substring filter on model name (default: no filter)
    * `:default` — pre-selected model name (highlighted in display)
    * `:label`   — prompt label (default: "Select a model")
  """
  @spec select([select_opt()]) :: {:ok, String.t()} | :cancelled
  def select(opts \\ []) do
    filter = Keyword.get(opts, :filter)
    default = Keyword.get(opts, :default)
    label = Keyword.get(opts, :label, "Select a model")

    case list_models(filter: filter) do
      [] ->
        Owl.IO.puts(Owl.Data.tag("\n  No models available.\n", :red))
        :cancelled

      models ->
        render_model_table(models, default)

        items = Enum.map(models, & &1.name)

        if default && default in items do
          Owl.IO.puts([
            Owl.Data.tag("\n  Default: ", [:faint]),
            Owl.Data.tag(default, [:bright, :green])
          ])
        end

        case interactive_select(items, label) do
          nil -> :cancelled
          name -> {:ok, name}
        end
    end
  end

  @doc """
  List available models with enriched metadata.

  Returns a list of `model_info` maps sorted by name. Each entry includes
  the model name, provider type, provider module, context length (if known),
  and a short display name for table rendering.

  ## Options

    * `:filter` — substring filter on model name (case-insensitive)
  """
  @spec list_models([{:filter, String.t()}]) :: [model_info()]
  def list_models(opts \\ []) do
    filter = Keyword.get(opts, :filter)

    ModelFactory.list_available()
    |> Enum.map(&enrich_model/1)
    |> maybe_filter(filter)
  end

  # ── Private: Enrich ──────────────────────────────────────────────────────

  defp enrich_model({name, provider_type, provider_module}) do
    config = ModelRegistry.get_config(name) || %{}

    context_length =
      case Map.get(config, "context_length") do
        nil -> Map.get(config, :context_length)
        v -> v
      end

    display_name = short_name(name)

    %{
      name: name,
      provider_type: provider_type,
      provider_module: provider_module,
      context_length: context_length,
      display_name: display_name
    }
  end

  # Strip common prefix patterns for display: "firepass-kimi-k2p5-turbo" → "kimi-k2p5-turbo"
  defp short_name(name) do
    name
    |> String.replace(~r/^(zai|firepass|openai|anthropic)-/, "")
  end

  defp maybe_filter(models, nil), do: models

  defp maybe_filter(models, filter) do
    downcased = String.downcase(filter)

    Enum.filter(models, fn model ->
      String.downcase(model.name) =~ downcased or
        String.downcase(model.provider_type) =~ downcased
    end)
  end

  # ── Private: Table Rendering ─────────────────────────────────────────────

  defp render_model_table(models, default) do
    header = render_header()

    rows =
      models
      |> Enum.with_index(1)
      |> Enum.map(fn {model, idx} -> render_model_row(model, idx, default) end)

    table = build_table(rows)

    Owl.IO.puts([header, "\n", table, "\n"])
  end

  defp render_header do
    Owl.Box.new(
      Owl.Data.tag(" 🤖 Model Selector ", [:bright, :cyan]),
      min_width: 60,
      border: :bottom,
      border_color: :cyan
    )
  end

  defp render_model_row(model, idx, default) do
    default_marker = if model.name == default, do: " ★", else: ""

    provider_tag =
      Owl.Data.tag(" #{model.provider_type} ", [:white, provider_bg(model.provider_type)])

    context_str =
      case model.context_length do
        nil -> "—"
        len -> format_context_length(len)
      end

    name_part =
      if model.name == default do
        Owl.Data.tag(" #{idx}. #{model.display_name}#{default_marker}", [:bright, :green])
      else
        Owl.Data.tag(" #{idx}. #{model.display_name}", :cyan)
      end

    context_part = Owl.Data.tag(" ctx: #{context_str}", :faint)

    [name_part, "  ", provider_tag, context_part]
  end

  defp format_context_length(len) when len >= 1_000_000, do: "#{div(len, 1_000_000)}M"
  defp format_context_length(len) when len >= 1_000, do: "#{div(len, 1_000)}k"
  defp format_context_length(len), do: "#{len}"

  defp provider_bg("openai"), do: :green_background
  defp provider_bg("anthropic"), do: :magenta_background
  defp provider_bg("gemini"), do: :blue_background
  defp provider_bg("zai_coding"), do: :yellow_background
  defp provider_bg("zai_api"), do: :yellow_background
  defp provider_bg("cerebras"), do: :red_background
  defp provider_bg("openrouter"), do: :cyan_background
  defp provider_bg("azure_openai"), do: :blue_background
  defp provider_bg(_), do: :black_background

  defp build_table(rows) do
    # Owl.Table.new/2 expects a list of maps (%{col => value}), but our rows
    # are lists of Owl.Data-tagged elements for custom layout.  Use the
    # plain-text fallback which correctly handles Owl.Tag elements.
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

  # ── Private: Interactive Selection ────────────────────────────────────────

  defp interactive_select(items, label) do
    # Owl.IO.select/2 requires an interactive terminal (arrow-key navigation)
    # and hangs in non-TTY contexts (piped input, capture_io).
    # Use the IO.gets-based fallback which works everywhere.
    fallback_select(items, label)
  end

  defp fallback_select(items, label) do
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
          trimmed in items -> trimmed
          true -> parse_selection(trimmed, items)
        end
    end
  end

  defp parse_selection(input, items) do
    case Integer.parse(input) do
      {num, ""} when num >= 1 and num <= length(items) ->
        Enum.at(items, num - 1)

      _ ->
        # Try fuzzy match on display name
        downcased = String.downcase(input)

        Enum.find(items, fn name ->
          String.downcase(name) =~ downcased
        end)
    end
  end
end
