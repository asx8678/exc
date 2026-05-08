defmodule CodePuppyControlWeb.SessionsController do
  @moduledoc """
  REST API controller for session management.

  Replaces `code_puppy/api/routers/sessions.py` from the Python FastAPI server.

  ## Endpoints

  - `GET /api/sessions` — List sessions with pagination
  - `GET /api/sessions/:id` — Get session metadata
  - `GET /api/sessions/:id/messages` — Get session messages with pagination
  - `DELETE /api/sessions/:id` — Delete a session
  """

  use CodePuppyControlWeb, :controller

  require Logger

  alias CodePuppyControl.Sessions
  alias CodePuppyControl.Sessions.ChatSession

  @session_id_regex ~r/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/

  @doc """
  GET /api/sessions

  Lists sessions with pagination support.

  Query params:
  - `offset` — number of sessions to skip (default 0)
  - `limit` — max sessions to return (1–200, default 50)
  - `sort_by` — field to sort by: `last_updated` (default), `created_at`, `session_id`
  - `order` — sort direction: `desc` (default) or `asc`
  """
  def index(conn, params) do
    with {:ok, offset, limit} <- validate_pagination(params, max_limit: 200, default_limit: 50),
         sort_by = Map.get(params, "sort_by", "last_updated"),
         order = Map.get(params, "order", "desc"),
         :ok <- validate_sort_by(sort_by),
         :ok <- validate_order(order) do
      {:ok, sessions} = Sessions.list_sessions_with_metadata()

      sorted = sort_sessions(sessions, sort_by, order)
      total = length(sorted)
      paginated = Enum.slice(sorted, offset, limit)

      json(conn, %{
        items: Enum.map(paginated, &session_to_json/1),
        total: total,
        offset: offset,
        limit: limit,
        has_more: offset + length(paginated) < total
      })
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(changeset_errors(changeset))

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  @doc """
  GET /api/sessions/:id

  Gets metadata for a specific session.
  """
  def show(conn, %{"id" => session_id}) do
    with :ok <- validate_session_id(session_id),
         {:ok, session} <- Sessions.load_session_full(session_id) do
      json(conn, session_to_json(session))
    else
      {:error, :invalid_session_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid session_id: must match ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session '#{session_id}' not found"})
    end
  end

  @doc """
  GET /api/sessions/:id/messages

  Gets messages for a session with pagination.

  Query params:
  - `offset` — number of messages to skip (default 0)
  - `limit` — max messages to return (1–500, default 100)
  """
  def messages(conn, %{"id" => session_id} = params) do
    with {:ok, offset, limit} <- validate_pagination(params, max_limit: 500, default_limit: 100),
         :ok <- validate_session_id(session_id),
         {:ok, %{history: history}} <- Sessions.load_session(session_id) do
      total = length(history)
      paginated = Enum.slice(history, offset, limit)

      json(conn, %{
        items: Enum.map(paginated, &serialize_message/1),
        total: total,
        offset: offset,
        limit: limit,
        has_more: offset + length(paginated) < total
      })
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(changeset_errors(changeset))

      {:error, :invalid_session_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid session ID format"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session '#{session_id}' messages not found"})
    end
  end

  @doc """
  DELETE /api/sessions/:id

  Deletes a session and its data.

  Auth: Protected (Wave 5 will add auth plug; currently open for loopback-only deployment).
  """
  def delete(conn, %{"id" => session_id}) do
    with :ok <- validate_session_id(session_id) do
      case Sessions.session_exists?(session_id) do
        true ->
          :ok = Sessions.delete_session(session_id)
          json(conn, %{message: "Session '#{session_id}' deleted"})

        false ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Session '#{session_id}' not found"})
      end
    else
      {:error, :invalid_session_id} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid session_id: must match ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$"})
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  defp validate_session_id(session_id) when is_binary(session_id) do
    if Regex.match?(@session_id_regex, session_id) do
      :ok
    else
      {:error, :invalid_session_id}
    end
  end

  defp validate_session_id(_), do: {:error, :invalid_session_id}

  defp validate_sort_by(sort_by) when sort_by in ~w(last_updated created_at session_id), do: :ok

  defp validate_sort_by(_),
    do: {:error, "sort_by must be one of: last_updated, created_at, session_id"}

  defp validate_order(order) when order in ~w(asc desc), do: :ok
  defp validate_order(_), do: {:error, "order must be 'asc' or 'desc'"}

  @doc false
  # Validates pagination query params using a schemaless Ecto changeset.
  # Returns {:ok, offset, limit} on success, or {:error, changeset} on failure.
  defp validate_pagination(params, opts) do
    max_limit = Keyword.get(opts, :max_limit, 200)
    default_limit = Keyword.get(opts, :default_limit, 50)

    types = %{offset: :integer, limit: :integer}

    attrs = %{
      offset: Map.get(params, "offset"),
      limit: Map.get(params, "limit")
    }

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(attrs, Map.keys(types))
      |> Ecto.Changeset.validate_number(:offset,
        greater_than_or_equal_to: 0,
        message: "must be >= 0"
      )
      |> Ecto.Changeset.validate_number(:limit,
        greater_than: 0,
        less_than_or_equal_to: max_limit,
        message: "must be between 1 and #{max_limit}"
      )

    if changeset.valid? do
      offset = Ecto.Changeset.get_change(changeset, :offset, 0)
      limit = Ecto.Changeset.get_change(changeset, :limit, default_limit)
      {:ok, offset, limit}
    else
      {:error, changeset}
    end
  end

  # Translates changeset validation errors into a JSON-friendly error map.
  defp changeset_errors(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%\{(.+?)\}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    %{errors: errors}
  end

  defp sort_sessions(sessions, "session_id", "asc"),
    do: Enum.sort_by(sessions, & &1.name)

  defp sort_sessions(sessions, "session_id", "desc"),
    do: Enum.sort_by(sessions, & &1.name, :desc)

  defp sort_sessions(sessions, "created_at", "asc"),
    do: Enum.sort_by(sessions, &(&1.inserted_at || ~N[1970-01-01 00:00:00]))

  defp sort_sessions(sessions, "created_at", "desc"),
    do: Enum.sort_by(sessions, &(&1.inserted_at || ~N[1970-01-01 00:00:00]), :desc)

  defp sort_sessions(sessions, _sort_by, "asc"),
    do: Enum.sort_by(sessions, &(&1.timestamp || ""))

  defp sort_sessions(sessions, _sort_by, "desc"),
    do: Enum.sort_by(sessions, &(&1.timestamp || ""), :desc)

  defp session_to_json(%ChatSession{} = session) do
    %{
      session_id: session.name,
      agent_name: nil,
      initial_prompt: nil,
      created_at: format_datetime(session.inserted_at),
      last_updated: session.timestamp,
      message_count: session.message_count
    }
  end

  defp session_to_json(session) when is_map(session) do
    # Handles the map format from ChatSession.to_map/1
    %{
      session_id: session[:name] || session["name"],
      agent_name: nil,
      initial_prompt: nil,
      created_at: format_datetime(session[:inserted_at]),
      last_updated: session[:timestamp] || session["timestamp"],
      message_count: session[:message_count] || session["message_count"] || 0
    }
  end

  defp serialize_message(msg) when is_map(msg) do
    # Messages stored in history are already maps; return as-is
    # for JSON serialization. Complex objects would need special handling.
    msg
  end

  defp serialize_message(msg) when is_list(msg) do
    # Some messages may be stored as keyword lists
    Map.new(msg)
  end

  defp serialize_message(msg) do
    %{"content" => to_string(msg)}
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp format_datetime(dt) when is_binary(dt), do: dt
end
