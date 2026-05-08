defmodule CodePuppyControl.LLM.RoundRobinFullTest do
  @moduledoc """
  Full-coverage round-robin tests ported from Python.

  Covers gap analysis items G21–G29:
  - G21: Initialization + field assertions
  - G22: N/A — Elixir RoundRobinModel has no `settings` field (Python-only concept)
  - G23: Single model initialization + name format
  - G24: model_name/0 property formatting
  - G25: get_current_model/0 delegation (Elixir equivalent of system/base_url delegation)
  - G26: Strategy.select integration (equivalent of request() rotation)
  - G27: Strategy.select basic (equivalent of request_stream basic)
  - G28: Strategy.select rotates (equivalent of request_stream rotation)
  - G29: Strategy.select with context (equivalent of request_stream + run_context)

  Deferred (G30–G35): OpenTelemetry span attribute tests.
  Now ported to test/llm/otel_span_test.exs.
  Tests are tagged @moduletag :otel and @moduletag skip: until OTel
  is integrated into the Elixir stack.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.RoundRobinModel
  alias CodePuppyControl.Routing.Strategy
  alias CodePuppyControl.Routing.Strategies.RoundRobin

  setup do
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RoundRobinModel)
    :ok
  end

  # ── G21: Initialization + Field Assertions ────────────────────────────────

  describe "initialization (G21)" do
    test "configure sets all state fields correctly" do
      :ok = RoundRobinModel.configure(models: ["model1", "model2"])

      state = RoundRobinModel.get_state()

      assert state.models == ["model1", "model2"]
      assert state.current_index == 0
      assert state.request_count == 0
      assert state.rotate_every == 1
    end

    test "configure with rotate_every preserves all fields" do
      :ok = RoundRobinModel.configure(models: ["a", "b", "c"], rotate_every: 3)

      state = RoundRobinModel.get_state()

      assert state.models == ["a", "b", "c"]
      assert state.current_index == 0
      assert state.request_count == 0
      assert state.rotate_every == 3
    end

    test "reconfigure resets index and request_count" do
      :ok = RoundRobinModel.configure(models: ["x", "y"])
      # Advance a few times
      RoundRobinModel.advance_and_get()
      RoundRobinModel.advance_and_get()

      # Reconfigure — should reset
      :ok = RoundRobinModel.configure(models: ["p", "q"], rotate_every: 5)

      state = RoundRobinModel.get_state()
      assert state.models == ["p", "q"]
      assert state.current_index == 0
      assert state.request_count == 0
      assert state.rotate_every == 5
    end
  end

  # ── G23: Single Model Initialization ─────────────────────────────────────

  describe "single model initialization (G23)" do
    test "single model configures and always returns that model" do
      :ok = RoundRobinModel.configure(models: ["only-one"])

      assert RoundRobinModel.get_current_model() == "only-one"
      assert RoundRobinModel.advance_and_get() == "only-one"
      assert RoundRobinModel.advance_and_get() == "only-one"

      # model_name format for single model
      assert RoundRobinModel.model_name() == "round_robin:only-one"
    end

    test "single model with rotate_every still always returns that model" do
      :ok = RoundRobinModel.configure(models: ["solo"], rotate_every: 5)

      for _ <- 1..10 do
        assert RoundRobinModel.advance_and_get() == "solo"
      end

      state = RoundRobinModel.get_state()
      # With a single model, index wraps back to 0
      assert state.current_index == 0
    end
  end

  # ── G24: model_name/0 Property Formatting ─────────────────────────────────

  describe "model_name/0 formatting (G24)" do
    test "default rotate_every omits rotate_every suffix" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2", "m3"])
      assert RoundRobinModel.model_name() == "round_robin:m1,m2,m3"
    end

    test "custom rotate_every includes suffix" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2", "m3"], rotate_every: 5)
      assert RoundRobinModel.model_name() == "round_robin:m1,m2,m3:rotate_every=5"
    end

    test "single model name format" do
      :ok = RoundRobinModel.configure(models: ["single_model"])
      assert RoundRobinModel.model_name() == "round_robin:single_model"
    end

    test "single model with rotate_every includes suffix" do
      :ok = RoundRobinModel.configure(models: ["solo"], rotate_every: 3)
      assert RoundRobinModel.model_name() == "round_robin:solo:rotate_every=3"
    end

    test "two models with rotate_every=2" do
      :ok = RoundRobinModel.configure(models: ["model1", "model2"], rotate_every: 2)
      assert RoundRobinModel.model_name() == "round_robin:model1,model2:rotate_every=2"
    end
  end

  # ── G25: Property Delegation via get_current_model ────────────────────────
  #
  # Python's RoundRobinModel delegates `system` and `base_url` to the
  # current model. In Elixir, the equivalent is `get_current_model/0`
  # returning the name of the model at the current rotation index.

  describe "get_current_model delegation (G25)" do
    test "initially returns first model" do
      :ok = RoundRobinModel.configure(models: ["model1", "model2"])

      assert RoundRobinModel.get_current_model() == "model1"
    end

    test "after rotation returns next model" do
      :ok = RoundRobinModel.configure(models: ["model1", "model2"])

      # advance_and_get returns current model AND advances state
      assert RoundRobinModel.advance_and_get() == "model1"
      # Now current has moved to model2
      assert RoundRobinModel.get_current_model() == "model2"
    end

    test "delegation follows rotation through all models" do
      :ok = RoundRobinModel.configure(models: ["m1", "m2", "m3"], rotate_every: 1)

      assert RoundRobinModel.get_current_model() == "m1"
      RoundRobinModel.advance_and_get()
      assert RoundRobinModel.get_current_model() == "m2"
      RoundRobinModel.advance_and_get()
      assert RoundRobinModel.get_current_model() == "m3"
      RoundRobinModel.advance_and_get()
      # Wraps back
      assert RoundRobinModel.get_current_model() == "m1"
    end

    test "delegation respects rotate_every" do
      :ok = RoundRobinModel.configure(models: ["a", "b"], rotate_every: 3)

      # Three calls: stays on "a"
      RoundRobinModel.advance_and_get()
      assert RoundRobinModel.get_current_model() == "a"
      RoundRobinModel.advance_and_get()
      assert RoundRobinModel.get_current_model() == "a"
      # Third call triggers rotation
      RoundRobinModel.advance_and_get()
      assert RoundRobinModel.get_current_model() == "b"
    end
  end

  # ── G26: Strategy.select Integration (request-like rotation) ─────────────
  #
  # Python's `request()` method calls `_get_next_model()` and delegates
  # the request to the returned model. In Elixir, the equivalent flow is
  # `Strategy.select/2` on the RoundRobin strategy, which calls
  # `RoundRobinModel.advance_and_get/0`.

  describe "Strategy.select integration (G26)" do
    test "global round-robin strategy rotates through models" do
      :ok = RoundRobinModel.configure(models: ["model1", "model2"], rotate_every: 1)

      strategy = %RoundRobin{use_global: true}

      assert {:ok, "model1"} = Strategy.select(strategy, %{})
      assert {:ok, "model2"} = Strategy.select(strategy, %{})
      # Wraps
      assert {:ok, "model1"} = Strategy.select(strategy, %{})
    end

    test "global strategy with rotate_every=2 stays on each model" do
      :ok = RoundRobinModel.configure(models: ["model1", "model2"], rotate_every: 2)

      strategy = %RoundRobin{use_global: true}

      # Two selects → model1
      assert {:ok, "model1"} = Strategy.select(strategy, %{})
      assert {:ok, "model1"} = Strategy.select(strategy, %{})
      # Two selects → model2
      assert {:ok, "model2"} = Strategy.select(strategy, %{})
      assert {:ok, "model2"} = Strategy.select(strategy, %{})
      # Wraps
      assert {:ok, "model1"} = Strategy.select(strategy, %{})
    end

    test "global strategy returns error when no models configured" do
      # Drive the actual no-models-configured path by configuring and then
      # clearing the ETS state to simulate an unconfigured GenServer.
      :ok = RoundRobinModel.configure(models: ["temp"])
      # Clear the ETS state to simulate no-models condition
      :ets.delete(:round_robin_state, :state)

      strategy = %RoundRobin{use_global: true}

      assert {:error, :no_models_configured} = Strategy.select(strategy, %{})
    after
      # Restore valid state for subsequent tests
      :ok = RoundRobinModel.configure(models: ["temp"])
    end

    test "non-global strategy with models list returns first available" do
      strategy = %RoundRobin{models: ["alpha", "beta"], use_global: false}

      # Non-global mode always returns first available (no state tracking)
      assert {:ok, "alpha"} = Strategy.select(strategy, %{})
      assert {:ok, "alpha"} = Strategy.select(strategy, %{})
    end
  end

  # ── G27: Strategy.select Basic (request_stream equivalent) ──────────────
  #
  # In Python, `request_stream` delegates streaming to the current model.
  # The Elixir equivalent is the strategy selecting the model that will
  # be used for a streaming request. The strategy's `select/2` is called
  # the same way regardless of streaming vs non-streaming.

  describe "Strategy.select for streaming flow (G27)" do
    test "select returns the first model for initial stream request" do
      :ok = RoundRobinModel.configure(models: ["stream-a", "stream-b"])

      strategy = %RoundRobin{use_global: true}

      # First stream request gets first model
      assert {:ok, "stream-a"} = Strategy.select(strategy, %{})
    end

    test "select with single model always returns that model" do
      :ok = RoundRobinModel.configure(models: ["only-streamer"])

      strategy = %RoundRobin{use_global: true}

      for _ <- 1..5 do
        assert {:ok, "only-streamer"} = Strategy.select(strategy, %{})
      end
    end
  end

  # ── G28: Strategy.select Rotates (stream rotation) ───────────────────────

  describe "Strategy.select rotation for streaming (G28)" do
    test "consecutive selects rotate models" do
      :ok = RoundRobinModel.configure(models: ["s1", "s2"])

      strategy = %RoundRobin{use_global: true}

      # First select → s1, second → s2
      {:ok, first} = Strategy.select(strategy, %{})
      {:ok, second} = Strategy.select(strategy, %{})

      assert first == "s1"
      assert second == "s2"

      # Third wraps back
      {:ok, third} = Strategy.select(strategy, %{})
      assert third == "s1"
    end

    test "rotation with rotate_every across multiple stream selections" do
      :ok = RoundRobinModel.configure(models: ["sa", "sb"], rotate_every: 2)

      strategy = %RoundRobin{use_global: true}

      # Two stream selections → sa
      {:ok, r1} = Strategy.select(strategy, %{})
      {:ok, r2} = Strategy.select(strategy, %{})
      assert r1 == "sa"
      assert r2 == "sa"

      # Next two → sb
      {:ok, r3} = Strategy.select(strategy, %{})
      {:ok, r4} = Strategy.select(strategy, %{})
      assert r3 == "sb"
      assert r4 == "sb"
    end
  end

  # ── G29: Strategy.select with Context (stream + run_context) ─────────────
  #
  # Python's `request_stream` accepts a `run_context` parameter.
  # In Elixir, context is passed to `Strategy.select/2` as a map.
  # The RoundRobin strategy uses `:excluded_models` from context.

  describe "Strategy.select with context (G29)" do
    test "non-global strategy excludes models from context" do
      strategy = %RoundRobin{
        models: ["alpha", "beta", "gamma"],
        use_global: false
      }

      # Without exclusion: returns first
      assert {:ok, "alpha"} = Strategy.select(strategy, %{})

      # With exclusion: returns first non-excluded
      context = %{excluded_models: ["alpha"]}
      assert {:ok, "beta"} = Strategy.select(strategy, context)
    end

    test "non-global strategy returns error when all models excluded" do
      strategy = %RoundRobin{
        models: ["only-choice"],
        use_global: false
      }

      context = %{excluded_models: ["only-choice"]}
      assert {:error, :all_models_excluded} = Strategy.select(strategy, context)
    end

    test "non-global strategy with empty models returns error" do
      strategy = %RoundRobin{models: [], use_global: false}
      assert {:error, :no_models_available} = Strategy.select(strategy, %{})
    end

    test "non-global strategy with nil models returns error" do
      strategy = %RoundRobin{models: nil, use_global: false}
      assert {:error, :no_models_configured} = Strategy.select(strategy, %{})
    end

    test "global strategy ignores excluded_models in context" do
      # Global strategy delegates to RoundRobinModel which doesn't
      # use excluded_models — that's handled at a higher level by the Router.
      :ok = RoundRobinModel.configure(models: ["g1", "g2"])

      strategy = %RoundRobin{use_global: true}
      context = %{excluded_models: ["g1"]}

      # Global strategy still returns g1 (rotation state is authoritative)
      assert {:ok, "g1"} = Strategy.select(strategy, context)
    end
  end

  # ── G30–G35: OpenTelemetry Span Attributes ─────────────────────────────────
  #
  # Ported to test/llm/otel_span_test.exs.
  # Tests are tagged :otel and :skip until OTel is integrated.

  describe "validation edge cases" do
    test "configure rejects empty models list" do
      assert {:error, :empty_models} = RoundRobinModel.configure(models: [])
    end

    test "configure rejects rotate_every of 0" do
      assert {:error, :invalid_rotate_every} =
               RoundRobinModel.configure(models: ["m1"], rotate_every: 0)
    end

    test "configure rejects negative rotate_every" do
      assert {:error, :invalid_rotate_every} =
               RoundRobinModel.configure(models: ["m1"], rotate_every: -5)
    end
  end
end
