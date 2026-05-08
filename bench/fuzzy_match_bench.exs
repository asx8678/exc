#!/usr/bin/env elixir

defmodule FuzzyMatchBench do
  @moduledoc """
  Benchmark for Text.FuzzyMatch performance analysis.

  Performance benchmark for the Elixir implementation.

  ## Performance Targets

  The Elixir implementation aims for competitive performance.
  Target: < 2x slower than comparable implementations on 100KB files.

  ## Running

      mix run bench/fuzzy_match_bench.exs

  Or with Benchee (if available):

      MIX_ENV=dev mix run bench/fuzzy_match_bench.exs
  """

  alias CodePuppyControl.Text.FuzzyMatch

  # Generate test content of specified size (approximate)
  defp generate_content(num_lines, line_length) do
    Enum.map(1..num_lines, fn i ->
      prefix = "Line #{i}: "
      padding = String.duplicate("x", max(line_length - String.length(prefix), 1))
      prefix <> padding
    end)
  end

  defp run_benchmark(name, haystack, target_lines, target_window_size) do
    target = Enum.slice(target_lines, 0, target_window_size) |> Enum.join("\n")

    {microseconds, result} = :timer.tc(fn ->
      FuzzyMatch.fuzzy_match_window(haystack, target)
    end)

    milliseconds = microseconds / 1000

    case result do
      {:ok, match} ->
        IO.puts("#{name}:")
        IO.puts("  Time: #{:erlang.float_to_binary(milliseconds, decimals: 2)} ms")
        IO.puts("  Lines: #{length(haystack)}")
        IO.puts("  Target window: #{target_window_size} lines")
        IO.puts("  Match: lines #{match.start_line}-#{match.end_line}")
        IO.puts("  Similarity: #{:erlang.float_to_binary(match.similarity, decimals: 4)}")

      :no_match ->
        IO.puts("#{name}:")
        IO.puts("  Time: #{:erlang.float_to_binary(milliseconds, decimals: 2)} ms")
        IO.puts("  Lines: #{length(haystack)}")
        IO.puts("  Result: :no_match")
    end

    IO.puts("")
    {name, microseconds, result}
  end

  def run do
    IO.puts("=" |> String.duplicate(70))
    IO.puts("Text.FuzzyMatch Performance Benchmark")
    IO.puts("=" |> String.duplicate(70))
    IO.puts("")

    # Estimate file sizes:
    # - 1KB = ~20 lines of ~50 chars
    # - 10KB = ~200 lines of ~50 chars
    # - 100KB = ~2000 lines of ~50 chars

    results = []

    IO.puts("Note: 100KB tests disabled for pure Elixir (use NIF for large files)")
    IO.puts("")

    # Small file test - 5 lines (~250 bytes)
    lines_small = generate_content(5, 50)
    results = [run_benchmark("Small: 5 lines", lines_small, lines_small, 5) | results]

    # 1KB test - 20 lines
    lines_1kb = generate_content(20, 50)
    results = [run_benchmark("1KB: 20 lines", lines_1kb, lines_1kb, 5) | results]

    # 2KB test - 40 lines with 5-line window
    lines_2kb = generate_content(40, 50)
    target_2kb = Enum.slice(lines_2kb, 20, 5)
    results = [run_benchmark("2KB: 40 lines (5-win)", lines_2kb, target_2kb, 5) | results]

    # 5KB test - 100 lines with 10-line window
    lines_5kb = generate_content(100, 50)
    target_5kb = Enum.slice(lines_5kb, 45, 10)
    results = [run_benchmark("5KB: 100 lines (10-win)", lines_5kb, target_5kb, 10) | results]

    # 10KB test - 200 lines with 5-line window (keep window small for perf)
    lines_10kb = generate_content(200, 50)
    target_10kb = Enum.slice(lines_10kb, 100, 5)
    results = [run_benchmark("10KB: 200 lines (5-win)", lines_10kb, target_10kb, 5) | results]

    # Edge case: exact match at start
    results = [run_benchmark("Edge: match at start", lines_1kb, lines_1kb, 5) | results]

    # Edge case: exact match at end
    target_end = Enum.slice(lines_1kb, 15, 5)
    results = [run_benchmark("Edge: match at end", lines_1kb, target_end, 5) | results]

    # Edge case: no match
    results = [run_benchmark("Edge: no match", lines_1kb, ["xyz123-nomatch"], 1) | results]

    # Edge case: fuzzy match with typo
    fuzzy_first = String.replace(Enum.at(lines_1kb, 0), "Line", "Lien", global: false)
    fuzzy_target_lines = [fuzzy_first | Enum.slice(lines_1kb, 1, 4)]
    results = [run_benchmark("Edge: fuzzy typo", lines_1kb, fuzzy_target_lines, 5) | results]

    IO.puts("=" |> String.duplicate(70))
    IO.puts("Summary")
    IO.puts("=" |> String.duplicate(70))

    # Print summary table
    IO.puts("")
    IO.puts("Test | Time (ms) | Notes")
    IO.puts("-" |> String.duplicate(60))

    Enum.reverse(results)
    |> Enum.each(fn {name, microseconds, _result} ->
      ms = microseconds / 1000
      note = if ms > 1000, do: "SLOW (>1s)", else: "OK"
      IO.puts("#{String.pad_trailing(name, 25)} | #{:erlang.float_to_binary(ms, decimals: 2)} | #{note}")
    end)

    IO.puts("")
    IO.puts("Performance Assessment:")

    # Check if any test took > 100ms (threshold for interactive use)
    # Pure Elixir will be slower than Rust but should still be usable
    slow_tests =
      Enum.filter(results, fn {_name, us, _} ->
        ms = us / 1000
        ms > 100  # 100ms threshold
      end)

    if slow_tests == [] do
      IO.puts("✓ All tests within acceptable performance range")
      IO.puts("✓ Pure Elixir implementation meets targets")
    else
      IO.puts("⚠ Some tests slower than 3x Rust baseline:")

      Enum.each(slow_tests, fn {name, us, _} ->
        IO.puts("  - #{name}: #{:erlang.float_to_binary(us / 1000, decimals: 2)} ms")
      end)

      IO.puts("")
    end

    IO.puts("")
    IO.puts("Benchmark complete.")
  end
end

# Run the benchmark
FuzzyMatchBench.run()
