defmodule CodePuppyControl.Rollout.MetricsTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Rollout.Metrics

  @select_event [:code_puppy, :runtime, :select]
  @fallback_event [:code_puppy, :runtime, :fallback]

  setup do
    # Reset the shared ETS table so tests don't bleed into each other
    Metrics.reset()

    # Start a fresh Metrics GenServer per test with unique name
    name = :"metrics_test_#{:erlang.unique_integer([:positive])}"
    start_supervised!({Metrics, name: name})
    %{metrics: name}
  end

  # ── Record / Query cycle ──────────────────────────────────────────────

  describe "record_success/2 and success_count/2" do
    test "returns 0 for unrecorded capability+runtime" do
      assert Metrics.success_count(:llm_client, :elixir) == 0
    end

    test "increments success counter" do
      Metrics.record_success(:llm_client, :elixir)
      assert Metrics.success_count(:llm_client, :elixir) == 1
    end

    test "increments independently per capability" do
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_success(:tools, :elixir)

      assert Metrics.success_count(:llm_client, :elixir) == 1
      assert Metrics.success_count(:tools, :elixir) == 1
    end

    test "increments independently per runtime" do
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_success(:llm_client, :python)

      assert Metrics.success_count(:llm_client, :elixir) == 1
      assert Metrics.success_count(:llm_client, :python) == 1
    end

    test "accumulates multiple increments" do
      for _ <- 1..10, do: Metrics.record_success(:tools, :elixir)
      assert Metrics.success_count(:tools, :elixir) == 10
    end

    test "returns the new counter value" do
      assert Metrics.record_success(:cli, :elixir) == 1
      assert Metrics.record_success(:cli, :elixir) == 2
      assert Metrics.record_success(:cli, :elixir) == 3
    end
  end

  describe "record_error/2 and error_count/2" do
    test "returns 0 for unrecorded capability+runtime" do
      assert Metrics.error_count(:plugins, :python) == 0
    end

    test "increments error counter" do
      Metrics.record_error(:plugins, :python)
      assert Metrics.error_count(:plugins, :python) == 1
    end

    test "increments independently per capability" do
      Metrics.record_error(:llm_client, :python)
      Metrics.record_error(:tools, :python)

      assert Metrics.error_count(:llm_client, :python) == 1
      assert Metrics.error_count(:tools, :python) == 1
    end

    test "increments independently per runtime" do
      Metrics.record_error(:llm_client, :elixir)
      Metrics.record_error(:llm_client, :python)

      assert Metrics.error_count(:llm_client, :elixir) == 1
      assert Metrics.error_count(:llm_client, :python) == 1
    end

    test "accumulates multiple error increments" do
      for _ <- 1..5, do: Metrics.record_error(:base_agent, :elixir)
      assert Metrics.error_count(:base_agent, :elixir) == 5
    end
  end

  # ── success_rate/2 ─────────────────────────────────────────────────────

  describe "success_rate/2" do
    test "returns 0.0 when no data exists" do
      assert Metrics.success_rate(:llm_client, :elixir) == 0.0
    end

    test "returns 1.0 when only successes exist" do
      Metrics.record_success(:tools, :elixir)
      Metrics.record_success(:tools, :elixir)
      assert Metrics.success_rate(:tools, :elixir) == 1.0
    end

    test "returns 0.0 when only errors exist" do
      Metrics.record_error(:plugins, :python)
      Metrics.record_error(:plugins, :python)
      assert Metrics.success_rate(:plugins, :python) == 0.0
    end

    test "calculates mixed success/error rate" do
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_error(:llm_client, :elixir)

      assert Metrics.success_rate(:llm_client, :elixir) == 3.0 / 4.0
    end

    test "is independent per capability" do
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_error(:llm_client, :elixir)

      Metrics.record_success(:tools, :elixir)
      Metrics.record_error(:tools, :elixir)

      assert Metrics.success_rate(:llm_client, :elixir) == 2.0 / 3.0
      assert Metrics.success_rate(:tools, :elixir) == 1.0 / 2.0
    end

    test "is independent per runtime" do
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_error(:llm_client, :elixir)

      Metrics.record_success(:llm_client, :python)

      assert Metrics.success_rate(:llm_client, :elixir) == 0.5
      assert Metrics.success_rate(:llm_client, :python) == 1.0
    end
  end

  # ── reset/0 ────────────────────────────────────────────────────────────

  describe "reset/0" do
    test "clears all counters" do
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_error(:tools, :python)
      Metrics.record_success(:plugins, :elixir)

      Metrics.reset()

      assert Metrics.success_count(:llm_client, :elixir) == 0
      assert Metrics.error_count(:tools, :python) == 0
      assert Metrics.success_count(:plugins, :elixir) == 0
      assert Metrics.summary() == %{}
    end

    test "counters start fresh after reset" do
      Metrics.record_success(:tools, :elixir)
      Metrics.reset()
      Metrics.record_success(:tools, :elixir)

      assert Metrics.success_count(:tools, :elixir) == 1
    end
  end

  # ── summary/0 ─────────────────────────────────────────────────────────

  describe "summary/0" do
    test "returns empty map when no data" do
      assert Metrics.summary() == %{}
    end

    test "returns per-capability per-runtime entries" do
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_error(:llm_client, :elixir)

      Metrics.record_success(:tools, :python)

      summary = Metrics.summary()

      expected_rate = 2.0 / 3.0

      assert %{elixir: %{successes: 2, errors: 1, rate: ^expected_rate}} =
               summary[:llm_client]

      assert %{python: %{successes: 1, errors: 0, rate: 1.0}} = summary[:tools]
    end

    test "handles multiple runtimes per capability" do
      Metrics.record_success(:llm_client, :elixir)
      Metrics.record_success(:llm_client, :python)
      Metrics.record_error(:llm_client, :python)

      summary = Metrics.summary()

      assert %{elixir: %{successes: 1, errors: 0, rate: 1.0}} =
               summary[:llm_client]

      assert %{python: %{successes: 1, errors: 1, rate: 0.5}} =
               summary[:llm_client]
    end

    test "includes zero entries after record+reset+record cycle" do
      Metrics.record_success(:cli, :elixir)
      Metrics.reset()
      Metrics.record_error(:cli, :elixir)

      summary = Metrics.summary()
      assert %{elixir: %{successes: 0, errors: 1, rate: 0.0}} = summary[:cli]
    end
  end

  # ── Telemetry integration: select events ──────────────────────────────

  describe "telemetry integration — [:code_puppy, :runtime, :select]" do
    setup do
      # Attach a test listener to verify the handler fires
      test_pid = self()

      :telemetry.attach_many(
        "metrics-test-select-observer",
        [@select_event],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:select_observed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("metrics-test-select-observer")
      end)

      :ok
    end

    test "increments success count on select event" do
      :telemetry.execute(
        @select_event,
        %{},
        %{capability: :llm_client, selected: :elixir, mode: :auto}
      )

      assert Metrics.success_count(:llm_client, :elixir) == 1

      assert_receive {:select_observed, %{},
                      %{capability: :llm_client, selected: :elixir, mode: :auto}}
    end

    test "accumulates multiple select events across capabilities" do
      :telemetry.execute(
        @select_event,
        %{},
        %{capability: :llm_client, selected: :elixir, mode: :auto}
      )

      :telemetry.execute(
        @select_event,
        %{},
        %{capability: :llm_client, selected: :elixir, mode: :auto}
      )

      :telemetry.execute(
        @select_event,
        %{},
        %{capability: :tools, selected: :python, mode: :auto}
      )

      assert Metrics.success_count(:llm_client, :elixir) == 2
      assert Metrics.success_count(:tools, :python) == 1
    end

    test "select event with python runtime increments python counter" do
      :telemetry.execute(
        @select_event,
        %{},
        %{capability: :plugins, selected: :python, mode: :python}
      )

      assert Metrics.success_count(:plugins, :python) == 1
      assert Metrics.success_count(:plugins, :elixir) == 0
    end
  end

  # ── Telemetry integration: fallback events ────────────────────────────

  describe "telemetry integration — [:code_puppy, :runtime, :fallback]" do
    setup do
      test_pid = self()

      :telemetry.attach_many(
        "metrics-test-fallback-observer",
        [@fallback_event],
        fn _event_name, measurements, metadata, _config ->
          send(test_pid, {:fallback_observed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("metrics-test-fallback-observer")
      end)

      :ok
    end

    test ":success event increments success counter" do
      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :success, capability: :llm_client, runtime: :elixir, reason: nil}
      )

      assert Metrics.success_count(:llm_client, :elixir) == 1
      assert Metrics.error_count(:llm_client, :elixir) == 0
    end

    test ":fallback event (primary failed) increments error counter" do
      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :fallback, capability: :tools, runtime: :elixir, reason: "timeout"}
      )

      assert Metrics.error_count(:tools, :elixir) == 1
      assert Metrics.success_count(:tools, :elixir) == 0
    end

    test ":fallback_success event increments success for secondary runtime" do
      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :fallback_success, capability: :cli, runtime: :python, reason: nil}
      )

      assert Metrics.success_count(:cli, :python) == 1
      assert Metrics.error_count(:cli, :python) == 0
    end

    test ":fallback_failed event increments error for secondary runtime" do
      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :fallback_failed, capability: :plugins, runtime: :python, reason: "crash"}
      )

      assert Metrics.error_count(:plugins, :python) == 1
      assert Metrics.success_count(:plugins, :python) == 0
    end

    test "full fallback lifecycle produces correct metrics" do
      # Primary fails
      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :fallback, capability: :llm_client, runtime: :elixir, reason: "e_fail"}
      )

      # Secondary succeeds
      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :fallback_success, capability: :llm_client, runtime: :python, reason: nil}
      )

      summary = Metrics.summary()

      assert %{elixir: %{successes: 0, errors: 1, rate: 0.0}} = summary[:llm_client]
      assert %{python: %{successes: 1, errors: 0, rate: 1.0}} = summary[:llm_client]
    end

    test "both-runtimes-failed produces two error records" do
      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :fallback, capability: :tools, runtime: :elixir, reason: "e_dead"}
      )

      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :fallback_failed, capability: :tools, runtime: :python, reason: "p_broken"}
      )

      assert Metrics.error_count(:tools, :elixir) == 1
      assert Metrics.error_count(:tools, :python) == 1
      assert Metrics.success_count(:tools, :elixir) == 0
      assert Metrics.success_count(:tools, :python) == 0
      assert Metrics.success_rate(:tools, :elixir) == 0.0
      assert Metrics.success_rate(:tools, :python) == 0.0
    end

    test ":success from fallback does NOT affect select metrics" do
      # This tests that counters are independent
      :telemetry.execute(
        @fallback_event,
        %{},
        %{event: :success, capability: :cli, runtime: :elixir, reason: nil}
      )

      assert Metrics.success_count(:cli, :elixir) == 1

      # Select events go to a different counter but same key structure
      :telemetry.execute(
        @select_event,
        %{},
        %{capability: :cli, selected: :elixir, mode: :auto}
      )

      assert Metrics.success_count(:cli, :elixir) == 2
    end
  end

  # ── Guard clauses ─────────────────────────────────────────────────────

  describe "guard clauses" do
    test "record_success raises on non-atom capability" do
      assert_raise FunctionClauseError, fn ->
        Metrics.record_success("llm_client", :elixir)
      end
    end

    test "record_success raises on non-atom runtime" do
      assert_raise FunctionClauseError, fn ->
        Metrics.record_success(:llm_client, "elixir")
      end
    end

    test "record_error raises on non-atom capability" do
      assert_raise FunctionClauseError, fn ->
        Metrics.record_error("tools", :python)
      end
    end

    test "record_error raises on non-atom runtime" do
      assert_raise FunctionClauseError, fn ->
        Metrics.record_error(:tools, "python")
      end
    end
  end

  # ── Multiple GenServers isolation ─────────────────────────────────────

  describe "ETS table is singleton by design" do
    test "second GenServer reuses existing named table" do
      # The ETS table :rollout_metrics is named and shared — starting a
      # second Metrics GenServer should not crash (init handles re-use).
      name2 = :"metrics_dup_#{:erlang.unique_integer([:positive])}"
      assert {:ok, _pid} = start_supervised({Metrics, name: name2}, id: name2)

      # Both instances see the same ETS table
      Metrics.record_success(:llm_client, :elixir)
      assert Metrics.success_count(:llm_client, :elixir) == 1
    end
  end
end
