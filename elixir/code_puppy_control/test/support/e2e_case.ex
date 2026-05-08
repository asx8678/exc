defmodule CodePuppyControl.E2ECase do
  @moduledoc """
  Test case template for end-to-end integration tests.

  These tests require a full application stack:
  - Database running with Ecto
  - PubSub available
  - EventStore running
  - Python worker bridge (real or mocked)

  ## Usage

      defmodule MyE2ETest do
        use CodePuppyControl.E2ECase

        test "full workflow" do
          # Test implementation
        end
      end

  ## Configuration

  E2E tests are tagged with `:e2e` and excluded by default.
  Run with:

      mix test --only e2e

  Or use the custom task:

      mix test.e2e

  ## Prerequisites

  Before running E2E tests, ensure:

  1. Database is created: `mix ecto.create`
  2. Migrations are run: `mix ecto.migrate`
  3. Test database is available
  4. (Optional) Python worker is installed for full stack tests

  ## Environment Variables

    * `SKIP_E2E` - Set to skip E2E tests entirely
    * `E2E_TIMEOUT` - Override default 120s timeout (milliseconds)
    * `E2E_NO_MOCK` - Use real Python worker instead of mock
  """

  use ExUnit.CaseTemplate

  alias CodePuppyControl.EventBus

  using do
    quote do
      import CodePuppyControl.E2ECase
      import CodePuppyControl.E2ECase.Helpers

      # Module-level tags
      @moduletag :e2e
      @moduletag timeout: 120_000
    end
  end

  setup tags do
    # Check if E2E tests should be skipped
    if System.get_env("SKIP_E2E") do
      raise "E2E tests skipped via SKIP_E2E environment variable"
    end

    # Use shared sandbox for cross-process communication testing
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(
        CodePuppyControl.Repo,
        shared: not tags[:async]
      )

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
    end)

    # Ensure EventStore is available
    CodePuppyControl.E2ECase.Helpers.ensure_event_store()

    # Clear event store for clean state
    CodePuppyControl.EventStore.clear_all()

    # Subscribe to global events
    CodePuppyControl.EventBus.subscribe_global()

    :ok
  end

  defmodule Helpers do
    @moduledoc """
    Helper functions for E2E tests.
    """

    alias CodePuppyControl.EventBus

    @doc """
    Ensures the EventStore is running.
    """
    def ensure_event_store do
      case CodePuppyControl.EventStore.start_link([]) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        _ -> :ok
      end
    end

    @doc """
    Collects events for a given run_id with timeout.
    """
    def collect_events(run_id, opts \\ []) do
      timeout = Keyword.get(opts, :timeout, 30_000)
      deadline = System.monotonic_time(:millisecond) + timeout

      collect_loop(run_id, [], deadline)
    end

    defp collect_loop(run_id, acc, deadline) do
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        Enum.reverse(acc)
      else
        receive do
          {:event, %{run_id: ^run_id} = event} ->
            if terminal?(event) do
              Enum.reverse([event | acc])
            else
              collect_loop(run_id, [event | acc], deadline)
            end

          {:event, %{"run_id" => ^run_id} = event} ->
            if terminal?(event) do
              Enum.reverse([event | acc])
            else
              collect_loop(run_id, [event | acc], deadline)
            end
        after
          min(remaining, 500) ->
            collect_loop(run_id, acc, deadline)
        end
      end
    end

    defp terminal?(%{type: t}) when t in ["completed", "run.completed", "failed", "run.failed"],
      do: true

    defp terminal?(%{"type" => t})
         when t in ["completed", "run.completed", "failed", "run.failed"],
         do: true

    defp terminal?(_), do: false

    @doc """
    Gets the type of an event (handles both atom and string keys).
    """
    def event_type(%{type: type}), do: type
    def event_type(%{"type" => type}), do: type
    def event_type(_), do: nil

    @doc """
    Waits for a run to reach terminal state or timeout.
    """
    def await_run_completion(run_id, timeout_ms \\ 30_000) do
      deadline = System.monotonic_time(:millisecond) + timeout_ms
      poll_interval = 100

      do_await(run_id, deadline, poll_interval)
    end

    defp do_await(run_id, deadline, poll_interval) do
      case CodePuppyControl.Run.Manager.get_run(run_id) do
        {:ok, %{status: status} = state}
        when status in [:completed, :failed, :cancelled] ->
          {:ok, state}

        {:ok, state} ->
          if System.monotonic_time(:millisecond) >= deadline do
            {:timeout, state}
          else
            Process.sleep(poll_interval)
            do_await(run_id, deadline, poll_interval)
          end

        {:error, :not_found} ->
          {:error, :not_found}
      end
    end

    @doc """
    Creates a temporary session ID for testing.
    """
    def temp_session_id(prefix \\ "test") do
      "#{prefix}-#{System.system_time(:millisecond)}-#{:rand.uniform(100_000)}"
    end

    @doc """
    Flushes the process mailbox of any pending events.
    """
    def flush_events do
      receive do
        {:event, _} -> flush_events()
      after
        0 -> :ok
      end
    end

    @doc """
    Subscribes to multiple topics at once.
    """
    def subscribe_all(session_id, run_id) do
      EventBus.subscribe_session(session_id)
      EventBus.subscribe_run(run_id)
      EventBus.subscribe_global()
      :ok
    end

    @doc """
    Unsubscribes from multiple topics at once.
    """
    def unsubscribe_all(session_id, run_id) do
      EventBus.unsubscribe_session(session_id)
      EventBus.unsubscribe_run(run_id)
      EventBus.unsubscribe_global()
      :ok
    end
  end
end
