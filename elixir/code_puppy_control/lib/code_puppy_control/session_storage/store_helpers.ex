defmodule CodePuppyControl.SessionStorage.StoreHelpers do
  @moduledoc """
  Pure helper functions for SessionStorage.Store.

  Extracted to keep Store.ex under the 600-line cap. Contains:
  - ISO timestamp generation
  - Session entry construction
  - Terminal metadata normalization
  - ChatSession / session-data → ETS entry conversion
  - Session result formatting

  All functions are pure with no side effects. (code_puppy-ctj.1)
  """

  # ---------------------------------------------------------------------------
  # Timestamp
  # ---------------------------------------------------------------------------

  @doc "Returns the current UTC time as ISO 8601 string."
  @spec now_iso() :: String.t()
  def now_iso, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # ---------------------------------------------------------------------------
  # Entry Construction
  # ---------------------------------------------------------------------------

  @doc "Builds an ETS session entry map from individual fields."
  @spec build_entry(
          String.t(),
          [map()],
          [String.t()],
          non_neg_integer(),
          boolean(),
          String.t(),
          boolean(),
          map() | nil
        ) :: map()
  def build_entry(
        name,
        history,
        compacted_hashes,
        total_tokens,
        auto_saved,
        timestamp,
        has_terminal,
        terminal_meta
      ) do
    %{
      name: name,
      history: history,
      compacted_hashes: compacted_hashes,
      total_tokens: total_tokens,
      message_count: length(history),
      auto_saved: auto_saved,
      timestamp: timestamp,
      has_terminal: has_terminal,
      terminal_meta: terminal_meta,
      updated_at: System.monotonic_time(:millisecond)
    }
  end

  # ---------------------------------------------------------------------------
  # Terminal Metadata Normalization
  # ---------------------------------------------------------------------------

  # Whitelist of known terminal_meta keys.  We never call String.to_atom/1
  # on persisted JSON / user-influenced data — only known keys are promoted
  # to atoms; unknown string keys are preserved as strings so downstream code
  # can still read them via dual-key access (get_key).  (code_puppy-ctj.1 fix)
  @terminal_meta_whitelist %{
    "session_id" => :session_id,
    "cols" => :cols,
    "rows" => :rows,
    "shell" => :shell,
    "attached_at" => :attached_at
  }

  @doc """
  Normalizes terminal metadata keys: promotes known string keys to atoms,
  preserves unknown string keys as strings.
  """
  @spec normalize_meta_keys(nil | map() | term()) :: nil | map() | term()
  def normalize_meta_keys(nil), do: nil

  def normalize_meta_keys(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_binary(k) ->
        {Map.get(@terminal_meta_whitelist, k, k), v}

      {k, v} when is_atom(k) ->
        {k, v}
    end)
  end

  def normalize_meta_keys(meta), do: meta

  @doc """
  Dual-key map accessor: tries atom key first, then string key fallback.

  Useful when reading data that may come from ETS (atom keys) or
  SQLite (string keys).
  """
  @spec get_key(map(), atom(), String.t(), term()) :: term()
  def get_key(map, atom_key, string_key, default \\ nil) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end

  # ---------------------------------------------------------------------------
  # Session / Entry Conversion
  # ---------------------------------------------------------------------------

  @doc """
  Converts a ChatSession map (from SQLite) to an ETS entry.

  Handles the dual-key nature of data coming from SQLite (string keys)
  by normalizing via `get_key/4`. Terminal metadata keys are also
  normalized via `normalize_meta_keys/1`.
  """
  @spec chat_session_to_entry(map()) :: map()
  def chat_session_to_entry(session) when is_map(session) do
    raw_meta = get_key(session, :terminal_meta, "terminal_meta")

    %{
      name: get_key(session, :name, "name", ""),
      history: get_key(session, :history, "history", []),
      compacted_hashes: get_key(session, :compacted_hashes, "compacted_hashes", []),
      total_tokens: get_key(session, :total_tokens, "total_tokens", 0),
      message_count: get_key(session, :message_count, "message_count", 0),
      auto_saved: get_key(session, :auto_saved, "auto_saved", false),
      timestamp: get_key(session, :timestamp, "timestamp", ""),
      has_terminal: get_key(session, :has_terminal, "has_terminal", false),
      terminal_meta: normalize_meta_keys(raw_meta),
      updated_at: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Converts lightweight session data from `Sessions.load_session/1` to
  an ETS entry. Missing fields default to zero / empty values.
  """
  @spec session_data_to_entry(String.t(), map()) :: map()
  def session_data_to_entry(name, data) do
    history = Map.get(data, :history, [])

    %{
      name: name,
      history: history,
      compacted_hashes: Map.get(data, :compacted_hashes, []),
      total_tokens: 0,
      message_count: length(history),
      auto_saved: false,
      timestamp: "",
      has_terminal: false,
      terminal_meta: nil,
      updated_at: System.monotonic_time(:millisecond)
    }
  end

  @doc "Formats a ChatSession struct for API responses."
  @spec session_to_result(map()) :: map()
  def session_to_result(session) do
    %{
      name: session.name,
      message_count: session.message_count,
      total_tokens: session.total_tokens,
      auto_saved: session.auto_saved,
      timestamp: session.timestamp
    }
  end

  # ---------------------------------------------------------------------------
  # Terminal Field Resolution (code_puppy-ctj.1 fix)
  # ---------------------------------------------------------------------------

  @doc """
  Resolves :has_terminal and :terminal_meta from opts, preserving existing
  ETS values when the caller does not explicitly provide them.

  Returns `{has_terminal, terminal_meta, has_terminal_explicit?}` where the
  third element indicates whether the caller explicitly set `:has_terminal` —
  this drives the terminal ETS table consistency logic (delete on explicit
  clear, preserve otherwise).

  The `session_table` argument is the ETS table reference (atom) to read
  existing terminal state from.
  """
  @spec resolve_terminal_fields(String.t(), keyword(), atom()) ::
          {boolean(), map() | nil, boolean()}
  def resolve_terminal_fields(name, opts, session_table) do
    has_terminal_explicit? = Keyword.has_key?(opts, :has_terminal)
    terminal_meta_explicit? = Keyword.has_key?(opts, :terminal_meta)

    {existing_ht, existing_tm} = get_existing_terminal_state(name, session_table)

    cond do
      # Case 1: Neither field explicit → preserve existing entirely.
      # This is the common path (save_session called without terminal opts),
      # e.g. autosave updating history while a terminal is attached.
      not has_terminal_explicit? and not terminal_meta_explicit? ->
        {existing_ht, existing_tm, false}

      # Case 2: has_terminal explicitly false → clear terminal state.
      # Caller is intentionally unregistering via save_session.
      has_terminal_explicit? and not Keyword.get(opts, :has_terminal) ->
        {false, nil, true}

      # Case 3: At least one explicit with has_terminal true (or implied by
      # providing terminal_meta). Use explicit values, falling back to
      # existing for anything not explicitly provided.
      true ->
        ht =
          if has_terminal_explicit?,
            do: Keyword.get(opts, :has_terminal),
            else: if(terminal_meta_explicit?, do: true, else: existing_ht)

        tm =
          if terminal_meta_explicit?,
            do: Keyword.get(opts, :terminal_meta),
            else: existing_tm

        {ht, tm, has_terminal_explicit?}
    end
  end

  @doc """
  Reads the current terminal state from the session ETS table.

  Returns `{false, nil}` for unknown sessions (safe defaults for a new row).
  """
  @spec get_existing_terminal_state(String.t(), atom()) ::
          {boolean(), map() | nil}
  def get_existing_terminal_state(name, session_table) do
    case :ets.lookup(session_table, name) do
      [{^name, entry}] -> {entry.has_terminal, entry.terminal_meta}
      [] -> {false, nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Search Filter Helpers (code_puppy-ctj.1 fresh port)
  # ---------------------------------------------------------------------------

  @doc "Filters session entries by name pattern (substring or regex)."
  @spec filter_by_name([map()], String.t() | Regex.t() | nil) :: [map()]
  def filter_by_name(sessions, nil), do: sessions

  def filter_by_name(sessions, pattern) when is_binary(pattern) do
    Enum.filter(sessions, fn e -> String.contains?(e.name, pattern) end)
  end

  def filter_by_name(sessions, %Regex{} = regex) do
    Enum.filter(sessions, fn e -> Regex.match?(regex, e.name) end)
  end

  @doc "Filters session entries by auto_saved flag."
  @spec filter_by_auto_saved([map()], boolean() | nil) :: [map()]
  def filter_by_auto_saved(sessions, nil), do: sessions

  def filter_by_auto_saved(sessions, flag) when is_boolean(flag) do
    Enum.filter(sessions, fn e -> e.auto_saved == flag end)
  end

  @doc "Filters session entries by total_tokens range."
  @spec filter_by_token_range([map()], non_neg_integer() | nil, non_neg_integer() | nil) :: [
          map()
        ]
  def filter_by_token_range(sessions, nil, nil), do: sessions

  def filter_by_token_range(sessions, min, max) do
    Enum.filter(sessions, fn e ->
      tokens = e.total_tokens || 0
      (is_nil(min) or tokens >= min) and (is_nil(max) or tokens <= max)
    end)
  end

  @doc "Filters session entries by timestamp range (ISO8601 strings)."
  @spec filter_by_time_range([map()], String.t() | nil, String.t() | nil) :: [map()]
  def filter_by_time_range(sessions, nil, nil), do: sessions

  def filter_by_time_range(sessions, since, until) do
    Enum.filter(sessions, fn e ->
      ts = e.timestamp || ""
      (is_nil(since) or ts >= since) and (is_nil(until) or ts <= until)
    end)
  end
end
