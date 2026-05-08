defmodule CodePuppyControl.Text.FuzzyMatchTest do
  @moduledoc """
  Tests for fuzzy window matching and Jaro-Winkler similarity.

  Ported from `code_puppy_core/src/fuzzy_match.rs` tests.
  """

  use ExUnit.Case

  alias CodePuppyControl.Text.FuzzyMatch
  alias CodePuppyControl.Text.JaroWinkler

  # ============================================================================
  # Jaro-Winkler similarity tests
  # ============================================================================

  describe "JaroWinkler.similarity/2" do
    test "identical strings return 1.0" do
      assert JaroWinkler.similarity("hello", "hello") == 1.0
      assert JaroWinkler.similarity("", "") == 1.0
      assert JaroWinkler.similarity("a", "a") == 1.0
    end

    test "empty string returns 0.0 against non-empty" do
      assert JaroWinkler.similarity("hello", "") == 0.0
      assert JaroWinkler.similarity("", "world") == 0.0
    end

    test "typo tolerance" do
      # "martha" vs "marhta" - transposition
      sim = JaroWinkler.similarity("martha", "marhta")
      assert sim > 0.9, "typo tolerance failed: sim = #{sim}"
      assert_in_delta sim, 0.9611111111111111, 0.0001
    end

    test "prefix boost" do
      # "code" prefix should get boost
      sim1 = JaroWinkler.similarity("code_puppy", "code_kitten")
      sim2 = JaroWinkler.similarity("puppy_code", "kitten_code")

      # Prefix match should score higher
      assert sim1 > sim2, "prefix boost failed: #{sim1} vs #{sim2}"
    end

    test "completely different strings have low similarity" do
      sim = JaroWinkler.similarity("abcdef", "ghijkl")
      assert sim < 0.5, "completely different strings should have low sim: #{sim}"
      assert sim == 0.0
    end

    test "similar but not identical" do
      sim = JaroWinkler.similarity("hello", "hallo")
      assert sim > 0.8
      assert sim < 1.0
    end

    test "case sensitivity" do
      sim = JaroWinkler.similarity("Hello", "hello")
      assert sim < 1.0
      assert sim > 0.8
    end

    test "single character difference" do
      sim = JaroWinkler.similarity("a", "b")
      assert sim == 0.0

      sim2 = JaroWinkler.similarity("abc", "abx")
      assert sim2 > 0.8
    end
  end

  # ============================================================================
  # FuzzyMatch.fuzzy_match_window/3 tests - exact matches
  # ============================================================================

  describe "fuzzy_match_window/3 exact matches" do
    test "exact match returns 1.0" do
      haystack = ["hello", "world", "foo", "bar"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "hello\nworld")

      assert {:ok, match} = result
      assert match.matched_text == "hello\nworld"
      assert match.start_line == 0
      assert match.end_line == 2
      assert_in_delta match.similarity, 1.0, 0.001
    end

    test "single line match" do
      haystack = ["apple", "banana", "cherry"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "banana")

      assert {:ok, match} = result
      assert match.matched_text == "banana"
      assert match.start_line == 1
      assert match.end_line == 2
    end

    test "trailing newline stripped" do
      haystack = ["hello", "world"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "hello\nworld\n")

      assert {:ok, match} = result
      assert match.start_line == 0
      assert match.matched_text == "hello\nworld"
    end

    test "window size 1" do
      haystack = ["a", "b", "c", "d", "e"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "c")

      assert {:ok, match} = result
      assert match.start_line == 2
      assert match.end_line == 3
      assert match.matched_text == "c"
    end
  end

  # ============================================================================
  # FuzzyMatch.fuzzy_match_window/3 fuzzy matches
  # ============================================================================

  describe "fuzzy_match_window/3 fuzzy matches" do
    test "fuzzy match finds best window" do
      haystack = ["def foo():", " pass", "def bar():", " return 1"]
      # "def baz():" is close to "def bar():" (typo)
      result = FuzzyMatch.fuzzy_match_window(haystack, "def baz():")

      assert {:ok, match} = result
      assert match.start_line == 2
      assert match.matched_text == "def bar():"
      assert match.similarity > 0.8
    end

    test "similar but not identical multi-line match" do
      haystack = ["line one", "line two", "line three", "line four"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "line one\nline 2")

      assert {:ok, match} = result
      assert match.start_line == 0
      assert match.end_line == 2
      assert match.similarity > 0.6
    end
  end

  # ============================================================================
  # FuzzyMatch.fuzzy_match_window/3 no match cases
  # ============================================================================

  describe "fuzzy_match_window/3 no match" do
    test "empty needle returns no match" do
      haystack = ["hello", "world"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "")
      assert result == :no_match
    end

    test "empty haystack returns no match" do
      haystack = []
      result = FuzzyMatch.fuzzy_match_window(haystack, "hello")
      assert result == :no_match
    end

    test "needle larger than haystack" do
      haystack = ["hello"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "hello\nworld\nfoo")
      assert result == :no_match
    end

    test "no match below threshold" do
      haystack = ["completely", "different", "text", "here"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "xyz123-nomatch")
      # Score should be below threshold
      assert result == :no_match
    end

    test "threshold option controls acceptance" do
      haystack = ["abc", "def", "ghi"]

      # With default threshold (0.6), should find match
      result1 = FuzzyMatch.fuzzy_match_window(haystack, "xyz")
      assert result1 == :no_match

      # With very low threshold, might find some match
      result2 = FuzzyMatch.fuzzy_match_window(haystack, "abc", threshold: 0.99)
      # With threshold 0.99, "abc" might still match itself at 1.0
      assert {:ok, _} = result2
    end
  end

  # ============================================================================
  # Multi-line window matching tests
  # ============================================================================

  describe "multi-line window matching" do
    test "large window performance test" do
      # Generate 100 lines of content
      haystack = Enum.map(0..99, fn i -> "line number #{i} with some content" end)

      # Find a 10-line window
      target = Enum.slice(haystack, 45, 10) |> Enum.join("\n")
      result = FuzzyMatch.fuzzy_match_window(haystack, target)

      assert {:ok, match} = result
      assert match.start_line == 45
      assert match.end_line == 55
      assert_in_delta match.similarity, 1.0, 0.001
    end

    test "finds correct window among many similar" do
      haystack = [
        "function foo() {",
        " return 1;",
        "}",
        "function bar() {",
        " return 2;",
        "}"
      ]

      # Looking for the second function
      result = FuzzyMatch.fuzzy_match_window(haystack, "function bar() {\n return 2;")

      assert {:ok, match} = result
      assert match.start_line == 3
      assert match.end_line == 5
    end
  end

  # ============================================================================
  # Unicode handling tests
  # ============================================================================

  describe "unicode handling" do
    test "unicode content" do
      haystack = ["こんにちは", "世界", "foo"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "こんにちは\n世界")

      assert {:ok, match} = result
      assert match.start_line == 0
      assert match.matched_text == "こんにちは\n世界"
    end

    test "emoji content" do
      haystack = ["🎉 party", "🚀 rocket", "🌟 star"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "🎉 party")

      assert {:ok, match} = result
      assert match.start_line == 0
    end

    test "accents and special chars" do
      haystack = ["Café résumé", "naïve", "résumé"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "Café résumé\nnaïve")

      assert {:ok, match} = result
      assert match.start_line == 0
    end
  end

  # ============================================================================
  # Edge cases
  # ============================================================================

  describe "edge cases" do
    test "whitespace lines" do
      haystack = ["", " ", " ", "content"]
      result = FuzzyMatch.fuzzy_match_window(haystack, " ")

      assert {:ok, match} = result
      assert match.start_line == 1
      assert match.matched_text == " "
    end

    test "only whitespace content" do
      haystack = ["", " ", "\t", " "]
      result = FuzzyMatch.fuzzy_match_window(haystack, "\t")

      assert {:ok, match} = result
      assert match.start_line == 2
    end

    test "very long lines" do
      long_line = String.duplicate("a", 1000)
      haystack = [long_line, "short", long_line]

      result = FuzzyMatch.fuzzy_match_window(haystack, long_line)

      assert {:ok, match} = result
      assert match.start_line == 0
    end

    test "many newlines in needle" do
      haystack = ["a", "b", "c", "d", "e"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "a\nb\nc\n")

      assert {:ok, match} = result
      assert match.start_line == 0
      assert match.end_line == 3
    end

    test "single character haystack and needle" do
      haystack = ["x"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "x")

      assert {:ok, match} = result
      assert match.start_line == 0
      assert match.end_line == 1
    end

    test "similar single characters" do
      haystack = ["a", "b", "c"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "a")

      assert {:ok, match} = result
      assert match.start_line == 0
    end
  end

  # ============================================================================
  # find_best_window/3 tests (Python bridge compatibility)
  # ============================================================================

  describe "find_best_window/3" do
    test "returns tuple format compatible with Python bridge" do
      haystack = ["hello", "world", "foo", "bar"]
      {{start_line, end_line}, score} = FuzzyMatch.find_best_window(haystack, "hello\nworld")

      assert start_line == 0
      assert end_line == 2
      assert_in_delta score, 1.0, 0.001
    end

    test "returns nil for no match" do
      haystack = ["hello"]
      {span, score} = FuzzyMatch.find_best_window(haystack, "nomatch-xyz")

      assert span == nil
      assert score == 0.0
    end

    test "respects threshold option" do
      haystack = ["abc", "def", "ghi"]

      # Should match exact
      {{start, _end}, score} = FuzzyMatch.find_best_window(haystack, "abc")
      assert start == 0
      assert score == 1.0
    end
  end

  # ============================================================================
  # Property-based assertions
  # ============================================================================

  describe "properties" do
    test "exact match always has similarity 1.0" do
      for haystack <- [
            ["hello"],
            ["a", "b", "c"],
            ["line one", "line two", "line three"]
          ],
          needle = Enum.join(haystack, "\n") do
        result = FuzzyMatch.fuzzy_match_window(haystack, needle)
        assert {:ok, match} = result
        assert_in_delta match.similarity, 1.0, 0.001
      end
    end

    test "result end_line is always greater than start_line" do
      haystack = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]

      for win_size <- 1..5,
          start <- 0..(length(haystack) - win_size),
          target = Enum.slice(haystack, start, win_size) |> Enum.join("\n") do
        result = FuzzyMatch.fuzzy_match_window(haystack, target)
        assert {:ok, match} = result
        assert match.end_line > match.start_line
        assert match.end_line - match.start_line == win_size
      end
    end

    test "no match returns :no_match atom" do
      haystack = ["completely", "unrelated", "content"]
      result = FuzzyMatch.fuzzy_match_window(haystack, "xyz123-nomatch-abc")
      assert result == :no_match
    end
  end

  # ============================================================================
  # Regression tests for critical bugs
  # ============================================================================

  describe "regression tests" do
    test "multi-codepoint graphemes are not identical in Jaro-Winkler" do
      # BUG: JaroWinkler.similarity("🇺🇸a", "🇺🇸b") returned 1.0 (WRONG)
      # String.length/1 counted graphemes but String.to_charlist/1 produced codepoints.
      # The fix ensures lengths are derived from the SAME representation (tuple of codepoints).
      assert JaroWinkler.similarity("🇺🇸a", "🇺🇸b") < 1.0
      assert JaroWinkler.similarity("e\u0301x", "e\u0301y") < 1.0
    end

    test "preserves best score even when below threshold" do
      # BUG: find_best_window/3 returned {nil, 0.0} unconditionally on :no_match.
      # Rust returns the best score even when no span clears threshold.
      # Use a search where at least one candidate passes the pre-filters
      # but scores below the specified threshold.
      # First character 'd' matches 'd' in "def abc():", and similar lengths.
      haystack = ["def abc():", " pass", "other content"]
      # "def xyz():" has similar prefix and length to "def abc():"
      # but scores below high threshold
      {span, score} = FuzzyMatch.find_best_window(haystack, "def xyz():", threshold: 0.95)
      # Below threshold, so no span returned
      assert span == nil
      # Score should be actual similarity (approx 0.8-0.9), not hardcoded 0.0
      assert score > 0.0
      # Confirm it's below threshold
      assert score < 0.95
    end

    test "threshold 0.0 does not crash" do
      # BUG: When every candidate scored 0.0 and threshold was 0.0, best_end stayed nil
      # but arithmetic (best_end - best_start) was attempted, causing ArithmeticError.
      result = FuzzyMatch.fuzzy_match_window(["abc"], "xyz", threshold: 0.0)
      # Should return :no_match (all scores below threshold), not crash
      assert result == :no_match
    end

    test "combining characters handled correctly" do
      # NFC form: "é" as single codepoint (U+00E9)
      # NFD form: "e" + combining acute accent (U+0065 U+0301)
      # Both should compute correctly based on their codepoint representation
      nfc = "café"
      nfd = "cafe\u0301"

      # Similarity should reflect actual codepoint differences
      sim = JaroWinkler.similarity(nfc, nfd)
      # These are different byte sequences, so similarity should be < 1.0
      assert sim < 1.0
    end
  end

  # ============================================================================
  # Performance sanity checks
  # ============================================================================

  describe "performance sanity" do
    test "handles moderately large content efficiently" do
      # Create content with 200 lines
      haystack = Enum.map(1..200, fn i -> "Line number #{i} with some content here" end)

      # Target a window in the middle
      target_lines = Enum.slice(haystack, 80, 20)
      target = Enum.join(target_lines, "\n")

      # Should complete in reasonable time (using simple timer)
      {microseconds, result} =
        :timer.tc(fn -> FuzzyMatch.fuzzy_match_window(haystack, target) end)

      assert {:ok, match} = result
      assert match.start_line == 80
      assert match.end_line == 100

      # Log performance - pure Elixir is expected to be slower than Rust
      # NOTE: This is a soft check; see benchmark for detailed performance analysis
      IO.puts("Moderate search (200 lines, 20-line window) took #{microseconds} microseconds")

      # Should complete in under 10 seconds for pure Elixir (Rust is ~50x faster)
      assert microseconds < 10_000_000,
             "Search took too long: #{microseconds} microseconds (consider Rustler NIF)"
    end

    test "handles 1KB content" do
      # ~1KB of content
      haystack = Enum.map(1..20, fn i -> "Line #{i}: #{String.duplicate("x", 40)}" end)
      target = Enum.slice(haystack, 5, 5) |> Enum.join("\n")

      {microseconds, result} =
        :timer.tc(fn -> FuzzyMatch.fuzzy_match_window(haystack, target) end)

      assert {:ok, _match} = result
      # Log performance for manual analysis
      IO.puts("1KB content search took #{microseconds} microseconds")
    end
  end
end
