defmodule CodePuppyControl.CLI.SlashCommands.Commands.AddModel.Interactive do
  @moduledoc """
  Interactive IO flow for the /add_model command.

  Handles the text-based browsing, selection, and confirmation loop that
  runs when a user invokes /add_model from the REPL.  Separated from the
  core AddModel module to keep each under the 600-line cap.

  The entry point is `run_interactive/0`.  It delegates persistence to
  `AddModel.add_model_to_config/2` and registry reload to
  `CodePuppyControl.ModelRegistry.reload/0`.
  """

  alias CodePuppyControl.CLI.SlashCommands.Commands.AddModel
  alias CodePuppyControl.ModelsDevParser.ModelInfo
  alias CodePuppyControl.ModelsDevParser.ProviderInfo

  @page_size 15

  # ── Public entry point ──────────────────────────────────────────────────

  @doc """
  Run the full interactive /add_model flow (provider → model → persist).

  Prints prompts and reads from stdin.  Returns `:ok` always — the REPL
  should not halt regardless of the outcome.
  """
  @spec run_interactive() :: :ok
  def run_interactive do
    case get_providers_list() do
      {:error, reason} ->
        IO.puts(IO.ANSI.red() <> "    Error loading providers: #{reason}" <> IO.ANSI.reset())

      {:ok, []} ->
        IO.puts(IO.ANSI.yellow() <> "    No providers available." <> IO.ANSI.reset())

      {:ok, providers} ->
        IO.puts("")
        IO.puts(IO.ANSI.bright() <> "    Add Model — Browse providers" <> IO.ANSI.reset())
        IO.puts("")

        browse_providers(providers, 0)
    end

    :ok
  end

  # ── Provider browsing ──────────────────────────────────────────────────

  defp browse_providers(providers, page) do
    total = length(providers)
    total_pages = max(1, ceil(total / @page_size))

    display_providers(providers, page)

    IO.puts("")

    prompt =
      if total_pages > 1 do
        "    Select provider [1-#{total}] (n=next, p=prev, f=filter, q=cancel): "
      else
        "    Select provider [1-#{total}] or q to cancel: "
      end

    IO.write(prompt)

    case IO.gets("") do
      :eof ->
        IO.puts(IO.ANSI.yellow() <> "    Cancelled." <> IO.ANSI.reset())

      {:error, _} ->
        IO.puts(IO.ANSI.yellow() <> "    Cancelled." <> IO.ANSI.reset())

      input ->
        handle_provider_input(String.trim(input), providers, page, total_pages)
    end
  end

  defp handle_provider_input(input, providers, page, total_pages) do
    cond do
      input =~ ~r/^[qQ]$/ ->
        IO.puts(IO.ANSI.yellow() <> "    Cancelled." <> IO.ANSI.reset())

      input == "n" and page + 1 < total_pages ->
        browse_providers(providers, page + 1)

      input == "p" and page > 0 ->
        browse_providers(providers, page - 1)

      String.starts_with?(input, "f ") ->
        query = String.trim_leading(input, "f ")
        filtered = AddModel.filter_providers(providers, query)

        if filtered == [] do
          IO.puts(IO.ANSI.faint() <> "    No providers match '#{query}'." <> IO.ANSI.reset())
          browse_providers(providers, page)
        else
          IO.puts(
            IO.ANSI.faint() <>
              "    Filtered: #{length(filtered)} provider(s) match '#{query}'." <> IO.ANSI.reset()
          )

          browse_providers(filtered, 0)
        end

      true ->
        case parse_selection(input, length(providers)) do
          {:ok, idx} ->
            provider = Enum.at(providers, idx)
            select_model_interactive(provider)

          {:error, reason} ->
            IO.puts(IO.ANSI.red() <> "    Invalid selection: #{reason}" <> IO.ANSI.reset())
            browse_providers(providers, page)
        end
    end
  end

  @doc false
  # Public for testability — tests call this directly to verify unsupported
  # provider rejection without driving the full provider-selection IO flow.
  def select_model_interactive(provider) do
    if AddModel.unsupported_provider?(provider.id) do
      reason = AddModel.unsupported_reason(provider.id)

      IO.puts(
        IO.ANSI.red() <>
          "    Cannot add model from #{provider.name}: #{reason}" <>
          IO.ANSI.reset()
      )

      return_to_menu_hint()
    else
      case get_models_list(provider.id) do
        {:error, reason} ->
          IO.puts(IO.ANSI.red() <> "    Error loading models: #{reason}" <> IO.ANSI.reset())

        {:ok, []} ->
          IO.puts(
            IO.ANSI.yellow() <> "    No models found for #{provider.name}." <> IO.ANSI.reset()
          )

        {:ok, models} ->
          IO.puts("")
          IO.puts(IO.ANSI.bright() <> "    #{provider.name} — Select model" <> IO.ANSI.reset())
          IO.puts("")

          browse_models(models, provider, 0)
      end
    end
  end

  # ── Model browsing ─────────────────────────────────────────────────────

  defp browse_models(models, provider, page) do
    total = length(models)
    total_pages = max(1, ceil(total / @page_size))

    display_models(models, page)

    IO.puts("")

    prompt =
      if total_pages > 1 do
        "    Select model [1-#{total}] (n=next, p=prev, f=filter, q=cancel): "
      else
        "    Select model [1-#{total}] or q to cancel: "
      end

    IO.write(prompt)

    case IO.gets("") do
      :eof ->
        IO.puts(IO.ANSI.yellow() <> "    Cancelled." <> IO.ANSI.reset())

      {:error, _} ->
        IO.puts(IO.ANSI.yellow() <> "    Cancelled." <> IO.ANSI.reset())

      input ->
        handle_model_input(String.trim(input), models, provider, page, total_pages)
    end
  end

  defp handle_model_input(input, models, provider, page, total_pages) do
    cond do
      input =~ ~r/^[qQ]$/ ->
        IO.puts(IO.ANSI.yellow() <> "    Cancelled." <> IO.ANSI.reset())

      input == "n" and page + 1 < total_pages ->
        browse_models(models, provider, page + 1)

      input == "p" and page > 0 ->
        browse_models(models, provider, page - 1)

      String.starts_with?(input, "f ") ->
        query = String.trim_leading(input, "f ")
        filtered = AddModel.filter_models(models, query)

        if filtered == [] do
          IO.puts(IO.ANSI.faint() <> "    No models match '#{query}'." <> IO.ANSI.reset())
          browse_models(models, provider, page)
        else
          IO.puts(
            IO.ANSI.faint() <>
              "    Filtered: #{length(filtered)} model(s) match '#{query}'." <> IO.ANSI.reset()
          )

          browse_models(filtered, provider, 0)
        end

      true ->
        case parse_selection(input, length(models)) do
          {:ok, idx} ->
            model = Enum.at(models, idx)
            execute_add_model(model, provider)

          {:error, reason} ->
            IO.puts(IO.ANSI.red() <> "    Invalid selection: #{reason}" <> IO.ANSI.reset())
            browse_models(models, provider, page)
        end
    end
  end

  # ── Add execution (with tool-calling confirmation) ─────────────────────

  @doc false
  # Public for testability — tests call this directly to exercise the
  # real confirmation + persistence + reload flow.
  def execute_add_model(model, provider) do
    # Warn about non-tool-calling models
    if not model.tool_call do
      IO.puts("")

      IO.puts(
        IO.ANSI.yellow() <>
          "    ⚠️  #{model.name} does NOT support tool calling!" <>
          IO.ANSI.reset()
      )

      IO.puts(
        IO.ANSI.yellow() <>
          "    This model won't be able to edit files, run commands, or use tools." <>
          IO.ANSI.reset()
      )

      IO.write("    Add anyway? (y/N): ")

      case IO.gets("") do
        resp when is_binary(resp) ->
          if String.trim(resp) =~ ~r/^[yY]/ do
            do_add_model(model, provider)
          else
            IO.puts(IO.ANSI.yellow() <> "    Cancelled." <> IO.ANSI.reset())
          end

        _ ->
          IO.puts(IO.ANSI.yellow() <> "    Cancelled." <> IO.ANSI.reset())
      end
    else
      do_add_model(model, provider)
    end
  end

  @doc false
  # Public for testability — tests call this directly to exercise the
  # persistence + reload path without the confirmation prompt.
  def do_add_model(model, provider) do
    case safe_persist(model, provider) do
      {:ok, model_key} ->
        IO.puts("")

        IO.puts(
          IO.ANSI.green() <>
            "    ✅ Added #{model_key} to extra_models.json" <>
            IO.ANSI.reset()
        )

        # Reload ModelRegistry so the new model is immediately available
        case safe_registry_reload() do
          :ok ->
            IO.puts(
              IO.ANSI.faint() <>
                "    Model registry reloaded." <>
                IO.ANSI.reset()
            )

          {:error, reason} ->
            IO.puts(
              IO.ANSI.yellow() <>
                "    Warning: registry reload failed: #{inspect(reason)}" <>
                IO.ANSI.reset()
            )
        end

        IO.puts("")

      {:error, :already_exists} ->
        IO.puts("")
        IO.puts(IO.ANSI.cyan() <> "    Model already in extra_models.json." <> IO.ANSI.reset())
        IO.puts("")

      {:error, :not_running} ->
        IO.puts("")

        IO.puts(
          IO.ANSI.red() <>
            "    ❌ Error adding model: persistence service not running" <>
            IO.ANSI.reset()
        )

        IO.puts("")

      {:error, reason} ->
        IO.puts("")

        IO.puts(
          IO.ANSI.red() <>
            "    ❌ Error adding model: #{reason}" <>
            IO.ANSI.reset()
        )

        IO.puts("")
    end
  end

  # ── Safe GenServer wrappers ────────────────────────────────────────────

  # Wraps AddModel.add_model_to_config/2 so that a crashed or missing
  # LockKeeper (GenServer :noproc) does not kill the caller.
  defp safe_persist(model, provider) do
    AddModel.add_model_to_config(model, provider)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:shutdown, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  # Wraps ModelRegistry.reload/0 so that a missing ModelRegistry
  # does not kill the caller.
  defp safe_registry_reload do
    CodePuppyControl.ModelRegistry.reload()
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:shutdown, _} -> {:error, :not_running}
    :exit, {:timeout, _} -> {:error, :timeout}
  end

  # ── Display helpers ────────────────────────────────────────────────────

  defp display_providers(providers, page) do
    total = length(providers)
    total_pages = max(1, ceil(total / @page_size))
    start_idx = page * @page_size

    Enum.slice(providers, start_idx, @page_size)
    |> Enum.with_index(fn provider, i ->
      num = i + start_idx + 1
      unsup = AddModel.unsupported_provider?(provider.id)
      count = ProviderInfo.model_count(provider)

      line =
        if unsup do
          "    #{num}. #{provider.name} (#{count} models) ⚠️"
        else
          "    #{num}. #{provider.name} (#{count} models)"
        end

      if unsup do
        IO.puts(IO.ANSI.faint() <> line <> IO.ANSI.reset())
      else
        IO.puts(line)
      end
    end)

    if total_pages > 1 do
      IO.puts(IO.ANSI.faint() <> "    Page #{page + 1}/#{total_pages}" <> IO.ANSI.reset())
    end
  end

  defp display_models(models, page) do
    total = length(models)
    total_pages = max(1, ceil(total / @page_size))
    start_idx = page * @page_size

    Enum.slice(models, start_idx, @page_size)
    |> Enum.with_index(fn model, i ->
      num = i + start_idx + 1

      icons =
        []
        |> maybe_icon(ModelInfo.has_vision?(model), "👁")
        |> maybe_icon(model.tool_call, "🔧")
        |> maybe_icon(model.reasoning, "🧠")

      icon_str = if icons == [], do: "", else: Enum.join(icons, " ") <> " "

      IO.puts("    #{num}. #{icon_str}#{model.name}")
    end)

    if total_pages > 1 do
      IO.puts(IO.ANSI.faint() <> "    Page #{page + 1}/#{total_pages}" <> IO.ANSI.reset())
    end
  end

  defp maybe_icon(icons, true, icon), do: icons ++ [icon]
  defp maybe_icon(icons, false, _icon), do: icons

  defp return_to_menu_hint do
    IO.puts(IO.ANSI.faint() <> "    Use /add_model to browse again." <> IO.ANSI.reset())
  end

  # ── Data access ────────────────────────────────────────────────────────

  defp get_providers_list do
    case Process.whereis(CodePuppyControl.ModelsDevParser.Registry) do
      nil -> {:error, "ModelsDev registry not started"}
      _pid -> {:ok, CodePuppyControl.ModelsDevParser.get_providers()}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp get_models_list(provider_id) do
    case Process.whereis(CodePuppyControl.ModelsDevParser.Registry) do
      nil ->
        {:error, "ModelsDev registry not started"}

      _pid ->
        {:ok,
         CodePuppyControl.ModelsDevParser.get_models(
           CodePuppyControl.ModelsDevParser.Registry,
           provider_id
         )}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Selection parsing ──────────────────────────────────────────────────

  defp parse_selection(input, max_index) do
    case Integer.parse(String.trim(input)) do
      {n, ""} when n >= 1 and n <= max_index ->
        {:ok, n - 1}

      _ ->
        {:error, "enter a number between 1 and #{max_index}"}
    end
  end
end
