defmodule CodePuppyControl.SessionStorage.AutosaveTracker do
  @moduledoc """
  Tracks autosave debounce and deduplication state.

  Mirrors the Python module-level globals (`_last_autosave_len`,
  `_last_autosave_hash`, `_last_autosave_time`) from
  `session_storage.py:34-68`.

  Implemented as an `Agent` for simplicity — the state is a single map
  updated atomically. Accepts an injectable `time_fn` for deterministic
  testing (see `start_link/1` options).

  ## State

      %{
        last_len: non_neg_integer(),
        last_hash: String.t(),
        last_time: integer(),  # monotonic milliseconds
        initialized: boolean(),
        time_fn: time_fn()
      }

  ## Debounce window

  2 seconds, matching Python's `AUTOSAVE_DEBOUNCE_SECONDS`.
  """

  use Agent

  @debounce_ms 2_000

  # ---------------------------------------------------------------------------
  # Types
  # ---------------------------------------------------------------------------

  @type time_fn :: (-> integer())

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts the AutosaveTracker agent.

  ## Options

    * `:name` — registration name (default: `__MODULE__`)
    * `:time_fn` — function returning monotonic time in ms
      (default: `fn -> System.monotonic_time(:millisecond) end`)

  Pass a custom `time_fn` in tests to control the clock without sleeps.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    time_fn = Keyword.get(opts, :time_fn, &default_time_fn/0)

    initial_state = %{
      last_len: 0,
      last_hash: "",
      last_time: 0,
      initialized: false,
      time_fn: time_fn
    }

    Agent.start_link(fn -> initial_state end, name: name)
  end

  @doc """
  Returns `true` if the autosave should be skipped.

  Skips when:
  1. The debounce window (2 s) has not elapsed since the last save, OR
  2. The history fingerprint (length + hash) is unchanged.

  A fresh tracker (no prior saves) always returns `false`.
  """
  @spec should_skip_autosave?([map()], GenServer.server()) :: boolean()
  def should_skip_autosave?(history, tracker \\ __MODULE__) do
    Agent.get(tracker, fn state ->
      # No prior save — never skip
      unless state.initialized do
        false
      else
        now = state.time_fn.()

        # Debounce check
        if now - state.last_time < @debounce_ms do
          true
        else
          {len, hash} = compute_fingerprint(history)
          len == state.last_len and hash == state.last_hash
        end
      end
    end)
  end

  @doc """
  Records that an autosave has completed.

  Updates the tracker with the history fingerprint and current timestamp.
  """
  @spec mark_autosave_complete([map()], GenServer.server()) :: :ok
  def mark_autosave_complete(history, tracker \\ __MODULE__) do
    Agent.update(tracker, fn state ->
      now = state.time_fn.()
      {len, hash} = compute_fingerprint(history)

      %{state | last_len: len, last_hash: hash, last_time: now, initialized: true}
    end)
  end

  # ---------------------------------------------------------------------------
  # Child spec for supervision tree
  # ---------------------------------------------------------------------------

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @spec default_time_fn :: integer()
  defp default_time_fn, do: System.monotonic_time(:millisecond)

  @spec compute_fingerprint([map()]) :: {non_neg_integer(), String.t()}
  defp compute_fingerprint([]), do: {0, ""}

  defp compute_fingerprint(history) do
    len = length(history)
    last_msg = List.last(history)

    hash =
      last_msg
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    {len, hash}
  end
end
