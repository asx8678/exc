defmodule CodePuppyControl.Compaction.ShadowModeTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.Compaction.ShadowMode

  describe "compare_and_log/2" do
    test "does nothing when disabled" do
      messages = [%{"parts" => []}]
      result = ShadowMode.compare_and_log(messages, enabled: false)
      assert result == :ok
    end

    test "returns :ok when counts match" do
      messages = [%{"parts" => []}]

      old_result = %{surviving_indices: [0, 1], dropped_count: 0}
      new_result = %{surviving_indices: [0, 1], dropped_count: 0}

      result =
        ShadowMode.compare_and_log(messages,
          old_result: old_result,
          new_result: new_result,
          enabled: true
        )

      assert result == :ok
    end

    test "returns warning when counts differ" do
      messages = [%{"parts" => []}]

      old_result = %{surviving_indices: [0, 1, 2], dropped_count: 0}
      new_result = %{surviving_indices: [0, 1], dropped_count: 1}

      result =
        ShadowMode.compare_and_log(messages,
          old_result: old_result,
          new_result: new_result,
          enabled: true
        )

      assert {:warning, msg} = result
      assert msg =~ "mismatch"
      assert msg =~ "old kept 3"
      assert msg =~ "new kept 2"
    end

    test "custom label appears in warning" do
      messages = [%{"parts" => []}]

      result =
        ShadowMode.compare_and_log(messages,
          old_result: %{surviving_indices: [0], dropped_count: 0},
          new_result: %{surviving_indices: [], dropped_count: 1},
          enabled: true,
          label: "my-phase"
        )

      assert {:warning, msg} = result
      assert msg =~ "[my-phase]"
    end
  end

  describe "compare_hashes/2" do
    test "does nothing when disabled" do
      result = ShadowMode.compare_hashes([], enabled: false)
      assert result == :ok
    end

    test "returns :ok when hashes match" do
      result =
        ShadowMode.compare_hashes([],
          old_hashes: ["a", "b", "c"],
          new_hashes: ["x", "y", "z"],
          enabled: true
        )

      assert result == :ok
    end

    test "returns warning on length mismatch" do
      result =
        ShadowMode.compare_hashes([],
          old_hashes: ["a", "b"],
          new_hashes: ["x"],
          enabled: true
        )

      assert {:warning, msg} = result
      assert msg =~ "length mismatch"
    end

    test "returns warning on uniqueness mismatch" do
      result =
        ShadowMode.compare_hashes([],
          old_hashes: ["a", "a", "b"],
          new_hashes: ["x", "y", "z"],
          enabled: true
        )

      assert {:warning, msg} = result
      assert msg =~ "uniqueness mismatch"
    end
  end

  describe "enabled?/0" do
    test "returns false by default" do
      # Ensure clean state
      Application.delete_env(:code_puppy_control, :shadow_mode_enabled)
      assert ShadowMode.enabled?() == false
    end

    test "returns true when configured" do
      Application.put_env(:code_puppy_control, :shadow_mode_enabled, true)
      assert ShadowMode.enabled?() == true
      Application.delete_env(:code_puppy_control, :shadow_mode_enabled)
    end
  end
end
