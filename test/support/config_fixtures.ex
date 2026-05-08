defmodule CodePuppyControl.Support.ConfigFixtures do
  @moduledoc """
  Golden-fixture helpers for config compatibility tests.

  Provides path resolution, loading, normalization, and sandbox utilities
  for the committed fixture files under `test/fixtures/config/`.

  ## Fixture layout

      test/fixtures/config/
      ├── minimal/ # Smallest valid configs
      ├── realistic/ # Production-like configs
      └── invalid/ # Malformed files for error-path tests

  ## Fixture sort order

  Fixtures stored on disk are pretty-printed for readability but not required
  to be in canonical sort order. Use `canonical_json/1` only for in-memory
  comparisons and snapshot assertions — not for writing committed fixtures.
  """

  @fixtures_root Path.join([__DIR__, "..", "fixtures", "config"]) |> Path.expand()

  # ── Path Resolution ──────────────────────────────────────────────────────

  @doc """
  Resolve a fixture path under `test/fixtures/config/<variant>/<name>`.

  ## Examples

      iex> path(:minimal, "puppy.cfg")
      # => ".../test/fixtures/config/minimal/puppy.cfg"

      iex> path(:invalid, "truncated.json")
      # => ".../test/fixtures/config/invalid/truncated.json"
  """
  @spec path(atom(), String.t()) :: String.t()
  def path(variant, name) when variant in [:minimal, :realistic, :invalid] do
    Path.join([@fixtures_root, Atom.to_string(variant), name])
  end

  # ── Loading ───────────────────────────────────────────────────────────────

  @doc """
  Read and parse a JSON fixture, returning the decoded term.

  Raises `Jason.DecodeError` if the file is not valid JSON.
  Raises `File.Error` if the file does not exist.
  """
  @spec load_json(atom(), String.t()) :: term()
  def load_json(variant, name) do
    variant
    |> path(name)
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Read raw bytes of a fixture (for byte-level snapshot assertions).
  """
  @spec read_raw(atom(), String.t()) :: binary()
  def read_raw(variant, name) do
    variant
    |> path(name)
    |> File.read!()
  end

  # ── Normalization ─────────────────────────────────────────────────────────

  @doc """
  Recursively normalize a term so it compares stably.

  - **Maps** → sorted list of `{key, normalize(value)}` tuples. This ensures
    equality is structural regardless of insertion order.
  - **Lists** → recurse into elements (order preserved — order matters for
    policy rules, pack fallbacks, etc.).
  - **Scalars** → unchanged.

  Returns a term suitable for `assert_equal` regardless of insertion order.

  ## Examples

      iex> normalize(%{"b" => 2, "a" => 1})
      [{"a", 1}, {"b", 2}]

      iex> normalize([%{"z" => 1}, %{"a" => 2}])
      [[{"a", 2}], [{"z", 1}]]
  """
  @spec normalize(term()) :: term()
  def normalize(term) when is_map(term) do
    term
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {k, v} -> {k, normalize(v)} end)
  end

  def normalize(term) when is_list(term) do
    Enum.map(term, &normalize/1)
  end

  def normalize(term), do: term

  # ── Canonical Serialization ──────────────────────────────────────────────

  @doc """
  Serialize to canonical JSON: string keys sorted alphabetically, compact
  form with trailing newline. Used for golden-snapshot comparisons.

  Raises `ArgumentError` if any map contains non-string keys, since this
  helper is intended for JSON-originated data (which is always string-keyed).

  Note: `Jason.OrderedObject` is not available in Jason 1.4.x, so we build
  a sorted-key encoder manually. This produces compact (non-pretty) JSON
  that is byte-identical for structurally equal inputs.

  ## Examples

      iex> canonical_json(%{"b" => 2, "a" => 1})
      "{\\"a\\":1,\\"b\\":2}\\n"
  """
  @spec canonical_json(term()) :: binary()
  def canonical_json(term) do
    term
    |> ensure_string_keys!()
    |> canonical_encode()
    |> Kernel.<>("\n")
  end

  # Validates that all map keys are strings (JSON data is always string-keyed).
  defp ensure_string_keys!(term) when is_map(term) do
    Enum.each(Map.keys(term), fn
      k when is_binary(k) -> :ok
      k -> raise ArgumentError, "canonical_json/1 requires string keys; got #{inspect(k)}"
    end)

    Map.new(term, fn {k, v} -> {k, ensure_string_keys!(v)} end)
  end

  defp ensure_string_keys!(term) when is_list(term), do: Enum.map(term, &ensure_string_keys!/1)
  defp ensure_string_keys!(term), do: term

  # Recursive encoder that emits sorted-key JSON.
  # Produces compact (non-pretty) output so the byte representation is
  # deterministic regardless of original insertion order.
  defp canonical_encode(term) when is_map(term) do
    inner =
      term
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical_encode(v) end)

    "{" <> inner <> "}"
  end

  defp canonical_encode(term) when is_list(term) do
    "[" <> Enum.map_join(term, ",", &canonical_encode/1) <> "]"
  end

  defp canonical_encode(term), do: Jason.encode!(term)

  # ── Sandbox Helpers ──────────────────────────────────────────────────────

  @doc """
  Create a temporary sandbox home under an ExUnit-provided `tmp_dir`,
  set up directory structure like `~/.code_puppy_ex/`, and pass the path
  to the given fun.

  No `Isolation.with_sandbox` is needed because `tmp_dir` paths are outside
  the legacy home (`~/.code_puppy/`), so the isolation guard will not block
  writes there. Only use `Isolation.with_sandbox` when a test explicitly
  targets the legacy home path.

  Returns whatever `fun` returns.
  """
  @spec with_tmp_home(Path.t(), (Path.t() -> result)) :: result when result: var
  def with_tmp_home(tmp_dir, fun) when is_function(fun, 1) do
    home = Path.join(tmp_dir, "code_puppy_ex")
    File.mkdir_p!(home)
    fun.(home)
  end

  # ── Fixture Copy ─────────────────────────────────────────────────────────

  @doc """
  Copy a fixture into a `tmp_dir` (used when `Loader` needs a real file path).
  Returns the full path to the copied file.
  """
  @spec copy_fixture_to_tmp(atom(), String.t(), Path.t()) :: String.t()
  def copy_fixture_to_tmp(variant, name, tmp_dir) do
    src = path(variant, name)
    dest = Path.join(tmp_dir, name)
    File.cp!(src, dest)
    dest
  end
end
