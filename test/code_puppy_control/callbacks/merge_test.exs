defmodule CodePuppyControl.Callbacks.MergeTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Callbacks.Merge

  doctest Merge

  describe "merge_results/2 with :concat_str" do
    test "concatenates string results with newlines" do
      assert "hello\nworld" = Merge.merge_results(["hello", "world"], :concat_str)
    end

    test "returns nil for empty list" do
      assert nil == Merge.merge_results([], :concat_str)
    end

    test "returns nil when all values are nil" do
      assert nil == Merge.merge_results([nil, nil], :concat_str)
    end

    test "filters out non-string and nil values" do
      assert "hello" = Merge.merge_results(["hello", nil, 42], :concat_str)
    end

    test "returns single string unchanged" do
      assert "hello" = Merge.merge_results(["hello"], :concat_str)
    end

    test "filters out callback_failed sentinel" do
      assert "hello
world" =
               Merge.merge_results(["hello", :callback_failed, "world"], :concat_str)
    end
  end

  describe "merge_results/2 with :extend_list" do
    test "flattens list results into one list" do
      assert [1, 2, 3, 4] = Merge.merge_results([[1, 2], [3, 4]], :extend_list)
    end

    test "returns nil for empty list" do
      assert nil == Merge.merge_results([], :extend_list)
    end

    test "returns nil when all values are nil" do
      assert nil == Merge.merge_results([nil, nil], :extend_list)
    end

    test "filters out non-list and nil values" do
      assert [1, 2] = Merge.merge_results([[1, 2], nil, "string"], :extend_list)
    end

    test "handles single list" do
      assert [1, 2] = Merge.merge_results([[1, 2]], :extend_list)
    end

    test "handles nested lists" do
      assert [1, 2, 3] = Merge.merge_results([[1, [2]], [3]], :extend_list)
    end

    test "handles callback_failed sentinel" do
      assert [1, 2] = Merge.merge_results([[1], :callback_failed, [2]], :extend_list)
    end
  end

  describe "merge_results/2 with :update_map" do
    test "merges maps with later values winning on conflict" do
      assert %{a: 1, b: 2} =
               Merge.merge_results([%{a: 1}, %{b: 2}], :update_map)
    end

    test "later values override earlier on key conflict" do
      result = Merge.merge_results([%{a: 1}, %{a: 2}], :update_map)
      assert result == %{a: 2}
    end

    test "deep merges nested maps" do
      assert %{a: %{x: 1, y: 2}} =
               Merge.merge_results(
                 [%{a: %{x: 1}}, %{a: %{y: 2}}],
                 :update_map
               )
    end

    test "returns nil for empty list" do
      assert nil == Merge.merge_results([], :update_map)
    end

    test "returns nil when all values are nil" do
      assert nil == Merge.merge_results([nil, nil], :update_map)
    end

    test "filters out non-map values" do
      assert %{a: 1} = Merge.merge_results([%{a: 1}, nil, "string"], :update_map)
    end

    test "handles callback_failed sentinel" do
      assert %{a: 1, b: 2} =
               Merge.merge_results([%{a: 1}, :callback_failed, %{b: 2}], :update_map)
    end

    test "load_models_config: dict/map returns are preserved (not dropped)" do
      # Simulates load_models_config with map-returns — maps must not be
      # silently dropped like they would be with :extend_list merge.
      result =
        Merge.merge_results(
          [%{"gpt-4" => %{type: "openai"}}, %{"claude-3" => %{type: "anthropic"}}],
          :update_map
        )

      assert %{"gpt-4" => %{type: "openai"}, "claude-3" => %{type: "anthropic"}} = result
    end
  end

  describe "merge_results/2 with :or_bool" do
    test "returns true when any value is true" do
      assert true = Merge.merge_results([false, true, false], :or_bool)
    end

    test "returns false when all values are false" do
      assert false == Merge.merge_results([false, false], :or_bool)
    end

    test "returns nil for empty list" do
      assert nil == Merge.merge_results([], :or_bool)
    end

    test "returns nil when all values are nil" do
      assert nil == Merge.merge_results([nil, nil], :or_bool)
    end

    test "filters out non-boolean values" do
      assert true = Merge.merge_results([true, nil, "string"], :or_bool)
    end

    test "handles single true" do
      assert true = Merge.merge_results([true], :or_bool)
    end

    test "handles callback_failed sentinel" do
      assert true = Merge.merge_results([false, :callback_failed, true], :or_bool)
    end
  end

  describe "merge_results/2 with :noop" do
    test "returns single value unchanged" do
      assert 42 = Merge.merge_results([42], :noop)
    end

    test "returns list of values when multiple" do
      result = Merge.merge_results([1, 2, 3], :noop)
      assert is_list(result)
      assert length(result) == 3
    end

    test "returns nil for empty list" do
      assert nil == Merge.merge_results([], :noop)
    end

    test "filters out nil but preserves callback_failed for single value" do
      assert 42 = Merge.merge_results([nil, :callback_failed, 42], :noop)
    end

    test "returns multiple non-nil values including callback_failed as list" do
      result = Merge.merge_results([1, nil, :callback_failed, 2], :noop)
      assert result == [1, :callback_failed, 2]
    end
  end

  describe "filter_valid/1" do
    test "removes nil values" do
      assert [1, 2] = Merge.filter_valid([1, nil, 2])
    end

    test "removes callback_failed sentinel" do
      assert [1, 2] = Merge.filter_valid([1, :callback_failed, 2])
    end

    test "returns empty list when all invalid" do
      assert [] = Merge.filter_valid([nil, :callback_failed, nil])
    end

    test "preserves falsy but valid values" do
      assert [false, 0, ""] = Merge.filter_valid([false, 0, ""])
    end
  end

  describe "deep_merge/2" do
    test "merges flat maps" do
      assert %{a: 1, b: 2} = Merge.deep_merge(%{a: 1}, %{b: 2})
    end

    test "right map wins on conflict" do
      assert %{a: 2} = Merge.deep_merge(%{a: 1}, %{a: 2})
    end

    test "recursively merges nested maps" do
      assert %{a: %{x: 1, y: 2}} =
               Merge.deep_merge(%{a: %{x: 1}}, %{a: %{y: 2}})
    end

    test "overwrites non-map values with right map value" do
      assert %{a: 2} = Merge.deep_merge(%{a: 1}, %{a: 2})
    end
  end

  describe "error_sentinel/0" do
    test "returns :callback_failed" do
      assert :callback_failed = Merge.error_sentinel()
    end
  end
end
