defmodule CodePuppyControl.SessionStorage.FileBackend do
  @moduledoc """
  File-based session storage backend (JSON on disk).

  Used as a fallback when the OTP SessionStorage.Store is not available
  (e.g. standalone scripts, testing outside the supervision tree).

  All sessions stored as JSON under `~/.code_puppy_ex/sessions/`.
  Never touches `~/.code_puppy/` — migration is via `SessionStorage.Migrator`.

  This module was extracted from `SessionStorage` to keep the main module
  under the 600-line cap. (code_puppy-ctj.1)
  """

  require Logger

  alias CodePuppyControl.SessionStorage.Format

  # ---------------------------------------------------------------------------
  # Types (shared with parent module)
  # ---------------------------------------------------------------------------

  @type session_name :: String.t()
  @type history :: [map()]
  @type compacted_hashes :: [String.t()]
  @type total_tokens :: non_neg_integer()

  @type session_metadata :: %{
          session_name: session_name(),
          timestamp: String.t(),
          message_count: non_neg_integer(),
          total_tokens: total_tokens(),
          auto_saved: boolean()
        }

  @type session_data :: %{
          format: String.t(),
          payload: %{
            messages: history(),
            compacted_hashes: compacted_hashes()
          },
          metadata: session_metadata()
        }

  # ---------------------------------------------------------------------------
  # CRUD Operations
  # ---------------------------------------------------------------------------

  @doc "Saves a session to JSON files. Options: `:compacted_hashes`, `:total_tokens`, `:auto_saved`, `:timestamp`, `:base_dir`."
  @spec save_session(session_name(), history(), keyword()) ::
          {:ok, session_metadata()} | {:error, term()}
  def save_session(name, history, opts \\ []) do
    dir = resolve_base_dir(opts)
    compacted_hashes = Keyword.get(opts, :compacted_hashes, [])
    total_tokens = Keyword.get(opts, :total_tokens, 0)
    auto_saved = Keyword.get(opts, :auto_saved, false)
    timestamp = Keyword.get(opts, :timestamp, now_iso())

    with :ok <- File.mkdir_p(dir) do
      paths = Format.build_paths(dir, name)
      message_count = length(history)

      payload = %{
        "messages" => history,
        "compacted_hashes" => compacted_hashes
      }

      metadata = %{
        "session_name" => name,
        "timestamp" => timestamp,
        "message_count" => message_count,
        "total_tokens" => total_tokens,
        "auto_saved" => auto_saved
      }

      session_data = %{
        "format" => Format.current_format(),
        "payload" => payload,
        "metadata" => metadata
      }

      with {:ok, session_tmp} <- write_tmp(paths.session_path, session_data),
           {:ok, meta_tmp} <- write_tmp(paths.metadata_path, metadata) do
        case rename_both(session_tmp, paths.session_path, meta_tmp, paths.metadata_path) do
          :ok ->
            {:ok,
             %{
               session_name: name,
               timestamp: timestamp,
               message_count: message_count,
               total_tokens: total_tokens,
               auto_saved: auto_saved
             }}

          {:error, reason} ->
            _ = File.rm(session_tmp)
            _ = File.rm(meta_tmp)
            {:error, reason}
        end
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Loads session messages and compacted hashes from JSON. Options: `:base_dir`."
  @spec load_session(session_name(), keyword()) ::
          {:ok, %{messages: history(), compacted_hashes: compacted_hashes()}}
          | {:error, :not_found | term()}
  def load_session(name, opts \\ []) do
    dir = resolve_base_dir(opts)
    paths = Format.build_paths(dir, name)

    case File.read(paths.session_path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"payload" => payload}} ->
            messages = Map.get(payload, "messages", [])
            hashes = Map.get(payload, "compacted_hashes", [])
            {:ok, %{messages: messages, compacted_hashes: hashes}}

          {:ok, data} when is_list(data) ->
            {:ok, %{messages: data, compacted_hashes: []}}

          {:ok, _other} ->
            {:error, "Unexpected session data format"}

          {:error, reason} ->
            {:error, "JSON decode error: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Loads full session data including format and metadata. Options: `:base_dir`."
  @spec load_session_full(session_name(), keyword()) ::
          {:ok, session_data()} | {:error, :not_found | term()}
  def load_session_full(name, opts \\ []) do
    dir = resolve_base_dir(opts)
    paths = Format.build_paths(dir, name)

    case File.read(paths.session_path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, "JSON decode error: #{inspect(reason)}"}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Updates session metadata fields. Options: `:auto_saved`, `:total_tokens`, `:timestamp`, `:base_dir`."
  @spec update_session(session_name(), keyword()) ::
          {:ok, session_metadata()} | {:error, term()}
  def update_session(name, opts \\ []) do
    dir = resolve_base_dir(opts)
    normalized = Format.normalize_name(name)

    case load_session_full(normalized, base_dir: dir) do
      {:ok, data} ->
        metadata = Map.get(data, "metadata", %{})

        updated_metadata =
          metadata
          |> maybe_put("auto_saved", Keyword.get(opts, :auto_saved))
          |> maybe_put("total_tokens", Keyword.get(opts, :total_tokens))
          |> maybe_put("timestamp", Keyword.get(opts, :timestamp))
          |> Map.put("updated_at", now_iso())

        updated_data = Map.put(data, "metadata", updated_metadata)

        paths = Format.build_paths(dir, normalized)

        with {:ok, session_tmp} <- write_tmp(paths.session_path, updated_data),
             {:ok, meta_tmp} <- write_tmp(paths.metadata_path, updated_metadata) do
          case rename_both(session_tmp, paths.session_path, meta_tmp, paths.metadata_path) do
            :ok ->
              {:ok, map_to_metadata(updated_metadata)}

            {:error, reason} ->
              _ = File.rm(session_tmp)
              _ = File.rm(meta_tmp)
              {:error, reason}
          end
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Deletes a session by name (idempotent). Options: `:base_dir`."
  @spec delete_session(session_name(), keyword()) :: :ok
  def delete_session(name, opts \\ []) do
    dir = resolve_base_dir(opts)
    paths = Format.build_paths(dir, name)
    _ = File.rm(paths.session_path)
    _ = File.rm(paths.metadata_path)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Listing & Search
  # ---------------------------------------------------------------------------

  @doc "Lists all session names sorted alphabetically. Options: `:base_dir`."
  @spec list_sessions(keyword()) :: {:ok, [session_name()]} | {:error, term()}
  def list_sessions(opts \\ []) do
    dir = resolve_base_dir(opts)

    case File.ls(dir) do
      {:ok, files} ->
        names =
          files
          |> Enum.filter(&String.ends_with?(&1, Format.session_ext()))
          |> Enum.reject(&String.ends_with?(&1, Format.metadata_suffix()))
          |> Enum.map(&Path.rootname(&1))
          |> Enum.sort()

        {:ok, names}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Lists sessions with metadata, sorted newest-first. Options: `:base_dir`."
  @spec list_sessions_with_metadata(keyword()) :: {:ok, [session_metadata()]} | {:error, term()}
  def list_sessions_with_metadata(opts \\ []) do
    dir = resolve_base_dir(opts)

    case File.ls(dir) do
      {:ok, files} ->
        meta_files =
          files
          |> Enum.filter(&String.ends_with?(&1, Format.metadata_suffix()))

        sessions =
          meta_files
          |> Enum.map(&load_metadata_file(Path.join(dir, &1)))
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(fn {:ok, meta} -> meta end)
          |> Enum.sort_by(& &1.timestamp, :desc)

        {:ok, sessions}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Searches sessions by filters.

  Options: `:name_pattern` (string/regex), `:auto_saved`, `:min_tokens`,
  `:max_tokens`, `:since`, `:until` (ISO8601), `:base_dir`, `:limit` (default 100).
  """
  @spec search_sessions(keyword()) :: {:ok, [session_metadata()]} | {:error, term()}
  def search_sessions(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    name_pattern = Keyword.get(opts, :name_pattern)
    auto_saved = Keyword.get(opts, :auto_saved)
    min_tokens = Keyword.get(opts, :min_tokens)
    max_tokens = Keyword.get(opts, :max_tokens)
    since = Keyword.get(opts, :since)
    until = Keyword.get(opts, :until)

    case list_sessions_with_metadata(opts) do
      {:ok, sessions} ->
        filtered =
          sessions
          |> filter_by_name(name_pattern)
          |> filter_by_auto_saved(auto_saved)
          |> filter_by_token_range(min_tokens, max_tokens)
          |> filter_by_time_range(since, until)
          |> Enum.take(limit)

        {:ok, filtered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup
  # ---------------------------------------------------------------------------

  @doc "Cleans up old sessions, keeping only the most recent N. Options: `:base_dir`."
  @spec cleanup_sessions(non_neg_integer(), keyword()) :: {:ok, [session_name()]}
  def cleanup_sessions(max_sessions, _opts \\ [])

  def cleanup_sessions(max_sessions, _opts) when max_sessions <= 0, do: {:ok, []}

  def cleanup_sessions(max_sessions, opts) do
    case list_sessions_with_metadata(opts) do
      {:ok, sessions} ->
        if length(sessions) <= max_sessions do
          {:ok, []}
        else
          to_delete = Enum.drop(sessions, max_sessions)
          deleted = delete_sessions(to_delete, opts)
          {:ok, deleted}
        end

      {:error, _} ->
        {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Export
  # ---------------------------------------------------------------------------

  @doc """
  Exports a session to JSON.

  Options: `:base_dir`, `:output_path` (write to file instead of returning string).
  """
  @spec export_session(session_name(), keyword()) ::
          {:ok, String.t() | Path.t()} | {:error, term()}
  def export_session(name, opts \\ []) do
    dir = resolve_base_dir(opts)

    with {:ok, data} <- load_session_full(name, base_dir: dir) do
      json = Jason.encode!(data, pretty: true)
      write_or_return(json, Keyword.get(opts, :output_path))
    end
  end

  @doc """
  Exports all sessions as a JSON array.

  Options: `:base_dir`, `:output_path` (write to file instead of returning string).
  """
  @spec export_all_sessions(keyword()) ::
          {:ok, String.t() | Path.t()} | {:error, term()}
  def export_all_sessions(opts \\ []) do
    with {:ok, names} <- list_sessions(opts) do
      sessions =
        names
        |> Enum.map(&load_session_full(&1, opts))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, data} -> data end)

      json = Jason.encode!(sessions, pretty: true)
      write_or_return(json, Keyword.get(opts, :output_path))
    end
  end

  # ---------------------------------------------------------------------------
  # Utility
  # ---------------------------------------------------------------------------

  @doc "Checks if a session exists. Options: `:base_dir`."
  @spec session_exists?(session_name(), keyword()) :: boolean()
  def session_exists?(name, opts \\ []) do
    dir = resolve_base_dir(opts)
    paths = Format.build_paths(dir, name)
    File.exists?(paths.session_path)
  end

  @doc "Returns the count of stored sessions. Options: `:base_dir`."
  @spec count_sessions(keyword()) :: non_neg_integer()
  def count_sessions(opts \\ []) do
    case list_sessions(opts) do
      {:ok, names} -> length(names)
      {:error, _} -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Internal Helpers (exposed for SessionStorage facade)
  # ---------------------------------------------------------------------------

  @doc false
  @spec resolve_base_dir(keyword()) :: Path.t()
  def resolve_base_dir(opts) do
    case Keyword.fetch(opts, :base_dir) do
      {:ok, dir} -> dir
      :error -> base_dir()
    end
  end

  @doc false
  @spec safe_resolve_base_dir(keyword()) :: {:ok, Path.t()} | {:error, term()}
  def safe_resolve_base_dir(opts) do
    case Keyword.fetch(opts, :base_dir) do
      {:ok, dir} ->
        {:ok, dir}

      :error ->
        try do
          {:ok, base_dir()}
        rescue
          e -> {:error, e}
        end
    end
  end

  @doc false
  @spec base_dir :: Path.t()
  def base_dir do
    raw =
      case System.get_env("PUP_SESSION_DIR") do
        nil -> "~/.code_puppy_ex/sessions"
        dir -> dir
      end

    raw |> Path.expand() |> validate_storage_dir!()
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp validate_storage_dir!(dir) do
    canonical = Path.expand(dir)
    ex_home = Path.expand("~/.code_puppy_ex")

    test_root =
      if Application.get_env(:code_puppy_control, :allow_test_session_root, false) do
        System.get_env("PUP_TEST_SESSION_ROOT")
      end

    allowed_roots = [ex_home] ++ if(test_root, do: [test_root], else: [])

    unless Enum.any?(allowed_roots, &path_under_root?(canonical, &1)) do
      raise ArgumentError, "Storage dir #{inspect(dir)} is outside ~/.code_puppy_ex/"
    end

    canonical
  end

  @spec path_under_root?(Path.t(), Path.t()) :: boolean()
  defp path_under_root?(path, root) do
    path_segments = Path.split(path)
    root_segments = Path.split(root)

    length(path_segments) >= length(root_segments) and
      Enum.take(path_segments, length(root_segments)) == root_segments
  end

  defp write_tmp(path, data) do
    json = Jason.encode!(data, pretty: true)
    tmp_path = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

    case File.write(tmp_path, json) do
      :ok -> {:ok, tmp_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rename_both(session_tmp, session_path, meta_tmp, meta_path) do
    case File.rename(session_tmp, session_path) do
      :ok ->
        case File.rename(meta_tmp, meta_path) do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rename(session_path, session_tmp)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_metadata_file(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, data} -> {:ok, map_to_metadata(data)}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp map_to_metadata(data) when is_map(data) do
    %{
      session_name: Map.get(data, "session_name", Map.get(data, "name", "")),
      timestamp: Map.get(data, "timestamp", ""),
      message_count: Map.get(data, "message_count", 0),
      total_tokens: Map.get(data, "total_tokens", 0),
      auto_saved: Map.get(data, "auto_saved", false)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Search filter helpers

  defp filter_by_name(sessions, nil), do: sessions

  defp filter_by_name(sessions, pattern) when is_binary(pattern) do
    case Regex.compile(pattern, "i") do
      {:ok, regex} -> filter_by_name(sessions, regex)
      {:error, _} -> sessions
    end
  end

  defp filter_by_name(sessions, %Regex{} = regex) do
    Enum.filter(sessions, fn meta ->
      Regex.match?(regex, meta.session_name)
    end)
  end

  defp filter_by_auto_saved(sessions, nil), do: sessions

  defp filter_by_auto_saved(sessions, flag) when is_boolean(flag) do
    Enum.filter(sessions, &(&1.auto_saved == flag))
  end

  defp filter_by_token_range(sessions, nil, nil), do: sessions

  defp filter_by_token_range(sessions, min, max) do
    Enum.filter(sessions, fn meta ->
      tokens = meta.total_tokens
      (is_nil(min) or tokens >= min) and (is_nil(max) or tokens <= max)
    end)
  end

  defp filter_by_time_range(sessions, nil, nil), do: sessions

  defp filter_by_time_range(sessions, since, until) do
    Enum.filter(sessions, fn meta ->
      ts = meta.timestamp
      (is_nil(since) or ts >= since) and (is_nil(until) or ts <= until)
    end)
  end

  defp delete_sessions(sessions, opts) do
    Enum.map(sessions, fn meta ->
      _ = delete_session(meta.session_name, opts)
      meta.session_name
    end)
  end

  defp write_or_return(json, nil), do: {:ok, json}

  defp write_or_return(json, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, json) do
      {:ok, path}
    end
  end
end
