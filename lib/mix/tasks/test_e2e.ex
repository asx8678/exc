defmodule Mix.Tasks.Test.E2e do
  @moduledoc """
  Run end-to-end integration tests for the CodePuppy hybrid architecture.

  This task runs E2E tests that validate the full stack:
  - Elixir control plane (Run.Manager, EventBus, EventStore)
  - Python worker bridge (via Port or mock)
  - Scheduler with Oban jobs
  - MCP server lifecycle

  ## Prerequisites

  Before running E2E tests, ensure:

    1. Database is created: `mix ecto.create`
    2. Migrations are run: `mix ecto.migrate`
    3. Test database is available

  ## Usage

      mix test.e2e                    # Run all E2E tests
      mix test.e2e --max-failures 1   # Stop on first failure
      mix test.e2e --seed 12345       # Use specific random seed
      mix test.e2e --trace            # Show detailed trace

  ## Environment Variables

    * `SKIP_E2E` - Set to skip E2E tests
    * `E2E_TIMEOUT` - Override default timeout (milliseconds)
    * `E2E_NO_MOCK` - Use real Python worker instead of mock

  ## Examples

      # Run E2E tests with trace
      mix test.e2e --trace

      # Run with custom timeout
      E2E_TIMEOUT=180000 mix test.e2e

      # Run specific test file
      mix test.e2e test/integration/e2e_test.exs

  ## See Also

    * `Mix.Tasks.Test` - Standard test runner
    * `mix test --only e2e` - Alternative way to run E2E tests
  """

  use Mix.Task

  @shortdoc "Run end-to-end integration tests"

  @impl true
  def run(args) do
    # Check if E2E should be skipped
    if System.get_env("SKIP_E2E") do
      Mix.shell().info("E2E tests skipped via SKIP_E2E environment variable")
      :ok
    else
      # Ensure we have the proper environment
      ensure_database()

      # Run E2E tests only
      Mix.Task.run("test", ["--only", "e2e" | args])
    end
  end

  defp ensure_database do
    # Check if database exists by trying to load it
    case Mix.Task.run("ecto.migrate", ["--quiet"]) do
      :ok ->
        :ok

      {:error, reason} ->
        Mix.shell().info("Note: Database migration had issues: #{inspect(reason)}")
        Mix.shell().info("Run `mix ecto.setup` first if tests fail due to missing tables")
        :ok

      _ ->
        :ok
    end
  catch
    _kind, _reason ->
      Mix.shell().info("Note: Could not ensure database state")
      :ok
  end
end
