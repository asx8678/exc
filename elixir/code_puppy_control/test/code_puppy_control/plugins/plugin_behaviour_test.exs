defmodule CodePuppyControl.Plugins.PluginBehaviourTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Plugins.PluginBehaviour

  setup do
    Callbacks.clear()
    :ok
  end

  describe "PluginBehaviour definition" do
    test "defines required callbacks: name/0, register/0" do
      callbacks = PluginBehaviour.behaviour_info(:callbacks)

      # name/0 is required
      assert {:name, 0} in callbacks
      # register/0 is required
      assert {:register, 0} in callbacks
    end

    test "defines optional callbacks: startup/0, shutdown/0, description/0, register_callbacks/0" do
      optional = PluginBehaviour.behaviour_info(:optional_callbacks)

      assert {:startup, 0} in optional
      assert {:shutdown, 0} in optional
      assert {:description, 0} in optional
      assert {:register_callbacks, 0} in optional
    end
  end

  describe "use PluginBehaviour macro" do
    test "provides default implementations for optional callbacks" do
      defmodule DefaultImplTest do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "default_impl_test"

        @impl true
        def register, do: :ok
      end

      # Default startup returns :ok
      assert DefaultImplTest.startup() == :ok
      # Default shutdown returns :ok
      assert DefaultImplTest.shutdown() == :ok
      # Default description returns ""
      assert DefaultImplTest.description() == ""
    end

    test "allows overriding default implementations" do
      defmodule OverrideTest do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "override_test"

        @impl true
        def register, do: :ok

        @impl true
        def startup, do: {:started, :override}

        @impl true
        def shutdown, do: {:stopped, :override}

        @impl true
        def description, do: "Overridden description"
      end

      assert OverrideTest.startup() == {:started, :override}
      assert OverrideTest.shutdown() == {:stopped, :override}
      assert OverrideTest.description() == "Overridden description"
    end
  end

  describe "name/0 return types" do
    test "plugin name can be a string" do
      defmodule StringNameTest do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "string_name_plugin"

        @impl true
        def register, do: :ok
      end

      assert StringNameTest.name() == "string_name_plugin"
    end

    test "plugin name can be an atom (backward compat)" do
      defmodule AtomNameTest do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: :atom_name_plugin

        @impl true
        def register, do: :ok
      end

      assert AtomNameTest.name() == :atom_name_plugin
    end
  end

  describe "register/0 callback" do
    test "register/0 can directly call Callbacks.register/2" do
      defmodule DirectRegisterTest do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: :direct_register

        @impl true
        def register do
          Callbacks.register(:load_prompt, fn -> "Direct!" end)
          :ok
        end
      end

      DirectRegisterTest.register()
      result = Callbacks.trigger(:load_prompt)
      assert result =~ "Direct!"
    end

    test "register/0 can return {:error, reason}" do
      defmodule ErrorRegisterTest do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: :error_register

        @impl true
        def register do
          {:error, :not_ready}
        end
      end

      assert ErrorRegisterTest.register() == {:error, :not_ready}
    end
  end

  describe "register_callbacks/0 backward compat" do
    test "register_callbacks/0 returns list of {hook, fun} tuples" do
      defmodule LegacyRegisterTest do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: :legacy_register

        @impl true
        def register do
          :ok
        end

        @impl true
        def register_callbacks do
          [{:load_prompt, fn -> "Legacy!" end}]
        end
      end

      callbacks = LegacyRegisterTest.register_callbacks()
      assert is_list(callbacks)
      assert length(callbacks) == 1
      {hook, fun} = hd(callbacks)
      assert hook == :load_prompt
      assert is_function(fun)
    end
  end
end
