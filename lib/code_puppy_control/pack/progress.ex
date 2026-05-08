defmodule CodePuppyControl.Pack.Progress do
  @moduledoc """
  Sub-agent result streaming — progress updates from workers to the leader.

  Workers send incremental status updates during sub-agent execution,
  so the leader receives progress information, not just final results.

  ## Architecture

  1. Worker calls `progress/4` at key execution milestones
  2. Progress messages are sent via `GenServer.cast` to the leader
  3. Leader handles `{:progress, run_id, payload}` messages
  4. Telemetry events are emitted for observability

  ## Progress Payloads

  Each progress message includes:

    * `:phase` — current execution phase (`:initializing`, `:executing`,
      `:finalizing`, `:streaming_output`)
    * `:progress` — 0.0–1.0 estimated completion
    * `:message` — human-readable status
    * `:data` — optional structured payload (tool results, token counts, etc.)

  ## Usage (Worker side)

      # During sub-agent execution:
      Progress.send_progress(leader_pid, run_id, :executing, 0.5,
        message: "Running grep across codebase",
        data: %{files_scanned: 42})

  ## Usage (Leader side)

      # In handle_info:
      def handle_info({:progress, run_id, payload}, state) do
        pct = trunc(payload.progress * 100)
        Logger.info("Run \#{run_id}: \#{payload.message} (\#{pct} pct)")
        {:noreply, state}
      end

  (code_puppy-jqr.3)
  """

  require Logger

  @type phase :: :initializing | :executing | :finalizing | :streaming_output

  @type payload :: %{
          phase: phase(),
          progress: float(),
          message: String.t(),
          data: map() | nil,
          timestamp: integer()
        }

  @progress_event [:code_puppy, :distributed_pack, :progress]

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Send a progress update from a worker to the leader.

  Returns `:ok` even if the leader is unreachable (fire-and-forget).
  Emits a telemetry event for observability.

  ## Options

    * `:message` — human-readable status (default: phase name)
    * `:data` — optional structured payload (default: `%{}`)
  """
  @spec send_progress(pid(), String.t(), phase(), float(), keyword()) :: :ok
  def send_progress(leader_pid, run_id, phase, progress, opts \\ []) do
    message = Keyword.get(opts, :message, default_message(phase))
    data = Keyword.get(opts, :data, %{})
    progress = clamp_progress(progress)

    payload = %{
      phase: phase,
      progress: progress,
      message: message,
      data: data,
      timestamp: System.monotonic_time(:millisecond)
    }

    # Fire-and-forget cast to leader
    if leader_pid && Process.alive?(leader_pid) do
      GenServer.cast(leader_pid, {:progress, run_id, payload})
    end

    # Emit telemetry for observability
    :telemetry.execute(
      @progress_event,
      %{progress: progress, system_time: System.system_time(:millisecond)},
      %{run_id: run_id, phase: phase}
    )

    :ok
  end

  @doc """
  Build a progress payload without sending it.

  Useful for testing or for building batch progress reports.
  """
  @spec build_payload(phase(), float(), keyword()) :: payload()
  def build_payload(phase, progress, opts \\ []) do
    message = Keyword.get(opts, :message, default_message(phase))
    data = Keyword.get(opts, :data, %{})

    %{
      phase: phase,
      progress: clamp_progress(progress),
      message: message,
      data: data,
      timestamp: System.monotonic_time(:millisecond)
    }
  end

  @doc """
  Format a progress payload as a human-readable string.

  Useful for logging or TUI display.
  """
  @spec format_payload(payload()) :: String.t()
  def format_payload(payload) do
    pct = Float.round(payload.progress * 100, 1)
    "[#{payload.phase}] #{payload.message} (#{pct}%)"
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp clamp_progress(p) when p < 0.0, do: 0.0
  defp clamp_progress(p) when p > 1.0, do: 1.0
  defp clamp_progress(p), do: p

  defp default_message(:initializing), do: "Initializing sub-agent"
  defp default_message(:executing), do: "Executing task"
  defp default_message(:finalizing), do: "Finalizing results"
  defp default_message(:streaming_output), do: "Streaming output"
  defp default_message(_), do: "Processing"
end
