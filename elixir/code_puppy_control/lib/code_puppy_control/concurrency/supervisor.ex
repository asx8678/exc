defmodule CodePuppyControl.Concurrency.Supervisor do
  @moduledoc """
  Supervisor for the concurrency limiter subsystem.

  Starts and monitors the `CodePuppyControl.Concurrency.Limiter` GenServer,
  restarting it on crashes to maintain concurrency control availability.

  ## Supervision Strategy

  Uses `:one_for_one` — if the limiter crashes, only the limiter is restarted.
  The ETS table is recreated on restart (stateless counters).

  ## Example

      # In application.ex
      children = [
        CodePuppyControl.Concurrency.Supervisor,
        # ... other children
      ]
  """

  use Supervisor

  @doc """
  Starts the concurrency supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      CodePuppyControl.Concurrency.Limiter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
