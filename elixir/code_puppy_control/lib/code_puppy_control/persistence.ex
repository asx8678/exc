defmodule CodePuppyControl.Persistence do
  @moduledoc """
  Safe atomic persistence helpers for file operations.

  Port of Python `code_puppy/persistence.py`. Provides atomic file write
  operations to prevent partial/corrupt files on crash or interruption.
  All writes use temp-file + atomic rename via `SafeWrite`.

  ## Features

  - Atomic text, binary, and JSON writes
  - Safe path resolution with path traversal prevention
  - ADR-003 isolation guard integration for config-home paths
  - Compact JSON writes (historically "msgpack" in Python API, now JSON)

  ## Migration Notes from Python

  - `atomic_write_msgpack` → `atomic_write_compact_json` (Python kept the
    name for API compat; internally it writes compact JSON, not msgpack)
  - `read_msgpack` → `read_compact_json`
  - Async wrappers (`_async` variants) are NOT ported: Elixir is
    inherently concurrent — use `Task.async/1` or `Task.Supervisor`
    for concurrent file I/O.
  - Thread-local directory creation cache is omitted: `File.mkdir_p/1`
    is idempotent and cheap on BEAM; caching would add ETS/GenServer
    complexity for negligible gain.

  ## ADR-003 Isolation Guard

  Writes targeting config-home paths (`~/.code_puppy_ex/` or
  `~/.code_puppy/`) are checked against the `Config.Isolation` guard.
  Writes to the legacy home (`~/.code_puppy/`) raise
  `IsolationViolation`. Writes to the active home are allowed.

  For paths outside config-home directories (e.g. project files),
  the guard is skipped — matching the Python belt-and-suspenders design.
  """

  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.Tools.FileModifications.SafeWrite

  require Logger

  # ── Path Resolution ────────────────────────────────────────────────────

  @doc """
  Resolve path to absolute, optionally verifying it's within `allowed_parent`.

  Uses `Path.expand/1` to normalize `..` components without following
  symlinks, preventing path traversal attacks while avoiding TOCTOU
  race conditions that could occur with symlink resolution.

  This mirrors Python's `safe_resolve_path` which uses `os.path.normpath`.

  ## Arguments

    * `path` — The path to resolve
    * `allowed_parent` — Optional parent directory that path must be within

  ## Returns

    * `{:ok, resolved_path}` — Path resolved successfully
    * `{:error, reason}` — Path is outside allowed_parent or resolution failed

  ## Examples

      iex> Persistence.safe_resolve_path("/tmp/../etc/passwd")
      {:ok, "/etc/passwd"}

      iex> Persistence.safe_resolve_path("../secret", "/tmp/sandbox")
      {:error, "Path /secret is outside allowed parent /tmp/sandbox"}
  """
  @spec safe_resolve_path(Path.t(), Path.t() | nil) ::
          {:ok, Path.t()} | {:error, String.t()}
  def safe_resolve_path(path, allowed_parent \\ nil) when is_binary(path) do
    try do
      # Path.expand/1 normalizes '..' without following symlinks (avoids TOCTOU)
      resolved = Path.expand(path)

      case allowed_parent do
        nil ->
          {:ok, resolved}

        parent when is_binary(parent) ->
          parent_resolved = Path.expand(parent)

          if path_within?(resolved, parent_resolved) do
            {:ok, resolved}
          else
            {:error, "Path #{resolved} is outside allowed parent #{parent}"}
          end
      end
    rescue
      e -> {:error, "Failed to resolve path #{path}: #{Exception.message(e)}"}
    end
  end

  # ── Isolation Guard ────────────────────────────────────────────────────

  @doc """
  Check ADR-003 isolation guard for writes targeting config-home paths.

  Belt-and-suspenders check: if the target path is under a config home
  directory (`~/.code_puppy/` or `~/.code_puppy_ex/`), we delegate to
  `Config.Isolation.allowed?/1`. For paths outside these directories
  (e.g. project files), the check is skipped.

  Canonical resolution is used so that symlinks whose lexical path is
  outside the config home but whose real target is inside are still
  caught (and vice-versa).

  ## Returns

    * `:ok` — Write is allowed
    * `{:error, :isolation_violation, message}` — Write is blocked

  ## Examples

      iex> Persistence.check_isolation_guard("/tmp/project/file.txt")
      :ok

      iex> Persistence.check_isolation_guard("~/code_puppy/config.json")
      {:error, :isolation_violation, "..."}
  """
  @spec check_isolation_guard(Path.t()) :: :ok | {:error, :isolation_violation, String.t()}
  def check_isolation_guard(path) when is_binary(path) do
    resolved = Paths.canonical_resolve(path)
    legacy_home = Paths.legacy_home_dir()
    active_home = Paths.home_dir()

    # Check if path is under either config home (canonical comparison)
    if path_under_home?(resolved, legacy_home) or path_under_home?(resolved, active_home) do
      if Isolation.allowed?(path) do
        :ok
      else
        {:error, :isolation_violation,
         "ConfigIsolationViolation: blocked atomic_write to #{resolved} (under legacy home)"}
      end
    else
      # Outside config homes — skip guard
      :ok
    end
  rescue
    # Defensive: never block a write due to a guard bug
    e ->
      Logger.debug("Isolation guard check failed for #{path}: #{Exception.message(e)}")
      :ok
  end

  # ── Atomic Write: Text ────────────────────────────────────────────────

  @doc """
  Write text file atomically using temp file + rename.

  The isolation guard is checked for config-home paths before writing.

  ## Arguments

    * `path` — Target file path
    * `content` — Text content to write

  ## Returns

    * `:ok` — File written successfully
    * `{:error, reason}` — Write failed

  ## Raises

  May raise `IsolationViolation` if path violates ADR-003 (via SafeWrite).
  """
  @spec atomic_write_text(Path.t(), String.t()) :: :ok | {:error, term()}
  def atomic_write_text(path, content) when is_binary(path) and is_binary(content) do
    with {:ok, resolved} <- safe_resolve_path(path),
         :ok <- check_isolation_guard(resolved) do
      ensure_parent_dir(resolved)
      SafeWrite.safe_write(resolved, content)
    end
  end

  # ── Atomic Write: Bytes ────────────────────────────────────────────────

  @doc """
  Write binary file atomically using temp file + rename.

  ## Arguments

    * `path` — Target file path
    * `data` — Binary data to write

  ## Returns

    * `:ok` — File written successfully
    * `{:error, reason}` — Write failed
  """
  @spec atomic_write_bytes(Path.t(), binary()) :: :ok | {:error, term()}
  def atomic_write_bytes(path, data) when is_binary(path) and is_binary(data) do
    with {:ok, resolved} <- safe_resolve_path(path),
         :ok <- check_isolation_guard(resolved) do
      ensure_parent_dir(resolved)
      SafeWrite.safe_write(resolved, data)
    end
  end

  # ── Atomic Write: JSON ─────────────────────────────────────────────────

  @doc """
  Write JSON file atomically with pretty-printed indentation.

  ## Arguments

    * `path` — Target file path
    * `data` — JSON-serializable data (must implement `Jason.Encoder`)
    * `opts` — Options:
      * `:indent` — JSON indentation (default: 2)
      * `:encoder` — Custom encoder function `(any -> iodata)`

  ## Returns

    * `:ok` — File written successfully
    * `{:error, reason}` — Write failed (including non-serializable data)

  ## Examples

      iex> Persistence.atomic_write_json("/tmp/data.json", %{key: "value"})
      :ok

      iex> Persistence.atomic_write_json("/tmp/data.json", %{key: "value"}, indent: 0)
      :ok
  """
  @spec atomic_write_json(Path.t(), term(), keyword()) :: :ok | {:error, term()}
  def atomic_write_json(path, data, opts \\ []) when is_binary(path) and is_list(opts) do
    indent = Keyword.get(opts, :indent, 2)
    encoder = Keyword.get(opts, :encoder)

    try do
      json_opts = if indent > 0, do: [pretty: true], else: []

      content =
        case encoder do
          nil -> Jason.encode!(data, json_opts)
          fun when is_function(fun, 1) -> Jason.encode!(fun.(data), json_opts)
        end

      atomic_write_text(path, content)
    rescue
      e in Protocol.UndefinedError ->
        {:error, "Data is not JSON-serializable: #{Exception.message(e)}"}

      e ->
        {:error, "JSON encoding failed: #{Exception.message(e)}"}
    end
  end

  # ── Atomic Write: Compact JSON (historically "msgpack") ────────────────

  @doc """
  Write compact JSON file atomically (binary output).

  Historical name kept for API compatibility. Now uses stdlib JSON
  instead of msgpack for free-threaded compatibility, matching the
  Python migration from msgpack to JSON.

  ## Arguments

    * `path` — Target file path
    * `data` — JSON-serializable data
    * `opts` — Options:
      * `:encoder` — Custom encoder function `(any -> iodata)`

  ## Returns

    * `:ok` — File written successfully
    * `{:error, reason}` — Write failed (including non-serializable data)
  """
  @spec atomic_write_compact_json(Path.t(), term(), keyword()) :: :ok | {:error, term()}
  def atomic_write_compact_json(path, data, opts \\ []) when is_binary(path) and is_list(opts) do
    # Isolation guard is applied inside atomic_write_bytes — no redundant check here.
    encoder = Keyword.get(opts, :encoder)

    try do
      content =
        case encoder do
          nil ->
            # Compact JSON: no pretty-printing, minimal separators
            Jason.encode!(data)

          fun when is_function(fun, 1) ->
            Jason.encode!(fun.(data))
        end

      atomic_write_bytes(path, content)
    rescue
      e in Protocol.UndefinedError ->
        {:error, "Data is not JSON-serializable: #{Exception.message(e)}"}

      e ->
        {:error, "JSON encoding failed: #{Exception.message(e)}"}
    end
  end

  # ── Read: JSON ─────────────────────────────────────────────────────────

  @doc """
  Read JSON file safely.

  Returns `default` if the file doesn't exist or contains invalid JSON.

  ## Arguments

    * `path` — File path to read
    * `default` — Value to return if file doesn't exist or is invalid (default: `nil`)

  ## Returns

    * `{:ok, data}` — Parsed JSON data
    * `{:ok, default}` — File missing or invalid JSON, returning default

  ## Examples

      iex> Persistence.read_json("/nonexistent.json", %{})
      {:ok, %{}}

      iex> Persistence.read_json("/tmp/valid.json")
      {:ok, %{"key" => "value"}}
  """
  @spec read_json(Path.t(), term()) :: {:ok, term()}
  def read_json(path, default \\ nil) when is_binary(path) do
    case safe_resolve_path(path) do
      {:ok, resolved} ->
        case File.read(resolved) do
          {:ok, content} ->
            try do
              {:ok, Jason.decode!(content)}
            rescue
              e ->
                Logger.warning("Failed to read JSON from #{resolved}: #{Exception.message(e)}")
                {:ok, default}
            end

          {:error, _enoent} ->
            {:ok, default}
        end

      {:error, reason} ->
        Logger.warning("Failed to resolve path #{path}: #{reason}")
        {:ok, default}
    end
  end

  # ── Read: Compact JSON (historically "msgpack") ────────────────────────

  @doc """
  Read compact JSON file safely.

  Historical name kept for API compatibility. Now reads compact JSON
  instead of msgpack, matching the Python migration.

  ## Arguments

    * `path` — File path to read
    * `default` — Value to return if file doesn't exist or is invalid

  ## Returns

    * `{:ok, data}` — Parsed data
    * `{:ok, default}` — File missing or invalid data, returning default
  """
  @spec read_compact_json(Path.t(), term()) :: {:ok, term()}
  def read_compact_json(path, default \\ nil) when is_binary(path) do
    # Same as read_json since we standardized on JSON
    read_json(path, default)
  end

  # ── Private Helpers ────────────────────────────────────────────────────

  # Ensure parent directory exists.
  # Unlike Python, we skip the caching layer — File.mkdir_p/1 is
  # idempotent and cheap; caching adds ETS/GenServer overhead for
  # negligible gain on BEAM.
  defp ensure_parent_dir(path) do
    parent = Path.dirname(path)

    case File.mkdir_p(parent) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, "Failed to create parent directory: #{:file.format_error(reason)}"}
    end
  end

  # Check if `resolved` path is lexically within `parent`.
  # Uses String prefix matching (like Python's startswith with os.sep).
  @spec path_within?(Path.t(), Path.t()) :: boolean()
  defp path_within?(resolved, parent) do
    resolved == parent or String.starts_with?(resolved, parent <> "/")
  end

  # Check if a path is under a given home directory using canonical resolution.
  @spec path_under_home?(Path.t(), String.t()) :: boolean()
  defp path_under_home?(resolved, home_dir) do
    canonical_home = Paths.canonical_resolve(home_dir)
    resolved == canonical_home or String.starts_with?(resolved, canonical_home <> "/")
  end
end
