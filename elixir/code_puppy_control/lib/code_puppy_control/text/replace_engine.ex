defmodule CodePuppyControl.Text.ReplaceEngine do
  @moduledoc """
  Pure Elixir port of the Rust replace engine for exact/fuzzy text replacement.

  This module provides content-aware text replacement that combines:
  - Fast exact matching for literal text
  - Fuzzy Jaro-Winkler matching for inexact matches
  - Unified diff generation for the result

  ## Examples

      iex> ReplaceEngine.replace_in_content("hello world", [{"world", "universe"}])
      {:ok, %{modified: "hello universe", diff: "--- original\\n+++ modified\\n...", jw_score: nil}}

      iex> ReplaceEngine.replace_in_content("line1\\nline2\\nline3", [{"line2", "replaced"}])
      {:ok, %{modified: "line1\\nreplaced\\nline3", diff: "...", jw_score: nil}}

      iex> ReplaceEngine.replace_in_content("unchanged", [{"nomatch", "x"}])
      {:error, %{reason: "No suitable match in content (JW 0.000 < 0.95)", jw_score: 0.0, original: "unchanged"}}

  The fuzzy match threshold is 0.95, providing strict matching while still
  tolerating minor whitespace and formatting differences.
  """

  alias CodePuppyControl.Text.FuzzyMatch
  alias CodePuppyControl.Text.Diff

  @fuzzy_threshold 0.95

  @typedoc """
  A replacement tuple: `{old_string, new_string}`.
  """
  @type replacement :: {String.t(), String.t()}

  @typedoc """
  Successful replacement result.
  """
  @type success_result :: %{
          modified: String.t(),
          diff: String.t(),
          jw_score: float() | nil
        }

  @typedoc """
  Failed replacement result.
  """
  @type error_result :: %{
          reason: String.t(),
          jw_score: float(),
          original: String.t()
        }

  @doc """
  Applies a list of replacements to content using exact then fuzzy matching.

  Each replacement is a `{old_str, new_str}` tuple. Replacements are applied
  sequentially—each subsequent replacement sees the result of the previous.

  ## Algorithm

  1. For each replacement:
     - Skip if `old_str` is empty (nothing to match)
     - Try exact match first (replace first occurrence only)
     - Fall back to fuzzy match if exact fails
  2. Fuzzy matching uses Jaro-Winkler similarity ≥ 0.95
  3. On fuzzy failure, returns original content unchanged

  ## Options

  None currently supported. Options are reserved for future compatibility.

  ## Returns

    * `{:ok, %{modified: String.t(), diff: String.t(), jw_score: float() | nil}}` -
      Success. The `diff` is a unified diff string, or `""` if unchanged.
      `jw_score` is `nil` for exact matches, or the last fuzzy match score.

    * `{:error, %{reason: String.t(), jw_score: float(), original: String.t()}}` -
      Failure on any fuzzy mismatch. `original` is returned unchanged.

  ## Examples

      # Exact match
      iex> ReplaceEngine.replace_in_content("foo bar baz", [{"bar", "qux"}])
      {:ok, %{modified: "foo qux baz", diff: "--- original\\n+++ modified\\n@@ -1 +1 @@\\n-foo bar baz\\n+foo qux baz\\n", jw_score: nil}}

      # Multiple replacements
      iex> ReplaceEngine.replace_in_content("a b c", [{"a", "x"}, {"b", "y"}, {"c", "z"}])
      {:ok, %{modified: "x y z", diff: _, jw_score: nil}}

      # Empty replacements (no-op)
      iex> ReplaceEngine.replace_in_content("unchanged", [])
      {:ok, %{modified: "unchanged", diff: "", jw_score: nil}}

      # Empty old_str skipped
      iex> ReplaceEngine.replace_in_content("content", [{"", "new"}])
      {:ok, %{modified: "content", diff: "", jw_score: nil}}

      # Fuzzy match (minor whitespace differences)
      iex> ReplaceEngine.replace_in_content("line1\\n  indented\\nline3", [{"indented", "replaced"}])
      {:ok, %{modified: "line1\\n  replaced\\nline3", diff: _, jw_score: score}} when score >= 0.95

      # Fuzzy match with line deletion (empty new_str)
      iex> ReplaceEngine.replace_in_content("a\\nb\\nc", [{"b\\n", ""}])
      {:ok, %{modified: "a\\nc", diff: _, jw_score: score}} when score >= 0.95

      # Fuzzy failure
      iex> ReplaceEngine.replace_in_content("hello", [{"xyz", "abc"}])
      {:error, %{reason: reason, jw_score: score, original: "hello"}}
      when score < 0.95 and is_binary(reason)
  """
  @spec replace_in_content(String.t(), [replacement()]) ::
          {:ok, success_result()} | {:error, error_result()}
  def replace_in_content(content, replacements)
      when is_binary(content) and is_list(replacements) do
    # Handle empty inputs early
    if Enum.empty?(replacements) do
      {:ok,
       %{
         modified: content,
         diff: "",
         jw_score: nil
       }}
    else
      do_replace_in_content(content, replacements)
    end
  end

  defp do_replace_in_content(content, replacements) do
    original = content
    modified = content
    # Cached lines for fuzzy matching (nil until needed)
    modified_lines = nil
    # Track last fuzzy match score
    last_jw_score = nil

    Enum.reduce_while(replacements, {modified, modified_lines, last_jw_score}, fn {old_str,
                                                                                   new_str},
                                                                                  {mod, lines, jw} ->
      # Skip empty old_str - nothing to match
      if old_str == "" do
        {:cont, {mod, lines, jw}}
      else
        apply_replacement({old_str, new_str}, mod, lines, jw, original)
      end
    end)
    |> finalize_result(original)
  end

  # Apply a single replacement (either exact or fuzzy)
  defp apply_replacement({old_str, new_str}, modified, modified_lines, last_jw_score, original) do
    # Fast path: exact match - replace first occurrence only
    case try_exact_replace(modified, old_str, new_str) do
      {:ok, new_modified} ->
        # Invalidate cached lines since content changed
        {:cont, {new_modified, nil, last_jw_score}}

      :no_match ->
        # Fuzzy match path
        fuzzy_replace(modified, modified_lines, old_str, new_str, original, last_jw_score)
    end
  end

  # Try exact replacement - replaces only the first occurrence
  defp try_exact_replace(content, old_str, new_str) do
    if String.contains?(content, old_str) do
      # Replace first occurrence only
      new_modified =
        String.replace(content, old_str, new_str, global: false)

      {:ok, new_modified}
    else
      :no_match
    end
  end

  # Fuzzy replacement path
  defp fuzzy_replace(modified, modified_lines, old_str, new_str, original, _last_jw_score) do
    # Lazy initialization of cached lines for fuzzy matching
    lines =
      modified_lines ||
        String.split(modified, "\n")

    # Fuzzy match: find best window in the current content
    # FuzzyMatch expects list of strings as haystack_lines
    case FuzzyMatch.fuzzy_match_window(lines, old_str, threshold: @fuzzy_threshold) do
      {:ok,
       %{matched_text: _matched, start_line: start_line, end_line: end_line, similarity: score}} ->
        # Check if match meets the stricter threshold
        if score < @fuzzy_threshold do
          {:halt,
           {:error,
            %{
              reason:
                "No suitable match in content (JW #{Float.round(score, 3)} < #{@fuzzy_threshold})",
              jw_score: score,
              original: original
            }}}
        else
          # Splice replacement into lines
          new_lines = splice_replacement(lines, start_line, end_line, new_str)

          # Rebuild the string immediately so subsequent exact matches work
          new_modified = Enum.join(new_lines, "\n")

          # Preserve trailing newline if original had one
          new_modified = preserve_trailing_newline(new_modified, original)

          {:cont, {new_modified, new_lines, score}}
        end

      :no_match ->
        # Get the best score for error reporting (match without threshold)
        # Call again without threshold to get the actual best match
        case FuzzyMatch.fuzzy_match_window(lines, old_str, threshold: 0.0) do
          {:ok, %{similarity: score}} ->
            {:halt,
             {:error,
              %{
                reason:
                  "No suitable match in content (JW #{Float.round(score, 3)} < #{@fuzzy_threshold})",
                jw_score: score,
                original: original
              }}}

          _ ->
            # No match at all, report 0.0
            {:halt,
             {:error,
              %{
                reason: "No suitable match in content (JW 0.000 < #{@fuzzy_threshold})",
                jw_score: 0.0,
                original: original
              }}}
        end
    end
  end

  # Splice replacement into lines: replace [start_line, end_line) with new_lines
  # Handle empty new_str: trim trailing newlines, if empty → delete lines (splice in empty list)
  defp splice_replacement(lines, start_line, end_line, new_str) do
    # Parse new_str into lines for splicing
    # Handle empty new_str: trim trailing newlines, if empty → return empty list
    new_lines =
      if new_str == "" do
        []
      else
        trimmed = String.trim_trailing(new_str, "\n")

        if trimmed == "" do
          []
        else
          String.split(trimmed, "\n")
        end
      end

    # Splice: replace [start_line, end_line) with new_lines
    {prefix, _old, suffix} =
      lines
      |> Enum.with_index()
      |> Enum.split_with(fn {_line, idx} -> idx < start_line end)
      |> then(fn {prefix, rest} ->
        # rest starts at start_line, we need to skip (end_line - start_line) elements
        skip_count = end_line - start_line
        {skipped, suffix} = Enum.split(rest, skip_count)
        {prefix, skipped, suffix}
      end)

    # Extract just the line strings (drop indices)
    prefix_lines = Enum.map(prefix, fn {line, _idx} -> line end)
    suffix_lines = Enum.map(suffix, fn {line, _idx} -> line end)

    # Combine: prefix + new_lines + suffix
    prefix_lines ++ new_lines ++ suffix_lines
  end

  # Preserve trailing newline if original had one
  defp preserve_trailing_newline(modified, original) do
    if String.ends_with?(original, "\n") and not String.ends_with?(modified, "\n") do
      modified <> "\n"
    else
      modified
    end
  end

  # Finalize the result - generate diff and build return value
  defp finalize_result({:error, error_result}, _original) do
    {:error, error_result}
  end

  defp finalize_result({modified, _lines, last_jw_score}, original) do
    # Generate unified diff
    diff =
      if modified == original do
        ""
      else
        Diff.unified_diff(original, modified,
          context_lines: 3,
          from_file: "original",
          to_file: "modified"
        )
      end

    {:ok,
     %{
       modified: modified,
       diff: diff,
       jw_score: last_jw_score
     }}
  end

  # Handle early halt from Enum.reduce_while error case
  defp finalize_result({:halt, result}, _original) do
    result
  end
end
