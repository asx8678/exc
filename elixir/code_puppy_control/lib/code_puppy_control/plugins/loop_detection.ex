defmodule CodePuppyControl.Plugins.LoopDetection do
  @moduledoc """
  Detects and prevents agents from getting stuck in infinite loops.

  Tracks tool call patterns per session and intervenes when repetition
  is detected:
  - **Warn threshold** (default: 3): injects a system-level warning
  - **Hard threshold** (default: 5): blocks the tool call (fail-closed)

  Configuration (puppy.cfg):
    loop_detection_warn = 3       # Threshold to inject warning
    loop_detection_stop = 5       # Threshold to block tool calls
    loop_detection_exempt_tools = wait,sleep  # Tools that can repeat safely

  Ported from `code_puppy/plugins/loop_detection/`.
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Plugins.LoopDetection.{State, Hasher}

  require Logger

  @default_exempt_tools ~w(wait sleep)

  @impl true
  def name, do: "loop_detection"

  @impl true
  def description, do: "Detects and blocks infinite tool-call loops per session"

  @impl true
  def register do
    Callbacks.register(:pre_tool_call, &__MODULE__.on_pre_tool_call/3)
    Callbacks.register(:post_tool_call, &__MODULE__.on_post_tool_call/5)
    Callbacks.register(:agent_run_end, &__MODULE__.on_agent_run_end/7)
    Callbacks.register(:shutdown, &__MODULE__.on_shutdown/0)
    :ok
  end

  @impl true
  def startup do
    State.init()
    :ok
  end

  @impl true
  def shutdown do
    reset()
    :ok
  end

  # ── Public API ──────────────────────────────────────────────────

  @doc "Reset loop detection state for a session or all sessions."
  @spec reset(String.t() | nil) :: :ok
  def reset(session_id \\ nil), do: State.reset(session_id)

  @doc "Get loop detection statistics."
  @spec get_stats(String.t() | nil) :: map()
  def get_stats(session_id \\ nil), do: State.get_stats(session_id)

  # ── Callback Implementations ────────────────────────────────────

  @doc false
  @spec on_pre_tool_call(String.t(), map(), term()) :: map() | nil
  def on_pre_tool_call(tool_name, tool_args, context) do
    if exempt?(tool_name) or empty_args?(tool_args) do
      nil
    else
      session_id = extract_session_id(context)
      call_hash = Hasher.hash_tool_call(tool_name, tool_args)

      case State.check_and_record(session_id, call_hash) do
        {:block, count} ->
          Logger.error("Loop hard limit reached — blocking tool call",
            session_id: session_id,
            call_hash: call_hash,
            count: count,
            tool: tool_name
          )

          hard = hard_threshold()

          %{
            "blocked" => true,
            "reason" =>
              "Loop detected: repeated #{tool_name} calls exceeded safety limit (#{hard})",
            "user_feedback" => block_user_feedback(tool_name, count, hard)
          }

        {:ok, _count} ->
          nil
      end
    end
  end

  @doc false
  @spec on_post_tool_call(String.t(), map(), term(), term(), number()) :: nil
  def on_post_tool_call(tool_name, tool_args, _result, _duration_ms, context) do
    if exempt?(tool_name) or empty_args?(tool_args) do
      nil
    else
      session_id = extract_session_id(context)
      call_hash = Hasher.hash_tool_call(tool_name, tool_args)

      case State.check_warn(session_id, call_hash) do
        {:warn, count} ->
          hard = hard_threshold()
          calls_until_block = max(0, hard - count)

          Logger.warning("Repetitive tool calls detected",
            session_id: session_id,
            count: count,
            tool: tool_name
          )

          warning_text =
            "⚠️ LOOP WARNING: Tool '#{tool_name}' called #{count} times " <>
              "with similar arguments. You may be stuck in a loop.\n\n" <>
              "Please consider:\n" <>
              "  1. Check if you're making progress\n" <>
              "  2. Stop calling tools and summarize findings\n" <>
              "  3. Ask the user for guidance if blocked\n\n" <>
              "After #{calls_until_block} more identical call(s), tools will be blocked."

          Callbacks.trigger(:stream_event, ["warning", warning_text, session_id])

        :ok ->
          nil
      end
    end

    nil
  end

  @doc false
  @spec on_agent_run_end(
          String.t(),
          String.t(),
          String.t() | nil,
          boolean(),
          term(),
          term(),
          term()
        ) ::
          :ok
  def on_agent_run_end(_agent, _model, session_id, _success, _error, _response_text, _metadata) do
    if session_id, do: reset(to_string(session_id))
    :ok
  end

  @doc false
  @spec on_shutdown() :: :ok
  def on_shutdown, do: reset()

  # ── Private ─────────────────────────────────────────────────────

  defp block_user_feedback(tool_name, count, hard) do
    remaining = hard - count

    block_msg =
      if remaining > 0,
        do: "After #{remaining} more call(s), tools will be blocked.",
        else: "Tools will be blocked after this call."

    "🛑 LOOP DETECTED: Tool '#{tool_name}' called #{count} times " <>
      "with identical arguments. This looks like an infinite loop.\n\n" <>
      "Please stop calling tools and produce your final answer now. " <>
      "If you cannot complete the task, summarize what you accomplished so far.\n\n" <>
      "To override: add '#{tool_name}' to loop_detection_exempt_tools " <>
      "or increase loop_detection_stop threshold.\n\n" <> block_msg
  end

  defp extract_session_id(context) when is_map(context) do
    case Map.get(context, "agent_session_id") || Map.get(context, :agent_session_id) do
      nil -> "default"
      id -> to_string(id)
    end
  end

  defp extract_session_id(_), do: "default"

  defp exempt?(tool_name), do: tool_name in get_exempt_tools()

  defp empty_args?(nil), do: true
  defp empty_args?(args) when is_map(args), do: map_size(args) == 0
  defp empty_args?(_), do: false

  defp hard_threshold do
    Application.get_env(:code_puppy_control, :loop_detection_stop, 5)
  end

  defp get_exempt_tools do
    case Application.get_env(:code_puppy_control, :loop_detection_exempt_tools) do
      nil ->
        @default_exempt_tools

      tools when is_list(tools) ->
        tools

      tools when is_binary(tools) ->
        tools |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

      _ ->
        @default_exempt_tools
    end
  end
end
