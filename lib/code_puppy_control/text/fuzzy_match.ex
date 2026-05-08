defmodule CodePuppyControl.Text.FuzzyMatch do
  @moduledoc """
  Fuzzy window matching: sliding-window Jaro-Winkler similarity search.

  Port of `code_puppy_core/src/fuzzy_match.rs`.

  Finds the best matching window of lines from a haystack against a needle,
  using Jaro-Winkler similarity scoring with aggressive pre-filtering.

  ## Algorithm

  1. **Parse needle**: Strip trailing newlines and split into lines
  2. **Build prefix sum**: O(1) window length estimation
  3. **Sliding window**: For each potential window:
     - Pre-filter 1: First-line length check (cheap rejection)
     - Pre-filter 2: First character check (ultra-cheap rejection)
     - Pre-filter 3: Prefix-sum O(1) length estimation
     - Only compute Jaro-Winkler for promising candidates
  4. **Return best match** above threshold

  ## Performance Optimizations

  - Aggressive early rejection based on length ratios
  - Prefix-sum array for O(1) window length estimation
  - Reusable buffer for window string building
  - Early exit on exact match

  ## Examples

      iex> haystack = ["hello", "world", "foo", "bar"]
      iex> FuzzyMatch.fuzzy_match_window(haystack, "hello\\nworld")
      {:ok, %{matched_text: "hello\\nworld", start_line: 0, end_line: 2, similarity: 1.0}}

      iex> FuzzyMatch.fuzzy_match_window(["apple", "banana", "cherry"], "banana")
      {:ok, %{matched_text: "banana", start_line: 1, end_line: 2, similarity: 1.0}}

      iex> FuzzyMatch.fuzzy_match_window(["hello"], "xyz123-nomatch")
      :no_match
  """

  alias CodePuppyControl.Text.JaroWinkler

  # Constants from Rust implementation
  @jw_threshold 0.6
  @length_threshold_ratio 0.5

  @doc """
  Find the best matching window in haystack lines for the given needle.

  Uses sliding window with Jaro-Winkler similarity, with prefix-sum pre-filters
  for O(1) length estimation and aggressive early rejection.

  ## Options

  - `:threshold` - Minimum similarity score to return a match (default: 0.6)

  ## Returns

  - `{:ok, %{matched_text: String.t(), start_line: integer(), end_line: integer(), similarity: float()}}` - Match found
  - `:no_match` - No suitable match found (below threshold)

  ## Examples

      iex> haystack = ["hello", "world", "foo", "bar"]
      iex> FuzzyMatch.fuzzy_match_window(haystack, "hello\\nworld")
      {:ok, %{matched_text: "hello\\nworld", start_line: 0, end_line: 2, similarity: 1.0}}

      iex> haystack = ["def foo():", "    pass", "def bar():", "    return 1"]
      iex> {:ok, result} = FuzzyMatch.fuzzy_match_window(haystack, "def baz():")
      iex> result.start_line == 2  # Matches "def bar():" (typo tolerant)
      true
      iex> result.similarity > 0.8
      true
  """
  @spec fuzzy_match_window([String.t()], String.t(), keyword()) ::
          {:ok,
           %{
             matched_text: String.t(),
             start_line: integer(),
             end_line: integer(),
             similarity: float()
           }}
          | :no_match
  def fuzzy_match_window(haystack_lines, needle, opts \\ [])

  def fuzzy_match_window([], _needle, _opts), do: :no_match

  def fuzzy_match_window(_haystack_lines, "", _opts), do: :no_match

  def fuzzy_match_window(haystack_lines, needle, opts)
      when is_list(haystack_lines) and is_binary(needle) do
    threshold = Keyword.get(opts, :threshold, @jw_threshold)

    # Parse needle: strip trailing newlines and split into lines
    needle_stripped = String.trim_trailing(needle, "\n")
    needle_lines = String.split(needle_stripped, "\n")

    if needle_lines == [] do
      :no_match
    else
      do_fuzzy_match(haystack_lines, needle_lines, needle_stripped, threshold)
    end
  end

  defp do_fuzzy_match(haystack_lines, needle_lines, needle_stripped, threshold) do
    win_size = length(needle_lines)

    # If window is larger than haystack, we can't match
    if win_size > length(haystack_lines) do
      :no_match
    else
      haystack_len = length(haystack_lines)
      # UNICODE PRE-FILTER PARITY: Use byte_size for length heuristics (matches Rust)
      # Note: JaroWinkler computes its own length from codepoints, not using this value
      needle_len = byte_size(needle_stripped)

      # Pre-extract first line for cheap pre-filtering
      needle_first_line = List.first(needle_lines)
      # UNICODE PRE-FILTER PARITY: Use byte_size for length heuristics (matches Rust)
      needle_first_len = byte_size(needle_first_line)
      needle_first_char = String.first(needle_first_line)

      # Build prefix sum for O(1) window length estimation
      prefix_sum = build_prefix_sum(haystack_lines)

      max_start = haystack_len - win_size + 1

      # Search for best match
      find_best_match(
        haystack_lines,
        needle_stripped,
        needle_len,
        needle_first_len,
        needle_first_char,
        win_size,
        max_start,
        prefix_sum,
        threshold,
        0,
        0,
        nil,
        0.0
      )
    end
  end

  # Build cumulative character counts for O(1) window length estimation
  defp build_prefix_sum(haystack_lines) do
    haystack_lines
    |> do_build_prefix_sum([0], 0)
    |> Enum.reverse()
    |> List.to_tuple()
  end

  defp do_build_prefix_sum([], acc, _current), do: acc

  defp do_build_prefix_sum([line | rest], acc, current) do
    # UNICODE PRE-FILTER PARITY: Use byte_size/1 to match Rust byte-length heuristics
    new_current = current + byte_size(line)
    do_build_prefix_sum(rest, [new_current | acc], new_current)
  end

  # O(1) access to prefix sum
  defp prefix_at(prefix_sum, i), do: elem(prefix_sum, i)

  # Main search loop - optimized with aggressive pre-filtering
  # BUG FIX: Terminal clause with nil best_end - prevents ArithmeticError when threshold is 0.0
  # and all scores are 0.0 (best_end never gets updated from nil).
  defp find_best_match(
         _haystack_lines,
         _needle_stripped,
         _needle_len,
         _needle_first_len,
         _needle_first_char,
         _win_size,
         max_start,
         _prefix_sum,
         _threshold,
         start_idx,
         _best_start,
         nil,
         _best_score
       )
       when start_idx >= max_start do
    # No valid window found (best_end never updated)
    :no_match
  end

  # BUG FIX: Terminal clause with non-nil best_end - safe to do arithmetic.
  defp find_best_match(
         haystack_lines,
         _needle_stripped,
         _needle_len,
         _needle_first_len,
         _needle_first_char,
         _win_size,
         max_start,
         _prefix_sum,
         threshold,
         start_idx,
         best_start,
         best_end,
         best_score
       )
       when start_idx >= max_start do
    # End of search - check threshold (best_end is guaranteed non-nil here)
    if best_score >= threshold do
      # Build the matched text
      window_lines = Enum.slice(haystack_lines, best_start, best_end - best_start)
      matched_text = Enum.join(window_lines, "\n")

      {:ok,
       %{
         matched_text: matched_text,
         start_line: best_start,
         end_line: best_end,
         similarity: best_score
       }}
    else
      :no_match
    end
  end

  # Main search recursive clause - processes one window then recurses.
  # NOTE: Some parameters are unused in terminal processing but kept for consistency.
  defp find_best_match(
         haystack_lines,
         needle_stripped,
         needle_len,
         needle_first_len,
         needle_first_char,
         win_size,
         max_start,
         prefix_sum,
         threshold,
         start_idx,
         best_start,
         best_end,
         best_score
       ) do
    first_line = Enum.at(haystack_lines, start_idx)

    # Pre-filter 1: First-line length check (cheap rejection)
    # UNICODE PRE-FILTER PARITY: Use byte_size/1 to match Rust byte-length heuristics
    passed_filter1 =
      if needle_first_len > 0 do
        first_line_len = byte_size(first_line)
        len_diff = abs(first_line_len - needle_first_len)
        len_diff <= needle_first_len * @length_threshold_ratio
      else
        true
      end

    if passed_filter1 do
      # Pre-filter 2: First character check (ultra-cheap rejection)
      # UNICODE FIX: Use String.first/1 for character comparison (works with Unicode)
      passed_filter2 =
        if needle_first_char != nil and needle_first_char != "" do
          first_char = String.first(first_line)
          needle_first_char == first_char
        else
          true
        end

      if passed_filter2 do
        window_end = start_idx + win_size

        # O(1) window length estimation using prefix sum
        window_chars =
          prefix_at(prefix_sum, window_end) - prefix_at(prefix_sum, start_idx) +
            max(win_size - 1, 0)

        # Pre-filter 3: Length ratio check
        len_diff = abs(window_chars - needle_len)
        max_len = max(needle_len, window_chars)

        passed_filter3 =
          if max_len > 0 do
            len_diff <= max_len * @length_threshold_ratio
          else
            true
          end

        if passed_filter3 do
          # Build window string (expensive, but only for promising candidates)
          window_buffer =
            haystack_lines
            |> Enum.slice(start_idx, win_size)
            |> Enum.join("\n")

          # Compute Jaro-Winkler similarity
          score = JaroWinkler.similarity(window_buffer, needle_stripped)

          # Update best match if this is better
          new_best_start = if score > best_score, do: start_idx, else: best_start
          new_best_end = if score > best_score, do: window_end, else: best_end
          new_best_score = max(score, best_score)

          # Early exit if we found an exact match
          if new_best_score >= 1.0 do
            window_lines =
              Enum.slice(haystack_lines, new_best_start, new_best_end - new_best_start)

            matched_text = Enum.join(window_lines, "\n")

            {:ok,
             %{
               matched_text: matched_text,
               start_line: new_best_start,
               end_line: new_best_end,
               similarity: new_best_score
             }}
          else
            find_best_match(
              haystack_lines,
              needle_stripped,
              needle_len,
              needle_first_len,
              needle_first_char,
              win_size,
              max_start,
              prefix_sum,
              threshold,
              start_idx + 1,
              new_best_start,
              new_best_end,
              new_best_score
            )
          end
        else
          # Failed filter 3, skip to next
          find_best_match(
            haystack_lines,
            needle_stripped,
            needle_len,
            needle_first_len,
            needle_first_char,
            win_size,
            max_start,
            prefix_sum,
            threshold,
            start_idx + 1,
            best_start,
            best_end,
            best_score
          )
        end
      else
        # Failed filter 2, skip to next
        find_best_match(
          haystack_lines,
          needle_stripped,
          needle_len,
          needle_first_len,
          needle_first_char,
          win_size,
          max_start,
          prefix_sum,
          threshold,
          start_idx + 1,
          best_start,
          best_end,
          best_score
        )
      end
    else
      # Failed filter 1, skip to next
      find_best_match(
        haystack_lines,
        needle_stripped,
        needle_len,
        needle_first_len,
        needle_first_char,
        win_size,
        max_start,
        prefix_sum,
        threshold,
        start_idx + 1,
        best_start,
        best_end,
        best_score
      )
    end
  end

  @doc """
  Find the best matching window and return the match result in a format
  compatible with the Python bridge.

  Returns `{{start_line, end_line}, score}` where end_line can be nil.

  ## Examples

      iex> haystack = ["hello", "world", "foo", "bar"]
      iex> FuzzyMatch.find_best_window(haystack, "hello\\nworld")
      {{0, 2}, 1.0}

      iex> FuzzyMatch.find_best_window(["hello"], "nomatch")
      {nil, 0.0}
  """
  @spec find_best_window([String.t()], String.t(), keyword()) ::
          {{integer(), integer() | nil}, float()} | {nil, float()}
  def find_best_window(haystack_lines, needle, opts \\ []) do
    # BUG FIX: Always return the actual best score, even when below threshold.
    # Previously returned {nil, 0.0} unconditionally, but Rust returns the best score.
    threshold = Keyword.get(opts, :threshold, @jw_threshold)

    {best_span, best_score} = search_best_window(haystack_lines, needle, threshold)

    if best_score >= threshold do
      {best_span, best_score}
    else
      {nil, best_score}
    end
  end

  # Internal function that always returns the best window found and its score,
  # regardless of threshold. Used by find_best_window/3 to preserve scores.
  defp search_best_window(haystack_lines, needle, _threshold) do
    case fuzzy_match_window(haystack_lines, needle, threshold: 0.0) do
      {:ok, result} ->
        {{result.start_line, result.end_line}, result.similarity}

      :no_match ->
        # No match found even with threshold 0.0
        {nil, 0.0}
    end
  end
end
