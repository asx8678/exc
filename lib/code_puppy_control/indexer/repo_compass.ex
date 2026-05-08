defmodule CodePuppyControl.Indexer.RepoCompass do
  @moduledoc """
  Compact repository indexer used by Repo Compass.

  This is the first high-leverage Python → Elixir rewrite slice for the repo.
  It ports the compact structure-map behavior from
  `code_puppy/plugins/repo_compass/indexer.py` into the Elixir control plane so
  Repo Compass can use an Elixir-native backend without changing its prompt
  budget assumptions or output shape.

  Unlike the generic `CodePuppyControl.Indexer.DirectoryIndexer`, this module is
  intentionally conservative:

  * only prompt-relevant files are included
  * Python source is summarized using Python-style symbol strings
  * unknown files are omitted instead of being returned as generic `file` items
  """

  alias CodePuppyControl.Indexer.{Constants, FileSummary}

  require Logger

  @type opts :: [
          max_files: pos_integer(),
          max_symbols_per_file: pos_integer(),
          ignored_dirs: [String.t()] | MapSet.t(String.t())
        ]

  @default_max_files 40
  @default_max_symbols 8
  @max_class_methods 3

  @important_files MapSet.new([
                     "README.md",
                     "pyproject.toml",
                     "package.json",
                     "Makefile",
                     "justfile"
                   ])

  @non_python_kinds %{
    ".md" => "docs",
    ".rst" => "docs",
    ".js" => "js",
    ".ts" => "ts",
    ".tsx" => "tsx",
    ".json" => "json",
    ".toml" => "toml",
    ".yaml" => "yaml",
    ".yml" => "yml"
  }

  @top_level_function_regex ~r/^(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\(([^)]*)\)\s*:/
  @top_level_class_regex ~r/^class\s+([A-Za-z_][A-Za-z0-9_]*)(?:\([^)]*\))?\s*:/
  @indented_method_regex ~r/^\s+(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/

  @doc """
  Builds a compact Repo Compass structure map.

  Returns the same `FileSummary` shape used by the Python implementation.
  """
  @spec index(Path.t(), opts()) :: {:ok, [FileSummary.t()]} | {:error, term()}
  def index(root, opts \\ []) do
    root = Path.expand(root)

    if not File.dir?(root) do
      {:error, {:not_a_directory, root}}
    else
      max_files = Keyword.get(opts, :max_files, @default_max_files)
      max_symbols = Keyword.get(opts, :max_symbols_per_file, @default_max_symbols)

      ignored =
        opts
        |> Keyword.get(:ignored_dirs, [])
        |> to_mapset()
        |> MapSet.union(Constants.ignored_dirs())

      summaries =
        root
        |> collect_candidate_files(root, ignored)
        |> Enum.sort_by(fn {_full_path, rel_path, depth} -> {depth, rel_path} end)
        |> Enum.reduce_while([], fn {full_path, rel_path, _depth}, acc ->
          case summarize_candidate(full_path, rel_path, max_symbols) do
            nil ->
              {:cont, acc}

            %FileSummary{} = summary ->
              next = [summary | acc]

              if length(next) >= max_files do
                {:halt, next}
              else
                {:cont, next}
              end
          end
        end)

      {:ok, Enum.reverse(summaries)}
    end
  end

  @doc """
  Bang variant of `index/2`.
  """
  @spec index!(Path.t(), opts()) :: [FileSummary.t()]
  def index!(root, opts \\ []) do
    case index(root, opts) do
      {:ok, summaries} -> summaries
      {:error, reason} -> raise "Repo Compass index failed: #{inspect(reason)}"
    end
  end

  defp collect_candidate_files(root, current, ignored) do
    case File.ls(current) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          full_path = Path.join(current, entry)

          case File.lstat(full_path) do
            {:ok, %File.Stat{type: :directory}} ->
              if should_descend?(entry, ignored) do
                collect_candidate_files(root, full_path, ignored)
              else
                []
              end

            {:ok, %File.Stat{type: :regular}} ->
              rel_path = Path.relative_to(full_path, root)
              [{full_path, rel_path, path_depth(rel_path)}]

            _ ->
              []
          end
        end)

      {:error, reason} ->
        Logger.debug(
          "Repo Compass indexer skipped unreadable directory #{current}: #{inspect(reason)}"
        )

        []
    end
  end

  defp should_descend?(entry, ignored) do
    not String.starts_with?(entry, ".") and not MapSet.member?(ignored, entry)
  end

  defp path_depth(rel_path) do
    rel_path
    |> Path.split()
    |> length()
  end

  defp summarize_candidate(full_path, rel_path, max_symbols) do
    basename = Path.basename(rel_path)
    ext = rel_path |> Path.extname() |> String.downcase()

    cond do
      MapSet.member?(@important_files, basename) ->
        %FileSummary{path: rel_path, kind: "project-file", symbols: []}

      ext == ".py" ->
        summarize_python_file(full_path, rel_path, max_symbols)

      Map.has_key?(@non_python_kinds, ext) ->
        %FileSummary{path: rel_path, kind: Map.fetch!(@non_python_kinds, ext), symbols: []}

      true ->
        nil
    end
  end

  defp summarize_python_file(full_path, rel_path, max_symbols) do
    with {:ok, content} <- File.read(full_path),
         true <- String.valid?(content) do
      %FileSummary{
        path: rel_path,
        kind: "python",
        symbols: summarize_python_symbols(content, max_symbols)
      }
    else
      _ -> nil
    end
  end

  defp summarize_python_symbols(content, max_symbols) do
    content
    |> split_lines()
    |> collect_python_symbols([], 0, max_symbols)
    |> Enum.reverse()
  end

  defp split_lines(content) do
    String.split(content, ~r/\r\n|\n|\r/, trim: false)
  end

  defp collect_python_symbols(_lines, acc, count, max_symbols) when count >= max_symbols, do: acc
  defp collect_python_symbols([], acc, _count, _max_symbols), do: acc

  defp collect_python_symbols([line | rest], acc, count, max_symbols) do
    cond do
      blank_or_comment?(line) ->
        collect_python_symbols(rest, acc, count, max_symbols)

      true ->
        case parse_top_level_class(line) do
          class_name when is_binary(class_name) ->
            methods = collect_class_methods(rest, indentation_size(line))
            symbol = format_class_symbol(class_name, methods)
            collect_python_symbols(rest, [symbol | acc], count + 1, max_symbols)

          _ ->
            case parse_top_level_function(line) do
              function_signature when is_binary(function_signature) ->
                collect_python_symbols(rest, [function_signature | acc], count + 1, max_symbols)

              _ ->
                collect_python_symbols(rest, acc, count, max_symbols)
            end
        end
    end
  end

  defp blank_or_comment?(line) do
    trimmed = String.trim_leading(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  defp parse_top_level_class(line) do
    if indentation_size(line) == 0 do
      case Regex.run(@top_level_class_regex, line) do
        [_, name] -> name
        _ -> nil
      end
    end
  end

  defp parse_top_level_function(line) do
    if indentation_size(line) == 0 do
      case Regex.run(@top_level_function_regex, line) do
        [_, name, raw_args] ->
          args = raw_args |> clean_argument_names() |> Enum.join(", ")
          "def #{name}(#{args})"

        _ ->
          nil
      end
    end
  end

  defp collect_class_methods(lines, class_indent) do
    lines
    |> Enum.reduce_while([], fn line, acc ->
      trimmed = String.trim_leading(line)
      indent = indentation_size(line)

      cond do
        trimmed == "" or String.starts_with?(trimmed, "#") ->
          {:cont, acc}

        indent <= class_indent ->
          {:halt, acc}

        true ->
          case Regex.run(@indented_method_regex, line) do
            [_, method_name] ->
              next_acc = if method_name in acc, do: acc, else: [method_name | acc]

              if length(next_acc) >= @max_class_methods do
                {:halt, next_acc}
              else
                {:cont, next_acc}
              end

            _ ->
              {:cont, acc}
          end
      end
    end)
    |> Enum.reverse()
  end

  defp format_class_symbol(class_name, []), do: "class #{class_name}"

  defp format_class_symbol(class_name, methods) do
    "class #{class_name} methods=#{Enum.join(methods, ",")}"
  end

  defp clean_argument_names(raw_args) do
    raw_args
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 in ["", "/", "*"]))
    |> Enum.map(fn arg ->
      arg
      |> String.replace(~r/\s*=.*$/, "")
      |> String.replace(~r/\s*:.*$/, "")
      |> String.trim_leading("*")
      |> String.trim()
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp indentation_size(line) do
    line
    |> String.to_charlist()
    |> Enum.take_while(&(&1 in [?\s, ?\t]))
    |> length()
  end

  defp to_mapset(list) when is_list(list), do: MapSet.new(list)
  defp to_mapset(%MapSet{} = set), do: set
end
