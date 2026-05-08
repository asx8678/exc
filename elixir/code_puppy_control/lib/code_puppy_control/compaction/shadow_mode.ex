defmodule CodePuppyControl.Compaction.ShadowMode do
  @moduledoc """
  Shadow mode utilities for compaction validation.

  Runs both an "old" (baseline) and "new" (compaction) pruning path,
  then logs differences without applying the new path's results.
  This allows safe validation of compaction changes before full rollout.

  Feature-flagged via opts — disabled by default.

  Port of `code_puppy/compaction/shadow_mode.py`.

  ## Usage

      ShadowMode.compare_and_log(
        messages,
        old_result: prune_result_old,
        new_result: prune_result_new,
        enabled: true
      )
  """

  require Logger

  @doc """
  Compare old and new pruning results and log differences.

  Only logs when `enabled: true`. Compares surviving message counts
  and reports any discrepancy.

  ## Options

    * `:enabled` — Whether to perform comparison (default: `false`)
    * `:old_result` — Result from baseline pruner (map with `:surviving_indices`)
    * `:new_result` — Result from new/compaction pruner
    * `:label` — Label for log messages (default: `"shadow-mode"`)

  Returns `:ok` or `{:warning, message}` if a mismatch was detected.
  """
  @spec compare_and_log([map()], keyword()) :: :ok | {:warning, String.t()}
  def compare_and_log(_messages, opts \\ []) do
    enabled = Keyword.get(opts, :enabled, false)

    if not enabled do
      :ok
    else
      do_compare(opts)
    end
  end

  @doc """
  Hash messages and compare old/new hash sets for consistency.

  Checks that the same number of unique hashes are produced by both paths.
  Only logs when `enabled: true`.
  """
  @spec compare_hashes([map()], keyword()) :: :ok | {:warning, String.t()}
  def compare_hashes(_messages, opts \\ []) do
    enabled = Keyword.get(opts, :enabled, false)

    if not enabled do
      :ok
    else
      do_compare_hashes(opts)
    end
  end

  @doc """
  Check if shadow mode is enabled via application config.

  Reads from `:code_puppy_control, :shadow_mode_enabled` (default: false).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:code_puppy_control, :shadow_mode_enabled, false)
  end

  # --- Private ---

  defp do_compare(opts) do
    label = Keyword.get(opts, :label, "shadow-mode")
    old_result = Keyword.get(opts, :old_result, %{})
    new_result = Keyword.get(opts, :new_result, %{})

    old_count = length(Map.get(old_result, :surviving_indices, []))
    new_count = length(Map.get(new_result, :surviving_indices, []))

    if old_count != new_count do
      msg =
        "[#{label}] prune_and_filter mismatch: " <>
          "old kept #{old_count} messages, new kept #{new_count} messages. " <>
          "old dropped=#{Map.get(old_result, :dropped_count, 0)}, " <>
          "new dropped=#{Map.get(new_result, :dropped_count, 0)}"

      Logger.warning(msg)
      {:warning, msg}
    else
      Logger.debug("[#{label}] prune_and_filter match: #{old_count} messages")
      :ok
    end
  end

  defp do_compare_hashes(opts) do
    label = Keyword.get(opts, :label, "shadow-mode")
    old_hashes = Keyword.get(opts, :old_hashes, [])
    new_hashes = Keyword.get(opts, :new_hashes, [])

    if length(old_hashes) != length(new_hashes) do
      msg =
        "[#{label}] hash_batch length mismatch: " <>
          "old=#{length(old_hashes)}, new=#{length(new_hashes)}"

      Logger.warning(msg)
      {:warning, msg}
    else
      old_unique = old_hashes |> MapSet.new() |> MapSet.size()
      new_unique = new_hashes |> MapSet.new() |> MapSet.size()

      if old_unique != new_unique do
        msg =
          "[#{label}] hash uniqueness mismatch: " <>
            "old has #{old_unique} unique, new has #{new_unique} unique"

        Logger.warning(msg)
        {:warning, msg}
      else
        Logger.debug(
          "[#{label}] hash_batch match: #{length(old_hashes)} hashes, #{old_unique} unique"
        )

        :ok
      end
    end
  end
end
