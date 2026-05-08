defmodule CodePuppyControl.LLM.StateMachinePropertyTest do
  @moduledoc """
  State-machine property tests for LLM GenServers.

  Uses StreamData to generate random sequences of operations and compares
  the GenServer output against a pure reference model. Catches state
  corruption, missing transitions, and invariant violations that unit
  tests alone might miss.

  Two state machines are tested:
  1. RoundRobinModel — configure, advance_and_get, get_current_model, reset
     Invariants: advance returns configured model, rotate_every triggers
     rotation, reset returns to first model, get_current_model is idempotent
  2. ModelAvailability — mark_terminal, mark_healthy, mark_sticky_retry,
     consume_sticky_attempt, reset_turn, reset_all, snapshot, select_first_available
     Invariants: terminal dominates sticky, consumed sticky unavailable until
     reset_turn, reset_all clears health not last-resort, select_first_available
     never returns an unavailable model, last_resort independent of health,
     last_resort survives reset_all, mark_as_last_resort toggles correctly
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :property

  alias CodePuppyControl.RoundRobinModel
  alias CodePuppyControl.ModelAvailability

  # ── RoundRobinModel State Machine ────────────────────────────────────────

  describe "RoundRobinModel state machine" do
    setup do
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(RoundRobinModel)
      :ok
    end

    # Pure reference model for RoundRobinModel state
    defmodule RRRef do
      @moduledoc false
      defstruct models: [], current_index: 0, rotate_every: 1, request_count: 0

      def new(models \\ [], rotate_every \\ 1) do
        %__MODULE__{models: models, rotate_every: rotate_every}
      end

      def configure(ref, models, rotate_every) do
        %{ref | models: models, current_index: 0, rotate_every: rotate_every, request_count: 0}
      end

      def advance(ref) do
        case ref.models do
          [] ->
            {nil, ref}

          models ->
            n = length(models)
            current_model = Enum.at(models, ref.current_index)
            new_request_count = ref.request_count + 1

            {new_index, new_request_count} =
              if new_request_count >= ref.rotate_every do
                {rem(ref.current_index + 1, n), 0}
              else
                {ref.current_index, new_request_count}
              end

            new_ref = %{ref | current_index: new_index, request_count: new_request_count}
            {current_model, new_ref}
        end
      end

      def current_model(ref) do
        case ref.models do
          [] -> nil
          models -> Enum.at(models, ref.current_index)
        end
      end

      def reset(ref) do
        %{ref | current_index: 0, request_count: 0}
      end
    end

    property "GenServer matches reference model for arbitrary operation sequences" do
      check all(
              ops <- list_of(rr_operation_gen(), min_length: 1, max_length: 60),
              max_runs: 50
            ) do
        initial_models = ["ma", "mb", "mc"]
        initial_rotate = 2
        ref = RRRef.configure(RRRef.new(), initial_models, initial_rotate)
        :ok = RoundRobinModel.configure(models: initial_models, rotate_every: initial_rotate)

        {final_ref, mismatches} =
          Enum.reduce(ops, {ref, []}, fn op, {ref, mismatches} ->
            {gs_result, ref_result, new_ref} = apply_rr_op(op, ref)

            if gs_result != ref_result do
              {new_ref, [{op, gs_result, ref_result} | mismatches]}
            else
              {new_ref, mismatches}
            end
          end)

        assert mismatches == [],
               "GenServer diverged from reference model: #{inspect(Enum.reverse(mismatches))}"

        # Final-state: internal GenServer state matches reference model
        gs = RoundRobinModel.get_state()
        assert gs.models == final_ref.models, "Final models mismatch"
        assert gs.current_index == final_ref.current_index, "Final index mismatch"
        assert gs.rotate_every == final_ref.rotate_every, "Final rotate_every mismatch"
        assert gs.request_count == final_ref.request_count, "Final request_count mismatch"
      end
    end

    property "advance_and_get always returns a configured model or nil" do
      check all(
              models <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 1,
                  max_length: 5
                ),
              rotate_every <- integer(1..5),
              num_advances <- integer(1..20),
              max_runs: 30
            ) do
        :ok = RoundRobinModel.configure(models: models, rotate_every: rotate_every)
        model_set = MapSet.new(models)

        for _ <- 1..num_advances//1 do
          result = RoundRobinModel.advance_and_get()

          assert result == nil or MapSet.member?(model_set, result),
                 "advance_and_get returned #{inspect(result)}, not in configured models"
        end
      end
    end

    property "rotation wraps correctly after N*rotate_every advances" do
      check all(
              num_models <- integer(2..4),
              rotate_every <- integer(1..3),
              max_runs: 30
            ) do
        models = for i <- 1..num_models, do: "m#{i}"
        :ok = RoundRobinModel.configure(models: models, rotate_every: rotate_every)
        for _ <- 1..(num_models * rotate_every)//1, do: RoundRobinModel.advance_and_get()
        assert RoundRobinModel.get_current_model() == hd(models)
      end
    end

    property "reset always returns to initial model" do
      check all(
              models <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 1,
                  max_length: 4
                ),
              rotate_every <- integer(1..3),
              num_advances <- integer(0..15),
              max_runs: 30
            ) do
        :ok = RoundRobinModel.configure(models: models, rotate_every: rotate_every)
        for _ <- 1..num_advances//1, do: RoundRobinModel.advance_and_get()
        :ok = RoundRobinModel.reset()

        assert RoundRobinModel.get_current_model() == hd(models),
               "After reset, should return first model"
      end
    end

    property "get_current_model is idempotent" do
      check all(
              models <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 1,
                  max_length: 4
                ),
              rotate_every <- integer(1..3),
              num_advances <- integer(0..10),
              max_runs: 30
            ) do
        :ok = RoundRobinModel.configure(models: models, rotate_every: rotate_every)
        for _ <- 1..num_advances//1, do: RoundRobinModel.advance_and_get()
        first = RoundRobinModel.get_current_model()
        for _ <- 1..10, do: assert(RoundRobinModel.get_current_model() == first)
      end
    end

    property "after rotate_every advances, the index advances" do
      check all(
              models <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 2,
                  max_length: 5
                ),
              rotate_every <- integer(1..4),
              max_runs: 30
            ) do
        :ok = RoundRobinModel.configure(models: models, rotate_every: rotate_every)
        idx_before = RoundRobinModel.get_state().current_index
        for _ <- 1..rotate_every, do: RoundRobinModel.advance_and_get()
        idx_after = RoundRobinModel.get_state().current_index

        assert idx_after == rem(idx_before + 1, length(models)),
               "After #{rotate_every} advances, index should advance"
      end
    end

    # -- Generators & Helpers for RoundRobinModel --

    defp rr_operation_gen do
      one_of([
        # Reconfigure with a new model list
        tuple({
          constant(:configure),
          list_of(string(:alphanumeric, min_length: 1, max_length: 6),
            min_length: 1,
            max_length: 4
          ),
          integer(1..5)
        }),
        # Advance
        constant(:advance_and_get),
        # Get current (no mutation, but validates state)
        constant(:get_current_model),
        # Reset
        constant(:reset)
      ])
    end

    defp apply_rr_op({:configure, models, rotate_every}, ref) do
      gs = RoundRobinModel.configure(models: models, rotate_every: rotate_every)
      {gs, :ok, RRRef.configure(ref, models, rotate_every)}
    end

    defp apply_rr_op(:advance_and_get, ref) do
      gs = RoundRobinModel.advance_and_get()
      {ref_result, new_ref} = RRRef.advance(ref)
      {gs, ref_result, new_ref}
    end

    defp apply_rr_op(:get_current_model, ref) do
      {RoundRobinModel.get_current_model(), RRRef.current_model(ref), ref}
    end

    defp apply_rr_op(:reset, ref) do
      {RoundRobinModel.reset(), :ok, RRRef.reset(ref)}
    end
  end

  # ── ModelAvailability State Machine ──────────────────────────────────────

  describe "ModelAvailability state machine" do
    setup do
      CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(ModelAvailability)
      ModelAvailability.reset_all()
      # Clean last_resort table for full test isolation
      for m <- ModelAvailability.get_last_resort_models(),
          do: ModelAvailability.mark_as_last_resort(m, false)

      :ok
    end

    # Pure reference model for ModelAvailability health state
    defmodule MARef do
      @moduledoc false
      # health: %{model_id => {:terminal, reason} | {:sticky_retry, reason, consumed}}
      # last_resort: MapSet of model_ids
      defstruct health: %{}, last_resort: MapSet.new()

      def new do
        %__MODULE__{}
      end

      def mark_terminal(ref, mid, reason),
        do: %{ref | health: Map.put(ref.health, mid, {:terminal, reason})}

      def mark_healthy(ref, mid),
        do: %{ref | health: Map.delete(ref.health, mid)}

      def mark_sticky_retry(ref, mid) do
        case Map.get(ref.health, mid) do
          {:terminal, _} ->
            ref

          {:sticky_retry, _, consumed} ->
            put_health_entry(ref, mid, {:sticky_retry, :retry_once_per_turn, consumed})

          nil ->
            put_health_entry(ref, mid, {:sticky_retry, :retry_once_per_turn, false})
        end
      end

      def consume_sticky(ref, mid) do
        case Map.get(ref.health, mid) do
          {:sticky_retry, reason, _} -> put_health_entry(ref, mid, {:sticky_retry, reason, true})
          _ -> ref
        end
      end

      def reset_turn(ref) do
        new_health =
          Map.new(ref.health, fn
            {mid, {:sticky_retry, reason, _}} -> {mid, {:sticky_retry, reason, false}}
            {mid, {:terminal, reason}} -> {mid, {:terminal, reason}}
          end)

        %{ref | health: new_health}
      end

      defp put_health_entry(ref, mid, entry), do: %{ref | health: Map.put(ref.health, mid, entry)}

      def reset_all(ref) do
        # reset_all clears health but NOT last_resort
        %{ref | health: %{}}
      end

      def mark_as_last_resort(ref, mid, true),
        do: %{ref | last_resort: MapSet.put(ref.last_resort, mid)}

      def mark_as_last_resort(ref, mid, false),
        do: %{ref | last_resort: MapSet.delete(ref.last_resort, mid)}

      def is_last_resort(ref, mid), do: MapSet.member?(ref.last_resort, mid)
      def get_last_resort_models(ref), do: ref.last_resort |> MapSet.to_list() |> Enum.sort()

      def snapshot(ref, mid) do
        case Map.get(ref.health, mid) do
          {:terminal, reason} -> %{available: false, reason: reason}
          {:sticky_retry, _, true} -> %{available: false, reason: :retry_once_per_turn}
          {:sticky_retry, _, false} -> %{available: true, reason: nil}
          nil -> %{available: true, reason: nil}
        end
      end
    end

    property "GenServer matches reference model for arbitrary operation sequences" do
      check all(
              ops <- list_of(ma_operation_gen(), min_length: 1, max_length: 80),
              max_runs: 50
            ) do
        ref = MARef.new()
        ModelAvailability.reset_all()
        # Clean last_resort table to match empty ref
        for m <- ModelAvailability.get_last_resort_models(),
            do: ModelAvailability.mark_as_last_resort(m, false)

        {final_ref, mismatches} =
          Enum.reduce(ops, {ref, []}, fn op, {ref, mismatches} ->
            {gs_result, ref_result, new_ref} = apply_ma_op(op, ref)

            if gs_result != ref_result do
              {new_ref, [{op, gs_result, ref_result} | mismatches]}
            else
              {new_ref, mismatches}
            end
          end)

        assert mismatches == [],
               "GenServer diverged from reference model: #{inspect(Enum.reverse(mismatches))}"

        # Final-state assertion: every touched model matches GenServer state,
        # including models that should now be healthy again.
        for model_id <- touched_model_ids(ops) do
          gs_snap = ModelAvailability.snapshot(model_id)
          ref_snap = MARef.snapshot(final_ref, model_id)

          assert gs_snap == ref_snap,
                 "Final state mismatch for #{inspect(model_id)}: GenServer=#{inspect(gs_snap)}, Ref=#{inspect(ref_snap)}"
        end

        # Final-state assertion: last_resort models match
        gs_lr = ModelAvailability.get_last_resort_models() |> Enum.sort()
        ref_lr = MARef.get_last_resort_models(final_ref)

        assert gs_lr == ref_lr,
               "Last resort mismatch: GenServer=#{inspect(gs_lr)}, Ref=#{inspect(ref_lr)}"
      end
    end

    # ── Invariant Properties ──────────────────────────────────────────────

    property "terminal status dominates sticky — mark_sticky on terminal is a no-op" do
      check all(
              mid <- string(:alphanumeric, min_length: 1, max_length: 10),
              reason <- one_of([constant(:quota), constant(:capacity)]),
              max_runs: 30
            ) do
        ModelAvailability.reset_all()
        ModelAvailability.mark_terminal(mid, reason)
        ModelAvailability.mark_sticky_retry(mid)
        snap = ModelAvailability.snapshot(mid)
        assert snap.available == false, "Terminal should remain unavailable after mark_sticky"
        assert snap.reason == reason
      end
    end

    property "consumed sticky stays unavailable until reset_turn" do
      check all(
              mid <- string(:alphanumeric, min_length: 1, max_length: 10),
              extra <- integer(0..3),
              max_runs: 30
            ) do
        ModelAvailability.reset_all()
        ModelAvailability.mark_sticky_retry(mid)
        assert ModelAvailability.snapshot(mid).available == true
        ModelAvailability.consume_sticky_attempt(mid)
        for _ <- 1..extra//1, do: ModelAvailability.consume_sticky_attempt(mid)

        assert ModelAvailability.snapshot(mid).available == false,
               "Consumed sticky should be unavailable"

        ModelAvailability.reset_turn()

        assert ModelAvailability.snapshot(mid).available == true,
               "After reset_turn, sticky should be available"
      end
    end

    property "reset_all clears health but not last-resort flags" do
      check all(
              mid <- string(:alphanumeric, min_length: 1, max_length: 10),
              max_runs: 30
            ) do
        ModelAvailability.reset_all()
        ModelAvailability.mark_terminal(mid, :quota)
        ModelAvailability.mark_as_last_resort(mid, true)
        assert ModelAvailability.snapshot(mid).available == false
        assert ModelAvailability.is_last_resort(mid) == true
        ModelAvailability.reset_all()
        assert ModelAvailability.snapshot(mid).available == true, "reset_all should clear health"

        assert ModelAvailability.is_last_resort(mid) == true,
               "reset_all should NOT clear last_resort"
      end
    end

    property "select_first_available never returns an unavailable model" do
      check all(
              models <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 1,
                  max_length: 5
                ),
              ops <- list_of(ma_multi_model_op_gen(models), max_length: 30),
              max_runs: 50
            ) do
        ModelAvailability.reset_all()

        # Apply random operations targeting the model set
        for op <- ops, do: apply_ma_mm_op(op)

        result = ModelAvailability.select_first_available(models)

        # Invariant: selected_model must be available (or nil if none are)
        if result.selected_model != nil do
          snap = ModelAvailability.snapshot(result.selected_model)

          assert snap.available == true,
                 "select_first_available returned #{inspect(result.selected_model)} which is not available: #{inspect(snap)}"
        end

        # Invariant: every skipped model must be genuinely unavailable
        for {skipped_id, reason} <- result.skipped do
          snap = ModelAvailability.snapshot(skipped_id)

          assert snap.available == false,
                 "select_first_available skipped #{inspect(skipped_id)} but it IS available: #{inspect(snap)}"

          assert snap.reason == reason,
                 "skip reason mismatch for #{inspect(skipped_id)}: expected #{inspect(reason)}, got #{inspect(snap.reason)}"
        end
      end
    end

    property "reset_turn does not restore terminal models" do
      check all(
              mid <- string(:alphanumeric, min_length: 1, max_length: 10),
              reason <- one_of([constant(:quota), constant(:capacity)]),
              max_runs: 20
            ) do
        ModelAvailability.reset_all()
        ModelAvailability.mark_terminal(mid, reason)
        ModelAvailability.reset_turn()
        snap = ModelAvailability.snapshot(mid)
        assert snap.available == false, "Terminal should survive reset_turn"
        assert snap.reason == reason
      end
    end

    property "mark_healthy clears any previous state" do
      check all(
              mid <- string(:alphanumeric, min_length: 1, max_length: 10),
              prior <- one_of([constant(:terminal), constant(:sticky)]),
              max_runs: 20
            ) do
        ModelAvailability.reset_all()

        if prior == :terminal,
          do: ModelAvailability.mark_terminal(mid, :quota),
          else: ModelAvailability.mark_sticky_retry(mid)

        ModelAvailability.mark_healthy(mid)
        snap = ModelAvailability.snapshot(mid)
        assert snap.available == true, "mark_healthy should make model available"
        assert snap.reason == nil
      end
    end

    # ── Focused Last-Resort Properties ───────────────────────────────────

    property "last_resort is independent of health state" do
      check all(
              mid <- string(:alphanumeric, min_length: 1, max_length: 10),
              max_runs: 30
            ) do
        ModelAvailability.reset_all()

        for m <- ModelAvailability.get_last_resort_models(),
            do: ModelAvailability.mark_as_last_resort(m, false)

        ModelAvailability.mark_terminal(mid, :quota)
        ModelAvailability.mark_as_last_resort(mid, true)
        assert ModelAvailability.snapshot(mid).available == false
        assert ModelAvailability.is_last_resort(mid) == true
        ModelAvailability.reset_all()
        assert ModelAvailability.snapshot(mid).available == true
        assert ModelAvailability.is_last_resort(mid) == true
        ModelAvailability.mark_as_last_resort(mid, false)
        assert ModelAvailability.is_last_resort(mid) == false
      end
    end

    property "mark_as_last_resort toggles and get_last_resort_models reflects current state" do
      check all(
              models <-
                list_of(string(:alphanumeric, min_length: 1, max_length: 8),
                  min_length: 1,
                  max_length: 5
                ),
              max_runs: 30
            ) do
        ModelAvailability.reset_all()

        for m <- ModelAvailability.get_last_resort_models(),
            do: ModelAvailability.mark_as_last_resort(m, false)

        expected_models = Enum.uniq(models)
        for m <- expected_models, do: ModelAvailability.mark_as_last_resort(m, true)
        assert Enum.sort(ModelAvailability.get_last_resort_models()) == Enum.sort(expected_models)
        ModelAvailability.mark_as_last_resort(hd(expected_models), false)

        assert Enum.sort(ModelAvailability.get_last_resort_models()) ==
                 Enum.sort(tl(expected_models))
      end
    end

    property "sticky retry on a last_resort model consumes correctly" do
      check all(
              mid <- string(:alphanumeric, min_length: 1, max_length: 10),
              max_runs: 20
            ) do
        ModelAvailability.reset_all()

        for m <- ModelAvailability.get_last_resort_models(),
            do: ModelAvailability.mark_as_last_resort(m, false)

        ModelAvailability.mark_as_last_resort(mid, true)
        ModelAvailability.mark_sticky_retry(mid)
        assert ModelAvailability.snapshot(mid).available == true
        assert ModelAvailability.is_last_resort(mid) == true
        ModelAvailability.consume_sticky_attempt(mid)
        assert ModelAvailability.snapshot(mid).available == false
        assert ModelAvailability.is_last_resort(mid) == true
        ModelAvailability.reset_turn()
        assert ModelAvailability.snapshot(mid).available == true
        assert ModelAvailability.is_last_resort(mid) == true
      end
    end

    # -- Generators & Helpers for ModelAvailability --

    defp ma_operation_gen do
      model_id = string(:alphanumeric, min_length: 1, max_length: 8)

      one_of([
        # mark_terminal
        tuple(
          {constant(:mark_terminal), model_id, one_of([constant(:quota), constant(:capacity)])}
        ),
        # mark_healthy
        tuple({constant(:mark_healthy), model_id}),
        # mark_sticky_retry
        tuple({constant(:mark_sticky_retry), model_id}),
        # consume_sticky
        tuple({constant(:consume_sticky), model_id}),
        # snapshot (verify state)
        tuple({constant(:snapshot), model_id}),
        # mark_as_last_resort
        tuple({constant(:mark_as_last_resort), model_id, boolean()}),
        # is_last_resort (verify state)
        tuple({constant(:is_last_resort), model_id}),
        # reset_turn
        constant(:reset_turn),
        # reset_all
        constant(:reset_all)
      ])
    end

    defp apply_ma_op({:mark_terminal, mid, r}, ref),
      do: {ModelAvailability.mark_terminal(mid, r), :ok, MARef.mark_terminal(ref, mid, r)}

    defp apply_ma_op({:mark_healthy, mid}, ref),
      do: {ModelAvailability.mark_healthy(mid), :ok, MARef.mark_healthy(ref, mid)}

    defp apply_ma_op({:mark_sticky_retry, mid}, ref),
      do: {ModelAvailability.mark_sticky_retry(mid), :ok, MARef.mark_sticky_retry(ref, mid)}

    defp apply_ma_op({:consume_sticky, mid}, ref),
      do: {ModelAvailability.consume_sticky_attempt(mid), :ok, MARef.consume_sticky(ref, mid)}

    defp apply_ma_op({:snapshot, mid}, ref),
      do: {ModelAvailability.snapshot(mid), MARef.snapshot(ref, mid), ref}

    defp apply_ma_op(:reset_turn, ref),
      do: {ModelAvailability.reset_turn(), :ok, MARef.reset_turn(ref)}

    defp apply_ma_op(:reset_all, ref),
      do: {ModelAvailability.reset_all(), :ok, MARef.reset_all(ref)}

    defp apply_ma_op({:mark_as_last_resort, mid, val}, ref),
      do:
        {ModelAvailability.mark_as_last_resort(mid, val), :ok,
         MARef.mark_as_last_resort(ref, mid, val)}

    defp apply_ma_op({:is_last_resort, mid}, ref),
      do: {ModelAvailability.is_last_resort(mid), MARef.is_last_resort(ref, mid), ref}

    defp touched_model_ids(ops) do
      ops
      |> Enum.flat_map(fn
        {:mark_terminal, model_id, _reason} -> [model_id]
        {:mark_healthy, model_id} -> [model_id]
        {:mark_sticky_retry, model_id} -> [model_id]
        {:consume_sticky, model_id} -> [model_id]
        {:snapshot, model_id} -> [model_id]
        {:mark_as_last_resort, model_id, _flag} -> [model_id]
        {:is_last_resort, model_id} -> [model_id]
        :reset_turn -> []
        :reset_all -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()
    end

    # Apply a multi-model operation (for select_first_available testing)
    defp apply_ma_mm_op({:mark_terminal, mid, r}), do: ModelAvailability.mark_terminal(mid, r)
    defp apply_ma_mm_op({:mark_healthy, mid}), do: ModelAvailability.mark_healthy(mid)
    defp apply_ma_mm_op({:mark_sticky_retry, mid}), do: ModelAvailability.mark_sticky_retry(mid)
    defp apply_ma_mm_op({:consume_sticky, mid}), do: ModelAvailability.consume_sticky_attempt(mid)
    defp apply_ma_mm_op(:reset_turn), do: ModelAvailability.reset_turn()
    defp apply_ma_mm_op(:reset_all), do: ModelAvailability.reset_all()

    defp ma_multi_model_op_gen(models) do
      one_of([
        tuple(
          {constant(:mark_terminal), member_of(models),
           one_of([constant(:quota), constant(:capacity)])}
        ),
        tuple({constant(:mark_healthy), member_of(models)}),
        tuple({constant(:mark_sticky_retry), member_of(models)}),
        tuple({constant(:consume_sticky), member_of(models)}),
        constant(:reset_turn),
        constant(:reset_all)
      ])
    end
  end
end
