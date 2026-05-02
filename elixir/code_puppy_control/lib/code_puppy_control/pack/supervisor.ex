defmodule CodePuppyControl.Pack.Supervisor do
  @moduledoc """
  Supervisor for Pack-related GenServers within `code_puppy_control`.

  Currently supervises:
    - `CodePuppyControl.Pack.NamingService` — ETS-backed capability index
    - `CodePuppyControl.Pack.Dispatcher` — Round-robin worker dispatch

  This supervisor is intended to be started by the umbrella root supervision
  tree (e.g., `code_puppy_e2k`). It is **not** wired into
  `CodePuppyControl.Application` — that belongs to the higher-level
  orchestrator.
  """

  use Supervisor

  @doc """
  Starts the Pack supervisor with default children.

  ## Options

  Accepts any `Supervisor.start_link/2` option. Passed through transparently.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      CodePuppyControl.Pack.NamingService,
      CodePuppyControl.Pack.Dispatcher
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
