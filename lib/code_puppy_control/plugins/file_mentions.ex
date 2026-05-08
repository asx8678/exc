defmodule CodePuppyControl.Plugins.FileMentions do
  @moduledoc """
  Auto-read file mentions from user prompts.
  Ported from Python: code_puppy/plugins/file_mentions/register_callbacks.py
  """

  use CodePuppyControl.Plugins.PluginBehaviour
  alias CodePuppyControl.Callbacks
  require Logger

  @default_max_file_size 5 * 1024 * 1024
  @default_max_files 10
  @default_max_dir_entries 500

  @file_mention_regex ~r"@((?:[a-zA-Z0-9_\-.][\w\-.]*/)*[\w\-]+(?:\.\w+)?)"
  @leading_punct_regex ~r"^[`\"\'(\[{<]+"
  @trailing_punct_regex ~r"[\)}]>.,;:!\"\'`]+$"
  @mention_boundary_regex ~r"[\s(\[{<\"\'`]"

  @state_key :code_puppy_file_mentions_state

  defp get_state do
    Process.get(@state_key, %{
      enabled: true,
      stats: %{mentions_found: 0, files_resolved: 0, files_failed: 0}
    })
  end

  @doc false
  def reset_state do
    Process.delete(@state_key)
    :ok
  end

  @doc false
  def enabled?, do: get_state().enabled

  @doc false
  def stats, do: get_state().stats

  @impl true
  def name, do: "file_mentions"
  @impl true
  def description, do: "Auto-read @file mentions from user prompts"
  @impl true
  def register do
    Callbacks.register(:load_prompt, &__MODULE__.on_load_prompt/0)
    Callbacks.register(:custom_command, &__MODULE__.handle_custom_command/2)
    Callbacks.register(:custom_command_help, &__MODULE__.custom_command_help/0)
    :ok
  end

  def extract_file_mentions(text) do
    Regex.scan(@file_mention_regex, text, return: :index)
    |> Enum.reduce({[], MapSet.new()}, fn [{start, _len}, {raw_start, raw_len}], {acc, seen} ->
      if mention_boundary?(text, start) do
        raw = String.slice(text, raw_start, raw_len)
        cleaned = sanitize_mention_path(raw)

        if cleaned && path_like?(cleaned) && !MapSet.member?(seen, cleaned) do
          {[cleaned | acc], MapSet.put(seen, cleaned)}
        else
          {acc, seen}
        end
      else
        {acc, seen}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  def mention_boundary?(_text, 0), do: true

  def mention_boundary?(text, index) do
    String.at(text, index - 1)
    |> case do
      nil -> true
      char -> Regex.match?(@mention_boundary_regex, char)
    end
  end

  def sanitize_mention_path(raw_path) do
    cleaned =
      raw_path
      |> String.trim()
      |> then(&Regex.replace(@leading_punct_regex, &1, ""))
      |> then(&Regex.replace(@trailing_punct_regex, &1, ""))
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  def path_like?(s), do: String.contains?(s, ".") or String.contains?(s, "/")

  def resolve_mention_path(file_path, cwd \\ nil) do
    cwd = cwd || File.cwd!()
    candidate = Path.join(cwd, file_path)

    cond do
      File.exists?(candidate) -> Path.expand(candidate)
      Path.absname(file_path) == file_path and File.exists?(file_path) -> file_path
      true -> nil
    end
  end

  def read_file_content(abs_path, max_size \\ @default_max_file_size) do
    case File.stat(abs_path) do
      {:ok, %{size: size}} when size > max_size ->
        Logger.debug("file_mentions: skipping #{abs_path}")
        nil

      {:ok, _} ->
        case File.read(abs_path) do
          {:ok, content} -> content
          {:error, _} -> nil
        end

      {:error, _} ->
        nil
    end
  end

  def list_directory(abs_path, max_entries \\ @default_max_dir_entries) do
    case File.ls(abs_path) do
      {:ok, entries} ->
        sorted = Enum.sort(entries)
        shown = Enum.take(sorted, max_entries)

        lines =
          Enum.map(shown, fn entry ->
            suffix = if File.dir?(Path.join(abs_path, entry)), do: "/", else: ""
            entry <> suffix
          end)

        if length(lines) == 0, do: "(empty)", else: Enum.join(lines, "\n")

      {:error, _} ->
        nil
    end
  end

  def generate_file_mention_context(text, cwd \\ nil, opts \\ []) do
    mentions = extract_file_mentions(text)
    if mentions == [], do: nil, else: build_context(mentions, cwd, opts)
  end

  defp build_context(mentions, cwd, opts) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    parts = mentions |> Enum.take(max_files) |> Enum.flat_map(&build_part(&1, cwd))

    if parts == [],
      do: nil,
      else: "## Auto-loaded @file mentions\n\n" <> Enum.join(parts, "\n\n")
  end

  defp build_part(mention, cwd) do
    case resolve_mention_path(mention, cwd) do
      nil ->
        []

      resolved ->
        if File.dir?(resolved) do
          case list_directory(resolved) do
            nil ->
              []

            listing ->
              [
                "<file_mention path=\"#{mention}\" type=\"directory\">\n#{listing}\n</file_mention>"
              ]
          end
        else
          case read_file_content(resolved) do
            nil -> []
            content -> ["<file_mention path=\"#{mention}\">\n#{content}\n</file_mention>"]
          end
        end
    end
  end

  def on_load_prompt do
    "\n\n## @file mention support\n\nUsers can reference files with @path syntax."
  end

  def handle_custom_command(_command, "file-mentions") do
    state = get_state()
    "@file mentions: #{if state.enabled, do: "enabled", else: "disabled"}"
  end

  def handle_custom_command(_command, _name), do: nil

  def custom_command_help do
    [{"file-mentions", "Show @file mention status"}]
  end
end
