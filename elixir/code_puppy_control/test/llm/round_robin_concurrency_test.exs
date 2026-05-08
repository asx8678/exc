defmodule CodePuppyControl.LLM.RoundRobinConcurrencyTest do
  @moduledoc """
  Concurrency safety tests for RoundRobinModel, ported from Python
  tests/test_round_robin_thread_safety.py.

  The Elixir RoundRobinModel is a GenServer backed by an ETS table with
  read/write concurrency enabled. These tests verify that `advance_and_get/0`
  distributes evenly under high concurrent access — i.e., no calls are
  swallowed or double-counted due to race conditions.

  Python → Elixir translation notes:
  - asyncio.gather → Task.async_stream / Task.yield_many
  - collections.Counter → Enum.frequencies/1
  - RoundRobinModel instance → named GenServer (configure/1 + advance_and_get/0)
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :property

  alias CodePuppyControl.RoundRobinModel

  # Number of concurrent worker tasks
  @num_workers 10
  # Calls each worker makes
  @calls_per_worker 300

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RoundRobinModel)
    :ok
  end

  # ── Helper ────────────────────────────────────────────────────────────────

  defp run_concurrent_workers(num_workers, calls_per_worker) do
    # Each task calls advance_and_get/0 repeatedly, collecting results locally.
    # Task.async_stream with max_concurrency ensures true parallelism.
    tasks =
      for _i <- 1..num_workers do
        Task.async(fn ->
          for _j <- 1..calls_per_worker do
            RoundRobinModel.advance_and_get()
          end
        end)
      end

    # Collect all results — timeout generous for CI
    task_results = Task.yield_many(tasks, 30_000)

    # Flatten: each task returned {:ok, list_of_models} or nil on timeout
    all_results =
      task_results
      |> Enum.flat_map(fn
        {_task, {:ok, models}} -> models
        {_task, nil} -> flunk("A worker task timed out")
        {_task, {:exit, reason}} -> flunk("A worker task crashed: #{inspect(reason)}")
      end)

    all_results
  end

  # ── Tests ─────────────────────────────────────────────────────────────────

  describe "concurrent access with rotate_every=1" do
    test "advance_and_get distributes evenly under high concurrency" do
      models = ["model0", "model1", "model2"]
      :ok = RoundRobinModel.configure(models: models, rotate_every: 1)

      all_results = run_concurrent_workers(@num_workers, @calls_per_worker)
      total = @num_workers * @calls_per_worker

      assert length(all_results) == total,
             "Expected #{total} results, got #{length(all_results)} — some calls were lost or duplicated"

      frequencies = Enum.frequencies(all_results)
      expected_per_model = total |> div(length(models))

      for model <- models do
        count = Map.get(frequencies, model, 0)

        assert count == expected_per_model,
               "#{model} got #{count} requests, expected #{expected_per_model}. " <>
                 "Distribution: #{inspect(frequencies)}"
      end
    end
  end

  describe "concurrent access with rotate_every > 1" do
    test "advance_and_get distributes evenly with rotate_every=3" do
      models = ["model0", "model1"]
      :ok = RoundRobinModel.configure(models: models, rotate_every: 3)

      # 6 workers × 300 calls = 1800 total
      # 1800 / 2 models = 900 each; 1800 divisible by rotate_every*num_models (6) ✓
      num_workers = 6
      calls_per_worker = 300

      all_results = run_concurrent_workers(num_workers, calls_per_worker)
      total = num_workers * calls_per_worker

      assert length(all_results) == total,
             "Expected #{total} results, got #{length(all_results)} — some calls were lost or duplicated"

      frequencies = Enum.frequencies(all_results)
      expected_per_model = total |> div(length(models))

      for model <- models do
        count = Map.get(frequencies, model, 0)

        assert count == expected_per_model,
               "#{model} got #{count} requests, expected #{expected_per_model}. " <>
                 "Distribution: #{inspect(frequencies)}"
      end
    end
  end

  describe "distribution invariant (property-based)" do
    property "no calls lost, all results from configured set, bounded skew" do
      import StreamData

      check all(
              num_models <- integer(2..5),
              rotate_every <- integer(1..4),
              num_workers <- integer(2..6),
              calls_per_worker <- integer(50..100),
              max_runs: 20
            ) do
        models = for i <- 1..num_models, do: "m#{i}"
        total = num_workers * calls_per_worker

        :ok = RoundRobinModel.configure(models: models, rotate_every: rotate_every)

        all_results = run_concurrent_workers(num_workers, calls_per_worker)

        # Invariant 1: no calls lost or duplicated
        assert length(all_results) == total,
               "Lost or duplicated calls: expected #{total}, got #{length(all_results)}"

        # Invariant 2: every result is a valid model from the configured set
        model_set = MapSet.new(models)

        for result <- all_results do
          assert MapSet.member?(model_set, result),
                 "Got unexpected model name: #{inspect(result)}, expected one of #{inspect(models)}"
        end

        # Invariant 3: bounded skew — no model gets more than one full
        # rotate_every-block more than any other. The max skew between any
        # two models is at most rotate_every * num_models.
        frequencies = Enum.frequencies(all_results)
        counts = Enum.map(models, &Map.get(frequencies, &1, 0))
        max_count = Enum.max(counts)
        min_count = Enum.min(counts)
        skew = max_count - min_count

        # Upper bound: at most one extra rotate_every-block per model
        max_allowed_skew = rotate_every * num_models

        assert skew <= max_allowed_skew,
               "Skew #{skew} between #{max_count} and #{min_count} exceeds " <>
                 "max allowed #{max_allowed_skew}. Distribution: #{inspect(frequencies)}"
      end
    end
  end
end
