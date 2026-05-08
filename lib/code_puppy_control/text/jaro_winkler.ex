defmodule CodePuppyControl.Text.JaroWinkler do
  @moduledoc """
  Optimized Jaro-Winkler string similarity algorithm.

  Port of `code_puppy_core/src/fuzzy_match.rs`.

  The Jaro similarity considers transpositions of characters, while the
  Winkler modification boosts scores for matching prefixes (up to 4 chars).

  ## Algorithm

  1. **Matching characters**: Characters are considered matching if they
     appear within `match_distance` positions of each other, where
     `match_distance = max(len1, len2) / 2 - 1`.

  2. **Transpositions**: A transposition occurs when matched characters
     appear in different orders in the two strings.

  3. **Jaro similarity**:
     ```
     jaro = (matches/len1 + matches/len2 + (matches - transpositions/2)/matches) / 3
     ```

  4. **Winkler boost**: `0.1 * prefix_len * (1.0 - jaro)` for matching prefix
     of up to 4 characters.

  ## Performance

  Uses binary pattern matching and tuple-based indexing for O(1) random access,
  avoiding the O(n) cost of List/Enum.at operations on charlists.

  ## Examples

      iex> JaroWinkler.similarity("hello", "hello")
      1.0

      iex> JaroWinkler.similarity("martha", "marhta")
      0.9611111111111111

      iex> JaroWinkler.similarity("code_puppy", "code_kitten") > JaroWinkler.similarity("puppy_code", "kitten_code")
      true
  """

  @doc """
  Compute Jaro-Winkler similarity between two strings.

  Returns a float between 0.0 (no similarity) and 1.0 (identical).

  ## Examples

      iex> JaroWinkler.similarity("hello", "hello")
      1.0

      iex> JaroWinkler.similarity("hello", "")
      0.0

      iex> JaroWinkler.similarity("", "")
      1.0

      iex> JaroWinkler.similarity("abcdef", "ghijkl")
      0.0

  """
  @spec similarity(binary(), binary()) :: float()
  def similarity(s1, s2) when s1 == s2, do: 1.0

  def similarity(s1, s2) when is_binary(s1) and is_binary(s2) do
    # CRITICAL FIX: Use the SAME representation for length and indexing.
    # String.length/1 counts graphemes but String.to_charlist/1 produces codepoints.
    # They disagree for multi-codepoint graphemes (e.g., "🇺🇸", combining chars).
    # We derive lengths from the tuple representation to ensure consistency.
    chars1 = s1 |> String.to_charlist() |> List.to_tuple()
    chars2 = s2 |> String.to_charlist() |> List.to_tuple()

    len1 = tuple_size(chars1)
    len2 = tuple_size(chars2)

    if len1 == 0 or len2 == 0 do
      0.0
    else
      do_similarity(chars1, chars2, len1, len2)
    end
  end

  defp do_similarity(chars1, chars2, len1, len2) do
    # Match distance: characters within this distance are considered matching
    match_distance = max(div(max(len1, len2), 2) - 1, 0)

    # Edge case: very short strings with match_distance=0 and different lengths
    if match_distance == 0 and len1 != len2 do
      0.0
    else
      compute_jaro_winkler(chars1, chars2, len1, len2, match_distance)
    end
  end

  # Get character at index from tuple
  defp char_at(chars, i), do: elem(chars, i)

  # (Unused but kept for potential future use)
  # defp in_bounds?(_chars, i) when i < 0, do: false
  # defp in_bounds?(chars, i), do: i < tuple_size(chars)

  defp compute_jaro_winkler(chars1, chars2, len1, len2, match_distance) do
    # PERFORMANCE FIX: Use tuples for O(1) access instead of lists.
    # Track matched characters using boolean tuples (initialized to false).
    s1_matched = :erlang.make_tuple(len1, false)
    s2_matched = :erlang.make_tuple(len2, false)

    # First pass: find matches
    {matches, s1_matched_tuple, s2_matched_tuple} =
      find_matches(chars1, chars2, len1, len2, match_distance, s1_matched, s2_matched, 0, 0)

    if matches == 0 do
      0.0
    else
      # Second pass: count transpositions
      transpositions =
        count_transpositions(chars1, chars2, len1, s1_matched_tuple, s2_matched_tuple)

      # Compute Jaro similarity
      matches_f = matches * 1.0
      len1_f = len1 * 1.0
      len2_f = len2 * 1.0
      transpositions_f = div(transpositions, 2) * 1.0

      jaro =
        (matches_f / len1_f +
           matches_f / len2_f +
           (matches_f - transpositions_f) / matches_f) / 3.0

      # Winkler modification: boost for common prefix (up to 4 chars)
      prefix_len = count_common_prefix(chars1, chars2, min(min(len1, len2), 4))
      winkler_boost = 0.1 * prefix_len * (1.0 - jaro)

      min(jaro + winkler_boost, 1.0)
    end
  end

  # Find matching characters - iterates through s1 and marks matches in s2
  # PERFORMANCE FIX: Use put_elem/3 for O(1) tuple updates instead of List.replace_at/3 (O(n)).
  defp find_matches(
         _chars1,
         _chars2,
         len1,
         _len2,
         _match_distance,
         s1_matched,
         s2_matched,
         matches,
         i
       )
       when i >= len1 do
    {matches, s1_matched, s2_matched}
  end

  defp find_matches(
         chars1,
         chars2,
         len1,
         len2,
         match_distance,
         s1_matched,
         s2_matched,
         matches,
         i
       ) do
    c1 = char_at(chars1, i)

    start_pos = max(i - match_distance, 0)
    end_pos = min(i + match_distance + 1, len2)

    case find_match_in_range(chars2, start_pos, end_pos, s2_matched, c1) do
      {:found, pos} ->
        # Use put_elem/3 for O(1) tuple update
        s1_matched_new = put_elem(s1_matched, i, true)
        s2_matched_new = put_elem(s2_matched, pos, true)

        find_matches(
          chars1,
          chars2,
          len1,
          len2,
          match_distance,
          s1_matched_new,
          s2_matched_new,
          matches + 1,
          i + 1
        )

      :not_found ->
        find_matches(
          chars1,
          chars2,
          len1,
          len2,
          match_distance,
          s1_matched,
          s2_matched,
          matches,
          i + 1
        )
    end
  end

  # Search for a match of c1 in the range [start_pos, end_pos) of chars2
  # PERFORMANCE FIX: Use elem/2 for O(1) tuple access instead of Enum.at/2 (O(n)).
  defp find_match_in_range(_chars2, pos, end_pos, _s2_matched, _c1) when pos >= end_pos do
    :not_found
  end

  defp find_match_in_range(chars2, pos, end_pos, s2_matched, c1) do
    if not elem(s2_matched, pos) and c1 == char_at(chars2, pos) do
      {:found, pos}
    else
      find_match_in_range(chars2, pos + 1, end_pos, s2_matched, c1)
    end
  end

  # Count transpositions: matched characters in different order
  defp count_transpositions(chars1, chars2, len1, s1_matched, s2_matched) do
    do_count_transpositions(chars1, chars2, len1, s1_matched, s2_matched, 0, 0, 0)
  end

  defp do_count_transpositions(
         _chars1,
         _chars2,
         len1,
         _s1_matched,
         _s2_matched,
         _k,
         transpositions,
         i
       )
       when i >= len1 do
    transpositions
  end

  defp do_count_transpositions(chars1, chars2, len1, s1_matched, s2_matched, k, transpositions, i) do
    if elem(s1_matched, i) do
      # Find next match in s2
      k_new = find_next_match_k(s2_matched, k, tuple_size(s2_matched))

      if k_new < tuple_size(s2_matched) and char_at(chars1, i) != char_at(chars2, k_new) do
        do_count_transpositions(
          chars1,
          chars2,
          len1,
          s1_matched,
          s2_matched,
          k_new + 1,
          transpositions + 1,
          i + 1
        )
      else
        do_count_transpositions(
          chars1,
          chars2,
          len1,
          s1_matched,
          s2_matched,
          k_new + 1,
          transpositions,
          i + 1
        )
      end
    else
      do_count_transpositions(
        chars1,
        chars2,
        len1,
        s1_matched,
        s2_matched,
        k,
        transpositions,
        i + 1
      )
    end
  end

  defp find_next_match_k(_s2_matched, k, len2) when k >= len2, do: k

  defp find_next_match_k(s2_matched, k, len2) do
    if elem(s2_matched, k) do
      k
    else
      find_next_match_k(s2_matched, k + 1, len2)
    end
  end

  # Count common prefix length (up to max_len)
  defp count_common_prefix(_chars1, _chars2, 0), do: 0

  defp count_common_prefix(chars1, chars2, max_len) do
    do_count_common_prefix(chars1, chars2, max_len, 0)
  end

  defp do_count_common_prefix(_chars1, _chars2, max_len, count) when count >= max_len, do: count

  defp do_count_common_prefix(chars1, chars2, max_len, count) do
    if char_at(chars1, count) == char_at(chars2, count) do
      do_count_common_prefix(chars1, chars2, max_len, count + 1)
    else
      count
    end
  end
end
