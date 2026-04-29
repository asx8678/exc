defmodule CodePuppyControl.Sessions do
  @moduledoc """
  Context module for chat session persistence.

  Provides the public API for saving, loading, and managing agent sessions
  stored in SQLite via Ecto. Replaces Python session_storage.py functionality.

  This module implements : Migrate session_storage.py to Elixir/Ecto.

  (code_puppy-ctj.1) Extended with `has_terminal` and `terminal_meta` fields
  for terminal session crash recovery tracking.
  """

  require Logger

  import Ecto.Query

  alias CodePuppyControl.Repo
  alias CodePuppyControl.Sessions.ChatSession

  @type session_name :: String.t()
  @type history :: list(map())
  @type compacted_hashes :: list(String.t())
  @type session_result :: {:ok, ChatSession.t()} | {:error, Ecto.Changeset.t() | term()}

  @doc """
  Saves a chat session to the database.

  Creates a new session if one with the given name doesn't exist,
  otherwise updates the existing session.

  ## Parameters
    - name: Session identifier
    - history: List of message maps
    - opts: Keyword options
      - compacted_hashes: List of hash strings for compacted messages
      - total_tokens: Total token count
      - auto_saved: Whether this was auto-saved
      - timestamp: ISO8601 timestamp string

  ## Returns
    - `{:ok, ChatSession.t()}` on success
    - `{:error, changeset}` on validation failure
  """
  @spec save_session(
          session_name(),
          history(),
          keyword()
        ) :: session_result()
  def save_session(name, history, opts \\ []) do
    # (code_puppy-ctj.1 fix) When opts omit :has_terminal / :terminal_meta,
    # preserve existing values from the database row instead of defaulting
    # to false/nil — which would silently clear registered terminal recovery
    # metadata. The Store layer resolves these before calling us, but direct
    # callers (e.g. python_worker/port.ex) bypass the Store.
    {has_terminal, terminal_meta} =
      resolve_terminal_attrs(name, opts)

    attrs = %{
      name: name,
      history: history,
      compacted_hashes: Keyword.get(opts, :compacted_hashes, []),
      total_tokens: Keyword.get(opts, :total_tokens, 0),
      message_count: length(history),
      auto_saved: Keyword.get(opts, :auto_saved, false),
      timestamp: Keyword.get(opts, :timestamp, now_iso()),
      # (code_puppy-ctj.1) Terminal session fields for crash recovery
      has_terminal: has_terminal,
      terminal_meta: terminal_meta
    }

    case Repo.get_by(ChatSession, name: name) do
      nil ->
        %ChatSession{}
        |> ChatSession.changeset(attrs)
        |> Repo.insert()

      existing ->
        existing
        |> ChatSession.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Loads a session by name, returning history and compacted hashes.

  ## Returns
    - `{:ok, %{history: list(), compacted_hashes: list()}}` on success
    - `{:error, :not_found}` if session doesn't exist
    - `{:error, reason}` on other failures
  """
  @spec load_session(session_name()) ::
          {:ok, %{history: history(), compacted_hashes: compacted_hashes()}}
          | {:error, :not_found | term()}
  def load_session(name) do
    case Repo.get_by(ChatSession, name: name) do
      nil ->
        {:error, :not_found}

      session ->
        {:ok,
         %{
           history: session.history || [],
           compacted_hashes: session.compacted_hashes || []
         }}
    end
  end

  @doc """
  Loads a session with full metadata.

  ## Returns
    - `{:ok, ChatSession.t()}` on success
    - `{:error, :not_found}` if session doesn't exist
  """
  @spec load_session_full(session_name()) :: {:ok, ChatSession.t()} | {:error, :not_found}
  def load_session_full(name) do
    case Repo.get_by(ChatSession, name: name) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Lists all session names.

  Returns sorted list of session names (without metadata).
  """
  @spec list_sessions() :: {:ok, list(session_name())}
  def list_sessions do
    names =
      ChatSession
      |> select([s], s.name)
      |> order_by([s], asc: s.name)
      |> Repo.all()

    {:ok, names}
  end

  @doc """
  Lists sessions with metadata.

  Returns sessions sorted by timestamp (newest first).
  """
  @spec list_sessions_with_metadata() :: {:ok, list(map())}
  def list_sessions_with_metadata do
    sessions =
      ChatSession
      |> order_by([s], desc: s.timestamp)
      |> Repo.all()
      |> Enum.map(&ChatSession.to_map/1)

    {:ok, sessions}
  end

  @doc """
  Deletes a session by name.

  Returns `:ok` even if session doesn't exist (idempotent).
  """
  @spec delete_session(session_name()) :: :ok
  def delete_session(name) do
    case Repo.get_by(ChatSession, name: name) do
      nil -> :ok
      session -> Repo.delete!(session)
    end

    :ok
  end

  @doc """
  Cleans up old sessions, keeping only the most recent N.

  ## Parameters
    - max_sessions: Maximum number of sessions to keep

  ## Returns
    - `{:ok, list(session_name())}` - names of deleted sessions
  """
  @spec cleanup_sessions(non_neg_integer()) :: {:ok, list(session_name())}
  def cleanup_sessions(max_sessions) when max_sessions <= 0 do
    {:ok, []}
  end

  def cleanup_sessions(max_sessions) do
    # Get all sessions sorted by timestamp (oldest first)
    sessions =
      ChatSession
      |> order_by([s], asc: s.timestamp)
      |> Repo.all()

    if length(sessions) <= max_sessions do
      {:ok, []}
    else
      # (code_puppy-ctj.1 fix: take oldest to delete, not newest)
      to_delete_count = length(sessions) - max_sessions
      to_delete = Enum.take(sessions, to_delete_count)
      deleted_names = Enum.map(to_delete, & &1.name)

      Enum.each(to_delete, fn session ->
        Repo.delete!(session)
      end)

      {:ok, deleted_names}
    end
  end

  @doc """
  Updates terminal metadata fields for an existing session.

  Durably persists `has_terminal` and `terminal_meta` to SQLite without
  requiring the full history. Returns an error if the session does not exist.

  (code_puppy-ctj.1) This is the durable write path for terminal tracking —
  `register_terminal` and `unregister_terminal` call this to ensure terminal
  metadata survives crashes.
  """
  @spec update_terminal_meta(session_name(), boolean(), map() | nil) ::
          {:ok, ChatSession.t()} | {:error, :not_found | term()}
  def update_terminal_meta(name, has_terminal, terminal_meta) do
    case Repo.get_by(ChatSession, name: name) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> ChatSession.changeset(%{
          has_terminal: has_terminal,
          terminal_meta: normalize_terminal_meta(terminal_meta)
        })
        |> Repo.update()
    end
  end

  @doc """
  Checks if a session exists.
  """
  @spec session_exists?(session_name()) :: boolean()
  def session_exists?(name) do
    Repo.exists?(from(s in ChatSession, where: s.name == ^name))
  end

  @doc """
  Gets the total count of sessions.
  """
  @spec count_sessions() :: non_neg_integer()
  def count_sessions do
    Repo.aggregate(ChatSession, :count)
  end

  # Private helpers

  # Whitelist of known terminal_meta keys — mirrors Store whitelist.
  # We never call String.to_atom/1 on persisted JSON / user-influenced
  # terminal_meta; only known keys are promoted to atoms.  Unknown string
  # keys are preserved as strings.  (code_puppy-ctj.1 fix)
  @terminal_meta_whitelist %{
    "session_id" => :session_id,
    "cols" => :cols,
    "rows" => :rows,
    "shell" => :shell,
    "attached_at" => :attached_at
  }

  # (code_puppy-ctj.1 fix) Resolve terminal attrs from opts, preserving
  # existing database values when the caller does not explicitly provide
  # :has_terminal or :terminal_meta.  Returns {has_terminal, terminal_meta}.
  @spec resolve_terminal_attrs(session_name(), keyword()) ::
          {boolean(), map() | nil}
  defp resolve_terminal_attrs(name, opts) do
    has_terminal_explicit? = Keyword.has_key?(opts, :has_terminal)
    terminal_meta_explicit? = Keyword.has_key?(opts, :terminal_meta)

    if has_terminal_explicit? or terminal_meta_explicit? do
      # At least one field is explicit — resolve both, falling back to
      # existing DB values for anything not explicitly provided.
      existing = get_existing_terminal_from_db(name)

      has_terminal =
        if has_terminal_explicit?,
          do: Keyword.get(opts, :has_terminal),
          else: if(terminal_meta_explicit?, do: true, else: elem(existing, 0))

      terminal_meta =
        if terminal_meta_explicit?,
          do: Keyword.get(opts, :terminal_meta),
          else: elem(existing, 1)

      {has_terminal, terminal_meta}
    else
      # Neither field explicit — preserve existing DB values.
      # For new sessions (no DB row), default to false/nil.
      existing = get_existing_terminal_from_db(name)
      existing
    end
  end

  # Reads existing terminal state from the DB. Returns {false, nil}
  # for unknown sessions (safe defaults for a new row).
  @spec get_existing_terminal_from_db(session_name()) ::
          {boolean(), map() | nil}
  defp get_existing_terminal_from_db(name) do
    case Repo.get_by(ChatSession, name: name) do
      nil -> {false, nil}
      session -> {session.has_terminal || false, session.terminal_meta}
    end
  end

  defp normalize_terminal_meta(nil), do: nil

  defp normalize_terminal_meta(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_binary(k) ->
        {Map.get(@terminal_meta_whitelist, k, k), v}

      {k, v} when is_atom(k) ->
        {k, v}
    end)
  end

  defp normalize_terminal_meta(meta), do: meta

  defp now_iso do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
