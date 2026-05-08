defmodule CodePuppyControl.StatefulCase do
  @moduledoc """
  ExUnit case template for tests that use stateful GenServers.

  Automatically resets all state before each test to ensure isolation.

  ## Usage

  Use this case template for tests that interact with stateful components:

      defmodule MyStatefulTest do
        use CodePuppyControl.StatefulCase

        test "something with state" do
          # All state has been reset before this test
          # ...
        end
      end

  ## Features

  - Automatically calls `CodePuppyControl.TestSupport.Reset.reset_all/0` before each test
  - Provides convenient aliases for common stateful modules
  - Ensures test isolation even when running tests in parallel or random order

  ## Comparison with regular Case

  | Template | Use When |
  |----------|----------|
  | `ExUnit.Case` | Tests with no stateful dependencies |
  | `CodePuppyControl.StatefulCase` | Tests using GenServers, ETS, or dynamic supervisors |

  ## Performance Note

  Resetting state adds ~10-50ms per test. For tests that don't need state
  isolation, use `ExUnit.Case` directly for faster execution.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # Common imports for stateful tests
      alias CodePuppyControl.{
        PolicyEngine,
        ModelAvailability,
        RoundRobinModel,
        EventStore,
        RuntimeState
      }

      alias CodePuppyControl.Tools.{AgentCatalogue, CommandRunner}

      import CodePuppyControl.TestSupport.Reset, only: [reset_all: 0]
    end
  end

  setup do
    CodePuppyControl.TestSupport.Reset.reset_all()
    :ok
  end
end
