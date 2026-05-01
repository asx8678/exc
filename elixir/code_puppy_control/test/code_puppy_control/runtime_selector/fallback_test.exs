defmodule CodePuppyControl.RuntimeSelector.FallbackTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.RuntimeSelector
  alias CodePuppyControl.RuntimeSelector.Fallback

  @fallback_event [:code_puppy, :runtime, :fallback]

  setup do
    # Ensure a named RuntimeSelector GenServer is running for
    # Fallback.with_fallback/2 to call select_runtime/1 on.
    case Process.whereis(RuntimeSelector) do
      nil ->
        start_supervised!({RuntimeSelector, name: RuntimeSelector})

      _pid ->
        :ok
    end

    # Default to :auto mode so capabilities go through feature flags.
    # Tests that need explicit modes will call set_mode/1.
    RuntimeSelector.set_mode(:auto)

    on_exit(fn ->
      RuntimeSelector.set_mode(:auto)
    end)

    :ok
  end

  describe "with_fallback/2 — primary success path" do
    test "primary :elixir succeeds → returns result with :elixir runtime" do
      RuntimeSelector.set_mode(:elixir)

      {:ok, result, runtime} =
        Fallback.with_fallback(:llm_client, fn
          :elixir -> "elixir_data"
          :python -> "python_data"
        end)

      assert result == "elixir_data"
      assert runtime == :elixir
    end

    test "primary :python succeeds → returns result with :python runtime" do
      RuntimeSelector.set_mode(:python)

      {:ok, result, runtime} =
        Fallback.with_fallback(:llm_client, fn
          :elixir -> "elixir_data"
          :python -> "python_data"
        end)

      assert result == "python_data"
      assert runtime == :python
    end

    test "primary succeeds with {:ok, _} return from function" do
      RuntimeSelector.set_mode(:elixir)

      {:ok, result, runtime} =
        Fallback.with_fallback(:tools, fn
          :elixir -> {:ok, "wrapped_data"}
          :python -> {:ok, "fallback_data"}
        end)

      assert result == {:ok, "wrapped_data"}
      assert runtime == :elixir
    end

    test "auto mode with feature flag enabled → elixir path" do
      CodePuppyControl.FeatureFlags.set(:llm_client, true, source: :test)
      RuntimeSelector.set_mode(:auto)

      {:ok, result, runtime} =
        Fallback.with_fallback(:llm_client, fn
          :elixir -> "elixir_result"
          :python -> "python_result"
        end)

      assert result == "elixir_result"
      assert runtime == :elixir
    end
  end

  describe "with_fallback/2 — fallback success path" do
    test "primary raises → fallback to secondary succeeds" do
      RuntimeSelector.set_mode(:elixir)

      {:ok, result, runtime} =
        Fallback.with_fallback(:tools, fn
          :elixir -> raise("primary_broken")
          :python -> "saved_by_python"
        end)

      assert result == "saved_by_python"
      assert runtime == :python
    end

    test "primary returns {:error, _} → fallback to secondary succeeds" do
      RuntimeSelector.set_mode(:elixir)

      {:ok, result, runtime} =
        Fallback.with_fallback(:cli, fn
          :elixir -> {:error, "primary_error"}
          :python -> "recovered"
        end)

      assert result == "recovered"
      assert runtime == :python
    end

    test "primary throws → fallback to secondary succeeds" do
      RuntimeSelector.set_mode(:elixir)

      {:ok, result, runtime} =
        Fallback.with_fallback(:base_agent, fn
          :elixir -> throw(:kaboom)
          :python -> "caught"
        end)

      assert result == "caught"
      assert runtime == :python
    end

    test "python primary fails → fallback to elixir succeeds" do
      RuntimeSelector.set_mode(:python)

      {:ok, result, runtime} =
        Fallback.with_fallback(:plugins, fn
          :elixir -> "elixir_saves_the_day"
          :python -> {:error, "python_broken"}
        end)

      assert result == "elixir_saves_the_day"
      assert runtime == :elixir
    end
  end

  describe "with_fallback/2 — both fail" do
    test "both raise → returns error with both reasons" do
      RuntimeSelector.set_mode(:elixir)

      {:error, {:both_runtimes_failed, reasons}} =
        Fallback.with_fallback(:llm_client, fn
          :elixir -> raise("primary_crash")
          :python -> raise("secondary_crash")
        end)

      assert reasons[:primary] == "primary_crash"
      assert reasons[:secondary] == "secondary_crash"
    end

    test "both return {:error, _} → returns error with both reasons" do
      RuntimeSelector.set_mode(:elixir)

      {:error, {:both_runtimes_failed, reasons}} =
        Fallback.with_fallback(:tools, fn
          :elixir -> {:error, "e_fail"}
          :python -> {:error, "p_fail"}
        end)

      assert reasons[:primary] == "e_fail"
      assert reasons[:secondary] == "p_fail"
    end

    test "primary raises, secondary returns {:error, _} → both captured" do
      RuntimeSelector.set_mode(:elixir)

      {:error, {:both_runtimes_failed, reasons}} =
        Fallback.with_fallback(:cli, fn
          :elixir -> raise("boom")
          :python -> {:error, "also_bad"}
        end)

      assert reasons[:primary] == "boom"
      assert reasons[:secondary] == "also_bad"
    end

    test "primary throws, secondary raises → both captured" do
      RuntimeSelector.set_mode(:elixir)

      {:error, {:both_runtimes_failed, reasons}} =
        Fallback.with_fallback(:plugins, fn
          :elixir -> throw(:primary_throw)
          :python -> raise("python_raise")
        end)

      assert reasons[:primary] == {:throw, :primary_throw}
      assert reasons[:secondary] == "python_raise"
    end
  end

  describe "with_fallback/2 — telemetry" do
    test "primary success emits :success event" do
      RuntimeSelector.set_mode(:elixir)
      test_pid = self()

      :telemetry.attach_many(
        "fallback-test-success",
        [@fallback_event],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:fallback_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("fallback-test-success")
      end)

      {:ok, _result, _runtime} =
        Fallback.with_fallback(:llm_client, fn
          :elixir -> "ok"
          :python -> "nope"
        end)

      assert_receive {:fallback_telemetry, %{},
                      %{event: :success, capability: :llm_client, runtime: :elixir, reason: nil}}

      refute_receive {:fallback_telemetry, _, _}, 50
    end

    test "fallback success emits :fallback then :fallback_success" do
      RuntimeSelector.set_mode(:elixir)
      test_pid = self()

      :telemetry.attach_many(
        "fallback-test-fallback-success",
        [@fallback_event],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:fb, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("fallback-test-fallback-success")
      end)

      {:ok, _result, _runtime} =
        Fallback.with_fallback(:tools, fn
          :elixir -> {:error, "e_fail"}
          :python -> "recovered"
        end)

      # First: fallback event (primary failed)
      assert_receive {:fb, %{},
                      %{event: :fallback, capability: :tools, runtime: :elixir, reason: "e_fail"}}

      # Second: fallback_success event (secondary succeeded)
      assert_receive {:fb, %{},
                      %{
                        event: :fallback_success,
                        capability: :tools,
                        runtime: :python,
                        reason: nil
                      }}

      refute_receive {:fb, _, _}, 50
    end

    test "both fail emits :fallback then :fallback_failed" do
      RuntimeSelector.set_mode(:elixir)
      test_pid = self()

      :telemetry.attach_many(
        "fallback-test-both-fail",
        [@fallback_event],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:fb, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("fallback-test-both-fail")
      end)

      {:error, _} =
        Fallback.with_fallback(:cli, fn
          :elixir -> {:error, "e_dead"}
          :python -> raise("p_broken")
        end)

      # First: fallback event (primary failed)
      assert_receive {:fb, %{},
                      %{event: :fallback, capability: :cli, runtime: :elixir, reason: "e_dead"}}

      # Second: fallback_failed event (secondary also failed)
      assert_receive {:fb, %{},
                      %{
                        event: :fallback_failed,
                        capability: :cli,
                        runtime: :python,
                        reason: "p_broken"
                      }}

      refute_receive {:fb, _, _}, 50
    end

    test "each capability scopes its own telemetry" do
      RuntimeSelector.set_mode(:elixir)
      test_pid = self()

      :telemetry.attach_many(
        "fallback-test-capabilities",
        [@fallback_event],
        fn _name, _measurements, metadata, _config ->
          send(test_pid, {:cap_fb, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("fallback-test-capabilities")
      end)

      # First call with :llm_client
      {:ok, _, _} =
        Fallback.with_fallback(:llm_client, fn
          :elixir -> "ok"
          :python -> "nope"
        end)

      # Second call with :tools — this one bounces
      {:ok, _, _} =
        Fallback.with_fallback(:tools, fn
          :elixir -> {:error, "e_fail"}
          :python -> "recovered"
        end)

      # :llm_client success
      assert_receive {:cap_fb, %{event: :success, capability: :llm_client, runtime: :elixir}}

      # :tools fallback events
      assert_receive {:cap_fb, %{event: :fallback, capability: :tools, runtime: :elixir}}
      assert_receive {:cap_fb, %{event: :fallback_success, capability: :tools, runtime: :python}}

      refute_receive {:cap_fb, _}, 50
    end
  end

  describe "with_fallback/2 — guard clauses" do
    test "raises if first argument is not an atom" do
      assert_raise FunctionClauseError, fn ->
        Fallback.with_fallback("not_an_atom", fn _ -> :ok end)
      end
    end

    test "raises if second argument is not a function" do
      assert_raise FunctionClauseError, fn ->
        Fallback.with_fallback(:llm_client, :not_a_function)
      end
    end
  end
end
