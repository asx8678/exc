defmodule CodePuppyControl.RateLimiter.Supervisor do
  @moduledoc """
  Supervisor for the adaptive rate limiter subsystem.

  Starts and monitors the `CodePuppyControl.RateLimiter` GenServer.
  Uses `:one_for_one` — if the limiter crashes, only the limiter is
  restarted. ETS tables are recreated on init.

  ## Supervision Strategy

  The rate limiter is a critical reliability component — it prevents
  rate-limit storms from cascading across providers. Restart intensity
  is kept low (5 restarts in 10 seconds) to surface persistent issues.
  """

  use Supervisor

  # Runtime `Mix.env/0` calls are forbidden in startup paths because Mix may
  # not be available in packaged releases. Capture it at compile time instead.
  @env Mix.env()
  @restart_opts if @env == :test,
                  do: [max_restarts: 1000, max_seconds: 60],
                  else: [max_restarts: 5, max_seconds: 10]

  @doc """
  Starts the rate limiter supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      CodePuppyControl.RateLimiter
    ]

    Supervisor.init(children, [strategy: :one_for_one] ++ @restart_opts)
  end
end
