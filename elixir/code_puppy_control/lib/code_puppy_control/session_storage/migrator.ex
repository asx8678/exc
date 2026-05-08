defmodule CodePuppyControl.SessionStorage.Migrator do
  @moduledoc """
  One-shot Python→Elixir session migrator.

  Reads sessions from the Python storage directory (`~/.code_puppy/subagent_sessions/`
  and `~/.code_puppy/autosaves/`) and writes them to the Elixir storage directory
  (`~/.code_puppy_ex/sessions/`).

  ## Features

  - **Idempotent**: Safe to run multiple times. Already-migrated sessions are skipped.
  - **Multi-format**: Handles Python JSON+HMAC (`.pkl`), pydantic-ai JSON (`.msgpack`),
    and Elixir-native JSON formats.
  - **Isolation**: Only READS from `~/.code_puppy/`, only WRITES to `~/.code_puppy_ex/`.
  - **Dry-run**: Supports `:dry_run` mode to preview without writing.

  ## Usage

      # Migrate all sessions
      {:ok, result} = Migrator.migrate()

      # Dry run (preview only)
      {:ok, result} = Migrator.migrate(dry_run: true)

      # Custom directories (for testing)
      {:ok, result} = Migrator.migrate(source_dir: "/tmp/sessions", dest_dir: "/tmp/out")

  ## Result

      %{
        migrated: ["session-a", "session-b"],
        skipped: ["already-there"],
        failed: [{"broken-session", "reason"}],
        total_source: 10,
        total_dest_before: 2
      }
  """

  require Logger

  alias CodePuppyControl.SessionStorage
  alias CodePuppyControl.SessionStorage.Format

  # Default Python session directories
  @default_subagent_dir "~/.code_puppy/subagent_sessions"
  @default_autosave_dir "~/.code_puppy/autosaves"

  @type migrate_result :: %{
          migrated: [String.t()],
          skipped: [String.t()],
          failed: [{String.t(), String.t()}],
          total_source: non_neg_integer(),
          total_dest_before: non_neg_integer()
        }

  @doc """
  Runs the migration from Python session storage to Elixir session storage.

  ## Options

    * `:source_dir` - override source directory (default: `~/.code_puppy/subagent_sessions/`)
    * `:source_autosave_dir` - override autosave source directory
    * `:dest_dir` - override destination directory (default: `~/.code_puppy_ex/sessions/`)
    * `:dry_run` - if `true`, don't write any files (default: `false`)
    * `:overwrite` - if `true`, overwrite existing sessions (default: `false`)

  ## Returns

    * `{:ok, migrate_result}` on completion
  """
  @spec migrate(keyword()) :: {:ok, migrate_result()}
  def migrate(opts \\ []) do
    source_dir = Keyword.get(opts, :source_dir, Path.expand(@default_subagent_dir))

    source_autosave_dir =
      Keyword.get(opts, :source_autosave_dir, Path.expand(@default_autosave_dir))

    dest_dir =
      case Keyword.fetch(opts, :dest_dir) do
        {:ok, dir} -> dir
        :error -> SessionStorage.base_dir()
      end

    dry_run = Keyword.get(opts, :dry_run, false)
    overwrite = Keyword.get(opts, :overwrite, false)

    # Count existing destination sessions
    total_dest_before =
      case SessionStorage.list_sessions(base_dir: dest_dir) do
        {:ok, names} -> length(names)
        {:error, _} -> 0
      end

    # Collect all source files
    subagent_files = list_session_files(source_dir, [".msgpack", ".json", ".pkl"])
    autosave_files = list_session_files(source_autosave_dir, [".pkl", ".json"])

    all_files = subagent_files ++ autosave_files
    total_source = length(all_files)

    # Process each file
    {migrated, skipped, failed} =
      Enum.reduce(all_files, {[], [], []}, fn {path, stem},
                                              {acc_migrated, acc_skipped, acc_failed} ->
        # Check if already migrated (unless overwrite)
        if not overwrite and SessionStorage.session_exists?(stem, base_dir: dest_dir) do
          {acc_migrated, [stem | acc_skipped], acc_failed}
        else
          case migrate_single_file(path, stem, dest_dir, dry_run) do
            {:ok, :migrated} ->
              {[stem | acc_migrated], acc_skipped, acc_failed}

            {:ok, :skipped} ->
              {acc_migrated, [stem | acc_skipped], acc_failed}

            {:error, reason} ->
              {acc_migrated, acc_skipped, [{stem, reason} | acc_failed]}
          end
        end
      end)

    {:ok,
     %{
       migrated: Enum.reverse(migrated),
       skipped: Enum.reverse(skipped),
       failed: Enum.reverse(failed),
       total_source: total_source,
       total_dest_before: total_dest_before
     }}
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp list_session_files(dir, extensions) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(fn f ->
          ext = Path.extname(f)
          ext in extensions
        end)
        |> Enum.map(fn f ->
          path = Path.join(dir, f)
          stem = Path.basename(f, Path.extname(f))
          {path, Format.normalize_name(stem)}
        end)

      {:error, _} ->
        []
    end
  end

  defp migrate_single_file(path, name, dest_dir, dry_run) do
    with {:ok, raw} <- File.read(path),
         {:ok, session_data} <- parse_source_file(raw) do
      if dry_run do
        Logger.info("[MIGRATOR] Would migrate: #{name}")
        {:ok, :migrated}
      else
        # Extract and normalize data for Elixir format
        {messages, compacted_hashes, metadata} = extract_session_fields(session_data, name)

        case SessionStorage.save_session(
               name,
               messages,
               base_dir: dest_dir,
               compacted_hashes: compacted_hashes,
               total_tokens: Map.get(metadata, "total_tokens", 0),
               auto_saved: Map.get(metadata, "auto_saved", false),
               timestamp: Map.get(metadata, "timestamp", Map.get(metadata, "created_at", nil))
             ) do
          {:ok, _meta} ->
            Logger.info("[MIGRATOR] Migrated: #{name}")
            {:ok, :migrated}

          {:error, reason} ->
            Logger.warning("[MIGRATOR] Failed to save #{name}: #{inspect(reason)}")
            {:error, "Save failed: #{inspect(reason)}"}
        end
      end
    else
      {:error, reason} ->
        Logger.warning("[MIGRATOR] Failed to parse #{name}: #{inspect(reason)}")
        {:error, "Parse failed: #{inspect(reason)}"}
    end
  end

  defp parse_source_file(raw) do
    case Format.detect_format(raw) do
      :python_json_hmac ->
        Format.parse_python_json_hmac(raw)

      :python_plain_json ->
        case Jason.decode(raw) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, "JSON decode: #{inspect(reason)}"}
        end

      :elixir_json ->
        # Already in Elixir format — just decode
        case Jason.decode(raw) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, "JSON decode: #{inspect(reason)}"}
        end

      :python_msgpack_hmac ->
        {:error,
         "Legacy msgpack format not supported (install msgpack Python lib to convert first)"}

      :unknown ->
        # Try plain JSON decode as last resort
        case Jason.decode(raw) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, "Unknown format, JSON fallback failed: #{inspect(reason)}"}
        end
    end
  end

  defp extract_session_fields(data, fallback_name) do
    case data do
      # pydantic-ai-json-v2 format: {"format": ..., "payload": [...], "metadata": {...}}
      %{"payload" => payload, "metadata" => metadata} when is_list(payload) ->
        messages = payload
        compacted_hashes = Map.get(metadata, "compacted_hashes", [])
        {messages, compacted_hashes, metadata}

      # Our Elixir format: {"format": ..., "payload": {"messages": [...], ...}, "metadata": {...}}
      %{"payload" => %{"messages" => messages} = payload, "metadata" => metadata} ->
        compacted_hashes = Map.get(payload, "compacted_hashes", [])
        {messages, compacted_hashes, metadata}

      # JSONV+HMAC format: {"messages": [...], "compacted_hashes": [...]}
      %{"messages" => messages} ->
        compacted_hashes = Map.get(data, "compacted_hashes", [])
        metadata = Map.drop(data, ["messages", "compacted_hashes"])
        {messages, compacted_hashes, metadata}

      # Legacy: raw list of messages
      messages when is_list(messages) ->
        {messages, [], %{"session_name" => fallback_name}}

      _ ->
        {[], [], %{"session_name" => fallback_name}}
    end
  end
end
