defmodule CodePuppyControl.CLI.Smoke.MockLLM do
  @moduledoc """
  Deterministic, no-network mock implementation of
  `CodePuppyControl.Agent.LLM` used by `mix pup_ex.smoke`.

  Lives in `lib/` (not `test/support/`) so the Mix task can reach it
  without the test-only elixirc path.  This module **never** makes
  network calls and **never** persists user-visible state — it is a
  pure stub used by the dogfood smoke runner before daily-driver use.

  ## Wiring

  The smoke runner injects this module via the
  `:repl_llm_module` Application env (the same hook used by
  `CodePuppyControl.CLI.OneShotMockLLM` in tests):

      Application.put_env(:code_puppy_control, :repl_llm_module,
                          CodePuppyControl.CLI.Smoke.MockLLM)

  The Smoke runner is responsible for restoring the previous value
  on teardown.

  ## Determinism

  Per the audit `PUP_*` naming convention, callers may override the
  canned reply via `PUP_SMOKE_MOCK_REPLY`.  Defaults to
  `\"smoke ok — no network\"`.  The module records the number of
  invocations in `:persistent_term` so the smoke runner can assert
  the LLM was actually exercised.  No GenServer is started — that
  keeps the mock usable in nano contexts where the supervision tree
  may not be fully booted.

  Refs: code_puppy-baa
  """

  @behaviour CodePuppyControl.Agent.LLM

  @default_reply "smoke ok — no network"

  @counter_key {__MODULE__, :invocation_count}
  @last_opts_key {__MODULE__, :last_opts}

  @doc """
  Reset the invocation counter and last-opts cache.

  Call from the Smoke runner before exercising the one-shot path so
  assertions are not contaminated by earlier runs.
  """
  @spec reset() :: :ok
  def reset do
    :persistent_term.put(@counter_key, 0)
    :persistent_term.erase(@last_opts_key)
    :ok
  end

  @doc """
  Number of times `stream_chat/4` has been invoked since the last
  `reset/0` (or process start).
  """
  @spec invocation_count() :: non_neg_integer()
  def invocation_count do
    :persistent_term.get(@counter_key, 0)
  end

  @doc """
  Returns the keyword opts the last `stream_chat/4` call observed,
  or `nil` if no call has been made.
  """
  @spec last_opts() :: keyword() | nil
  def last_opts do
    :persistent_term.get(@last_opts_key, nil)
  end

  @doc """
  Returns the canned reply text the mock will emit.

  Resolution order:

  1. `PUP_SMOKE_MOCK_REPLY` env var (if non-empty)
  2. `#{inspect(@default_reply)}` fallback
  """
  @spec canned_reply() :: String.t()
  def canned_reply do
    case System.get_env("PUP_SMOKE_MOCK_REPLY") do
      nil -> @default_reply
      "" -> @default_reply
      value -> value
    end
  end

  # ── Behaviour callback ──────────────────────────────────────────────

  @impl true
  def stream_chat(_messages, _tools, opts, callback_fn) do
    text = canned_reply()

    new_count = :persistent_term.get(@counter_key, 0) + 1
    :persistent_term.put(@counter_key, new_count)
    :persistent_term.put(@last_opts_key, opts)

    callback_fn.({:text, text})
    callback_fn.({:done, :complete})

    {:ok, %{text: text, tool_calls: []}}
  end
end
