defmodule CodePuppyControl.Pack.Registries do
  @moduledoc """
  Supervisor that owns the Registry processes used by RemoteNodeProxy
  and RemoteNodeSupervisor for `:via`-tuple process lookup.

  Without this supervisor the `:via` registration path is broken — the
  Registry modules don't exist, so `GenServer.whereis/1` and
  `start_link(name: via_tuple)` crash.

  Start this supervisor (or include its children in the app tree)
  before any `RemoteNodeSupervisor` or `RemoteNodeProxy` that uses
  named registration.

  ## Children

  - `CodePuppyControl.Pack.RemoteNodeSupervisor.Registry` — unique keys
  - `CodePuppyControl.Pack.RemoteNodeProxy.Registry` — unique keys
  """

  use Supervisor

  # ── Public API ───────────────────────────────────────────────────────────

  @doc """
  Starts the Registries supervisor.

  ## Options

  - `:name` — registration name (defaults to `__MODULE__`)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  # ── Supervisor Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: CodePuppyControl.Pack.RemoteNodeSupervisor.Registry},
      {Registry, keys: :unique, name: CodePuppyControl.Pack.RemoteNodeProxy.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
