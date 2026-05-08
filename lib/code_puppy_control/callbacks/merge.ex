defmodule CodePuppyControl.Callbacks.Merge do
  @moduledoc """
  Pure merge logic for combining callback results.

  Merge semantics (ported from Python `code_puppy/callbacks.py`):

  | Type | Strategy | Description |
  |------|----------|-------------|
  | `str` | `:concat_str` | Concatenate with newlines |
  | `list` | `:extend_list` | Flatten into one list |
  | `dict/map` | `:update_map` | Deep-merge, later wins on conflict |
  | `bool` | `:or_bool` | OR — any True wins |
  | `nil` | (skipped) | `nil` results are ignored |

  Callbacks that crash return `:callback_failed` sentinel (replacing `_CALLBACK_FAILED`
  in the Python implementation). Error sentinels are filtered out before merging
  for typed strategies (:concat_str, :extend_list, :update_map, :or_bool).
  For :noop strategy, :callback_failed is preserved in results (Python behavior).
  """

  @typedoc "Sentinel value returned when a callback crashes"
  @type error_sentinel :: :callback_failed

  @doc """
  Merges a list of callback results according to the given strategy.

  For typed strategies, filters out `nil` and `:callback_failed` before merging.
  For `:noop`, filters only `nil` (preserving `:callback_failed` sentinels).

  ## Examples

      iex> CodePuppyControl.Callbacks.Merge.merge_results(["hello", "world"], :concat_str)
      "hello\\nworld"

      iex> CodePuppyControl.Callbacks.Merge.merge_results([[1, 2], [3, 4]], :extend_list)
      [1, 2, 3, 4]

      iex> CodePuppyControl.Callbacks.Merge.merge_results([%{a: 1}, %{b: 2}], :update_map)
      %{a: 1, b: 2}

      iex> CodePuppyControl.Callbacks.Merge.merge_results([true, false, nil], :or_bool)
      true

      iex> CodePuppyControl.Callbacks.Merge.merge_results([nil, nil], :concat_str)
      nil
  """
  @spec merge_results([term()], atom()) :: term()
  def merge_results(results, strategy)

  def merge_results(results, :noop) do
    # For :noop, filter nil. Preserve :callback_failed in multi-valued results,
    # but prefer a real value when it is the only non-error value.
    non_nil = Enum.filter(results, &(&1 != nil))
    real = Enum.reject(non_nil, &(&1 == :callback_failed))

    case {non_nil, real} do
      {[], _} -> nil
      {[single], _} -> single
      {_, [only_real]} -> only_real
      {multiple, _} -> multiple
    end
  end

  def merge_results(results, :concat_str) do
    results
    |> filter_valid()
    |> Enum.filter(&is_binary/1)
    |> case do
      [] -> nil
      [single] -> single
      strs -> Enum.join(strs, "\n")
    end
  end

  def merge_results(results, :extend_list) do
    results
    |> filter_valid()
    |> Enum.filter(&is_list/1)
    |> case do
      [] -> nil
      [single] -> single
      lists -> List.flatten(lists)
    end
  end

  def merge_results(results, :update_map) do
    results
    |> filter_valid()
    |> Enum.filter(&is_map/1)
    |> case do
      [] -> nil
      [single] -> single
      maps -> Enum.reduce(maps, %{}, fn elem, acc -> deep_merge(acc, elem) end)
    end
  end

  def merge_results(results, :or_bool) do
    results
    |> filter_valid()
    |> Enum.filter(&is_boolean/1)
    |> case do
      [] -> nil
      [single] -> single
      bools -> Enum.any?(bools)
    end
  end

  @doc """
  Filters out `nil` and `:callback_failed` sentinel values from results.

  Returns only valid (non-nil, non-error) results.

  ## Examples

      iex> CodePuppyControl.Callbacks.Merge.filter_valid([1, nil, :callback_failed, 2])
      [1, 2]

      iex> CodePuppyControl.Callbacks.Merge.filter_valid([nil, :callback_failed])
      []
  """
  @spec filter_valid([term()]) :: [term()]
  def filter_valid(results) when is_list(results) do
    Enum.filter(results, fn
      nil -> false
      :callback_failed -> false
      _ -> true
    end)
  end

  @doc """
  Deep-merges two maps. The second map's values take precedence on conflict.

  Nested maps are merged recursively; other values are overwritten.

  ## Examples

      iex> CodePuppyControl.Callbacks.Merge.deep_merge(%{a: %{x: 1}}, %{a: %{y: 2}})
      %{a: %{x: 1, y: 2}}

      iex> CodePuppyControl.Callbacks.Merge.deep_merge(%{a: 1}, %{a: 2})
      %{a: 2}
  """
  @spec deep_merge(map(), map()) :: map()
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  def deep_merge(_left, right), do: right

  @doc """
  Returns the error sentinel value used when a callback crashes.
  """
  @spec error_sentinel() :: :callback_failed
  def error_sentinel, do: :callback_failed
end
