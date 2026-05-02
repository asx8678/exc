defmodule CodePuppyControl.SessionStorage do
  @moduledoc """
  Session CRUD, search, and export for Code Puppy with ETS caching,
  Phoenix PubSub notifications, and disk crash-survivability.

  ## Storage backends

  When running inside the OTP supervision tree, delegates to
  `SessionStorage.Store` (ETS + SQLite + PubSub).
  Outside the OTP app (e.g. standalone scripts), falls back to
  file-based JSON storage via `SessionStorage.FileBackend`.

  ## PubSub Events

  Two subscription modes with **different event shapes** (by design):

  - **Per-session** (`subscribe/1`): receives `{:session_event, %{type:, name:, timestamp:, payload:}}`
    on topic `"session:{name}"`. Event types: `:saved`, `:updated`, `:deleted`.
  - **Global** (`subscribe_all/0`): receives `{:session_saved, name, meta}`,
    `{:session_deleted, name}`, `{:sessions_cleaned, [name]}` on topic `"sessions:events"`.

  The asymmetry preserves backwards compatibility with existing subscribers
  that depend on the global tuple shape.

  (code_puppy-ctj.1)
  """

  require Logger

  alias CodePuppyControl.SessionStorage.Format
  alias CodePuppyControl.SessionStorage.Store
  alias CodePuppyControl.SessionStorage.FileBackend
  alias CodePuppyControl.SessionStorage.PubSub, as: SSPubSub

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type session_name :: String.t()
  @type message :: map()
  @type history :: [message()]
  @type compacted_hashes :: [String.t()]
  @type total_tokens :: non_neg_integer()

  @type session_metadata :: %{
          session_name: session_name(),
          timestamp: String.t(),
          message_count: non_neg_integer(),
          total_tokens: total_tokens(),
          auto_saved: boolean()
        }

  @typedoc """
  Full session data with string keys (matching JSON decode shape).

  Note: The internal Store returns atom-keyed `session_entry()` maps;
  this facade converts them to the string-keyed shape below.

  Shape:

      %{
        "format" => String.t(),
        "payload" => %{
          "messages" => history(),
          "compacted_hashes" => compacted_hashes()
        },
        "metadata" => %{
          "session_name" => session_name(),
          "timestamp" => String.t(),
          "message_count" => non_neg_integer(),
          "total_tokens" => total_tokens(),
          "auto_saved" => boolean()
        }
      }
  """
  @type session_data :: %{required(String.t()) => term()}

  # ---------------------------------------------------------------------------
  # Directory Management
  # ---------------------------------------------------------------------------

  @doc "Returns the base directory for Elixir session storage."
  @spec base_dir :: Path.t()
  defdelegate base_dir, to: FileBackend

  @doc "Ensures the session storage directory exists."
  @spec ensure_dir :: {:ok, Path.t()} | {:error, term()}
  def ensure_dir do
    dir = base_dir()

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # CRUD Operations
  # ---------------------------------------------------------------------------

  @doc """
  Saves a session (creates or updates).
  Options: `:compacted_hashes`, `:total_tokens`, `:auto_saved`, `:timestamp`,
  `:base_dir`, `:has_terminal`, `:terminal_meta`.
  """
  @spec save_session(session_name(), history(), keyword()) ::
          {:ok, session_metadata()} | {:error, term()}
  def save_session(name, history, opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      save_via_store(name, history, opts)
    else
      FileBackend.save_session(name, history, opts)
    end
  end

  defp save_via_store(name, history, opts) do
    case Store.save_session(name, history, opts) do
      {:ok, result} ->
        {:ok,
         %{
           session_name: result.name,
           timestamp: result[:timestamp] || now_iso(),
           message_count: result.message_count,
           total_tokens: result.total_tokens,
           auto_saved: result[:auto_saved] || false
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Loads session messages and compacted hashes.
  Options: `:base_dir`.
  """
  @spec load_session(session_name(), keyword()) ::
          {:ok, %{messages: history(), compacted_hashes: compacted_hashes()}}
          | {:error, :not_found | term()}
  def load_session(name, opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      case Store.load_session(name) do
        {:ok, %{history: history, compacted_hashes: hashes}} ->
          {:ok, %{messages: history, compacted_hashes: hashes}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      FileBackend.load_session(name, opts)
    end
  end

  @doc """
  Loads full session data including format and metadata.
  Options: `:base_dir`.
  """
  @spec load_session_full(session_name(), keyword()) ::
          {:ok, session_data()} | {:error, :not_found | term()}
  def load_session_full(name, opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      case Store.load_session_full(name) do
        {:ok, entry} ->
          {:ok,
           %{
             "format" => Format.current_format(),
             "payload" => %{
               "messages" => entry.history,
               "compacted_hashes" => entry.compacted_hashes
             },
             "metadata" => %{
               "session_name" => entry.name,
               "timestamp" => entry.timestamp,
               "message_count" => entry.message_count,
               "total_tokens" => entry.total_tokens,
               "auto_saved" => entry.auto_saved
             }
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      FileBackend.load_session_full(name, opts)
    end
  end

  @doc """
  Updates session metadata fields.
  When Store is available, delegates to Store (SQLite + ETS + PubSub).
  Options: `:auto_saved`, `:total_tokens`, `:timestamp`, `:base_dir`.
  """
  @spec update_session(session_name(), keyword()) ::
          {:ok, session_metadata()} | {:error, term()}
  def update_session(name, opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      Store.update_session(name, opts)
    else
      FileBackend.update_session(name, opts)
    end
  end

  @doc """
  Deletes a session by name (idempotent).
  Options: `:base_dir`.
  """
  @spec delete_session(session_name(), keyword()) :: :ok | {:error, term()}
  def delete_session(name, opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      Store.delete_session(name)
    else
      FileBackend.delete_session(name, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Listing & Search
  # ---------------------------------------------------------------------------

  @doc """
  Lists all session names sorted alphabetically.
  Options: `:base_dir`.
  """
  @spec list_sessions(keyword()) :: {:ok, [session_name()]} | {:error, term()}
  def list_sessions(opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      Store.list_sessions()
    else
      FileBackend.list_sessions(opts)
    end
  end

  @doc """
  Lists sessions with metadata, sorted newest-first.
  Options: `:base_dir`.
  """
  @spec list_sessions_with_metadata(keyword()) :: {:ok, [session_metadata()]} | {:error, term()}
  def list_sessions_with_metadata(opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      case Store.list_sessions_with_metadata() do
        {:ok, entries} -> {:ok, Enum.map(entries, &store_entry_to_metadata/1)}
      end
    else
      FileBackend.list_sessions_with_metadata(opts)
    end
  end

  @doc """
  Searches sessions by filters.
  Options: `:name_pattern`, `:auto_saved`, `:min_tokens`, `:max_tokens`,
  `:since`, `:until`, `:base_dir`, `:limit`.
  """
  @spec search_sessions(keyword()) :: {:ok, [session_metadata()]} | {:error, term()}
  def search_sessions(opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      Store.search_sessions(opts)
    else
      FileBackend.search_sessions(opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup
  # ---------------------------------------------------------------------------

  @doc """
  Cleans up old sessions, keeping only the most recent N.
  Options: `:base_dir`.
  """
  @spec cleanup_sessions(non_neg_integer(), keyword()) ::
          {:ok, [session_name()]} | {:error, term()}
  def cleanup_sessions(max_sessions, _opts \\ [])

  def cleanup_sessions(max_sessions, _opts) when max_sessions <= 0, do: {:ok, []}

  def cleanup_sessions(max_sessions, opts) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      Store.cleanup_sessions(max_sessions)
    else
      FileBackend.cleanup_sessions(max_sessions, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Export
  # ---------------------------------------------------------------------------

  @doc """
  Exports a session to JSON. Composes from Store or falls back to FileBackend.
  Options: `:base_dir`, `:output_path`.
  """
  @spec export_session(session_name(), keyword()) ::
          {:ok, String.t() | Path.t()} | {:error, term()}
  def export_session(name, opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      export_session_via_store(name, opts)
    else
      FileBackend.export_session(name, opts)
    end
  end

  defp export_session_via_store(name, opts) do
    case Store.load_session_full(name) do
      {:ok, entry} ->
        data = %{
          "format" => Format.current_format(),
          "payload" => %{
            "messages" => entry.history,
            "compacted_hashes" => entry.compacted_hashes
          },
          "metadata" => %{
            "session_name" => entry.name,
            "timestamp" => entry.timestamp,
            "message_count" => entry.message_count,
            "total_tokens" => entry.total_tokens,
            "auto_saved" => entry.auto_saved
          }
        }

        json = Jason.encode!(data, pretty: true)
        write_or_return(json, Keyword.get(opts, :output_path))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Exports all sessions as a JSON array.
  Options: `:base_dir`, `:output_path`.
  """
  @spec export_all_sessions(keyword()) ::
          {:ok, String.t() | Path.t()} | {:error, term()}
  def export_all_sessions(opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      export_all_via_store(opts)
    else
      FileBackend.export_all_sessions(opts)
    end
  end

  defp export_all_via_store(opts) do
    {:ok, entries} = Store.list_sessions_with_metadata()

    items =
      Enum.map(entries, fn entry ->
        case Store.load_session_full(entry.name) do
          {:ok, full} ->
            %{
              "format" => Format.current_format(),
              "payload" => %{
                "messages" => full.history,
                "compacted_hashes" => full.compacted_hashes
              },
              "metadata" => %{
                "session_name" => full.name,
                "timestamp" => full.timestamp,
                "message_count" => full.message_count,
                "total_tokens" => full.total_tokens,
                "auto_saved" => full.auto_saved
              }
            }

          {:error, _} ->
            nil
        end
      end)
      |> Enum.filter(&(&1 != nil))

    json = Jason.encode!(items, pretty: true)
    write_or_return(json, Keyword.get(opts, :output_path))
  end

  defp write_or_return(json, nil), do: {:ok, json}

  defp write_or_return(json, path) do
    case File.write(path, json) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Async Autosave
  # ---------------------------------------------------------------------------

  @doc """
  Non-blocking version of `save_session/3`. Snapshots history immediately,
  submits the save to a background Task, and returns `:ok`.

  When Store is available, delegates to `save_session/3` (which routes to Store).
  Only resolves `:base_dir` eagerly when Store is unavailable — fixing the
  previous bug where `save_session_async/3` always forced FileBackend.

  Same options as `save_session/3`.
  """
  @spec save_session_async(session_name(), history(), keyword()) :: :ok
  def save_session_async(name, history, opts \\ []) do
    history_snapshot = history

    opts_resolved =
      if store_available?() do
        # Store path — no :base_dir needed; Store handles routing
        opts
      else
        # FileBackend path — resolve base_dir eagerly (before Task spawn)
        # to protect against env teardown races
        case FileBackend.safe_resolve_base_dir(opts) do
          {:ok, dir} ->
            Keyword.put(opts, :base_dir, dir)

          {:error, reason} ->
            Logger.warning("Async session save skipped: #{inspect(reason)}")
            nil
        end
      end

    if opts_resolved do
      _ =
        Task.start(fn ->
          case save_session(name, history_snapshot, opts_resolved) do
            {:ok, _meta} -> mark_autosave_complete(history_snapshot)
            {:error, reason} -> Logger.warning("Async session save failed: #{inspect(reason)}")
          end
        end)

      :ok
    else
      :ok
    end
  end

  @doc "Returns `true` if the autosave should be skipped (debounce + dedup)."
  @spec should_skip_autosave?(history()) :: boolean()
  def should_skip_autosave?(history) do
    CodePuppyControl.SessionStorage.AutosaveTracker.should_skip_autosave?(history)
  end

  @doc "Records that an autosave has completed."
  @spec mark_autosave_complete(history()) :: :ok
  def mark_autosave_complete(history) do
    CodePuppyControl.SessionStorage.AutosaveTracker.mark_autosave_complete(history)
  end

  # ---------------------------------------------------------------------------
  # Terminal Session Tracking
  # ---------------------------------------------------------------------------

  @doc "Registers a terminal session for crash recovery. Durably persists to SQLite."
  @spec register_terminal(session_name(), map()) :: :ok | {:error, term()}
  def register_terminal(session_name, meta) do
    if store_available?() do
      Store.register_terminal(session_name, meta)
    else
      {:error, :store_not_available}
    end
  end

  @doc "Unregisters a terminal session from crash recovery tracking."
  @spec unregister_terminal(session_name()) :: :ok | {:error, term()}
  def unregister_terminal(session_name) do
    if store_available?() do
      Store.unregister_terminal(session_name)
    else
      {:error, :store_not_available}
    end
  end

  @doc "Lists all tracked terminal sessions. Returns `[]` if Store is not running."
  @spec list_terminal_sessions() :: [map()]
  def list_terminal_sessions do
    if store_available?() do
      Store.list_terminal_sessions()
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # PubSub — Per-session and Global Subscriptions
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes the calling process to events for a specific session.

  Events received: `{:session_event, %{type:, name:, timestamp:, payload:}}`
  where `type` is `:saved`, `:updated`, `:deleted`, or `:custom`.
  """
  @spec subscribe(session_name()) :: :ok | {:error, term()}
  def subscribe(name) do
    SSPubSub.subscribe(name)
  end

  @doc "Unsubscribes from events for a specific session."
  @spec unsubscribe(session_name()) :: :ok | {:error, term()}
  def unsubscribe(name) do
    SSPubSub.unsubscribe(name)
  end

  @doc """
  Subscribes the calling process to global session lifecycle events.

  Events received (different shape from per-session!):
  - `{:session_saved, name, meta}` — after a session is saved
  - `{:session_deleted, name}` — after a session is deleted
  - `{:sessions_cleaned, [name]}` — after cleanup removes sessions
  """
  @spec subscribe_all() :: :ok | {:error, term()}
  def subscribe_all do
    SSPubSub.subscribe_all()
  end

  @doc "Unsubscribes from global session events."
  @spec unsubscribe_all() :: :ok | {:error, term()}
  def unsubscribe_all do
    SSPubSub.unsubscribe_all()
  end

  @doc """
  Subscribes the calling process to session lifecycle events via PubSub.
  Alias for `subscribe_all/0`.
  """
  @spec subscribe_sessions() :: :ok | {:error, term()}
  def subscribe_sessions do
    if store_available?() do
      Store.subscribe_sessions()
    else
      :ok
    end
  end

  @doc """
  Subscribes the calling process to terminal recovery events via PubSub.
  """
  @spec subscribe_terminal() :: :ok | {:error, term()}
  def subscribe_terminal do
    if store_available?() do
      Store.subscribe_terminal()
    else
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Utility
  # ---------------------------------------------------------------------------

  @doc "Checks if a session exists. Options: `:base_dir`."
  @spec session_exists?(session_name(), keyword()) :: boolean()
  def session_exists?(name, opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      Store.session_exists?(name)
    else
      FileBackend.session_exists?(name, opts)
    end
  end

  @doc "Returns the count of stored sessions. Options: `:base_dir`."
  @spec count_sessions(keyword()) :: non_neg_integer()
  def count_sessions(opts \\ []) do
    if store_available?() and not Keyword.has_key?(opts, :base_dir) do
      Store.count_sessions()
    else
      FileBackend.count_sessions(opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Private Helpers
  # ---------------------------------------------------------------------------

  @spec store_available?() :: boolean()
  defp store_available? do
    Process.whereis(Store) != nil
  end

  @spec store_entry_to_metadata(map()) :: session_metadata()
  defp store_entry_to_metadata(entry) do
    %{
      session_name: entry.name,
      timestamp: entry.timestamp,
      message_count: entry.message_count,
      total_tokens: entry.total_tokens,
      auto_saved: entry.auto_saved
    }
  end

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
