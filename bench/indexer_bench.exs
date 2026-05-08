#!/usr/bin/env elixir
# Indexer Benchmark
#
# Run with: mix run bench/indexer_bench.exs
#
# This benchmark measures the performance of the Elixir indexer implementation
# against the code_puppy project root, comparing different file count limits.

# Add benchee to the load path if not already available
try do
  Code.ensure_loaded?(Benchee)
rescue
  _ ->
    IO.puts("Benchee is required for benchmarking.")
    IO.puts("Please add {:benchee, \"~> 1.1\", only: :dev, runtime: false} to your deps.")
    System.halt(1)
end

alias CodePuppyControl.Indexer

# Path to the code_puppy project root (from elixir/code_puppy_control/)
project_root = Path.expand("../../", __DIR__)

IO.puts("Benchmarking indexer on: #{project_root}")
IO.puts("")

Benchee.run(
  %{
    "index_40_files" => fn ->
      Indexer.index!(project_root, max_files: 40)
    end,
    "index_100_files" => fn ->
      Indexer.index!(project_root, max_files: 100)
    end,
    "index_200_files" => fn ->
      Indexer.index!(project_root, max_files: 200)
    end,
    "index_40_with_16_symbols" => fn ->
      Indexer.index!(project_root, max_files: 40, max_symbols_per_file: 16)
    end,
    "index_100_with_16_symbols" => fn ->
      Indexer.index!(project_root, max_files: 100, max_symbols_per_file: 16)
    end
  },
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.Markdown, file: "bench/results/indexer_results.md"}
  ],
  warmup: 2,
  time: 10,
  memory_time: 2,
  parallel: 1,
  print: [
    benchmarking: true,
    configuration: true,
    fast_warning: true
  ]
)

# Print additional statistics
IO.puts("\n--- Additional Statistics ---\n")

# Run once to collect detailed stats
{:ok, summaries_40} = Indexer.index(project_root, max_files: 40)
{:ok, summaries_100} = Indexer.index(project_root, max_files: 100)

# Category breakdown
by_kind_40 = Enum.group_by(summaries_40, & &1.kind)
by_kind_100 = Enum.group_by(summaries_100, & &1.kind)

IO.puts("Files indexed (max 40):")
IO.puts("  Total: #{length(summaries_40)}")

for {kind, files} <- Enum.sort_by(by_kind_40, fn {_, files} -> -length(files) end) do
  symbol_count = Enum.sum(Enum.map(files, fn f -> length(f.symbols) end))
  IO.puts("  #{kind}: #{length(files)} files (#{symbol_count} symbols)")
end

IO.puts("")
IO.puts("Files indexed (max 100):")
IO.puts("  Total: #{length(summaries_100)}")

for {kind, files} <- Enum.sort_by(by_kind_100, fn {_, files} -> -length(files) end) do
  symbol_count = Enum.sum(Enum.map(files, fn f -> length(f.symbols) end))
  IO.puts("  #{kind}: #{length(files)} files (#{symbol_count} symbols)")
end

# Extract a sample of paths at different depths
IO.puts("\n--- Sample Indexed Files ---\n")

sample_paths =
  summaries_40
  |> Enum.take_random(min(10, length(summaries_40)))
  |> Enum.map(& &1.path)
  |> Enum.sort()

IO.puts("Sample paths:")
for path <- sample_paths do
  IO.puts("  - #{path}")
end

IO.puts("")
IO.puts("Benchmark complete!")
