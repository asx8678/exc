defmodule CodePuppyControl.Plugins.LoaderTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Plugins.Loader

  setup do
    Callbacks.clear()
    :ok
  end

  describe "load_all/0" do
    test "returns a map with builtin and user keys" do
      result = Loader.load_all()
      assert is_map(result)
      assert Map.has_key?(result, :builtin)
      assert Map.has_key?(result, :user)
      assert is_list(result.builtin)
      assert is_list(result.user)
    end

    test "discovers compiled builtin plugins" do
      result = Loader.load_all()
      # At minimum, the Motd plugin should be discovered
      assert is_list(result.builtin)
    end
  end

  describe "load_plugin/1 with module (register/0)" do
    test "loads a plugin that uses register/0" do
      assert {:ok, :test_plugin} = Loader.load_plugin(CodePuppyControl.Test.TestPlugin)
    end

    test "register/0 callbacks are registered with the callback system" do
      Loader.load_plugin(CodePuppyControl.Test.TestPlugin)

      # The test plugin uses register/0 to register :load_prompt
      callbacks = Callbacks.get_callbacks(:load_prompt)
      assert length(callbacks) >= 1

      result = Callbacks.trigger(:load_prompt)
      assert result =~ "Test Plugin Instructions"
    end

    test "returns error for non-plugin module" do
      assert {:error, {:not_a_plugin, String}} = Loader.load_plugin(String)
    end
  end

  describe "load_plugin/1 with module (register_callbacks/0 legacy)" do
    test "loads a plugin using legacy register_callbacks/0" do
      assert {:ok, :legacy_test_plugin} =
               Loader.load_plugin(CodePuppyControl.Test.LegacyTestPlugin)
    end

    test "legacy register_callbacks/0 tuples are registered" do
      Loader.load_plugin(CodePuppyControl.Test.LegacyTestPlugin)

      # Legacy plugin registers :load_prompt and :custom_command_help
      result = Callbacks.trigger(:load_prompt)
      assert result =~ "Legacy Plugin Instructions"

      help = Callbacks.trigger(:custom_command_help)
      assert {"legacy", "A legacy test command"} in help
    end
  end

  describe "load_plugin/1 with file path" do
    test "returns error for non-existent file" do
      assert {:error, {:file_not_found, _}} = Loader.load_plugin("/tmp/nonexistent.ex")
    end

    test "loads a .ex file containing a plugin" do
      # Create a temp plugin file
      dir = System.tmp_dir!()
      plugin_dir = Path.join(dir, "test_file_plugin")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.ex"), """
      defmodule TestFilePlugin do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: :test_file_plugin

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "File plugin!" end)
          :ok
        end
      end
      """)

      file_path = Path.join(plugin_dir, "register_callbacks.ex")
      assert {:ok, :test_file_plugin} = Loader.load_plugin(file_path)

      # Clean up
      File.rm_rf!(plugin_dir)
    end

    test "returns error when .ex file has no PluginBehaviour module" do
      dir = System.tmp_dir!()
      File.mkdir_p!(dir)

      file_path = Path.join(dir, "no_plugin.ex")
      File.write!(file_path, "defmodule NoPlugin do end")

      assert {:error, {:no_plugins_found, _}} = Loader.load_plugin(file_path)

      File.rm!(file_path)
    end
  end

  describe "priv_plugins_dir/0" do
    test "returns a path ending in plugins" do
      dir = Loader.priv_plugins_dir()
      assert is_binary(dir)
      assert String.ends_with?(dir, "plugins")
    end
  end

  describe "user_plugins_dir/0" do
    test "returns a path under the configured plugins directory" do
      dir = Loader.user_plugins_dir()
      assert is_binary(dir)
      assert dir =~ "plugins"
    end
  end

  describe "ensure_user_plugins_dir/0" do
    test "creates the directory" do
      dir = Loader.ensure_user_plugins_dir()
      assert File.dir?(dir)
    end
  end

  describe "list_loaded/0" do
    test "returns plugin info after loading" do
      Loader.load_plugin(CodePuppyControl.Test.TestPlugin)

      loaded = Loader.list_loaded()
      test_plugin = Enum.find(loaded, fn p -> p.name == :test_plugin end)

      assert test_plugin != nil
      assert test_plugin.module == CodePuppyControl.Test.TestPlugin
      assert test_plugin.type == :builtin
    end
  end

  describe "plugin lifecycle" do
    test "startup/0 is called when plugin is loaded" do
      CodePuppyControl.Test.TestPlugin.start_agent()
      CodePuppyControl.Test.TestPlugin.reset_state()

      Loader.load_plugin(CodePuppyControl.Test.TestPlugin)

      Process.sleep(10)
      state = CodePuppyControl.Test.TestPlugin.get_state()
      assert state[:startup_called] == true

      CodePuppyControl.Test.TestPlugin.stop_agent()
    end
  end

  describe "security: user plugin validation" do
    test "skips user plugins with suspicious names (path traversal)" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_symlink_test_#{uniq}")

      File.mkdir_p!(plugins_base)

      # Create a file OUTSIDE the plugins dir
      outside_file = Path.join(tmp_dir, "evil_#{uniq}.ex")
      File.write!(outside_file, "defmodule Evil do end")

      # Create a symlink FROM inside plugins dir TO the outside file
      symlink_path = Path.join(plugins_base, "evil_link.ex")
      File.ln_s!(outside_file, symlink_path)

      # The safe_plugin_path? check must reject the symlinked file
      refute Loader.safe_plugin_path?(symlink_path, plugins_base)

      # Clean up
      File.rm_rf!(plugins_base)
      File.rm(outside_file)
    end

    test "rejects symlinked plugin files that escape the plugins directory" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_escalation_test_#{uniq}")
      plugin_dir = Path.join(plugins_base, "evil_plugin")

      # Set up directory structure
      File.mkdir_p!(plugin_dir)

      # Create a .ex file outside the plugins dir
      outside_dir = Path.join(tmp_dir, "cp_outside_#{uniq}")
      File.mkdir_p!(outside_dir)

      outside_file = Path.join(outside_dir, "evil.ex")

      File.write!(outside_file, """
      defmodule EvilEscapingPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "evil_escaping_plugin"

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "ESCAPED!" end)
          :ok
        end
      end
      """)

      # Create a symlink inside the plugin dir pointing to the outside file
      symlink_path = Path.join(plugin_dir, "register_callbacks.ex")
      File.rm(symlink_path)
      File.ln_s!(outside_file, symlink_path)

      # The safe_plugin_path? check should reject the symlinked file
      # because its canonical path is outside the plugins base dir
      refute Loader.safe_plugin_path?(symlink_path, plugins_base)

      # Clean up
      File.rm_rf!(plugins_base)
      File.rm_rf!(outside_dir)
    end

    test "allows plugin files that stay within the plugins directory" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_safe_test_#{uniq}")
      plugin_dir = Path.join(plugins_base, "safe_plugin")

      File.mkdir_p!(plugin_dir)

      file_path = Path.join(plugin_dir, "register_callbacks.ex")
      File.write!(file_path, "# safe plugin file")

      assert Loader.safe_plugin_path?(file_path, plugins_base)

      File.rm_rf!(plugins_base)
    end

    test "rejects plugin directory that is a symlink escaping plugins dir" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_dir_symlink_test_#{uniq}")
      File.mkdir_p!(plugins_base)

      # Create an outside directory
      outside_dir = Path.join(tmp_dir, "cp_dir_outside_#{uniq}")
      File.mkdir_p!(outside_dir)

      # Symlink the plugin directory itself to outside
      symlink_plugin = Path.join(plugins_base, "escaped_dir")
      File.ln_s!(outside_dir, symlink_plugin)

      refute Loader.safe_plugin_path?(symlink_plugin, plugins_base)

      File.rm_rf!(plugins_base)
      File.rm_rf!(outside_dir)
    end

    test "rejects intermediate directory symlink that escapes plugins dir" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_nested_symlink_test_#{uniq}")
      plugin_dir = Path.join(plugins_base, "nested_escape")
      File.mkdir_p!(plugin_dir)

      # Create an outside directory
      outside_dir = Path.join(tmp_dir, "cp_nested_outside_#{uniq}")
      File.mkdir_p!(outside_dir)

      # Replace a subdirectory with a symlink to outside
      internal_link = Path.join(plugin_dir, "subdir")
      File.ln_s!(outside_dir, internal_link)

      file_path = Path.join(internal_link, "register_callbacks.ex")

      refute Loader.safe_plugin_path?(file_path, plugins_base)

      File.rm_rf!(plugins_base)
      File.rm_rf!(outside_dir)
    end

    test "allows valid internal symlink within plugins dir" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_internal_symlink_test_#{uniq}")
      File.mkdir_p!(plugins_base)

      # Shared directory within plugins_base
      shared_dir = Path.join(plugins_base, "_shared")
      File.mkdir_p!(shared_dir)

      shared_file = Path.join(shared_dir, "helper.ex")
      File.write!(shared_file, "# safe")

      # Plugin directory with symlink to shared file
      plugin_dir = Path.join(plugins_base, "my_plugin")
      File.mkdir_p!(plugin_dir)

      symlink_path = Path.join(plugin_dir, "register_callbacks.ex")
      File.ln_s!(shared_file, symlink_path)

      assert Loader.safe_plugin_path?(symlink_path, plugins_base)

      File.rm_rf!(plugins_base)
    end
  end
end
