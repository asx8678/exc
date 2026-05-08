defmodule CodePuppyControl.CodeContext do
  @moduledoc """
  Symbol-augmented code exploration with caching.
  """
  alias CodePuppyControl.FileOps.{Lister, Reader}
  alias CodePuppyControl.{Parser, Tokens.Estimator}

  @cache_table :code_context_cache
  @cache_ttl_ms :timer.minutes(5)
  @default_max_files 50
  @extensions %{
    ".py" => "python",
    ".rs" => "rust",
    ".js" => "javascript",
    ".jsx" => "javascript",
    ".ts" => "typescript",
    ".tsx" => "typescript",
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".heex" => "elixir",
    ".go" => "go",
    ".java" => "java",
    ".rb" => "ruby",
    ".c" => "c",
    ".cpp" => "cpp",
    ".h" => "c",
    ".hpp" => "cpp"
  }
  @supported Map.keys(@extensions)

  @doc false
  def init_cache do
    try do
      :ets.new(@cache_table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    rescue
      ArgumentError -> @cache_table
    end
  end

  @on_load :init_on_load
  def init_on_load,
    do:
      (
        init_cache()
        :ok
      )

  def ensure_cache_exists do
    if :ets.whereis(@cache_table) == :undefined, do: init_cache()
    @cache_table
  end

  @doc "Explore a file — read content, extract symbols, count tokens. Options: include_content, force_refresh"
  @spec explore_file(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def explore_file(file_path, opts \\ []) do
    abs_path = Path.expand(file_path)
    include_content = Keyword.get(opts, :include_content, true)

    if Keyword.get(opts, :force_refresh, false) do
      do_explore_file(abs_path, include_content)
    else
      case get_cached(abs_path) do
        {:ok, cached} -> {:ok, filter_content(cached, include_content)}
        :miss -> do_explore_file(abs_path, include_content)
      end
    end
  end

  defp do_explore_file(abs_path, include_content) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, %{content: content, size: size, num_lines: lines}} <-
           Reader.read_file(abs_path, normalize_eol: true),
         lang = detect_language(abs_path),
         {:ok, outline} <- Parser.extract_symbols(content, lang || "unknown") do
      errors = outline["errors"] || []

      result = %{
        file_path: abs_path,
        content: if(include_content, do: content, else: nil),
        language: lang || "unknown",
        outline: %{
          language: outline["language"] || lang || "unknown",
          symbols: outline["symbols"] || [],
          extraction_time_ms:
            outline["extraction_time_ms"] || System.monotonic_time(:millisecond) - start_time,
          success: outline["success"] || false,
          errors: errors
        },
        file_size: size,
        num_lines: lines,
        num_tokens: Estimator.estimate_tokens(content),
        parse_time_ms: System.monotonic_time(:millisecond) - start_time,
        has_errors: errors != [],
        error_message: if(errors != [], do: Enum.join(errors, ", "), else: nil),
        cached_at: System.system_time(:millisecond)
      }

      put_cached(abs_path, result)
      {:ok, filter_content(result, include_content)}
    else
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  @doc "Get symbol outline for a file. Options: max_depth"
  @spec get_outline(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_outline(file_path, opts \\ []) do
    abs_path = Path.expand(file_path)

    case File.read(abs_path) do
      {:ok, content} ->
        lang = detect_language(abs_path)
        start = System.monotonic_time(:millisecond)

        case Parser.extract_symbols(content, lang || "unknown") do
          {:ok, outline} ->
            symbols = outline["symbols"] || []

            filtered =
              if max_depth = Keyword.get(opts, :max_depth),
                do: Enum.filter(symbols, &((&1["depth"] || 0) <= max_depth)),
                else: symbols

            {:ok,
             %{
               language: outline["language"] || lang || "unknown",
               symbols: filtered,
               extraction_time_ms: System.monotonic_time(:millisecond) - start,
               success: outline["success"] || false,
               errors: outline["errors"] || []
             }}

          {:error, reason} ->
            {:error, format_error(reason)}
        end

      {:error, reason} ->
        {:error, "Failed to read file: #{format_error(reason)}"}
    end
  end

  @doc "Explore directory. Options: pattern, recursive, max_files, include_content"
  @spec explore_directory(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def explore_directory(directory, opts \\ []) do
    abs_dir = Path.expand(directory)
    pattern = Keyword.get(opts, :pattern, "*")
    max_files = Keyword.get(opts, :max_files, @default_max_files)

    with {:ok, files} <-
           Lister.list_files(abs_dir,
             recursive: Keyword.get(opts, :recursive, true),
             max_files: max_files * 2
           ) do
      files
      |> Enum.filter(&(Access.get(&1, :type) == :file and matches_pattern?(&1.path, pattern)))
      |> Enum.take(max_files)
      |> Enum.map(&Path.join(abs_dir, &1.path))
      |> Task.async_stream(&explore_or_nil(&1, Keyword.get(opts, :include_content, false)),
        max_concurrency: CodePuppyControl.Runtime.Limits.io_concurrency(),
        timeout: 10_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()
      |> Enum.flat_map(fn
        {:ok, nil} -> []
        {:ok, r} -> [r]
        {:exit, _} -> []
      end)
      |> then(&{:ok, &1})
    end
  end

  defp explore_or_nil(path, include_content) do
    case explore_file(path, include_content: include_content) do
      {:ok, r} -> r
      {:error, _} -> nil
    end
  end

  @doc "Find symbol definitions across a directory."
  @spec find_symbol_definitions(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def find_symbol_definitions(directory, symbol_name) do
    abs_dir = Path.expand(directory)

    with {:ok, files} <- Lister.list_files(abs_dir, recursive: true, max_files: 1000) do
      files
      |> Enum.filter(&(Access.get(&1, :type) == :file and supported_ext?(&1.path)))
      |> Enum.map(&Path.join(abs_dir, &1.path))
      |> Task.async_stream(&find_in_file(&1, symbol_name),
        max_concurrency: CodePuppyControl.Runtime.Limits.io_concurrency(),
        timeout: 5_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()
      |> Enum.flat_map(fn
        {:ok, m} -> m
        {:exit, _} -> []
      end)
      |> then(&{:ok, &1})
    end
  end

  defp find_in_file(p, symbol_name) do
    case get_outline(p) do
      {:ok, %{symbols: syms}} ->
        Enum.filter(syms, fn s -> (s["name"] || "") == symbol_name end)
        |> Enum.map(fn s ->
          content =
            case Reader.read_file(p, start_line: s["start_line"] || 1, num_lines: 1) do
              {:ok, %{content: c}} -> String.trim(c)
              _ -> nil
            end

          %{file_path: p, symbol: s, line_content: content}
        end)

      {:error, _} ->
        []
    end
  end

  @doc "Get cache statistics: size, hits, misses, hit_rate."
  @spec cache_stats() :: map()
  def cache_stats do
    ensure_cache_exists()

    size =
      case :ets.select_count(@cache_table, [{{:_, %{cached_at: :_}}, [], [true]}]) do
        c when is_integer(c) -> c
        _ -> 0
      end

    stats =
      case :ets.lookup(@cache_table, :_cache_stats) do
        [{:_cache_stats, s}] -> s
        [] -> %{hits: 0, misses: 0}
      end

    total = stats.hits + stats.misses

    %{
      size: size,
      hits: stats.hits,
      misses: stats.misses,
      hit_rate: if(total > 0, do: Float.round(stats.hits / total, 4), else: 0.0)
    }
  end

  @doc "Invalidate cache entries. Returns count removed."
  @spec invalidate_cache(String.t() | nil) :: integer()
  def invalidate_cache(file_path \\ nil) do
    ensure_cache_exists()

    if file_path do
      :ets.delete(@cache_table, Path.expand(file_path))
      1
    else
      case :ets.info(@cache_table, :size) do
        s when is_integer(s) ->
          :ets.delete_all_objects(@cache_table)
          s

        _ ->
          0
      end
    end
  end

  # Cache operations
  defp get_cached(abs_path) do
    ensure_cache_exists()

    case :ets.lookup(@cache_table, abs_path) do
      [{^abs_path, entry}] ->
        if System.system_time(:millisecond) - (entry[:cached_at] || 0) < @cache_ttl_ms do
          update_counter(2)
          {:ok, entry}
        else
          :ets.delete(@cache_table, abs_path)
          update_counter(3)
          :miss
        end

      [] ->
        update_counter(3)
        :miss
    end
  end

  defp put_cached(abs_path, result),
    do:
      (
        ensure_cache_exists()
        :ets.insert(@cache_table, {abs_path, result})
      )

  defp update_counter(pos) do
    :ets.update_counter(
      @cache_table,
      :_cache_stats,
      {pos, 1},
      {:_cache_stats, %{hits: 0, misses: 0}}
    )
  catch
    _, _ -> :ok
  end

  defp filter_content(r, true), do: r
  defp filter_content(r, false), do: Map.put(r, :content, nil)
  defp detect_language(p), do: Map.get(@extensions, String.downcase(Path.extname(p)))
  defp matches_pattern?(_, "*"), do: true

  defp matches_pattern?(p, pat) do
    ext = String.downcase(Path.extname(p))
    pat_ext = String.downcase(Path.extname(pat))

    if String.starts_with?(pat, "*") and pat_ext != "",
      do: ext == pat_ext,
      else: String.contains?(p, pat)
  end

  defp supported_ext?(p), do: String.downcase(Path.extname(p)) in @supported
  defp format_error(r) when is_binary(r), do: r
  defp format_error(r), do: inspect(r)
end
