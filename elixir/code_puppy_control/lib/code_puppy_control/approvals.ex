defmodule CodePuppyControl.Approvals do
  @moduledoc """
  One-shot approval store for file operations that require user confirmation.

  When the `PolicyEngine` returns `%AskUser{}`, the `Tool.Runner` records a
  pending approval request here. Users can then grant one-shot approvals
  through the REPL prompt or the `/approve` slash command.

  ## Safety Properties

  - **One-shot only** — approvals are consumed on first match, never persistent.
  - **Scoped matching** — approvals match on `session_id + operation + normalized_path + tool_name + args_fingerprint`.
  - **Fail-closed** — unmatched or expired requests are never auto-approved.
  - **No global approve-all** — every approval targets a specific request.

  ## Usage

      # Record a pending request (called from Tool.Runner on AskUser)
      :ok = Approvals.record_pending(%Approvals.Request{
        operation: "create",
        file_path: "lib/foo.ex",
        tool_name: "create_file",
        session_id: "sess-1",
        args_fingerprint: Approvals.Request.compute_args_fingerprint(%{"content" => "..."})
      })

      # User approves the most recent request via /approve last
      :ok = Approvals.approve_last("sess-1")

      # Runner checks for a matching approval before failing
      :allowed = Approvals.consume_approval(%Approvals.Request{
        operation: "create",
        file_path: "lib/foo.ex",
        tool_name: "create_file",
        session_id: "sess-1",
        args_fingerprint: Approvals.Request.compute_args_fingerprint(%{"content" => "..."})
      })
  """

  use GenServer

  require Logger

  # ── Request Struct ──────────────────────────────────────────────────────

  defmodule Request do
    @moduledoc """
    A single approval request for a file operation.

    Matching uses exact comparison on `operation`, `tool_name`, and
    `normalized_path` (the result of `Path.expand/1`).
    """

    @type t :: %__MODULE__{
            id: integer(),
            operation: String.t(),
            file_path: String.t(),
            normalized_path: String.t(),
            tool_name: String.t(),
            prompt: String.t() | nil,
            inserted_at: integer(),
            session_id: String.t() | nil,
            run_id: String.t() | nil,
            args_fingerprint: String.t()
          }

    defstruct [
      :id,
      :operation,
      :file_path,
      :normalized_path,
      :tool_name,
      :prompt,
      :inserted_at,
      :session_id,
      :run_id,
      :args_fingerprint
    ]

    @doc """
    Creates a new Request with defaults for computed fields.

    Normalizes the file path via `Path.expand/1` so that relative and
    absolute paths comparing equal on disk also compare equal in the
    approval store.

    When `:args` is provided, a SHA-256 fingerprint of the sorted
    arguments is computed and stored as `args_fingerprint`.  This
    ensures that approvals for the same path but different content
    (e.g. different `old_str`/`new_str` in a `replace_in_file`) are
    distinguished.
    """
    @spec new(keyword()) :: t()
    def new(attrs) when is_list(attrs) do
      file_path = Keyword.get(attrs, :file_path, "")
      normalized = if file_path != "", do: Path.expand(file_path), else: ""
      args = Keyword.get(attrs, :args, %{})

      %__MODULE__{
        id: System.unique_integer([:positive]),
        operation: Keyword.get(attrs, :operation, "access"),
        file_path: file_path,
        normalized_path: normalized,
        tool_name: Keyword.get(attrs, :tool_name, ""),
        prompt: Keyword.get(attrs, :prompt),
        inserted_at: System.system_time(:millisecond),
        session_id: Keyword.get(attrs, :session_id),
        run_id: Keyword.get(attrs, :run_id),
        args_fingerprint: compute_args_fingerprint(args)
      }
    end

    @doc """
    Returns true if two requests match for approval purposes.

    Two requests match when **all** of the following are true:

      - `session_id` is strictly equal when either request carries one
        (two nil session_ids are treated as matching for backward compat)
      - `operation` is equal
      - `normalized_path` is equal
      - `tool_name` is equal
      - `args_fingerprint` is equal (nil and "" are treated as equivalent)
    """
    @spec matches?(t(), t()) :: boolean()
    def matches?(%__MODULE__{} = a, %__MODULE__{} = b) do
      session_match?(a.session_id, b.session_id) and
        a.operation == b.operation and
        a.normalized_path == b.normalized_path and
        a.tool_name == b.tool_name and
        fingerprint_match?(a.args_fingerprint, b.args_fingerprint)
    end

    @doc """
    Computes a deterministic SHA-256 fingerprint of tool arguments.

    The args map is sorted by key and JSON-encoded before hashing so
    that structurally identical maps produce the same fingerprint
    regardless of insertion order.

    Returns a lowercase hex string, or `""` when args is empty or not a map.
    """
    @spec compute_args_fingerprint(map() | term()) :: String.t()
    def compute_args_fingerprint(args) when is_map(args) and map_size(args) > 0 do
      # Convert to a sorted list of [key, value] pairs so Jason can
      # encode it deterministically regardless of map insertion order.
      args
      |> Enum.map(fn {k, v} -> [to_string(k), v] end)
      |> Enum.sort_by(fn [k, _v] -> k end)
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
    end

    def compute_args_fingerprint(_), do: ""

    @doc """
    Returns the first 8 hex characters of the args fingerprint, for
    display in `/approve list` output.
    """
    @spec fingerprint_prefix(t()) :: String.t()
    def fingerprint_prefix(%__MODULE__{args_fingerprint: fp})
        when is_binary(fp) and byte_size(fp) >= 8 do
      String.slice(fp, 0, 8)
    end

    def fingerprint_prefix(_), do: ""

    # ── Private match helpers ────────────────────────────────────────────

    # Session IDs must match exactly when either is present.
    # Two nils match; nil vs non-nil does not.
    defp session_match?(nil, nil), do: true
    defp session_match?(sid, nil) when is_binary(sid) and sid != "", do: false
    defp session_match?(nil, sid) when is_binary(sid) and sid != "", do: false
    defp session_match?(a, b), do: a == b

    # Fingerprints must match when either is non-empty.
    # nil and "" are treated as equivalent (both mean "no fingerprint").
    defp fingerprint_match?(a, b) when a == b, do: true
    defp fingerprint_match?(nil, ""), do: true
    defp fingerprint_match?("", nil), do: true
    defp fingerprint_match?(_, _), do: false
  end

  # ── Client API ────────────────────────────────────────────────────────

  @doc """
  Starts the Approvals GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a pending approval request.

  The request is stored so the user can later approve it via `/approve last`.
  Pending requests are retained until explicitly cleared or consumed.
  """
  @spec record_pending(Request.t()) :: :ok
  def record_pending(%Request{} = req) do
    GenServer.call(__MODULE__, {:record_pending, req})
  end

  @doc """
  Returns all pending (unapproved) requests, ordered oldest-first.

  When `session_id` is provided, only requests belonging to that
  session are returned.  When `nil` (the default), all requests are
  returned regardless of session scope.
  """
  @spec list_pending(String.t() | nil) :: [Request.t()]
  def list_pending(session_id \\ nil) do
    GenServer.call(__MODULE__, {:list_pending, session_id})
  end

  @doc """
  Approves the most recent pending request (one-shot).

  When `session_id` is provided, only pending requests belonging to
  that session are considered.  When `nil`, the most recent request
  across all sessions is approved (backward-compatible default).

  The approval is stored as a one-shot grant that will be consumed by the
  next matching `consume_approval/1` call. Returns `:ok` if a request was
  approved, or `{:error, :none_pending}` if there are no eligible pending
  requests.
  """
  @spec approve_last(String.t() | nil) :: :ok | {:error, :none_pending}
  def approve_last(session_id \\ nil) do
    GenServer.call(__MODULE__, {:approve_last, session_id})
  end

  @doc """
  Removes a pending request by its `id`.

  Used by the interactive approval path to clean up a pending request
  that was approved inline (via the `y/N` prompt), preventing it from
  remaining as a stale pending entry.
  """
  @spec remove_pending(integer()) :: :ok
  def remove_pending(request_id) when is_integer(request_id) do
    GenServer.call(__MODULE__, {:remove_pending, request_id})
  end

  @doc """
  Clears all pending requests and one-shot approvals.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Attempts to consume a one-shot approval matching the given request.

  - Returns `:allowed` if a matching one-shot approval was found and consumed.
  - Returns `:no_match` if no matching approval exists.

  The approval is consumed (removed) on match — one-shot semantics.
  """
  @spec consume_approval(Request.t()) :: :allowed | :no_match
  def consume_approval(%Request{} = req) do
    GenServer.call(__MODULE__, {:consume_approval, req})
  end

  # ── GenServer Callbacks ───────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      pending: [],
      one_shot_approvals: []
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:record_pending, %Request{} = req}, _from, state) do
    # Deduplicate: don't add a duplicate pending request
    already_pending = Enum.any?(state.pending, &Request.matches?(&1, req))

    state =
      if already_pending do
        state
      else
        %{state | pending: state.pending ++ [req]}
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:list_pending, session_id}, _from, state) do
    {:reply, filter_by_session(state.pending, session_id), state}
  end

  @impl true
  def handle_call({:approve_last, session_id}, _from, state) do
    eligible = filter_by_session(state.pending, session_id)

    case List.last(eligible) do
      nil ->
        {:reply, {:error, :none_pending}, state}

      req ->
        # Remove from pending, add to one-shot approvals
        pending = Enum.reject(state.pending, &(&1.id == req.id))
        approvals = [req | state.one_shot_approvals]
        {:reply, :ok, %{state | pending: pending, one_shot_approvals: approvals}}
    end
  end

  @impl true
  def handle_call({:remove_pending, request_id}, _from, state) do
    pending = Enum.reject(state.pending, &(&1.id == request_id))
    {:reply, :ok, %{state | pending: pending}}
  end

  @impl true
  def handle_call({:consume_approval, %Request{} = req}, _from, state) do
    case find_and_remove_matching(state.one_shot_approvals, req) do
      {:found, remaining} ->
        {:reply, :allowed, %{state | one_shot_approvals: remaining}}

      :not_found ->
        {:reply, :no_match, state}
    end
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{pending: [], one_shot_approvals: []}}
  end

  # ── Private ───────────────────────────────────────────────────────────

  # Removes **one** matching approval, preserving any additional matching
  # approvals as separate one-shot grants.
  defp find_and_remove_matching(approvals, req) do
    case Enum.split_with(approvals, &Request.matches?(&1, req)) do
      {[_matched | rest_matched], non_matching} ->
        {:found, rest_matched ++ non_matching}

      {[], _} ->
        :not_found
    end
  end

  # Filters requests by session_id.  When `nil`, returns all requests
  # (backward-compatible behaviour).
  defp filter_by_session(requests, nil), do: requests

  defp filter_by_session(requests, session_id) do
    Enum.filter(requests, &(&1.session_id == session_id))
  end
end
