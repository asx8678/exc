defmodule CodePuppyControl.Indexer.RepoCompassTest do
  @moduledoc """
  Tests for the RepoCompass indexer.

  ## Python-as-data fixtures (allowlisted)

  `.py` test fixtures exercise static symbol extraction via the data-only
  PythonParser. These are allowlisted as Python source parsing tests, not
  Python runtime tests. See ADR-005 for the full policy rationale.
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.Indexer.RepoCompass

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "repo_compass_indexer_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "ports the compact Python structure-map behavior", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "pkg"))
    File.mkdir_p!(Path.join(tmp_dir, "build"))
    File.mkdir_p!(Path.join(tmp_dir, ".git"))

    File.write!(Path.join(tmp_dir, "README.md"), "# Demo\n")
    File.write!(Path.join(tmp_dir, "notes.txt"), "ignored by Repo Compass\n")
    File.write!(Path.join([tmp_dir, "build", "generated.py"]), "def ignored():\n    pass\n")
    File.write!(Path.join([tmp_dir, ".git", "hidden.py"]), "def ignored():\n    pass\n")

    File.write!(
      Path.join([tmp_dir, "pkg", "mod.py"]),
      "class Greeter:\n" <>
        "    def hello(self, name):\n" <>
        "        return name\n\n" <>
        "    async def later(self, delay):\n" <>
        "        return delay\n\n" <>
        "def wave(person, times):\n" <>
        "    return person\n"
    )

    assert {:ok, summaries} = RepoCompass.index(tmp_dir, max_files: 10, max_symbols_per_file: 5)

    by_path = Map.new(summaries, fn summary -> {summary.path, summary} end)

    assert Map.has_key?(by_path, "README.md")
    assert Map.has_key?(by_path, "pkg/mod.py")
    refute Map.has_key?(by_path, "build/generated.py")
    refute Map.has_key?(by_path, ".git/hidden.py")
    refute Map.has_key?(by_path, "notes.txt")

    assert by_path["README.md"].kind == "project-file"
    assert by_path["pkg/mod.py"].kind == "python"
    assert "def wave(person, times)" in by_path["pkg/mod.py"].symbols

    assert Enum.any?(by_path["pkg/mod.py"].symbols, fn symbol ->
             String.starts_with?(symbol, "class Greeter") and
               String.contains?(symbol, "methods=hello,later")
           end)

    paths = Enum.map(summaries, & &1.path)

    assert paths ==
             Enum.sort_by(paths, fn rel_path ->
               {length(Path.split(rel_path)), rel_path}
             end)
  end

  test "caps both returned files and returned symbols", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "pkg"))
    File.write!(Path.join(tmp_dir, "README.md"), "# Demo\n")
    File.write!(Path.join(tmp_dir, "package.json"), "{}\n")

    File.write!(
      Path.join([tmp_dir, "pkg", "many.py"]),
      "class One:\n" <>
        "    def a(self):\n" <>
        "        pass\n\n" <>
        "    def b(self):\n" <>
        "        pass\n\n" <>
        "    def c(self):\n" <>
        "        pass\n\n" <>
        "    def d(self):\n" <>
        "        pass\n\n" <>
        "def alpha(first, second=1, *, flag=False):\n" <>
        "    return first\n\n" <>
        "async def beta(item: str):\n" <>
        "    return item\n"
    )

    # Use max_files: 3 to include README.md, package.json, and pkg/many.py
    assert {:ok, summaries} = RepoCompass.index(tmp_dir, max_files: 3, max_symbols_per_file: 2)
    assert length(summaries) == 3

    python_summary = Enum.find(summaries, &(&1.path == "pkg/many.py"))
    assert python_summary
    assert length(python_summary.symbols) == 2

    class_symbol = Enum.find(python_summary.symbols, &String.starts_with?(&1, "class One"))
    assert class_symbol == "class One methods=a,b,c"
    assert "def alpha(first, second, flag)" in python_summary.symbols
    refute Enum.any?(python_summary.symbols, &(&1 == "def beta(item)"))
  end

  test "returns an error for a missing directory" do
    missing =
      Path.join(System.tmp_dir!(), "missing_repo_compass_#{System.unique_integer([:positive])}")

    assert {:error, {:not_a_directory, ^missing}} = RepoCompass.index(missing)
  end

  test "class at end of file preserves method order", %{tmp_dir: tmp_dir} do
    File.write!(
      Path.join(tmp_dir, "eof_class.py"),
      "class Eof:\n" <>
        "    def alpha(self):\n" <>
        "        pass\n\n" <>
        "    def beta(self):\n" <>
        "        pass\n"
    )

    assert {:ok, [summary]} = RepoCompass.index(tmp_dir)
    assert Enum.any?(summary.symbols, &String.contains?(&1, "methods=alpha,beta"))
  end
end
