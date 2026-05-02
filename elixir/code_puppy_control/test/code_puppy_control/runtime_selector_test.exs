defmodule CodePuppyControl.RuntimeSelectorTest do
  @moduledoc """
  Tests for the RuntimeSelector module. (code_puppy-bwt)

  Covers:
  - mode/0 reads PUP_RUNTIME env correctly (python, elixir, auto, unset → auto)
  - mode/0 handles case-insensitive values
  - select/1 in :elixir mode always returns :elixir
  - select/1 in :python mode always returns :python
  - select/1 in :auto mode returns based on FeatureFlags
  - select_with_reason/1 returns correct reason atoms
  - elixir_handles?/1 convenience wrapper works
  - Unknown capability in auto mode → :python (conservative default)
  - Integration: set flag → select changes result

  async: false because tests mutate the PUP_RUNTIME env var globally.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.RuntimeSelector
  alias CodePuppyControl.FeatureFlags

  @env_var "PUP_RUNTIME"

  setup do
    # Capture the original env value so we can restore it
    original = System.get_env(@env_var)

    # Ensure FeatureFlags GenServer is running for auto-mode tests
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(FeatureFlags)
    FeatureFlags.reset_all()

    on_exit(fn ->
      # Restore original env (or delete if it was nil)
      if original do
        System.put_env(@env_var, original)
      else
        System.delete_env(@env_var)
      end

      FeatureFlags.reset_all()
    end)

    :ok
  end

  # ===========================================================================
  # mode/0
  # ===========================================================================

  describe "mode/0" do
    test "returns :python when PUP_RUNTIME=python" do
      System.put_env(@env_var, "python")
      assert RuntimeSelector.mode() == :python
    end

    test "returns :elixir when PUP_RUNTIME=elixir" do
      System.put_env(@env_var, "elixir")
      assert RuntimeSelector.mode() == :elixir
    end

    test "returns :auto when PUP_RUNTIME=auto" do
      System.put_env(@env_var, "auto")
      assert RuntimeSelector.mode() == :auto
    end

    test "returns :auto when PUP_RUNTIME is unset" do
      System.delete_env(@env_var)
      assert RuntimeSelector.mode() == :auto
    end

    test "returns :auto for unrecognised values" do
      System.put_env(@env_var, "kubernetes")
      assert RuntimeSelector.mode() == :auto
    end

    test "handles case-insensitive value 'Python'" do
      System.put_env(@env_var, "Python")
      assert RuntimeSelector.mode() == :python
    end

    test "handles case-insensitive value 'ELIXIR'" do
      System.put_env(@env_var, "ELIXIR")
      assert RuntimeSelector.mode() == :elixir
    end

    test "handles case-insensitive value 'Auto'" do
      System.put_env(@env_var, "Auto")
      assert RuntimeSelector.mode() == :auto
    end

    test "handles mixed case 'pYtHoN'" do
      System.put_env(@env_var, "pYtHoN")
      assert RuntimeSelector.mode() == :python
    end
  end

  # ===========================================================================
  # select/1 in :elixir mode
  # ===========================================================================

  describe "select/1 in :elixir mode" do
    setup do
      System.put_env(@env_var, "elixir")
      :ok
    end

    test "always returns :elixir for known capability" do
      assert RuntimeSelector.select("elixir.llm_client") == :elixir
    end

    test "returns :elixir even for unknown capability" do
      assert RuntimeSelector.select("elixir.unknown") == :elixir
    end

    test "returns :elixir for any string" do
      assert RuntimeSelector.select("anything") == :elixir
      assert RuntimeSelector.select("") == :elixir
    end
  end

  # ===========================================================================
  # select/1 in :python mode
  # ===========================================================================

  describe "select/1 in :python mode" do
    setup do
      System.put_env(@env_var, "python")
      :ok
    end

    test "always returns :python for known capability" do
      assert RuntimeSelector.select("elixir.llm_client") == :python
    end

    test "returns :python even for unknown capability" do
      assert RuntimeSelector.select("elixir.unknown") == :python
    end

    test "returns :python for any string" do
      assert RuntimeSelector.select("anything") == :python
      assert RuntimeSelector.select("") == :python
    end
  end

  # ===========================================================================
  # select/1 in :auto mode
  # ===========================================================================

  describe "select/1 in :auto mode" do
    setup do
      System.put_env(@env_var, "auto")
      FeatureFlags.reset_all()
      :ok
    end

    test "returns :python when flag is disabled" do
      assert FeatureFlags.enabled?("elixir.llm_client") == false
      assert RuntimeSelector.select("elixir.llm_client") == :python
    end

    test "returns :elixir when flag is enabled" do
      :ok = FeatureFlags.set_flag("elixir.llm_client", true)
      assert RuntimeSelector.select("elixir.llm_client") == :elixir
    end

    test "returns :python for unknown capability (conservative default)" do
      assert RuntimeSelector.select("elixir.nonexistent") == :python
    end

    test "returns :python for empty string" do
      assert RuntimeSelector.select("") == :python
    end

    test "routes each capability independently" do
      :ok = FeatureFlags.set_flag("elixir.tools", true)
      :ok = FeatureFlags.set_flag("elixir.llm_client", true)
      # tools and llm_client are on
      assert RuntimeSelector.select("elixir.tools") == :elixir
      assert RuntimeSelector.select("elixir.llm_client") == :elixir
      # base_agent still off
      assert RuntimeSelector.select("elixir.base_agent") == :python
    end
  end

  # ===========================================================================
  # select/1 in :auto mode (unset env)
  # ===========================================================================

  describe "select/1 when PUP_RUNTIME is unset (defaults to :auto)" do
    setup do
      System.delete_env(@env_var)
      FeatureFlags.reset_all()
      :ok
    end

    test "behaves like auto mode — returns :python by default" do
      assert RuntimeSelector.select("elixir.llm_client") == :python
    end

    test "behaves like auto mode — returns :elixir when flag enabled" do
      :ok = FeatureFlags.set_flag("elixir.cli", true)
      assert RuntimeSelector.select("elixir.cli") == :elixir
    end
  end

  # ===========================================================================
  # select_with_reason/1
  # ===========================================================================

  describe "select_with_reason/1" do
    test "returns {:elixir, :env_override} in elixir mode" do
      System.put_env(@env_var, "elixir")
      assert RuntimeSelector.select_with_reason("elixir.llm_client") == {:elixir, :env_override}
    end

    test "returns {:python, :env_override} in python mode" do
      System.put_env(@env_var, "python")
      assert RuntimeSelector.select_with_reason("elixir.llm_client") == {:python, :env_override}
    end

    test "returns {:elixir, :feature_flag} in auto mode with flag enabled" do
      System.put_env(@env_var, "auto")
      :ok = FeatureFlags.set_flag("elixir.tools", true)
      assert RuntimeSelector.select_with_reason("elixir.tools") == {:elixir, :feature_flag}
    end

    test "returns {:python, :default} in auto mode with flag disabled" do
      System.put_env(@env_var, "auto")
      FeatureFlags.reset_all()
      assert RuntimeSelector.select_with_reason("elixir.base_agent") == {:python, :default}
    end

    test "returns {:python, :default} for unknown capability in auto mode" do
      System.put_env(@env_var, "auto")
      assert RuntimeSelector.select_with_reason("elixir.unknown") == {:python, :default}
    end
  end

  # ===========================================================================
  # elixir_handles?/1
  # ===========================================================================

  describe "elixir_handles?/1" do
    test "returns true in elixir mode" do
      System.put_env(@env_var, "elixir")
      assert RuntimeSelector.elixir_handles?("elixir.llm_client") == true
    end

    test "returns false in python mode" do
      System.put_env(@env_var, "python")
      assert RuntimeSelector.elixir_handles?("elixir.llm_client") == false
    end

    test "returns true in auto mode when flag enabled" do
      System.put_env(@env_var, "auto")
      :ok = FeatureFlags.set_flag("elixir.plugins", true)
      assert RuntimeSelector.elixir_handles?("elixir.plugins") == true
    end

    test "returns false in auto mode when flag disabled" do
      System.put_env(@env_var, "auto")
      FeatureFlags.reset_all()
      assert RuntimeSelector.elixir_handles?("elixir.plugins") == false
    end

    test "returns false for unknown capability in auto mode" do
      System.put_env(@env_var, "auto")
      assert RuntimeSelector.elixir_handles?("unknown.capability") == false
    end
  end

  # ===========================================================================
  # Integration: set flag → select changes result
  # ===========================================================================

  describe "integration: flag change affects select" do
    setup do
      System.put_env(@env_var, "auto")
      FeatureFlags.reset_all()
      :ok
    end

    test "enabling a flag switches select from :python to :elixir" do
      cap = "elixir.cli"

      # Initially disabled
      assert RuntimeSelector.select(cap) == :python
      assert RuntimeSelector.elixir_handles?(cap) == false

      # Enable it
      :ok = FeatureFlags.set_flag(cap, true)

      # Now Elixir handles it
      assert RuntimeSelector.select(cap) == :elixir
      assert RuntimeSelector.elixir_handles?(cap) == true
    end

    test "disabling a flag switches select from :elixir to :python" do
      cap = "elixir.base_agent"

      :ok = FeatureFlags.set_flag(cap, true)
      assert RuntimeSelector.select(cap) == :elixir

      :ok = FeatureFlags.set_flag(cap, false)
      assert RuntimeSelector.select(cap) == :python
    end

    test "changing mode overrides flag state" do
      cap = "elixir.tools"
      :ok = FeatureFlags.set_flag(cap, true)

      # Auto mode: flag says Elixir
      System.put_env(@env_var, "auto")
      assert RuntimeSelector.select(cap) == :elixir

      # Force Python: flag is ignored
      System.put_env(@env_var, "python")
      assert RuntimeSelector.select(cap) == :python

      # Back to auto: flag still says Elixir
      System.put_env(@env_var, "auto")
      assert RuntimeSelector.select(cap) == :elixir
    end

    test "reason changes when mode changes" do
      cap = "elixir.llm_client"
      :ok = FeatureFlags.set_flag(cap, true)

      System.put_env(@env_var, "auto")
      assert RuntimeSelector.select_with_reason(cap) == {:elixir, :feature_flag}

      System.put_env(@env_var, "elixir")
      assert RuntimeSelector.select_with_reason(cap) == {:elixir, :env_override}

      System.put_env(@env_var, "python")
      assert RuntimeSelector.select_with_reason(cap) == {:python, :env_override}
    end
  end
end
