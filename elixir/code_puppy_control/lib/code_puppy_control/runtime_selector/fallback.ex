defmodule CodePuppyControl.RuntimeSelector.Fallback do
  @moduledoc """
  Auto-fallback wrapper for runtime selection.

  Executes a function with the selected runtime for a given capability.
  If it fails (raises or returns `{:error, _}`), automatically retries
  with the alternative runtime.

  The runtime is selected via `RuntimeSelector.select_runtime/1` so the
  selection respects the current mode (`:python`, `:elixir`, or `:auto` with
  per-capability feature flags).

  ## Usage

      {:ok, result, runtime} = Fallback.with_fallback(:file_ops, fn
        :elixir -> ElixirBackend.run()
        :python -> PythonBackend.run()
      end)

  Telemetry events are emitted at `[:code_puppy, :runtime, :fallback]` with
  metadata `%{event: :success | :fallback | :fallback_success | :fallback_failed,
  capability: atom(), runtime: atom(), reason: term() | nil}`.
  """

  alias CodePuppyControl.RuntimeSelector

  @doc """
  Execute `fun` with the selected runtime for `capability`.

  If the primary runtime fails (raises or returns `{:error, _}`), retries
  with the alternative runtime. If both fail, returns an error with both
  reasons.

  Returns `{:ok, result, runtime_used}` on success, or
  `{:error, {:both_runtimes_failed, primary: reason, secondary: reason2}}`
  if both runtimes fail.

  ## Telemetry

  Emits the following events at `[:code_puppy, :runtime, :fallback]`:

    * `{:success, capability, primary, nil}` — primary runtime succeeded
    * `{:fallback, capability, primary, reason}` — primary failed, trying secondary
    * `{:fallback_success, capability, secondary, nil}` — secondary succeeded
    * `{:fallback_failed, capability, secondary, reason}` — both failed
  """
  @spec with_fallback(atom(), (atom() -> any())) :: {:ok, any(), atom()} | {:error, any()}
  def with_fallback(capability, fun) when is_atom(capability) and is_function(fun, 1) do
    primary = RuntimeSelector.select_runtime(capability)

    case try_runtime(primary, fun) do
      {:ok, result} ->
        emit_telemetry(:success, capability, primary, nil)
        {:ok, result, primary}

      {:error, reason} ->
        secondary = other_runtime(primary)
        emit_telemetry(:fallback, capability, primary, reason)

        case try_runtime(secondary, fun) do
          {:ok, result} ->
            emit_telemetry(:fallback_success, capability, secondary, nil)
            {:ok, result, secondary}

          {:error, reason2} ->
            emit_telemetry(:fallback_failed, capability, secondary, reason2)
            {:error, {:both_runtimes_failed, primary: reason, secondary: reason2}}
        end
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────

  @doc false
  # Try executing `fun` with the given `runtime`.
  #
  # Returns `{:ok, result}` if the function succeeds (or returns
  # `{:ok, _}`), or `{:error, reason}` if the function returns
  # `{:error, _}`, raises, or throws.
  defp try_runtime(runtime, fun) do
    case fun.(runtime) do
      {:error, reason} ->
        {:error, reason}

      result ->
        {:ok, result}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, value -> {:error, {kind, value}}
  end

  # Return the alternative runtime for the given one.
  defp other_runtime(:python), do: :elixir
  defp other_runtime(:elixir), do: :python

  # Emit a telemetry event for the fallback lifecycle.
  defp emit_telemetry(event, capability, runtime, reason) do
    :telemetry.execute(
      [:code_puppy, :runtime, :fallback],
      %{},
      %{event: event, capability: capability, runtime: runtime, reason: reason}
    )
  end
end
