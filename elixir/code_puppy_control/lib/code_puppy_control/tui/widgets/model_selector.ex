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
        # No models with valid credentials — show diagnostic info
        # instead of the misleading "No models available"
        # Then offer to show all configured models (with missing credentials)
        # so the user can select one anyway.
        render_no_credentials_diagnostic(filter)

        case offer_configured_models_choice(default) do
          :cancelled -> :cancelled
          :show_all -> select_any_configured(filter, default, label)
        end

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

  # ── Private: No-Credentials Diagnostic ──────────────────────────────────

  # When list_available/0 returns empty (all models lack credentials),
  # show a diagnostic summary instead of the misleading "No models available".
  # This helps the user understand WHAT models are configured and WHAT
  # credentials they need to set.
  defp render_no_credentials_diagnostic(filter) do
    summary = ModelFactory.diagnostic_summary()

    if summary.total == 0 do
      Owl.IO.puts(Owl.Data.tag("\n  No models configured. Add models via /add_model.\n", :red))
    else
      Owl.IO.puts([
        Owl.Data.tag("\n  No models currently available with valid credentials.\n", :red),
        Owl.Data.tag(
          "  #{summary.total} model(s) configured, " <>
            "#{summary.available} available, " <>
            "#{length(summary.unavailable)} missing credentials",
          [:faint]
        ),
        if(summary.unsupported != [],
          do:
            Owl.Data.tag(
              ", #{length(summary.unsupported)} unsupported",
              [:faint]
            ),
          else: []
        ),
        Owl.Data.tag(".\n", [:faint])
      ])

      # Collect entries from unavailable and unsupported lists
      credential_issues =
        (summary.unavailable
         |> Enum.map(fn {name, type, vars} ->
           {name, type, {:missing, vars}}
         end)) ++
          (summary.unsupported
           |> Enum.map(fn {name, type} ->
             {name, type, :unsupported}
           end))

      # Apply filter
      filtered =
        case filter do
          nil ->
            credential_issues

          f ->
            downcased = String.downcase(f)

            Enum.filter(credential_issues, fn {name, type, _status} ->
              String.downcase(name) =~ downcased or
                (type != nil and safe_downcase(type) =~ downcased)
            end)
        end

      shown = Enum.take(filtered, 20)

      if shown != [] do
        Owl.IO.puts(Owl.Data.tag("  Credential status:\n", [:faint, :yellow]))

        for {name, type, status} <- shown do
          type_str = safe_type_string(type)

          {label, color} =
            case status do
              {:missing, vars} -> {" needs: #{Enum.join(vars, ", ")}", [:bright, :yellow]}
              :unsupported -> {" unsupported type", [:bright, :red]}
            end

          Owl.IO.puts([
            Owl.Data.tag("    • ", [:faint]),
            Owl.Data.tag(name, :cyan),
            Owl.Data.tag(" (#{type_str})", [:faint]),
            Owl.Data.tag(label, color)
          ])
        end

        if length(filtered) > 20 do
          Owl.IO.puts(
            Owl.Data.tag(
              "    ... and #{length(filtered) - 20} more\n",
              [:faint]
            )
          )
        end
      end

      Owl.IO.puts([
        Owl.Data.tag("\n  Set credentials via: ", [:faint]),
        Owl.Data.tag("export OPENAI_API_KEY=sk-...", [:bright, :yellow]),
        Owl.Data.tag(" or ", [:faint]),
        Owl.Data.tag("/add_model", [:bright, :yellow])
      ])
    end
  end

  # ── Private: Fallback Selection from Configured Models ──────────────────

  # After showing the no-credentials diagnostic, offer the user a choice
  # to view all configured models (including those without valid credentials)
  # and select one anyway. Returns :show_all or :cancelled.
  defp offer_configured_models_choice(_default) do
    Owl.IO.puts([
      Owl.Data.tag("\n  ", []),
      Owl.Data.tag("View all configured models anyway?", [:bright, :yellow]),
      Owl.Data.tag(" (y/N): ", [:faint])
    ])

    case IO.gets("  > ") do
      :eof ->
        :cancelled

      {:error, _} ->
        :cancelled

      input ->
        trimmed = String.trim(input)

        if trimmed == "y" or trimmed == "Y" or trimmed == "yes" do
          :show_all
        else
          :cancelled
        end
    end
  end

  # Show all configured models (including those with missing credentials)
  # and let the user select one.
  defp select_any_configured(filter, default, label) do
    configured = ModelFactory.list_configured()

    configured =
      case filter do
        nil ->
          configured

        f ->
          downcased = String.downcase(f)

          Enum.filter(configured, fn {name, type, _status} ->
            String.downcase(name) =~ downcased or
              (type != nil and safe_downcase(type) =~ downcased)
          end)
      end

    if configured == [] do
      Owl.IO.puts(Owl.Data.tag("  No models match the filter.\n", :red))
      :cancelled
    else
      render_configured_models(configured, default)
      items = Enum.map(configured, fn {name, _type, _status} -> name end)

      case interactive_select(items, label) do
        nil -> :cancelled
        name -> {:ok, name}
      end
    end
  end

  defp render_configured_models(configured, default) do
    header =
      Owl.Box.new(
        Owl.Data.tag(" ⚠ Configured Models (some without credentials) ", [:bright, :yellow]),
        min_width: 60,
        border: :bottom,
        border_color: :yellow
      )

    rows =
      configured
      |> Enum.with_index(1)
      |> Enum.map(fn {{name, type, status}, idx} ->
        render_configured_row(name, type, status, idx, default)
      end)

    table = build_table(rows)
    Owl.IO.puts([header, "\n", table, "\n"])
  end

  defp render_configured_row(name, type, status, idx, default) do
    default_marker = if name == default, do: " ★", else: ""

    cred_tag =
      case status do
        :ok ->
          Owl.Data.tag(" ✓ ", :green_background)

        {:missing, vars} ->
          var_str = Enum.join(vars, ", ")
          Owl.Data.tag(" ✗ #{var_str} ", [:white, :red_background])

        {:unsupported, _} ->
          Owl.Data.tag(" ⚠ unsupported ", [:white, :magenta_background])
      end

    type_tag = Owl.Data.tag(" #{safe_type_string(type)} ", [:white, :black_background])

    name_part =
      if name == default do
        Owl.Data.tag(" #{idx}. #{short_name(name)}#{default_marker}", [:bright, :green])
      else
        Owl.Data.tag(" #{idx}. #{short_name(name)}", :cyan)
      end

    %{
      "Model" => name_part,
      "Type" => type_tag,
      "Credentials" => cred_tag
    }
  end

  defp maybe_filter(models, nil), do: models

  defp maybe_filter(models, filter) do
    downcased = String.downcase(filter)

    Enum.filter(models, fn model ->
      String.downcase(model.name) =~ downcased or
        safe_downcase(model.provider_type) =~ downcased
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

    %{
      "Model" => name_part,
      "Provider" => provider_tag,
      "Context" => context_part
    }
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

  @model_column_order %{
    "Model" => 0,
    "Provider" => 1,
    "Context" => 2,
    "Type" => 3,
    "Credentials" => 4
  }

  defp build_table(rows) do
    Owl.Table.new(
      rows,
      border_style: :solid,
      padding_x: 1,
      sort_columns: fn a, b ->
        Map.get(@model_column_order, a, 99) < Map.get(@model_column_order, b, 99)
      end
    )
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

  # ── Private: Type-Safe Helpers ────────────────────────────────────────────

  # Safely display a provider type value that may not be a string.
  # Binary types show as-is; non-binary (malformed config, e.g. integer 123)
  # use inspect/1.  nil becomes "?".
  defp safe_type_string(type) when is_binary(type), do: type
  defp safe_type_string(nil), do: "?"
  defp safe_type_string(type), do: inspect(type)

  # Safely downcase a value for filter matching.  Non-binary values return
  # empty string so String.downcase/1 never crashes on raw config data.
  defp safe_downcase(value) when is_binary(value), do: String.downcase(value)
  defp safe_downcase(_), do: ""
end
