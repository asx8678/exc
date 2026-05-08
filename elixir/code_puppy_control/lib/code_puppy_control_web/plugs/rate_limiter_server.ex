defmodule CodePuppyControlWeb.Plugs.RateLimiterServer do
  @moduledoc """
  GenServer that owns the auth rate-limiter ETS table.

  Previously the ETS table was created inside a `Task` child in the
  application supervisor.  Because the Task completes immediately,
  the table's owning process died and the ETS table would be garbage-
  collected once no process held a reference.

  This GenServer lives for the lifetime of the application, ensuring
  the `:auth_rate_limiter` ETS table persists and is always available
  to the `RateLimiter` plug.

  ## Supervision

  Add as a **permanent** child _before_ the endpoint:

      {CodePuppyControlWeb.Plugs.RateLimiterServer, []}

  The `RateLimiter` plug calls `ensure_table!/0` which delegates to
  this server if the table does not yet exist.
  """

  use GenServer

  @table :auth_rate_limiter

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Start the GenServer and create the ETS table.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Ensure the ETS table exists.  Safe to call from any process.
  If the table already exists, this is a no-op.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.info(@table) == :undefined do
      # Table might be created by this server but not yet visible
      # due to a race. Try asking the server.
      try do
        GenServer.call(__MODULE__, :create_table, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    create_table()
    {:ok, %{}}
  end

  @impl true
  def handle_call(:create_table, _from, state) do
    create_table()
    {:reply, :ok, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp create_table do
    if :ets.info(@table) == :undefined do
      :ets.new(@table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end
end
