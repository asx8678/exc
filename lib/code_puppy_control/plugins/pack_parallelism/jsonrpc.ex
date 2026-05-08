defmodule CodePuppyControl.Plugins.PackParallelism.JSONRPC do
  @moduledoc """
  JSON-RPC handler functions for the PackParallelism GenServer.

  Dispatched through `StdioService` when the Elixir control plane is
  active, replacing the Python-side handlers in `bridge_controller.py`.

  Each function receives a params map and returns a result map suitable
  for JSON-RPC response encoding.  All calls delegate to the
  `CodePuppyControl.Plugins.PackParallelism` GenServer for
  race-free, serialized state mutations.

  ## Methods

  - `run_limiter.acquire`  — Acquire a pack slot (blocking with timeout)
  - `run_limiter.release`  — Release a pack slot
  - `run_limiter.status`  — Return current counts and config
  - `run_limiter.set_limit` — Update the concurrency limit at runtime
  - `run_limiter.reset`    — Emergency force-reset of all state
  """

  alias CodePuppyControl.Plugins.PackParallelism

  @default_wait_timeout 600_000

  @doc """
  Handle `run_limiter.acquire` JSON-RPC method.
  """
  @spec handle_jsonrpc_acquire(map()) :: map()
  def handle_jsonrpc_acquire(params) do
    timeout_ms =
      case Map.get(params, "timeout") do
        nil -> @default_wait_timeout
        t when is_number(t) -> trunc(t * 1000)
        _ -> @default_wait_timeout
      end

    case PackParallelism.acquire(timeout: timeout_ms) do
      :ok ->
        %{"status" => "ok"}

      {:error, :timeout} ->
        %{"status" => "timeout", "fallback" => true}
    end
  end

  @doc """
  Handle `run_limiter.release` JSON-RPC method.
  """
  @spec handle_jsonrpc_release(map()) :: map()
  def handle_jsonrpc_release(_params) do
    PackParallelism.release()
    %{"status" => "ok"}
  end

  @doc """
  Handle `run_limiter.status` JSON-RPC method.
  """
  @spec handle_jsonrpc_status(map()) :: map()
  def handle_jsonrpc_status(_params) do
    s = PackParallelism.status()

    %{
      "status" => "ok",
      "limit" => s.limit,
      "active" => s.active,
      "waiters" => s.waiters,
      "available" => s.available
    }
  end

  @doc """
  Handle `run_limiter.set_limit` JSON-RPC method.
  """
  @spec handle_jsonrpc_set_limit(map()) :: map()
  def handle_jsonrpc_set_limit(params) do
    limit = Map.get(params, "limit", 2)

    case PackParallelism.set_limit(limit) do
      :ok ->
        s = PackParallelism.status()
        %{"status" => "ok", "limit" => s.limit, "active" => s.active, "available" => s.available}

      {:error, :invalid} ->
        %{"status" => "error", "message" => "Invalid limit value"}
    end
  end

  @doc """
  Handle `run_limiter.reset` JSON-RPC method.
  """
  @spec handle_jsonrpc_reset(map()) :: map()
  def handle_jsonrpc_reset(_params) do
    previous = PackParallelism.reset()
    %{"status" => "ok", "previous" => previous}
  end
end
