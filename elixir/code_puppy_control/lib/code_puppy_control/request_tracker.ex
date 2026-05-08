defmodule CodePuppyControl.RequestTracker do
  @moduledoc """
  Tracks pending requests and correlates responses.

  This GenServer maintains a registry of pending JSON-RPC requests,
  allowing the system to match incoming responses with their original
  requesters via `handle_call` / `GenServer.reply`.
  """

  use GenServer

  require Logger

  @type request_id :: String.t() | integer()
  @type pending_request :: %{
          from: GenServer.from() | nil,
          awaiter: GenServer.from() | nil,
          method: String.t(),
          result: {:ok, term()} | {:error, term()} | nil,
          timestamp: integer()
        }

  # Client API

  @doc """
  Starts the RequestTracker process.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a pending request and awaits its response.

  Returns `{:ok, result}` on success or `{:error, reason}` on timeout
  or other failure.
  """
  @spec await_request(request_id(), String.t(), timeout()) :: {:ok, term()} | {:error, term()}
  def await_request(request_id, method, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:register, request_id, method, timeout}, timeout + 5000)
  end

  @doc """
  Registers a pending request without blocking.
  Call this BEFORE sending the request to avoid race conditions.
  Returns :ok on success.
  """
  @spec register_request(request_id(), String.t(), timeout()) :: :ok
  def register_request(request_id, method, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:register_only, request_id, method, timeout})
  end

  @doc """
  Awaits a previously registered request's response.
  Call this AFTER sending the request.
  Returns {:ok, result} or {:error, reason}.
  """
  @spec await_response(request_id(), timeout()) :: {:ok, term()} | {:error, term()}
  def await_response(request_id, timeout \\ 30_000) do
    GenServer.call(__MODULE__, {:await, request_id}, timeout + 5000)
  end

  @doc """
  Completes a pending request with a result.
  """
  @spec complete_request(request_id(), term()) :: :ok | {:error, :not_found}
  def complete_request(request_id, result) do
    GenServer.call(__MODULE__, {:complete, request_id, result})
  end

  @doc """
  Fails a pending request with an error reason.
  """
  @spec fail_request(request_id(), term()) :: :ok | {:error, :not_found}
  def fail_request(request_id, reason) do
    GenServer.call(__MODULE__, {:fail, request_id, reason})
  end

  @doc """
  Provides a user response to a prompt request.

  This is used by the UI to send user input back to a waiting agent.
  The response is matched to the original prompt via prompt_id.
  """
  @spec provide_response(String.t(), term()) :: :ok | {:error, :not_found}
  def provide_response(prompt_id, response) do
    # For now, we treat prompt responses as completing a pending request
    # In the future, this may need a separate prompt tracking system
    complete_request(prompt_id, %{"response" => response, "prompt_id" => prompt_id})
  end

  @doc """
  Returns statistics about pending requests.
  """
  @spec stats() :: %{pending: non_neg_integer(), oldest_ms: non_neg_integer() | nil}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule periodic cleanup of stale requests
    schedule_cleanup()

    {:ok, %{pending: %{}, timers: %{}}}
  end

  @impl true
  def handle_call({:register, request_id, method, timeout}, from, state) do
    pending = %{
      from: from,
      awaiter: nil,
      method: method,
      result: nil,
      timestamp: System.monotonic_time(:millisecond)
    }

    # Set a timer to auto-fail this request on timeout
    timer_ref = Process.send_after(self(), {:timeout, request_id}, timeout)

    new_state = %{
      state
      | pending: Map.put(state.pending, request_id, pending),
        timers: Map.put(state.timers, request_id, timer_ref)
    }

    # Return noreply - we'll reply later when the response arrives
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:register_only, request_id, method, timeout}, _from, state) do
    pending = %{
      from: nil,
      awaiter: nil,
      method: method,
      result: nil,
      timestamp: System.monotonic_time(:millisecond)
    }

    timer_ref = Process.send_after(self(), {:timeout, request_id}, timeout)

    new_state = %{
      state
      | pending: Map.put(state.pending, request_id, pending),
        timers: Map.put(state.timers, request_id, timer_ref)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:await, request_id}, from, state) do
    case Map.get(state.pending, request_id) do
      nil ->
        # Not registered or already completed
        {:reply, {:error, :not_found}, state}

      %{result: {:ok, result}} = _pending ->
        # Result already arrived, return immediately
        new_pending = Map.delete(state.pending, request_id)
        new_timers = Map.delete(state.timers, request_id)
        cancel_timer(state.timers, request_id)
        {:reply, {:ok, result}, %{state | pending: new_pending, timers: new_timers}}

      %{result: {:error, reason}} = _pending ->
        # Error already arrived
        new_pending = Map.delete(state.pending, request_id)
        new_timers = Map.delete(state.timers, request_id)
        cancel_timer(state.timers, request_id)
        {:reply, {:error, reason}, %{state | pending: new_pending, timers: new_timers}}

      pending ->
        # Still waiting, store the awaiter
        new_pending = Map.put(state.pending, request_id, %{pending | awaiter: from})
        {:noreply, %{state | pending: new_pending}}
    end
  end

  @impl true
  def handle_call({:complete, request_id, result}, _from, state) do
    case Map.get(state.pending, request_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{awaiter: nil, from: nil} = pending ->
        # New pattern: awaiter hasn't called yet, store result
        new_pending = Map.put(state.pending, request_id, %{pending | result: {:ok, result}})
        {:reply, :ok, %{state | pending: new_pending}}

      %{awaiter: awaiter} when awaiter != nil ->
        # New pattern: awaiter is waiting, reply directly
        GenServer.reply(awaiter, {:ok, result})
        new_pending = Map.delete(state.pending, request_id)
        new_timers = Map.delete(state.timers, request_id)
        cancel_timer(state.timers, request_id)
        {:reply, :ok, %{state | pending: new_pending, timers: new_timers}}

      %{from: from} ->
        # Old pattern (backward compat): reply to original caller
        GenServer.reply(from, {:ok, result})
        new_pending = Map.delete(state.pending, request_id)
        new_timers = Map.delete(state.timers, request_id)
        cancel_timer(state.timers, request_id)
        {:reply, :ok, %{state | pending: new_pending, timers: new_timers}}
    end
  end

  @impl true
  def handle_call({:fail, request_id, reason}, _from, state) do
    case Map.get(state.pending, request_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{awaiter: nil, from: nil} = pending ->
        # New pattern: awaiter hasn't called yet, store error
        new_pending = Map.put(state.pending, request_id, %{pending | result: {:error, reason}})
        {:reply, :ok, %{state | pending: new_pending}}

      %{awaiter: awaiter} when awaiter != nil ->
        # New pattern: awaiter is waiting, reply directly with error
        GenServer.reply(awaiter, {:error, reason})
        new_pending = Map.delete(state.pending, request_id)
        new_timers = Map.delete(state.timers, request_id)
        cancel_timer(state.timers, request_id)
        {:reply, :ok, %{state | pending: new_pending, timers: new_timers}}

      %{from: from} ->
        # Old pattern (backward compat): reply to original caller with error
        GenServer.reply(from, {:error, reason})
        new_pending = Map.delete(state.pending, request_id)
        new_timers = Map.delete(state.timers, request_id)
        cancel_timer(state.timers, request_id)
        {:reply, :ok, %{state | pending: new_pending, timers: new_timers}}
    end
  end

  @impl true
  def handle_call({:provide_response, prompt_id, response}, _from, state) do
    # Treat prompt_id as a request_id for completion
    case Map.get(state.pending, prompt_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{awaiter: nil, from: nil} = pending ->
        # New pattern: awaiter hasn't called yet, store result
        result = %{"response" => response, "prompt_id" => prompt_id}
        new_pending = Map.put(state.pending, prompt_id, %{pending | result: {:ok, result}})
        {:reply, :ok, %{state | pending: new_pending}}

      %{awaiter: awaiter} when awaiter != nil ->
        # New pattern: awaiter is waiting, reply directly
        result = %{"response" => response, "prompt_id" => prompt_id}
        GenServer.reply(awaiter, {:ok, result})
        new_pending = Map.delete(state.pending, prompt_id)
        new_timers = Map.delete(state.timers, prompt_id)
        cancel_timer(state.timers, prompt_id)
        {:reply, :ok, %{state | pending: new_pending, timers: new_timers}}

      %{from: from} ->
        # Old pattern (backward compat): reply to original caller
        result = %{"response" => response, "prompt_id" => prompt_id}
        GenServer.reply(from, {:ok, result})
        new_pending = Map.delete(state.pending, prompt_id)
        new_timers = Map.delete(state.timers, prompt_id)
        cancel_timer(state.timers, prompt_id)
        {:reply, :ok, %{state | pending: new_pending, timers: new_timers}}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    now = System.monotonic_time(:millisecond)

    oldest_ms =
      state.pending
      |> Map.values()
      |> Enum.map(fn %{timestamp: ts} -> now - ts end)
      |> Enum.min(&<=/2, fn -> nil end)

    {:reply, %{pending: map_size(state.pending), oldest_ms: oldest_ms}, state}
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _} ->
        new_timers = Map.delete(state.timers, request_id)
        {:noreply, %{state | timers: new_timers}}

      {%{awaiter: awaiter, from: from} = pending, new_pending} ->
        Logger.warning("Request #{request_id} (#{pending.method}) timed out")

        # Reply to whoever is waiting (awaiter in new pattern, from in old pattern)
        target = awaiter || from
        if target, do: GenServer.reply(target, {:error, :timeout})

        new_timers = Map.delete(state.timers, request_id)
        {:noreply, %{state | pending: new_pending, timers: new_timers}}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    schedule_cleanup()

    now = System.monotonic_time(:millisecond)
    # 5 minutes
    stale_threshold = 5 * 60 * 1000

    stale_ids =
      for {id, %{timestamp: ts, awaiter: awaiter, from: from}} <- state.pending,
          now - ts > stale_threshold,
          do: {id, awaiter || from}

    for {id, target} <- stale_ids do
      Logger.warning("Cleaning up stale request #{id}")
      # Guard against nil target (register_only without awaiter)
      if target, do: GenServer.reply(target, {:error, :stale_request})
    end

    stale_id_set = MapSet.new(stale_ids, fn {id, _} -> id end)

    new_pending = Map.drop(state.pending, MapSet.to_list(stale_id_set))
    new_timers = Map.drop(state.timers, MapSet.to_list(stale_id_set))

    # Cancel timers for stale requests
    for {id, timer} <- state.timers, MapSet.member?(stale_id_set, id) do
      Process.cancel_timer(timer)
    end

    {:noreply, %{state | pending: new_pending, timers: new_timers}}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 60_000)
  end

  defp cancel_timer(timers, request_id) do
    case Map.get(timers, request_id) do
      nil -> :ok
      timer -> Process.cancel_timer(timer)
    end
  end
end
