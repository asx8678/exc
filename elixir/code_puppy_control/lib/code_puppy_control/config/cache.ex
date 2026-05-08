defmodule CodePuppyControl.Config.Cache do
  @moduledoc """
  Cache and session persistence settings.

  Manages auto-save behavior, WebSocket history replay, and session
  storage configuration.

  ## Config keys in `puppy.cfg`

  - `auto_save_session` — enable/disable auto-save (default `true`)
  - `max_saved_sessions` — max sessions to keep (default `20`)
  - `ws_history_maxlen` — events to buffer per WS session for replay (default `200`)
  - `ws_history_ttl_seconds` — TTL for abandoned WS sessions (default `3600`)
  - `frontend_emitter_enabled` — enable frontend event emitter (default `true`)
  - `frontend_emitter_max_recent_events` — buffer size (default `100`)
  - `frontend_emitter_queue_size` — subscriber queue size (default `100`)
  """

  alias CodePuppyControl.Config.Loader

  @doc "Return `true` if the frontend emitter is enabled (default `true`)."
  @spec frontend_emitter_enabled?() :: boolean()
  def frontend_emitter_enabled?, do: truthy?("frontend_emitter_enabled", true)

  @doc "Return max recent events to buffer (default `100`)."
  @spec frontend_emitter_max_recent_events() :: pos_integer()
  def frontend_emitter_max_recent_events do
    parse_int("frontend_emitter_max_recent_events", 100, 1)
  end

  @doc "Return max subscriber queue size (default `100`)."
  @spec frontend_emitter_queue_size() :: pos_integer()
  def frontend_emitter_queue_size do
    parse_int("frontend_emitter_queue_size", 100, 1)
  end

  @doc """
  Return max events to buffer per WebSocket session for replay (default `200`).
  """
  @spec ws_history_maxlen() :: pos_integer()
  def ws_history_maxlen do
    parse_int("ws_history_maxlen", 200, 1)
  end

  @doc """
  Return TTL in seconds for abandoned WebSocket session history (default `3600`).
  Set to `0` to disable cleanup.
  """
  @spec ws_history_ttl_seconds() :: non_neg_integer()
  def ws_history_ttl_seconds do
    case Loader.get_value("ws_history_ttl_seconds") do
      nil ->
        3600

      val ->
        case Integer.parse(val) do
          {n, _} when n >= 0 -> n
          _ -> 3600
        end
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────

  @truthy_values MapSet.new(["1", "true", "yes", "on"])

  defp truthy?(key, default) do
    case Loader.get_value(key) do
      nil -> default
      val -> String.downcase(String.trim(val)) in @truthy_values
    end
  end

  defp parse_int(key, default, min_val) do
    case Loader.get_value(key) do
      nil ->
        default

      val ->
        case Integer.parse(val) do
          {n, _} when n >= min_val -> n
          _ -> default
        end
    end
  end
end
