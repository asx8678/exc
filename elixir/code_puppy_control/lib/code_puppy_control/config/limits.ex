defmodule CodePuppyControl.Config.Limits do
  @moduledoc """
  Resource limits and compaction configuration.

  Manages token budgets, compaction thresholds, message limits, and
  timeout values from `puppy.cfg`.

  ## Config keys in `puppy.cfg`

  - `protected_token_count` — tokens in recent messages exempt from compaction (default `50000`)
  - `compaction_threshold` — context fraction that triggers compaction (default `0.85`)
  - `compaction_strategy` — `"summarization"` or `"truncation"` (default `"summarization"`)
  - `resume_message_count` — messages to show on resume (default `50`)
  - `message_limit` — max agent steps (default `100`)
  - `max_session_tokens` — hard token budget per session (default `0` = disabled)
  - `max_run_tokens` — hard token budget per run (default `0` = disabled)
  - `bus_request_timeout_seconds` — timeout for user input requests (default `300.0`)
  - `max_turns` — max agent turns (if set)
  """

  alias CodePuppyControl.Config.Loader

  @default_context_length 128_000

  # ── Protected tokens ────────────────────────────────────────────────────

  @doc """
  Return the protected token count — tokens in recent messages exempt
  from summarization. Default `50000`, clamped to 75% of model context.
  """
  @spec protected_token_count() :: pos_integer()
  def protected_token_count do
    configured =
      case Loader.get_value("protected_token_count") do
        nil ->
          50_000

        val ->
          case Integer.parse(val) do
            {n, _} -> n
            :error -> 50_000
          end
      end

    max_protected = div(context_length() * 75, 100)
    configured |> max(1000) |> min(max_protected)
  end

  # ── Compaction ──────────────────────────────────────────────────────────

  @doc """
  Return the compaction threshold (0.5–0.95). Default `0.85`.
  """
  @spec compaction_threshold() :: float()
  def compaction_threshold do
    case Loader.get_value("compaction_threshold") do
      nil ->
        0.85

      val ->
        case Float.parse(val) do
          {f, _} -> f |> max(0.5) |> min(0.95)
          :error -> 0.85
        end
    end
  end

  @doc """
  Return the compaction strategy: `"summarization"` or `"truncation"`.
  Default `"summarization"`.
  """
  @spec compaction_strategy() :: String.t()
  def compaction_strategy do
    case Loader.get_value("compaction_strategy") do
      nil -> "summarization"
      "truncation" -> "truncation"
      _ -> "summarization"
    end
  end

  # ── Message limits ──────────────────────────────────────────────────────

  @doc "Return the max agent message/steps limit (default `100`)."
  @spec message_limit() :: pos_integer()
  def message_limit do
    parse_int("message_limit", 100, 1)
  end

  @doc "Return the number of messages to show on resume (default `50`, range `1–100`)."
  @spec resume_message_count() :: pos_integer()
  def resume_message_count do
    case Loader.get_value("resume_message_count") do
      nil ->
        50

      val ->
        case Integer.parse(val) do
          {n, _} -> n |> max(1) |> min(100)
          :error -> 50
        end
    end
  end

  # ── Token budgets ───────────────────────────────────────────────────────

  @doc """
  Hard token budget per session (`0` = disabled).
  """
  @spec max_session_tokens() :: non_neg_integer()
  def max_session_tokens do
    parse_int("max_session_tokens", 0, 0)
  end

  @doc """
  Hard token budget per run (`0` = disabled).
  """
  @spec max_run_tokens() :: non_neg_integer()
  def max_run_tokens do
    parse_int("max_run_tokens", 0, 0)
  end

  # ── Timeouts ────────────────────────────────────────────────────────────

  @doc """
  Return the timeout in seconds for bus request/response operations.
  Default `300.0` (5 minutes), range `10.0–3600.0`.
  """
  @spec bus_request_timeout_seconds() :: float()
  def bus_request_timeout_seconds do
    case Loader.get_value("bus_request_timeout_seconds") do
      nil ->
        300.0

      val ->
        case Float.parse(val) do
          {f, _} -> f |> max(10.0) |> min(3600.0)
          :error -> 300.0
        end
    end
  end

  # ── WebSocket & Memory ──────────────────────────────────────────────

  @doc """
  WebSocket history TTL in seconds.
  Env override: PUPPY_WS_HISTORY_TTL_SECONDS
  Default: 3600 (1 hour)
  """
  def ws_history_ttl_seconds do
    case System.get_env("PUPPY_WS_HISTORY_TTL_SECONDS") do
      nil -> parse_int("ws_history_ttl_seconds", 3600, 60)
      val -> max(60, String.to_integer(val))
    end
  end

  @doc "Memory extraction model override. Returns nil if not set."
  def memory_extraction_model do
    case Loader.get_value("memory_extraction_model") do
      nil -> nil
      "" -> nil
      val -> val
    end
  end

  # ── Summarization settings ──────────────────────────────────────────────

  @doc "Return summarization trigger fraction (default `0.85`, range `0.5–0.95`)."
  @spec summarization_trigger_fraction() :: float()
  def summarization_trigger_fraction do
    parse_float("summarization_trigger_fraction", 0.85, 0.5, 0.95)
  end

  @doc "Return summarization keep fraction (default `0.10`, range `0.05–0.50`)."
  @spec summarization_keep_fraction() :: float()
  def summarization_keep_fraction do
    case Loader.get_value("summarization_keep_fraction") do
      nil ->
        0.10

      val ->
        case Float.parse(val) do
          {f, _} -> f |> max(0.05) |> min(0.50)
          :error -> 0.10
        end
    end
  end

  @doc "Return `true` if pre-truncation of tool args is enabled (default `true`)."
  @spec summarization_pretruncate_enabled?() :: boolean()
  def summarization_pretruncate_enabled?, do: truthy?("summarization_pretruncate_enabled", true)

  @doc "Return max characters for tool call args before truncation (default `500`)."
  @spec summarization_arg_max_length() :: pos_integer()
  def summarization_arg_max_length do
    case Loader.get_value("summarization_arg_max_length") do
      nil ->
        500

      val ->
        case Integer.parse(val) do
          {n, _} -> n |> max(100) |> min(10_000)
          :error -> 500
        end
    end
  end

  @doc "Return max characters for tool return content before truncation (default `5000`)."
  @spec summarization_return_max_length() :: pos_integer()
  def summarization_return_max_length do
    case Loader.get_value("summarization_return_max_length") do
      nil ->
        5000

      val ->
        case Integer.parse(val) do
          {n, _} -> n |> max(500) |> min(100_000)
          :error -> 5000
        end
    end
  end

  @doc """
  Return characters to preserve from start of truncated return (default `500`).
  Clamped to range `100–5000`.
  """
  @spec summarization_return_head_chars() :: pos_integer()
  def summarization_return_head_chars do
    case Loader.get_value("summarization_return_head_chars") do
      nil ->
        500

      val ->
        case Integer.parse(val) do
          {n, _} -> n |> max(100) |> min(5_000)
          :error -> 500
        end
    end
  end

  @doc """
  Return characters to preserve from end of truncated return (default `200`).
  Clamped to range `50–2000`.
  """
  @spec summarization_return_tail_chars() :: pos_integer()
  def summarization_return_tail_chars do
    case Loader.get_value("summarization_return_tail_chars") do
      nil ->
        200

      val ->
        case Integer.parse(val) do
          {n, _} -> n |> max(50) |> min(2_000)
          :error -> 200
        end
    end
  end

  @doc "Model to use for summarization. Default: claude-3-haiku"
  def summarization_model do
    case Loader.get_value("summarization_model") do
      nil -> "claude-3-haiku"
      "" -> "claude-3-haiku"
      val -> val
    end
  end

  @doc "Maximum input tokens for summarization. Default: 100_000"
  def summarization_max_input_tokens,
    do: parse_int("summarization_max_input_tokens", 100_000, 1000)

  @doc "Enable automatic summarization. Default: true"
  def auto_summarize_enabled?, do: truthy?("auto_summarize", true)

  @doc "Minimum messages before summarization. Default: 10"
  def summarization_min_messages, do: parse_int("summarization_min_messages", 10, 1)

  # ── Context length (helper) ─────────────────────────────────────────────

  @doc """
  Return the model context length. In the Elixir port this delegates to
  the model registry; for now returns a sensible default.
  """
  @spec context_length() :: pos_integer()
  def context_length, do: @default_context_length

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

  defp parse_float(key, default, min_val, max_val) do
    case Loader.get_value(key) do
      nil ->
        default

      val ->
        case Float.parse(val) do
          {f, _} -> f |> max(min_val) |> min(max_val)
          :error -> default
        end
    end
  end
end
