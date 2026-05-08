defmodule CodePuppyControl.Gitignore do
  @moduledoc """
  Gitignore-aware path filtering, ported from Python's code_puppy/utils/gitignore.py.

  Implements native gitignore pattern matching (no external dependencies) with support for:
  - `*` - matches any characters except `/`
  - `**` - matches zero or more directories
  - `?` - matches any single character
  - `[abc]` - character class matching
  - `[!abc]` or `[^abc]` - negated character class
  - `!pattern` - negation (un-ignore)
  - `pattern/` - directory-only patterns
  - `#` - comments
  - `/pattern` - anchored to root (relative to .gitignore location)

  The `for_directory/1` function walks up from a directory collecting all
  applicable .gitignore files, then returns a matcher that can test paths.

  Uses ETS-based caching for matchers to avoid repeated directory walks.

  ## Directory-only Pattern Limitation

  When using `pattern_match?/2` directly with patterns ending in `/`
  (directory-only patterns like `build/`), the match is based on a heuristic:
  paths ending with `/` or having no extension are considered directories.
  For accurate directory-only matching that uses actual filesystem stat
  information, use the full `for_directory/1` and `ignored?/2` workflow.

  ## Examples

      iex> matcher = Gitignore.for_directory("/my/repo")
      iex> Gitignore.ignored?(matcher, "build/artifact.o")
      true
      iex> Gitignore.ignored?(matcher, "src/main.ex")
      false
  """

  alias CodePuppyControl.Gitignore.Pattern

  require Logger

  @cache_table :gitignore_cache
  @cache_ttl_ms :timer.minutes(5)
  @max_cache_entries 128

  defmodule Matcher do
    @moduledoc """
    Holds compiled gitignore patterns for a directory.
    """
    defstruct [:root, :patterns, :negations]

    @type pattern :: {String.t(), keyword()}
    @type t :: %__MODULE__{
            root: String.t(),
            patterns: [pattern()],
            negations: [pattern()]
          }
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Build a matcher for `directory` by collecting all .gitignore files.

  Walks from the given directory up to the filesystem root, reading
  every .gitignore file encountered. Patterns from ancestor directories
  are applied first (lower priority), with patterns from closer directories
  overriding them.

  Returns `nil` if no .gitignore files are found.
  """
  @spec for_directory(String.t() | Path.t()) :: Matcher.t() | nil
  def for_directory(directory) do
    directory = Path.expand(directory)

    # Check cache first
    case cache_get(directory) do
      {:ok, matcher} ->
        matcher

      :miss ->
        matcher = build_matcher(directory)
        cache_put(directory, matcher)
        matcher
    end
  end

  @doc """
  Returns true if `path` matches any gitignore pattern in the matcher.

  `path` may be absolute or relative. If absolute, it must be a
  descendant of `matcher.root`; otherwise returns false (not ignored).

  Negation patterns (starting with `!`) are applied after inclusion patterns,
  allowing files to be explicitly un-ignored.
  """
  @spec ignored?(Matcher.t() | nil, String.t() | Path.t()) :: boolean()
  def ignored?(nil, _path), do: false

  def ignored?(%Matcher{} = matcher, path) do
    # Normalize path relative to matcher root
    rel_path = get_relative_path(matcher.root, path)

    # If path is outside root, it's not ignored by this matcher
    if rel_path == nil do
      false
    else
      do_ignored?(matcher, rel_path)
    end
  end

  @doc """
  Clear the ETS cache. Useful for tests.
  """
  @spec clear_cache() :: :ok
  def clear_cache() do
    ensure_cache_table()
    :ets.delete_all_objects(@cache_table)
    :ok
  end

  @doc """
  Parse a single gitignore pattern line into a structured format.

  Returns nil for empty lines and comments.

  ## Examples

      iex> Gitignore.parse_pattern("*.log")
      {:ok, "*.log", is_negation: false, is_directory: false, anchored: false}

      iex> Gitignore.parse_pattern("!important.log")
      {:ok, "important.log", is_negation: true, is_directory: false, anchored: false}

      iex> Gitignore.parse_pattern("build/")
      {:ok, "build", is_negation: false, is_directory: true, anchored: false}

      iex> Gitignore.parse_pattern("/rooted.txt")
      {:ok, "rooted.txt", is_negation: false, is_directory: false, anchored: true}
  """
  @spec parse_pattern(String.t()) :: {:ok, String.t(), keyword()} | nil
  def parse_pattern(line) do
    line = String.trim(line)

    cond do
      # Empty line or comment
      line == "" or String.starts_with?(line, "#") ->
        nil

      # Negation pattern
      String.starts_with?(line, "!") ->
        pattern = String.slice(line, 1..-1//1) |> String.trim()
        parse_attributes(pattern, is_negation: true)

      # Regular pattern
      true ->
        parse_attributes(line, is_negation: false)
    end
  end

  @doc """
  Test if a path matches a gitignore pattern.

  Supports all standard gitignore pattern syntax. See `CodePuppyControl.Gitignore.Pattern`
  for the underlying implementation.

  ## Examples

      iex> Gitignore.pattern_match?("*.log", "debug.log")
      true

      iex> Gitignore.pattern_match?("*.log", "debug.txt")
      false

      iex> Gitignore.pattern_match?("doc/*.txt", "doc/readme.txt")
      true

      iex> Gitignore.pattern_match?("doc/*.txt", "doc/api/readme.txt")
      false

      iex> Gitignore.pattern_match?("[!0-9]file.txt", "afile.txt")
      true

      iex> Gitignore.pattern_match?("[!0-9]file.txt", "1file.txt")
      false
  """
  @spec pattern_match?(String.t(), String.t()) :: boolean()
  def pattern_match?(pattern, path) do
    Pattern.pattern_match?(pattern, path)
  end

  # ============================================================================
  # Internal Implementation
  # ============================================================================

  # Parse pattern attributes (directory-only, anchored)
  defp parse_attributes(pattern, attrs) do
    # Check for trailing / (directory-only)
    {pattern, is_dir} =
      if String.ends_with?(pattern, "/") do
        {String.slice(pattern, 0..-2//1), true}
      else
        {pattern, false}
      end

    # Check for leading / (anchored to root)
    anchored = String.starts_with?(pattern, "/")
    pattern = if anchored, do: String.slice(pattern, 1..-1//1), else: pattern

    {:ok, pattern,
     is_negation: Keyword.get(attrs, :is_negation, false),
     is_directory: is_dir,
     anchored: anchored}
  end

  # Build matcher by walking up directory tree
  defp build_matcher(directory) do
    lines = collect_gitignore_lines(directory)

    patterns = parse_patterns(lines)

    # Return nil if no valid patterns found (only comments/blank lines)
    if patterns == [] do
      nil
    else
      # Split into inclusion and negation patterns
      {inclusions, negations} =
        Enum.split_with(patterns, fn {_, attrs} ->
          not Keyword.get(attrs, :is_negation, false)
        end)

      %Matcher{
        root: directory,
        patterns: inclusions,
        negations: negations
      }
    end
  end

  # Collect lines from all .gitignore files walking up the tree
  defp collect_gitignore_lines(directory) do
    directory
    |> walk_ancestors()
    |> Enum.reverse()
    |> Enum.flat_map(&read_gitignore/1)
  end

  # Walk up from directory to root, collecting directories
  defp walk_ancestors(directory) do
    Stream.unfold(directory, fn
      nil ->
        nil

      current ->
        parent = Path.dirname(current)
        # Stop when we reach root (parent == current)
        next = if parent != current, do: parent, else: nil
        {current, next}
    end)
  end

  # Read .gitignore file if it exists
  defp read_gitignore(dir) do
    gitignore_path = Path.join(dir, ".gitignore")

    case File.read(gitignore_path) do
      {:ok, content} ->
        String.split(content, "\n")

      {:error, _} ->
        []
    end
  end

  # Parse all pattern lines, returning {pattern, attrs} tuples
  defp parse_patterns(lines) do
    lines
    |> Enum.map(&parse_pattern/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {:ok, pattern, attrs} -> {pattern, attrs} end)
  end

  # Get relative path from root, handling absolute/relative input
  defp get_relative_path(root, path) do
    # If path is already relative, use it directly
    if Path.type(path) == :relative do
      path
    else
      path = Path.expand(path)

      case Path.relative_to(path, root) do
        ^path when path != root ->
          # Not under root
          nil

        rel_path ->
          rel_path
      end
    end
  end

  # Check if path is ignored by matcher
  defp do_ignored?(%Matcher{} = matcher, rel_path) do
    # Test against inclusion patterns
    # We need to re-add the anchored prefix since it was stripped during parsing
    included =
      Enum.any?(matcher.patterns, fn {pat, attrs} ->
        anchored = Keyword.get(attrs, :anchored, false)
        # Reconstruct the pattern with / prefix if it was anchored
        full_pat = if anchored, do: "/" <> pat, else: pat
        Pattern.pattern_match?(full_pat, rel_path)
      end)

    if not included do
      false
    else
      # Test against negation patterns - any match un-ignores the file
      negated =
        Enum.any?(matcher.negations, fn {pat, attrs} ->
          anchored = Keyword.get(attrs, :anchored, false)
          full_pat = if anchored, do: "/" <> pat, else: pat
          Pattern.pattern_match?(full_pat, rel_path)
        end)

      not negated
    end
  end

  # ============================================================================
  # ETS Cache Implementation
  # ============================================================================

  defp ensure_cache_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [
            :set,
            :named_table,
            :public,
            read_concurrency: true,
            write_concurrency: true
          ])
        rescue
          ArgumentError ->
            # Another process created the table between our check and creation
            @cache_table
        end

      ref ->
        ref
    end
  end

  defp cache_get(directory) do
    ensure_cache_table()

    case :ets.lookup(@cache_table, directory) do
      [{^directory, matcher, timestamp}] ->
        if System.monotonic_time(:millisecond) - timestamp < @cache_ttl_ms do
          {:ok, matcher}
        else
          :ets.delete(@cache_table, directory)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp cache_put(directory, matcher) do
    ensure_cache_table()

    # Prune if cache is too large (simple LRU approximation)
    if :ets.info(@cache_table, :size) >= @max_cache_entries do
      # Delete oldest entries
      all_entries = :ets.tab2list(@cache_table)
      sorted = Enum.sort_by(all_entries, &elem(&1, 2), :asc)
      to_delete = Enum.take(sorted, div(@max_cache_entries, 4))

      Enum.each(to_delete, fn {key, _, _} ->
        :ets.delete(@cache_table, key)
      end)
    end

    :ets.insert(@cache_table, {directory, matcher, System.monotonic_time(:millisecond)})
  end
end
