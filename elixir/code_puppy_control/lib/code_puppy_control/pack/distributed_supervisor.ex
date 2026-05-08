defmodule CodePuppyControl.Pack.DistributedSupervisor do
  @moduledoc """
  DynamicSupervisor managing per-remote-node children for distributed packs.

  Starts one child per configured worker node. Each child will be a
  `RemoteNodeSupervisor` (Phase I.2) — for now, this supervisor starts
  empty and provides the skeleton for future phases.

  Disabled by default. Controlled by `packs.distributed.enabled` config.

  (Phase I.1 — code_puppy-yge.2)
  """

  use DynamicSupervisor

  @registry CodePuppyControl.Pack.Registry
  @via_key :distributed_supervisor

  # ── Client API ────────────────────────────────────────────────────────────

  @doc """
  Starts the DistributedSupervisor linked to the current process.

  Registered via `{:via, Registry, {Pack.Registry, :distributed_supervisor}}`
  so other processes can look it up without knowing its pid.
  """
  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, via_tuple())
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a child under the DistributedSupervisor.

  Wraps `DynamicSupervisor.start_child/2` with the via-tuple name.
  """
  @spec start_child(Supervisor.child_spec() | {module(), term()}) ::
          DynamicSupervisor.on_start_child()
  def start_child(child_spec) do
    DynamicSupervisor.start_child(via_tuple(), child_spec)
  end

  @doc """
  Terminates a child identified by pid.

  Wraps `DynamicSupervisor.terminate_child/2` with the via-tuple name.
  """
  @spec stop_child(pid()) :: :ok | {:error, :not_found}
  def stop_child(pid) do
    DynamicSupervisor.terminate_child(via_tuple(), pid)
  end

  @doc """
  Returns the list of currently running children pids.
  """
  @spec children() :: [pid()]
  def children do
    DynamicSupervisor.which_children(via_tuple())
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @doc """
  Returns the count of active children.
  """
  @spec count() :: non_neg_integer()
  def count do
    DynamicSupervisor.count_children(via_tuple())[:active] || 0
  rescue
    _ -> 0
  end

  # ── DynamicSupervisor Callbacks ──────────────────────────────────────────

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Private ──────────────────────────────────────────────────────────────

  defp via_tuple do
    {:via, Registry, {@registry, @via_key}}
  end
end
