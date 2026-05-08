defmodule CodePuppyControl.Gitignore.Pattern do
  @moduledoc """
  Core pattern matching logic for gitignore patterns.

  This module handles the low-level pattern matching operations including:
  - Wildcard matching (*, ?, [...] character classes)
  - Double-star (**) path matching
  - Anchored vs unanchored pattern handling
  - Escaped character handling

  ## Limitations

  Pattern matching against individual path strings (via `pattern_match?/2`) cannot
  distinguish between files and directories since we don't stat the filesystem.
  Patterns ending in `/` (like `build/`) will match both files and directories.
  The `CodePuppyControl.FileOps.walk_directory/6` function handles this correctly
  by using stat information from the filesystem.

  For accurate directory-only matching, use the full `Gitignore.for_directory/1`
  and `Gitignore.ignored?/2` workflow which operates on actual file system
  entries with type information.
  """

  @doc """
  Test if a path matches a gitignore pattern.

  Supports all standard gitignore pattern syntax including:
  - `*` - matches any characters except `/`
  - `**` - matches zero or more directories
  - `?` - matches any single character except `/`
  - `[abc]` - character class matching
  - `[!abc]` or `[^abc]` - negated character class
  - `pattern/` - directory-only patterns (with limitation noted in moduledoc)
  - `/pattern` - anchored to root

  ## Examples

      iex> Pattern.pattern_match?("*.log", "debug.log")
      true

      iex> Pattern.pattern_match?("*.log", "debug.txt")
      false

      iex> Pattern.pattern_match?("doc/*.txt", "doc/readme.txt")
      true

      iex> Pattern.pattern_match?("doc/*.txt", "doc/api/readme.txt")
      false

      iex> Pattern.pattern_match?("[!0-9]file.txt", "afile.txt")
      true

      iex> Pattern.pattern_match?("[!0-9]file.txt", "1file.txt")
      false
  """
  @spec pattern_match?(String.t(), String.t()) :: boolean()
  def pattern_match?(pattern, path) do
    # Check if pattern ends with / (directory-only)
    {pattern, dir_only} =
      if String.ends_with?(pattern, "/") do
        {String.slice(pattern, 0..-2//1), true}
      else
        {pattern, false}
      end

    # Check if pattern is anchored (starts with /)
    anchored = String.starts_with?(pattern, "/")
    pattern = if anchored, do: String.slice(pattern, 1..-1//1), else: pattern

    matches = matches_pattern?(pattern, path, anchored)

    if dir_only do
      # Directory-only pattern - since we don't stat, we use a heuristic:
      # paths ending with / or having no extension are likely directories
      matches and (String.ends_with?(path, "/") or not String.contains?(path, "."))
    else
      matches
    end
  end

  # Main pattern matching logic
  defp matches_pattern?(pattern, path, anchored) do
    # Handle escaped characters first (convert to special marker)
    {pattern, path} = handle_escaped_chars(pattern, path)

    # Normalize path separators
    path = String.replace(path, "\\", "/")
    pattern = String.replace(pattern, "\\", "/")

    # Split pattern into segments for ** handling
    pat_segments = String.split(pattern, "/")
    path_segments = String.split(path, "/")

    cond do
      # Pattern contains ** (matches across directories)
      Enum.member?(pat_segments, "**") ->
        matches_double_star?(pat_segments, path_segments, anchored)

      # Anchored pattern (must match from root)
      anchored ->
        segments_match?(pat_segments, Enum.take(path_segments, length(pat_segments)))

      # Unanchored pattern (can match at any depth)
      true ->
        matches_unanchored?(pat_segments, path_segments)
    end
  end

  # Convert escaped characters to temporary markers to protect them during matching
  defp handle_escaped_chars(pattern, path) do
    # Replace escaped special chars in pattern with unique markers
    pattern =
      pattern
      |> String.replace("\\*", "<<ESCAPED_STAR>>")
      |> String.replace("\\?", "<<ESCAPED_QUESTION>>")
      |> String.replace("\\[", "<<ESCAPED_LBRACKET>>")
      |> String.replace("\\]", "<<ESCAPED_RBRACKET>>")

    # Also escape the same chars in path for exact matching
    path =
      path
      |> String.replace("*", "<<ESCAPED_STAR>>")
      |> String.replace("?", "<<ESCAPED_QUESTION>>")
      |> String.replace("[", "<<ESCAPED_LBRACKET>>")
      |> String.replace("]", "<<ESCAPED_RBRACKET>>")

    {pattern, path}
  end

  # Match ** patterns (can span directory boundaries)
  defp matches_double_star?(pat_segments, path_segments, _anchored) do
    # Split pattern around **
    {before_star, after_star} = split_at_double_star(pat_segments)

    cond do
      # ** at start: matches at any depth (including root)
      # e.g., **/deep_file matches deep_file, a/deep_file, a/b/deep_file
      before_star == [] ->
        if after_star == [] do
          # Just ** - matches anything
          true
        else
          # Try to match suffix at any position in path
          suffix_len = length(after_star)

          if suffix_len > length(path_segments) do
            false
          else
            # Match suffix at the end (or at root if that's where it is)
            max_start = max(length(path_segments) - suffix_len, 0)

            Enum.any?(0..max_start, fn start_idx ->
              suffix = Enum.slice(path_segments, start_idx, suffix_len)
              segments_match?(after_star, suffix)
            end)
          end
        end

      # ** at end: matches anything nested under prefix
      # e.g., docs/** matches docs/readme.md, docs/api/reference.md
      after_star == [] ->
        prefix_len = length(before_star)

        if prefix_len > length(path_segments) do
          false
        else
          prefix_segments = Enum.take(path_segments, prefix_len)
          segments_match?(before_star, prefix_segments)
        end

      # ** in middle: prefix must match before **, suffix must match after
      true ->
        prefix_len = length(before_star)
        suffix_len = length(after_star)

        if prefix_len + suffix_len > length(path_segments) do
          false
        else
          # Match prefix at start
          prefix_segments = Enum.take(path_segments, prefix_len)
          prefix_match = segments_match?(before_star, prefix_segments)

          # Match suffix at end (anywhere after prefix)
          min_suffix_start = prefix_len
          max_suffix_start = length(path_segments) - suffix_len

          prefix_match and
            Enum.any?(min_suffix_start..max_suffix_start, fn start_idx ->
              suffix = Enum.slice(path_segments, start_idx, suffix_len)
              segments_match?(after_star, suffix)
            end)
        end
    end
  end

  defp split_at_double_star(segments) do
    case Enum.split_while(segments, &(&1 != "**")) do
      {before, ["**" | after_rest]} -> {before, after_rest}
      {before, []} -> {before, []}
    end
  end

  # Check if pattern matches at any position in path
  # For patterns without "/", match against the basename (last segment) at any depth
  # For patterns with "/", match at the corresponding depth
  defp matches_unanchored?(pat_segments, path_segments) do
    pat_len = length(pat_segments)
    path_len = length(path_segments)

    if pat_len == 1 do
      # Pattern has no "/" (like "*.log") - matches against last segment at any depth
      # This matches Python pathspec behavior where unanchored patterns match at any depth
      last_segment = List.last(path_segments)
      segments_match?(pat_segments, [last_segment])
    else
      # Pattern has "/" (like "dir/*.txt"), can match at any depth
      if pat_len > path_len do
        false
      else
        Enum.any?(0..(path_len - pat_len), fn start_idx ->
          subsegments = Enum.slice(path_segments, start_idx, pat_len)
          segments_match?(pat_segments, subsegments)
        end)
      end
    end
  end

  # Check if two segment lists match
  defp segments_match?([], []), do: true
  defp segments_match?([], _), do: false
  defp segments_match?(_, []), do: false

  defp segments_match?([pat_seg | pat_rest], [path_seg | path_rest]) do
    segment_match?(pat_seg, path_seg) and segments_match?(pat_rest, path_rest)
  end

  # Match a single segment
  defp segment_match?(pattern, path) do
    match_chars(String.to_charlist(pattern), String.to_charlist(path))
  end

  # Character-level matching with glob support
  defp match_chars([], []), do: true
  defp match_chars([], [_ | _]), do: false

  # * matches any characters except /
  defp match_chars([?* | pat_rest], path) do
    # Try all possible lengths for *
    {before_slash, _} = Enum.split_while(path, &(&1 != ?/))
    max_len = length(before_slash)

    Enum.any?(0..max_len, fn i ->
      {consumed, remaining} = Enum.split(path, i)
      # * cannot match /
      if Enum.any?(consumed, &(&1 == ?/)) do
        false
      else
        match_chars(pat_rest, remaining)
      end
    end)
  end

  # ? matches any single character except /
  defp match_chars([?\? | pat_rest], [p | path_rest]) when p != ?/,
    do: match_chars(pat_rest, path_rest)

  defp match_chars([?\? | _], _), do: false

  # Character class [abc] or [!abc]
  defp match_chars([?[ | pat_rest], [p | path_rest]) do
    case parse_char_class(pat_rest, [], true) do
      {:ok, {:negated, chars}, rest_of_pattern} ->
        # Negated class: match if p is NOT in chars
        if Enum.member?(chars, p) do
          false
        else
          match_chars(rest_of_pattern, path_rest)
        end

      {:ok, chars, rest_of_pattern} when is_list(chars) ->
        # Regular class: match if p is in chars
        if Enum.member?(chars, p) do
          match_chars(rest_of_pattern, path_rest)
        else
          false
        end

      :error ->
        false
    end
  end

  defp match_chars([?[ | _], []), do: false

  # Escaped characters
  defp match_chars([?\\, c | pat_rest], [p | path_rest]) when c == p,
    do: match_chars(pat_rest, path_rest)

  defp match_chars([?\\, _ | _], [_ | _]), do: false

  # Regular character match
  defp match_chars([c | pat_rest], [c | path_rest]), do: match_chars(pat_rest, path_rest)

  # No match - pattern char doesn't equal path char
  defp match_chars([_ | _], [_ | _]), do: false

  # No match - ran out of path but still have pattern
  defp match_chars([_ | _], []), do: false

  # Parse character class like [abc] or [!abc] or [^abc]
  # Returns {:ok, chars, rest_of_pattern} or {:ok, {:negated, chars}, rest_of_pattern}
  # where chars is a list of allowed characters

  # Track if we're at the first character to handle ] as literal
  defp parse_char_class(chars, acc, first_char)

  defp parse_char_class([], _acc, _), do: :error

  # Negated class starts with ! or ^ (only at first position)
  defp parse_char_class([?! | rest], acc, true), do: parse_char_class_negated(rest, acc, false)
  defp parse_char_class([?^ | rest], acc, true), do: parse_char_class_negated(rest, acc, false)

  # ] as first char is literal, otherwise it's closing the class
  defp parse_char_class([?] | rest], acc, true) do
    # ] at first position is literal
    parse_char_class(rest, [?] | acc], false)
  end

  defp parse_char_class([?] | rest], acc, false), do: {:ok, Enum.reverse(acc), rest}

  # Regular character
  defp parse_char_class([c | rest], acc, _) do
    # Handle ranges like a-z
    case rest do
      [?-, end_char | rest_after] when end_char != ?] and c < end_char ->
        chars = Enum.to_list(c..end_char)
        parse_char_class(rest_after, chars ++ acc, false)

      _ ->
        parse_char_class(rest, [c | acc], false)
    end
  end

  defp parse_char_class_negated([], _acc, _), do: :error

  # ] as first char in negated class is literal
  defp parse_char_class_negated([?] | rest], acc, true) do
    parse_char_class_negated(rest, [?] | acc], false)
  end

  # Closing bracket - return negated class
  defp parse_char_class_negated([?] | rest], acc, false),
    do: {:ok, {:negated, Enum.reverse(acc)}, rest}

  defp parse_char_class_negated([c | rest], acc, _) do
    case rest do
      [?-, end_char | rest_after] when end_char != ?] and c < end_char ->
        chars = Enum.to_list(c..end_char)
        parse_char_class_negated(rest_after, chars ++ acc, false)

      _ ->
        parse_char_class_negated(rest, [c | acc], false)
    end
  end
end
