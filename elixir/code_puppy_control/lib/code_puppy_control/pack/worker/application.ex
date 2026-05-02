defmodule CodePuppyControl.Pack.Worker.Application do
  @moduledoc """
  Lightweight OTP application supervisor for worker nodes.

  Starts a minimal supervision tree — no Phoenix Endpoint, no CLI,
  no TUI, no full session storage. Only what's needed to receive
  and execute sub-agent dispatches from a leader node.

  ## Started children

  - Pack.Worker — main dispatch GenServer
  - Pack.SubAgentPool — DynamicSupervisor for sub-agent processes
  - ProviderRegistry — model provider lookup
  - HttpClient (Finch) — for LLM API calls

  ## NOT started

  - CodePuppyControlWeb.Endpoint
  - CLI / REPL / TUI
  - SessionStorage
  - Full plugin system
  - PolicyEngine

  Start with: `CodePuppyControl.Pack.Worker.Application.start(:normal, opts)`
  Or via mix: `mix pup.worker --sname pup_worker_01 --cookie secret`

  (Phase I.2 — code_puppy-yge.2)
  """

  use Supervisor

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Starts the worker supervisor linked to the calling process.

  ## Options

    * `:node_name` — Erlang node name (defaults to `Node.self/0`)
    * `:cookie` — Distribution cookie (optional)
    * `:capabilities` — Explicit capabilities map (optional, auto-detected)
    * `:mode` — `:ephemeral` or `:persistent` (default: `:persistent`)

  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Application callback — starts the worker as a standalone OTP application.

  This allows `CodePuppyControl.Pack.Worker.Application` to be listed in
  `mix.exs` `extra_applications` or started via `Application.start/1`.
  """
  @spec start(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(_type, opts \\ []) do
    case start_link(opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Supervisor Callbacks ─────────────────────────────────────────────────

  @impl true
  def init(opts) do
    children = [
      # Minimal infrastructure
      {Finch, name: CodePuppyControl.Finch},
      CodePuppyControl.ModelFactory.ProviderRegistry,

      # Pack execution
      {DynamicSupervisor, name: CodePuppyControl.Pack.SubAgentPool, strategy: :one_for_one},
      {CodePuppyControl.Pack.Worker, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
