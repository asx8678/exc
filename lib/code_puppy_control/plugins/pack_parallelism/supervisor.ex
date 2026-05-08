defmodule CodePuppyControl.Plugins.PackParallelism.Supervisor do
  @moduledoc """
  Supervisor for the Pack Parallelism concurrency limiter.

  Starts and monitors the `CodePuppyControl.Plugins.PackParallelism` GenServer,
  restarting it on crashes to maintain concurrency control availability.

  ## Supervision Strategy

  Uses `:one_for_one` — if the GenServer crashes, only it is restarted.
  The ETS table is recreated on restart (stateless counters).

  ## Example

      # In application.ex
      children = [
        CodePuppyControl.Plugins.PackParallelism.Supervisor,
        # ... other children
      ]
  """

  use Supervisor

  # The fast suite exercises restart paths for supervised singletons. The
  # default supervisor intensity (3 restarts / 5s) can take down the whole
  # application during test-order races, cascading into unrelated "no process"
  # failures. Keep production defaults, but relax this inner supervisor in test
  # just like the root app supervisor. Runtime Mix.env/0 calls are avoided.
  @env Mix.env()
  @test_supervisor_opts if @env == :test, do: [max_restarts: 1000, max_seconds: 60], else: []

  @doc """
  Starts the pack parallelism supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      CodePuppyControl.Plugins.PackParallelism
    ]

    opts = [strategy: :one_for_one] ++ @test_supervisor_opts
    Supervisor.init(children, opts)
  end
end
