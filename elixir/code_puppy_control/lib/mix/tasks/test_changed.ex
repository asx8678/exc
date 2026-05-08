defmodule Mix.Tasks.Test.Changed do
  @moduledoc """
  Runs tests only for files that have changed according to git.

  Maps `lib/**/*.ex` files to their corresponding `test/**/*_test.exs`
  files and runs only those test files that exist. Directly changed test
  files are also included.

  ## Usage

      mix test.changed [options]

  ## Options

    * `--base`   - Git ref to compare against (default: HEAD).
                   Ignored when `--staged` is set.
    * `--staged` - Only check staged files.
    * `--depth`  - Include tests for files that depend on changed
                   files, up to N levels deep (default: 0).

  All other options are passed through to `mix test`.

  ## Examples

      mix test.changed                    # Tests for uncommitted changes
      mix test.changed --staged           # Tests for staged changes only
      mix test.changed --base main        # Tests for changes since main branch
      mix test.changed --depth 2          # Include dependent file tests
      mix test.changed --max-failures 1   # Pass-through to mix test
  """

  use Mix.Task

  @shortdoc "Runs tests only for changed files"

  @switches [base: :string, staged: :boolean, depth: :integer]

  @impl Mix.Task
  def run(args) do
    ensure_git_repo!()

    {opts, args, invalid} = OptionParser.parse(args, switches: @switches)
    validate_options!(invalid)

    base = Keyword.get(opts, :base, "HEAD")
    staged? = Keyword.get(opts, :staged, false)
    depth = Keyword.get(opts, :depth, 0)

    # Drop our custom options and reconstruct argv for `mix test`
    test_opts = Keyword.drop(opts, [:base, :staged, :depth])
    passthrough = OptionParser.to_argv(test_opts) ++ args

    changed_files = get_changed_files(base, staged?)

    case changed_files do
      [] ->
        Mix.shell().info("No changed files detected. Nothing to test.")

      _ ->
        {lib_files, direct_test_files} = partition_files(changed_files)

        mapped_tests =
          lib_files
          |> Enum.map(&lib_to_test/1)
          |> Enum.filter(&File.exists?/1)

        all_tests = Enum.uniq(direct_test_files ++ mapped_tests)

        all_tests =
          if depth > 0 and lib_files != [] do
            expand_with_dependents(lib_files, all_tests, depth)
          else
            all_tests
          end

        case all_tests do
          [] ->
            Mix.shell().info("No test files found for changed files:")

            for file <- Enum.sort(changed_files) do
              Mix.shell().info("  #{file}")
            end

          _ ->
            print_plan(changed_files, lib_files, direct_test_files, mapped_tests, all_tests)
            Mix.Task.run("test", all_tests ++ passthrough)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Git helpers
  # ---------------------------------------------------------------------------

  defp ensure_git_repo! do
    case System.cmd("git", ["rev-parse", "--is-inside-work-tree"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> Mix.raise("Not a git repository:\n#{String.trim(output)}")
    end
  end

  defp get_changed_files(_base, true = _staged?) do
    case System.cmd("git", ["diff", "--cached", "--name-only", "--relative"]) do
      {output, 0} -> String.split(output, "\n", trim: true)
      {output, _} -> Mix.raise("Failed to get staged files:\n#{String.trim(output)}")
    end
  end

  defp get_changed_files(base, false = _staged?) do
    case System.cmd("git", ["diff", "--name-only", "--relative", base]) do
      {output, 0} ->
        String.split(output, "\n", trim: true)

      {output, _} ->
        Mix.raise("Failed to get changed files against #{base}:\n#{String.trim(output)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Option validation
  # ---------------------------------------------------------------------------

  defp validate_options!(invalid) do
    Enum.each(invalid, fn
      {"--depth", value} ->
        Mix.raise("--depth requires an integer value, got: #{inspect(value)}")

      {"--" <> key, _value} when key in ["base", "staged"] ->
        Mix.raise("Invalid value for --#{key}")

      _ ->
        :ok
    end)
  end

  # ---------------------------------------------------------------------------
  # File classification & mapping
  # ---------------------------------------------------------------------------

  defp partition_files(files) do
    Enum.reduce(files, {[], []}, fn file, {lib_acc, test_acc} ->
      cond do
        test_file?(file) -> {lib_acc, [file | test_acc]}
        lib_file?(file) -> {[file | lib_acc], test_acc}
        true -> {lib_acc, test_acc}
      end
    end)
  end

  defp test_file?(path) do
    String.ends_with?(path, "_test.exs") and
      (String.starts_with?(path, "test/") or String.contains?(path, "/test/"))
  end

  defp lib_file?(path) do
    String.ends_with?(path, ".ex") and
      (String.starts_with?(path, "lib/") or String.contains?(path, "/lib/"))
  end

  @doc """
  Maps a lib file path to its corresponding test file path.

  Handles both standard and umbrella project structures:

      iex> Mix.Tasks.Test.Changed.lib_to_test("lib/foo/bar.ex")
      "test/foo/bar_test.exs"

      iex> Mix.Tasks.Test.Changed.lib_to_test("apps/my_app/lib/foo/bar.ex")
      "apps/my_app/test/foo/bar_test.exs"

  """
  def lib_to_test(lib_path) do
    parts = Path.split(lib_path)

    {prefix, rest} =
      case Enum.split_while(parts, &(&1 != "lib")) do
        {pre, ["lib" | tail]} -> {pre, tail}
        _ -> {[], tl(parts)}
      end

    test_path =
      (prefix ++ ["test" | rest])
      |> Path.join()

    String.replace_suffix(test_path, ".ex", "_test.exs")
  end

  # ---------------------------------------------------------------------------
  # Dependency expansion via `mix xref`
  # ---------------------------------------------------------------------------

  defp expand_with_dependents(lib_files, current_tests, depth) do
    case build_reverse_dependency_graph() do
      {:ok, reverse_graph} ->
        dependents = find_dependents(lib_files, reverse_graph, depth)

        dependent_tests =
          dependents
          |> Enum.filter(&lib_file?/1)
          |> Enum.map(&lib_to_test/1)
          |> Enum.filter(&File.exists?/1)

        Enum.uniq(current_tests ++ dependent_tests)

      {:error, reason} ->
        Mix.shell().error(
          "Warning: Could not build dependency graph (#{reason}). " <>
            "Skipping depth expansion."
        )

        current_tests
    end
  end

  defp build_reverse_dependency_graph do
    Mix.Task.run("compile", ["--no-warnings-as-errors"])

    case System.cmd("mix", ["xref", "graph", "--format", "dot"], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_dot_graph(output)}

      {output, _} ->
        {:error, String.trim(output)}
    end
  end

  defp parse_dot_graph(dot_output) do
    # DOT format:  "lib/a.ex" -> "lib/b.ex"
    # Build a reverse graph: callee → [callers]
    dot_output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/"([^"]+)"\s*->\s*"([^"]+)"/, line) do
        [_, caller, callee] ->
          Map.update(acc, callee, [caller], &[caller | &1])

        _ ->
          acc
      end
    end)
  end

  defp find_dependents(changed_files, reverse_graph, depth) do
    changed_set = MapSet.new(changed_files)

    {_visited, dependents} =
      Enum.reduce(1..depth, {changed_set, MapSet.new()}, fn _, {visited, dependents} ->
        # Find callers of all files in the visited set
        callers =
          visited
          |> Enum.flat_map(&Map.get(reverse_graph, &1, []))
          |> MapSet.new()

        # Only keep callers we haven't already processed
        new_callers = MapSet.difference(callers, visited)
        # Exclude the original changed files from dependents
        new_dependents = MapSet.difference(new_callers, changed_set)

        {MapSet.union(visited, new_callers), MapSet.union(dependents, new_dependents)}
      end)

    MapSet.to_list(dependents)
  end

  # ---------------------------------------------------------------------------
  # Output
  # ---------------------------------------------------------------------------

  defp print_plan(changed_files, lib_files, direct_test_files, _mapped_tests, all_tests) do
    Mix.shell().info("")
    Mix.shell().info("Changed files (#{length(changed_files)}):")

    for file <- Enum.sort(changed_files) do
      Mix.shell().info("  #{file}")
    end

    if lib_files != [] do
      Mix.shell().info("")
      Mix.shell().info("Mapped lib \u2192 test:")

      for lib <- Enum.sort(lib_files) do
        test = lib_to_test(lib)

        if File.exists?(test) do
          Mix.shell().info("  #{lib} \u2192 #{test}")
        else
          Mix.shell().info("  #{lib} \u2192 (no test found)")
        end
      end
    end

    if direct_test_files != [] do
      Mix.shell().info("")
      Mix.shell().info("Directly changed test files:")

      for file <- Enum.sort(direct_test_files) do
        Mix.shell().info("  #{file}")
      end
    end

    Mix.shell().info("")
    Mix.shell().info("Running #{length(all_tests)} test file(s):")

    for file <- Enum.sort(all_tests) do
      Mix.shell().info("  #{file}")
    end

    Mix.shell().info("")
  end
end
