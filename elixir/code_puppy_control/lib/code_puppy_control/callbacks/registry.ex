defmodule CodePuppyControl.Callbacks.Registry do
  @moduledoc """
  ETS-backed GenServer for callback storage.

  ## Design

  - **ETS table** stores `{hook_name, [callbacks_ordered_by_registration_time]}`
  - **Reads** are lock-free via `:ets.lookup/2` (concurrent-safe on BEAM)
  - **Writes** go through the GenServer to ensure ordering consistency
  - **Registration is idempotent** — registering the same function twice is a no-op
  - **Callbacks are ordered by registration time** — first registered, first executed

  ## ETS Table Details

  - Table type: `:set` (one entry per hook name)
  - Read concurrency: `true` (optimized for frequent reads)
  - Write concurrency: `true` (optimized for concurrent registration)
  - Named table: `#{__MODULE__}` for direct access without a handle
  """

  use GenServer

  @table __MODULE__

  # ── Public API ──────────────────────────────────────────────────

  @doc """
  Starts the callback registry.

  Called by the application supervisor — not typically invoked directly.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a callback function for the given hook.

  Idempotent: if the function is already registered for this hook,
  this is a no-op. Callbacks are stored in registration order.

  Returns `:ok`.
  """
  @spec register(atom(), function()) :: :ok
  def register(hook_name, fun) when is_atom(hook_name) and is_function(fun) do
    GenServer.call(__MODULE__, {:register, hook_name, fun})
  end

  @doc """
  Unregisters a callback function from the given hook.

  Returns `true` if the callback was found and removed, `false` otherwise.
  """
  @spec unregister(atom(), function()) :: boolean()
  def unregister(hook_name, fun) when is_atom(hook_name) and is_function(fun) do
    GenServer.call(__MODULE__, {:unregister, hook_name, fun})
  end

  @doc """
  Returns an ordered list of callbacks registered for the given hook.

  Read directly from ETS — no GenServer message overhead.
  Returns an empty list if no callbacks are registered.
  """
  @spec get_callbacks(atom()) :: [function()]
  def get_callbacks(hook_name) when is_atom(hook_name) do
    case :ets.lookup(@table, hook_name) do
      [{^hook_name, callbacks}] -> callbacks
      [] -> []
    end
  end

  @doc """
  Returns the count of callbacks registered for the given hook.

  If `hook_name` is `:all`, returns the total count across all hooks.
  """
  @spec count(atom()) :: non_neg_integer()
  def count(:all) do
    @table
    |> :ets.tab2list()
    |> Enum.reduce(0, fn {_name, cbs}, acc -> acc + length(cbs) end)
  end

  def count(hook_name) when is_atom(hook_name) do
    hook_name |> get_callbacks() |> length()
  end

  @doc """
  Returns all hook names that have at least one callback registered.
  """
  @spec active_hooks() :: [atom()]
  def active_hooks do
    @table
    |> :ets.tab2list()
    |> Enum.filter(fn {_name, cbs} -> cbs != [] end)
    |> Enum.map(fn {name, _} -> name end)
    |> Enum.sort()
  end

  @doc """
  Removes all callbacks. Primarily used in test teardown.

  If `hook_name` is provided, only clears callbacks for that hook.
  """
  @spec clear(atom() | nil) :: :ok
  def clear(hook_name \\ nil) do
    GenServer.call(__MODULE__, {:clear, hook_name})
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:register, hook_name, fun}, _from, state) do
    existing = get_callbacks(hook_name)

    if fun in existing do
      # Idempotent — already registered
      {:reply, :ok, state}
    else
      updated = existing ++ [fun]
      :ets.insert(@table, {hook_name, updated})
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:unregister, hook_name, fun}, _from, state) do
    existing = get_callbacks(hook_name)

    if fun in existing do
      updated = List.delete(existing, fun)
      :ets.insert(@table, {hook_name, updated})
      {:reply, true, state}
    else
      {:reply, false, state}
    end
  end

  @impl true
  def handle_call({:clear, nil}, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:clear, hook_name}, _from, state) do
    :ets.delete(@table, hook_name)
    {:reply, :ok, state}
  end
end
