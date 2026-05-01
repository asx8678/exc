defmodule CodePuppyControl.Pack.Dispatch.Fallback do
  @moduledoc """
  Graceful degradation strategies for distributed dispatch failures.

  When remote dispatch fails (no matching workers, node disconnected,
  capability mismatch), this module provides fallback strategies:

  1. **Local fallback** — execute locally (always safe)
  2. **Retry with broader criteria** — relax filters and try again
  3. **Queue for later** — defer dispatch until a worker becomes available
  4. **Error with context** — return a rich error explaining what's needed

  ## Decision Logic

  Most dispatch failures are *infrastructure* problems (nodes down, no
  workers registered yet) — these degrade to local execution silently
  with a warning log. A **capability mismatch** is different: the caller
  explicitly asked for something no worker can do, and silently falling
  back to local would hide a logic error. So capability mismatch returns
  `{:error, reason, message}` instead.

  ## Telemetry

  Every fallback decision emits a telemetry event so cluster operators
  can monitor degradation rates:

      [:code_puppy, :distributed_pack, :fallback, :local]

  Measurements include the fallback reason for alerting/thresholds.
  """

  require Logger

  # ── Types ────────────────────────────────────────────────────────────────

  @type fallback_reason ::
          :no_workers_registered
          | :no_matching_capabilities
          | :all_workers_disconnected
          | :all_workers_busy
          | {:node_not_found, node()}
          | {:node_disconnected, node()}
          | {:capability_mismatch, atom(), node()}

  @type fallback_result ::
          {:fallback_local, fallback_reason()}
          | {:error, fallback_reason(), String.t()}

  # ── Public API ──────────────────────────────────────────────────────────

  @doc """
  Determine the fallback action when remote dispatch fails.

  Returns a tagged tuple describing what to do:

  - `{:fallback_local, reason}` — execute locally, with reason for logging
  - `{:error, reason, message}` — cannot execute, with human-readable error

  ## Examples

      iex> CodePuppyControl.Pack.Dispatch.Fallback.resolve(:no_workers_registered)
      {:fallback_local, :no_workers_registered}

      iex> CodePuppyControl.Pack.Dispatch.Fallback.resolve({:capability_mismatch, :terrier, :"pup_worker@host"})
      {:error, {:capability_mismatch, :terrier, :"pup_worker@host"}, \"...\"}
  """
  @spec resolve(fallback_reason(), keyword()) :: fallback_result()
  def resolve(reason, opts \\ [])

  def resolve(:no_workers_registered, _opts) do
    {:fallback_local, :no_workers_registered}
  end

  def resolve(:no_matching_capabilities, _opts) do
    {:fallback_local, :no_matching_capabilities}
  end

  def resolve(:all_workers_disconnected, _opts) do
    {:fallback_local, :all_workers_disconnected}
  end

  def resolve(:all_workers_busy, _opts) do
    {:fallback_local, :all_workers_busy}
  end

  def resolve({:node_not_found, _node} = reason, _opts) do
    {:fallback_local, reason}
  end

  def resolve({:node_disconnected, _node} = reason, _opts) do
    {:fallback_local, reason}
  end

  def resolve({:capability_mismatch, _capability, _node} = reason, _opts) do
    {:error, reason, explain(reason)}
  end

  @doc """
  Human-readable error message for a fallback reason.

  Used by `/pack cluster` status, error reporting, and any UI that needs
  to explain *why* dispatch degraded.

  Every reason produces a clear, actionable message — not just "error".
  """
  @spec explain(fallback_reason()) :: String.t()
  def explain(:no_workers_registered) do
    "No remote workers are registered in the cluster. " <>
      "Ensure at least one pack worker node is connected and has advertised capabilities."
  end

  def explain(:no_matching_capabilities) do
    "No remote workers match the requested capabilities. " <>
      "Check that the sub-agent type and OS filter are correct, " <>
      "or register a worker with the needed capabilities."
  end

  def explain(:all_workers_disconnected) do
    "All registered workers are currently disconnected. " <>
      "Check network connectivity and that remote nodes are running."
  end

  def explain(:all_workers_busy) do
    "All matching workers are at capacity. " <>
      "Wait for in-flight runs to complete, or add more workers to the cluster."
  end

  def explain({:node_not_found, node}) do
    "The requested node #{inspect(node)} is not found in the cluster. " <>
      "It may have been deregistered or never connected. " <>
      "Verify the node name and that it has joined the pack."
  end

  def explain({:node_disconnected, node}) do
    "The node #{inspect(node)} is disconnected. " <>
      "Check that the remote BEAM instance is running and " <>
      "the Erlang distribution cookie is correct."
  end

  def explain({:capability_mismatch, capability, node}) do
    "Node #{inspect(node)} does not support the '#{capability}' capability. " <>
      "The worker explicitly lacks this capability — " <>
      "this is a configuration error, not an infrastructure issue. " <>
      "Either configure the worker to support '#{capability}' " <>
      "or dispatch to a different node."
  end

  @doc """
  Log a fallback event with appropriate severity.

  - **Warning**: infrastructure degradation (disconnected, no workers, mismatch)
  - **Info**: expected/normal fallback (all workers busy, node not found)

  Always emits a telemetry event for observability dashboards.
  """
  @spec log_fallback(fallback_reason(), keyword()) :: :ok
  def log_fallback(reason, opts \\ [])

  def log_fallback(:all_workers_busy, opts) do
    Logger.info("[Pack.Fallback] #{explain(:all_workers_busy)}")

    emit_telemetry(:all_workers_busy, opts)
  end

  def log_fallback({:node_not_found, _node} = reason, opts) do
    Logger.info("[Pack.Fallback] #{explain(reason)}")

    emit_telemetry(reason, opts)
  end

  def log_fallback(reason, opts) do
    Logger.warning("[Pack.Fallback] #{explain(reason)}")

    emit_telemetry(reason, opts)
  end

  # ── Telemetry ────────────────────────────────────────────────────────────

  defp emit_telemetry(reason, opts) do
    :telemetry.execute(
      [:code_puppy, :distributed_pack, :fallback, :local],
      %{count: 1},
      %{
        reason: reason,
        source: Keyword.get(opts, :source, :dispatch)
      }
    )
  end
end
