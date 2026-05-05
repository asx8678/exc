defmodule CodePuppyControl.SessionStorage.Store.Operations do
  @moduledoc """
  Business logic for Store operations, extracted for line-cap compliance.

  All functions in this module are pure side-effectful operations that
  operate on ETS tables and SQLite. They are called exclusively by
  `Store` GenServer callbacks. (code_puppy-ctj.1)
  """

  require Logger

  alias CodePuppyControl.Sessions
  alias CodePuppyControl.SessionStorage.StoreHelpers
  alias CodePuppyControl.SessionStorage.PubSub, as: SSPubSub

  @pubsub CodePuppyControl.PubSub
  @sessions_topic "sessions:events"
  @terminal_topic "terminal:recovery"
  @session_table :session_store_ets
  @terminal_table :session_terminal_ets

  # ---------------------------------------------------------------------------
  # Save
  # ---------------------------------------------------------------------------

  @spec do_save_session(String.t(), [map()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def do_save_session(name, history, opts) do
    compacted_hashes = Keyword.get(opts, :compacted_hashes, [])
    total_tokens = Keyword.get(opts, :total_tokens, 0)
    auto_saved = Keyword.get(opts, :auto_saved, false)
    timestamp = Keyword.get(opts, :timestamp) || StoreHelpers.now_iso()

    {has_terminal, terminal_meta, terminal_explicit?} =
      StoreHelpers.resolve_terminal_fields(name, opts, @session_table)

    case Sessions.save_session(name, history,
           compacted_hashes: compacted_hashes,
           total_tokens: total_tokens,
           auto_saved: auto_saved,
           timestamp: timestamp,
           has_terminal: has_terminal,
           terminal_meta: terminal_meta
         ) do
      {:ok, session} ->
        entry =
          StoreHelpers.build_entry(
            name,
            history,
            compacted_hashes,
            total_tokens,
            auto_saved,
            timestamp,
            has_terminal,
            terminal_meta
          )

        :ets.insert(@session_table, {name, entry})

        Phoenix.PubSub.broadcast(
          @pubsub,
          @sessions_topic,
          {:session_saved, name, Map.drop(entry, [:history])}
        )

        SSPubSub.broadcast_event(name, :saved, Map.drop(entry, [:history]))

        cond do
          has_terminal && terminal_meta -> :ets.insert(@terminal_table, {name, terminal_meta})
          terminal_explicit? && !has_terminal -> :ets.delete(@terminal_table, name)
          true -> :ok
        end

        {:ok, StoreHelpers.session_to_result(session)}

      {:error, reason} ->
        Logger.error("Session save failed for #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  @spec do_delete_session(String.t()) :: :ok
  def do_delete_session(name) do
    # SQLite write is best-effort — ETS cleanup always happens
    try do
      Sessions.delete_session(name)
    rescue
      e ->
        Logger.warning("Store: delete_session SQLite write failed for #{name}: #{inspect(e)}")
    end

    :ets.delete(@session_table, name)
    had_terminal = match?([{^name, _}], :ets.lookup(@terminal_table, name))
    :ets.delete(@terminal_table, name)
    Phoenix.PubSub.broadcast(@pubsub, @sessions_topic, {:session_deleted, name})
    SSPubSub.broadcast_event(name, :deleted, %{})

    if had_terminal do
      Phoenix.PubSub.broadcast(@pubsub, @terminal_topic, {:terminal_unregistered, name})
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Cleanup
  # ---------------------------------------------------------------------------

  @spec do_cleanup_sessions(non_neg_integer()) :: {:ok, [String.t()]}
  def do_cleanup_sessions(max_sessions) do
    all_entries =
      @session_table
      |> :ets.tab2list()
      |> Enum.map(fn {_, e} -> e end)
      |> Enum.sort_by(& &1.timestamp, :asc)

    if length(all_entries) <= max_sessions do
      {:ok, []}
    else
      to_delete_count = length(all_entries) - max_sessions
      to_delete = Enum.take(all_entries, to_delete_count)
      deleted = Enum.map(to_delete, & &1.name)

      # Best-effort SQLite deletes — failures are logged, not propagated
      Enum.each(deleted, fn name ->
        try do
          Sessions.delete_session(name)
        rescue
          e ->
            Logger.warning(
              "Store: cleanup delete_session SQLite write failed for #{name}: #{inspect(e)}"
            )
        end
      end)

      Enum.each(deleted, fn n ->
        :ets.delete(@session_table, n)
        :ets.delete(@terminal_table, n)
      end)

      Phoenix.PubSub.broadcast(@pubsub, @sessions_topic, {:sessions_cleaned, deleted})
      Enum.each(deleted, fn n -> SSPubSub.broadcast_event(n, :deleted, %{}) end)
      {:ok, deleted}
    end
  end

  # ---------------------------------------------------------------------------
  # Register Terminal
  # ---------------------------------------------------------------------------

  @spec do_register_terminal(String.t(), map()) :: :ok | {:error, term()}
  def do_register_terminal(session_name, meta) do
    case :ets.lookup(@session_table, session_name) do
      [{^session_name, entry}] ->
        case Sessions.update_terminal_meta(session_name, true, meta) do
          {:ok, _session} ->
            :ets.insert(@terminal_table, {session_name, meta})
            updated = %{entry | has_terminal: true, terminal_meta: meta}
            :ets.insert(@session_table, {session_name, updated})

            Phoenix.PubSub.broadcast(
              @pubsub,
              @terminal_topic,
              {:terminal_registered, session_name}
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "Store: durable register_terminal failed for #{session_name}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      [] ->
        case Sessions.save_session(session_name, [], has_terminal: true, terminal_meta: meta) do
          {:ok, _session} ->
            entry =
              StoreHelpers.build_entry(
                session_name,
                [],
                [],
                0,
                false,
                StoreHelpers.now_iso(),
                true,
                meta
              )

            :ets.insert(@session_table, {session_name, entry})
            :ets.insert(@terminal_table, {session_name, meta})

            Phoenix.PubSub.broadcast(
              @pubsub,
              @terminal_topic,
              {:terminal_registered, session_name}
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "Store: register_terminal failed to create session for #{session_name}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Unregister Terminal
  # ---------------------------------------------------------------------------

  @spec do_unregister_terminal(String.t()) :: :ok | {:error, term()}
  def do_unregister_terminal(session_name) do
    case :ets.lookup(@session_table, session_name) do
      [{^session_name, entry}] ->
        case Sessions.update_terminal_meta(session_name, false, nil) do
          {:ok, _session} ->
            :ets.delete(@terminal_table, session_name)
            updated = %{entry | has_terminal: false, terminal_meta: nil}
            :ets.insert(@session_table, {session_name, updated})

            Phoenix.PubSub.broadcast(
              @pubsub,
              @terminal_topic,
              {:terminal_unregistered, session_name}
            )

            :ok

          {:error, reason} ->
            Logger.error(
              "Store: durable unregister_terminal failed for #{session_name}: #{inspect(reason)}"
            )

            {:error, reason}
        end

      [] ->
        Logger.warning("Store: unregister_terminal for unknown session #{session_name}")
        {:error, :session_not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Update Session
  # ---------------------------------------------------------------------------

  @spec do_update_session(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def do_update_session(name, opts) do
    case :ets.lookup(@session_table, name) do
      [{^name, entry}] ->
        updated_entry =
          entry
          |> maybe_put_entry(:auto_saved, Keyword.get(opts, :auto_saved))
          |> maybe_put_entry(:total_tokens, Keyword.get(opts, :total_tokens))
          |> maybe_put_entry(:timestamp, Keyword.get(opts, :timestamp))
          |> Map.put(:updated_at, System.monotonic_time(:millisecond))

        case Sessions.save_session(name, updated_entry.history,
               compacted_hashes: updated_entry.compacted_hashes,
               total_tokens: updated_entry.total_tokens,
               auto_saved: updated_entry.auto_saved,
               timestamp: updated_entry.timestamp,
               has_terminal: updated_entry.has_terminal,
               terminal_meta: updated_entry.terminal_meta
             ) do
          {:ok, _session} ->
            :ets.insert(@session_table, {name, updated_entry})

            Phoenix.PubSub.broadcast(
              @pubsub,
              @sessions_topic,
              {:session_saved, name, Map.drop(updated_entry, [:history])}
            )

            SSPubSub.broadcast_event(name, :updated, Map.drop(updated_entry, [:history]))
            {:ok, store_entry_to_metadata(updated_entry)}

          {:error, reason} ->
            Logger.error("Session update failed for #{name}: #{inspect(reason)}")
            {:error, reason}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  @spec do_recover_from_disk() :: non_neg_integer()
  def do_recover_from_disk do
    case safe_list_sessions_with_metadata() do
      {:ok, sessions} ->
        count =
          Enum.reduce(sessions, 0, fn session, acc ->
            entry = StoreHelpers.chat_session_to_entry(session)
            :ets.insert(@session_table, {session.name, entry})
            acc + 1
          end)

        Logger.info("SessionStorage.Store: recovered #{count} sessions from SQLite")
        count

      {:error, reason} ->
        # (code-puppy-be7) Repo-unavailable in escript mode is expected;
        # downgrade to warning so it doesn't pollute startup logs.
        log_level =
          case reason do
            %RuntimeError{message: msg} when is_binary(msg) ->
              if String.contains?(msg, "could not lookup Ecto repo"), do: :warning, else: :error

            _ ->
              :error
          end

        Logger.log(log_level, "SessionStorage.Store: disk recovery failed: #{inspect(reason)}")
        0
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp store_entry_to_metadata(entry) do
    %{
      session_name: entry.name,
      timestamp: entry.timestamp,
      message_count: entry.message_count,
      total_tokens: entry.total_tokens,
      auto_saved: entry.auto_saved
    }
  end

  defp maybe_put_entry(entry, _key, nil), do: entry
  defp maybe_put_entry(entry, key, value), do: Map.put(entry, key, value)

  # Wraps Sessions.list_sessions_with_metadata/0 so Repo errors
  # return {:error, reason} instead of crashing the GenServer.
  # TODO(code_puppy-3m9.4): Remove if Sessions ever returns {:error,_} natively.
  defp safe_list_sessions_with_metadata do
    try do
      {:ok, sessions} = Sessions.list_sessions_with_metadata()
      {:ok, sessions}
    rescue
      e -> {:error, e}
    end
  end
end
