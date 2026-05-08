defmodule CodePuppyControl.CLI.SessionResume do
  @moduledoc """
  Restores the most recent persisted session for `pup --continue`.

  # DECISION(code_puppy-djs.5): `--continue` restores the newest available
  # session non-interactively. A multi-session picker belongs in `/sessions` or
  # a later CLI flag; making `-c` stop for a prompt would be rude CLI behavior.

  # DECISION(code_puppy-djs.5): restored messages are loaded into
  # `CodePuppyControl.Agent.State`, then the normal REPL loop is started with
  # the restored `:session_id`. Process state remains a cache; persisted
  # `SessionStorage` is still the source of truth. Tiny but important detail,
  # because GenServers are not databases, despite what some folks keep trying.
  """

  require Logger

  alias CodePuppyControl.Agent.State, as: AgentState
  alias CodePuppyControl.REPL.Loop
  alias CodePuppyControl.SessionStorage
  alias CodePuppyControl.Telemetry

  @default_agent "code-puppy"
  @internal_opt_keys [:session_storage_opts]

  @type resume_reason ::
          :latest | :no_sessions | :list_failed | :load_failed | :agent_state_failed
  @type resume_result :: {:ok, map()} | {:fresh, map(), resume_reason()}

  @doc """
  Loads the newest persisted session into `Agent.State` and returns REPL opts.

  Test-only callers may pass `:session_storage_opts` in `opts`; those options
  are used for `SessionStorage` calls and stripped before returning REPL opts.
  Production CLI invocations do not set this key.
  """
  @spec restore_latest(map()) :: resume_result()
  def restore_latest(opts) when is_map(opts) do
    loop_opts = loop_opts(opts)
    storage_opts = storage_opts(opts)

    case SessionStorage.list_sessions_with_metadata(storage_opts) do
      {:ok, []} ->
        Telemetry.session_resume(nil, false, :no_sessions)
        {:fresh, loop_opts, :no_sessions}

      {:ok, sessions} ->
        sessions
        |> latest_session()
        |> restore_session(loop_opts, storage_opts)

      {:error, reason} ->
        Logger.warning("Session resume listing failed; starting fresh: #{inspect(reason)}")
        Telemetry.session_resume(nil, false, :list_failed)
        {:fresh, loop_opts, :list_failed}
    end
  end

  defp latest_session(sessions) do
    Enum.max_by(sessions, &session_sort_value/1, fn -> nil end)
  end

  defp restore_session(nil, loop_opts, _storage_opts) do
    Telemetry.session_resume(nil, false, :no_sessions)
    {:fresh, loop_opts, :no_sessions}
  end

  defp restore_session(session_meta, loop_opts, storage_opts) do
    with {:ok, session_id} <- session_name(session_meta),
         {:ok, session_data} <- SessionStorage.load_session(session_id, storage_opts),
         {:ok, messages} <- session_messages(session_data),
         {:ok, agent_key} <- resolve_agent_key(loop_opts),
         :ok <- put_agent_state(session_id, agent_key, messages) do
      Telemetry.session_resume(session_id, true, :latest)
      {:ok, Map.put(loop_opts, :session_id, session_id)}
    else
      {:error, {:agent_state_failed, reason}} ->
        Logger.warning("Session resume state restore failed; starting fresh: #{inspect(reason)}")
        Telemetry.session_resume(session_id_or_nil(session_meta), false, :agent_state_failed)
        {:fresh, loop_opts, :agent_state_failed}

      {:error, reason} ->
        Logger.warning("Session resume load failed; starting fresh: #{inspect(reason)}")
        Telemetry.session_resume(session_id_or_nil(session_meta), false, :load_failed)
        {:fresh, loop_opts, :load_failed}
    end
  end

  defp loop_opts(opts), do: Map.drop(opts, @internal_opt_keys)

  defp storage_opts(opts) do
    case Map.get(opts, :session_storage_opts, []) do
      storage_opts when is_list(storage_opts) -> storage_opts
      _other -> []
    end
  end

  defp session_name(session_meta) when is_map(session_meta) do
    case metadata_value(session_meta, :session_name) || metadata_value(session_meta, :name) do
      name when is_binary(name) and name != "" -> {:ok, name}
      _other -> {:error, :missing_session_name}
    end
  end

  defp session_name(_session_meta), do: {:error, :invalid_session_metadata}

  defp session_id_or_nil(session_meta) do
    case session_name(session_meta) do
      {:ok, session_id} -> session_id
      {:error, _reason} -> nil
    end
  end

  defp session_messages(%{} = session_data) do
    case Map.get(session_data, :messages, Map.get(session_data, "messages", [])) do
      messages when is_list(messages) -> {:ok, messages}
      _other -> {:error, :invalid_session_messages}
    end
  end

  defp session_messages(_session_data), do: {:error, :invalid_session_data}

  defp resolve_agent_key(loop_opts) do
    display_name = agent_display_name(loop_opts)

    case Loop.resolve_agent_key(display_name) do
      {:ok, agent_key} -> {:ok, agent_key}
      {:error, _reason} -> {:ok, fallback_agent_key(display_name)}
    end
  end

  defp agent_display_name(%{agent: agent}) when is_binary(agent) and agent != "", do: agent
  defp agent_display_name(_loop_opts), do: @default_agent

  defp fallback_agent_key(display_name) do
    String.replace(display_name, "-", "_")
  end

  defp put_agent_state(session_id, agent_key, messages) do
    try do
      AgentState.set_messages(session_id, agent_key, messages)
    catch
      :exit, reason -> {:error, {:agent_state_failed, reason}}
    end
  end

  defp session_sort_value(session_meta) when is_map(session_meta) do
    updated_at_value =
      session_meta
      |> metadata_value(:updated_at)
      |> sort_value_from_metadata()

    timestamp_value =
      session_meta
      |> metadata_value(:timestamp)
      |> sort_value_from_metadata()

    updated_at_value || timestamp_value || 0
  end

  defp session_sort_value(_session_meta), do: 0

  defp metadata_value(map, key) when is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp sort_value_from_metadata(nil), do: nil
  defp sort_value_from_metadata(value) when is_integer(value), do: value

  defp sort_value_from_metadata(%DateTime{} = value) do
    DateTime.to_unix(value, :microsecond)
  end

  defp sort_value_from_metadata(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp sort_value_from_metadata(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> nil
    end
  end

  defp sort_value_from_metadata(_value), do: nil
end
