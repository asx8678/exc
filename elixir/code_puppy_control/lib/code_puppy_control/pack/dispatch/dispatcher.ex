defmodule CodePuppyControl.Pack.Dispatch.Dispatcher do
  @moduledoc """
  Central dispatch router for agent invocations.

  Routes invocations to either local or remote execution based on
  the presence of a `node:` option. When no node is specified,
  dispatch is ALWAYS local — zero behavior change from pre-distributed mode.

  This is the backward-compatibility guarantee: existing code that calls
  `cp_invoke_agent(agent, prompt)` without a node option continues to
  work exactly as before, even when distributed pack infrastructure
  is available.

  ## Dispatch Rules

  | Condition | Action | Return |
  |-----------|--------|--------|
  | No `:node`, no `:auto_dispatch` | **Local** (backward compat) | `{:local, :noop}` |
  | `:node` set | Remote via `RemoteNodeProxy` | `{:remote, node, run_id}` or `{:error, _}` |
  | `:auto_dispatch` truthy | Auto-select worker | `{:local, :noop}` (falls back to local until capability query lands) |

  ## Telemetry

  Emits `[:code_puppy, :pack, :dispatch, :decision]` for every routing decision,
  including metadata about the dispatch kind and agent name.
  """

  require Logger

  @doc """
  Route an agent invocation to the appropriate executor.

  ## Options

  - `:node` — explicit remote node target. When absent, always local.
  - `:auto_dispatch` — when true, use capability query to find best worker.
    When false or absent, local dispatch (default: false).

  ## Returns

  - `{:local, result}` — dispatched locally (standard path)
  - `{:remote, node, run_id}` — dispatched to remote worker
  - `{:error, reason}` — dispatch failed
  """
  @spec dispatch(atom(), map(), keyword()) ::
          {:local, term()} | {:remote, node(), String.t()} | {:error, term()}
  def dispatch(agent_name, params, opts \\ []) do
    node = Keyword.get(opts, :node)
    auto = Keyword.get(opts, :auto_dispatch, false)

    cond do
      # Case 1: Explicit remote node target
      not is_nil(node) ->
        do_remote_dispatch(node, agent_name, params, opts)

      # Case 2: Auto-dispatch — find best worker via capability query
      auto ->
        do_auto_dispatch(agent_name, params, opts)

      # Case 3: Local dispatch — backward-compatible default
      # This is the critical path: NO node option = local, period.
      true ->
        emit_decision(:local, agent_name, %{reason: :no_node_specified})
        {:local, :noop}
    end
  end

  @doc """
  Returns `true` if the dispatch would go to a remote node.

  Useful for logging, telemetry, or pre-checking without actually
  performing the dispatch.

  ## Examples

      iex> Dispatcher.remote_dispatch?(node: :worker@host)
      true

      iex> Dispatcher.remote_dispatch?([])
      false

      iex> Dispatcher.remote_dispatch?(auto_dispatch: true)
      false
  """
  @spec remote_dispatch?(keyword()) :: boolean()
  def remote_dispatch?(opts) do
    not is_nil(Keyword.get(opts, :node))
  end

  # ── Private: Remote Dispatch ──────────────────────────────────────────

  defp do_remote_dispatch(node, agent_name, params, opts) do
    emit_decision(:remote, agent_name, %{node: node, reason: :explicit_node})

    # Route through RemoteNodeProxy which handles the actual GenServer call
    # to the remote worker node.
    proxy =
      {:via, Registry, {CodePuppyControl.Pack.RemoteNodeProxy.Registry, node}}

    case CodePuppyControl.Pack.RemoteNodeProxy.dispatch(proxy, agent_name, params, opts) do
      {:ok, run_id} ->
        {:remote, node, run_id}

      {:error, reason} ->
        Logger.warning(
          "[Dispatcher] Remote dispatch to #{inspect(node)} failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  catch
    kind, reason ->
      error_msg = Exception.format(kind, reason, __STACKTRACE__)
      Logger.error("[Dispatcher] Remote dispatch to #{inspect(node)} crashed: #{error_msg}")
      reason_str =
        case reason do
          %{__exception__: true} -> Exception.message(reason)
          _ -> inspect(reason)
        end

      {:error, {:remote_dispatch_crashed, reason_str}}
  end

  # ── Private: Auto Dispatch ─────────────────────────────────────────────

  defp do_auto_dispatch(agent_name, _params, _opts) do
    emit_decision(:auto, agent_name, %{})

    # TODO(code_puppy-aeg.3): Implement capability-based worker selection.
    #
    # Future implementation:
    #   1. Query NamingService for connected workers with matching capabilities
    #   2. Select best worker based on load/affinity/capabilities
    #   3. Delegate to RemoteNodeProxy.dispatch/3
    #   4. Return {:remote, selected_node, run_id}
    #
    # For now, auto_dispatch falls back to local when no capability query
    # infrastructure is available. This is the safe default — existing
    # non-distributed setups are unaffected.

    {:local, :noop}
  end

  # ── Private: Telemetry ─────────────────────────────────────────────────

  defp emit_decision(kind, agent_name, extra) do
    :telemetry.execute(
      [:code_puppy, :pack, :dispatch, :decision],
      %{system_time: System.system_time(:millisecond)},
      Map.merge(%{kind: kind, agent_name: agent_name}, extra)
    )
  end
end
