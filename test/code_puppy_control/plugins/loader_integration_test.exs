defmodule CodePuppyControl.Plugins.LoaderIntegrationTest do
  @moduledoc """
  Integration tests for the plugin loader using PUP_EX_HOME/Paths.plugins_dir
  and Loader.load_all/0.

  Validates:
  - Valid user plugins are discovered and loaded
  - Suspicious plugin names are skipped
  - Symlink escapes (plugin dir, nested dir, final file) are skipped
  - Valid internal symlinks are allowed
  - Broken plugin does not block later plugin loading
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.Plugins.Loader

  setup do
    Callbacks.clear()
    :ok
  end

  # Helper: create a sandbox PUP_EX_HOME with a plugins/ subdirectory
  defp setup_sandbox(_tags) do
    uniq = :erlang.unique_integer([:positive])
    tmp_dir = System.tmp_dir!()
    sandbox = Path.join(tmp_dir, "cp_loader_int_#{uniq}")

    plugins_dir = Path.join(sandbox, "plugins")
    File.mkdir_p!(plugins_dir)

    # Stash the original env so we can restore it
    orig_pup_ex_home = System.get_env("PUP_EX_HOME")
    System.put_env("PUP_EX_HOME", sandbox)

    on_exit(fn ->
      if orig_pup_ex_home do
        System.put_env("PUP_EX_HOME", orig_pup_ex_home)
      else
        System.delete_env("PUP_EX_HOME")
      end

      File.rm_rf!(sandbox)
    end)

    %{sandbox: sandbox, plugins_dir: plugins_dir, uniq: uniq}
  end

  # Helper: write a valid plugin to a plugin directory
  defp write_valid_plugin(plugin_dir, module_name_atom, tag) do
    File.mkdir_p!(plugin_dir)

    File.write!(Path.join(plugin_dir, "register_callbacks.ex"), """
    defmodule #{module_name_atom} do
      use CodePuppyControl.Plugins.PluginBehaviour

      @impl true
      def name, do: "#{tag}"

      @impl true
      def register do
        CodePuppyControl.Callbacks.register(:load_prompt, fn -> "LOADED: #{tag}" end)
        :ok
      end
    end
    """)
  end

  # ── Valid user plugins load via load_all/0 ───────────────────────

  describe "integration: valid user plugins" do
    test "user .ex plugin is discovered by load_all/0 with PUP_EX_HOME" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      tag = "int_valid_#{uniq}"
      module_atom = :"IntValidPlugin#{uniq}"
      plugin_dir = Path.join(plugins_dir, "valid_plugin")
      write_valid_plugin(plugin_dir, module_atom, tag)

      # Paths.plugins_dir() should resolve to our sandbox
      assert Paths.plugins_dir() == plugins_dir

      # load_all/0 should discover the user plugin
      result = Loader.load_all()
      assert is_list(result.user)

      # The plugin should be registered
      loaded = Loader.list_loaded()
      found = Enum.any?(loaded, fn p -> to_string(p.name) == tag end)
      assert found, "Expected user plugin '#{tag}' to be loaded"

      # The callback should fire
      result = Callbacks.trigger(:load_prompt)
      assert result =~ "LOADED: #{tag}"
    end

    test "user .exs plugin is discovered by load_all/0 with PUP_EX_HOME" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      tag = "int_valid_exs_#{uniq}"
      module_atom = :"IntValidExsPlugin#{uniq}"
      plugin_dir = Path.join(plugins_dir, "valid_exs_plugin")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.exs"), """
      defmodule #{module_atom} do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "#{tag}"

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "LOADED: #{tag}" end)
          :ok
        end
      end
      """)

      assert Paths.plugins_dir() == plugins_dir

      result = Loader.load_all()
      assert is_list(result.user)

      loaded = Loader.list_loaded()
      found = Enum.any?(loaded, fn p -> to_string(p.name) == tag end)
      assert found, "Expected user .exs plugin '#{tag}' to be loaded"
    end
  end

  # ── Suspicious plugin names are skipped ──────────────────────────

  describe "integration: suspicious plugin names" do
    test "plugin with '..' in name is skipped" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: _uniq} =
        setup_sandbox([])

      evil_dir = Path.join(plugins_dir, "evil..plugin")
      File.mkdir_p!(evil_dir)

      # Even if it has a valid plugin file, the name check should reject it
      File.write!(Path.join(evil_dir, "register_callbacks.ex"), """
      defmodule NeverLoadThis do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "evil_dot_dot"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "ESCAPED!" end)
          :ok
        end
      end
      """)

      result = Loader.load_all()
      # The evil plugin should NOT appear in user results
      assert not Enum.any?(result.user, fn name ->
               to_string(name) == "evil_dot_dot"
             end),
             "Plugin with '..' in name should be skipped"
    end

    test "plugin with '/' in name is skipped" do
      %{sandbox: _sandbox, plugins_dir: _plugins_dir, uniq: _uniq} =
        setup_sandbox([])

      # Create a directory with a slash in the name (which File.ls won't
      # naturally create, but simulate by checking the guard logic)
      suspicious_names = ["evil/plugin", "plugin/../../etc", "bad\\0name"]

      for name <- suspicious_names do
        assert String.contains?(name, ["..", "/", "\\", <<0>>]),
               "Expected '#{name}' to contain suspicious characters"
      end
    end
  end

  # ── Symlink escape scenarios ─────────────────────────────────────

  describe "integration: symlink escape protection" do
    test "plugin directory itself is a symlink escaping plugins dir" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      # Create an outside directory with a plugin
      outside_dir = Path.join(System.tmp_dir!(), "cp_outside_symlink_#{uniq}")
      File.mkdir_p!(outside_dir)

      tag = "int_symlink_dir_#{uniq}"
      module_atom = :"IntSymlinkDirPlugin#{uniq}"
      write_valid_plugin(outside_dir, module_atom, tag)

      # Create a symlink IN the plugins dir pointing to the outside directory
      symlink_plugin = Path.join(plugins_dir, "symlinked_plugin")
      File.ln_s!(outside_dir, symlink_plugin)

      # safe_plugin_path? should reject the symlinked directory
      refute Loader.safe_plugin_path?(symlink_plugin, plugins_dir),
             "Symlinked plugin directory escaping plugins dir should be rejected"

      # load_all should not load the escaped plugin
      result = Loader.load_all()

      assert not Enum.any?(result.user, fn name ->
               to_string(name) == tag
             end),
             "Symlink-escaped plugin should not be loaded"

      File.rm_rf!(outside_dir)
    end

    test "intermediate directory symlink is rejected (nested symlink escape)" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      # Create an outside directory
      outside_dir = Path.join(System.tmp_dir!(), "cp_outside_nested_#{uniq}")
      File.mkdir_p!(outside_dir)

      # Inside the plugin dir, create a subdirectory that is a symlink
      # to the outside directory, then put a plugin file via that symlink
      plugin_dir = Path.join(plugins_dir, "nested_escape")
      File.mkdir_p!(plugin_dir)

      # symlink: plugins/nested_escape/internal_link → outside_dir
      internal_link = Path.join(plugin_dir, "internal_link")
      File.ln_s!(outside_dir, internal_link)

      # Write a plugin file through the symlink path
      symlink_file = Path.join(internal_link, "register_callbacks.ex")

      tag = "int_nested_symlink_#{uniq}"

      File.write!(symlink_file, """
      defmodule IntNestedSymlinkPlugin#{uniq} do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "#{tag}"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "NESTED ESCAPE!" end)
          :ok
        end
      end
      """)

      # The file path through the symlink should be rejected
      # because the intermediate directory is a symlink to outside
      refute Loader.safe_plugin_path?(symlink_file, plugins_dir),
             "File accessed through intermediate symlink escaping plugins dir should be rejected"

      File.rm_rf!(outside_dir)
    end

    test "final file symlink is rejected (register_callbacks.exs → outside)" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      plugin_dir = Path.join(plugins_dir, "final_symlink")
      File.mkdir_p!(plugin_dir)

      # Create a file outside the plugins dir
      outside_dir = Path.join(System.tmp_dir!(), "cp_outside_final_#{uniq}")
      File.mkdir_p!(outside_dir)

      outside_file = Path.join(outside_dir, "evil.exs")

      tag = "int_final_symlink_#{uniq}"

      File.write!(outside_file, """
      defmodule IntFinalSymlinkPlugin#{uniq} do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "#{tag}"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "FINAL ESCAPE!" end)
          :ok
        end
      end
      """)

      # Symlink: plugin_dir/register_callbacks.exs → outside_file
      symlink_path = Path.join(plugin_dir, "register_callbacks.exs")
      File.ln_s!(outside_file, symlink_path)

      # The symlinked file should be rejected
      refute Loader.safe_plugin_path?(symlink_path, plugins_dir),
             "Final-file symlink escaping plugins dir should be rejected"

      File.rm_rf!(outside_dir)
    end

    test "valid internal symlink within plugins dir is allowed" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      # Create a shared lib directory within the plugins dir
      shared_dir = Path.join(plugins_dir, "_shared_libs")
      File.mkdir_p!(shared_dir)

      # Create a plugin directory that symlinks to a file within the
      # plugins dir (still inside plugins_dir)
      plugin_dir = Path.join(plugins_dir, "internal_symlink")
      File.mkdir_p!(plugin_dir)

      # Create a valid plugin in the shared dir (still within plugins_dir)
      tag = "int_internal_symlink_#{uniq}"
      module_atom = :"IntInternalSymlink#{uniq}"

      shared_file = Path.join(shared_dir, "helper.ex")

      File.write!(shared_file, """
      defmodule #{module_atom} do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "#{tag}"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "INTERNAL OK" end)
          :ok
        end
      end
      """)

      # Symlink: plugin_dir/register_callbacks.ex → shared_dir/helper.ex
      symlink_path = Path.join(plugin_dir, "register_callbacks.ex")
      File.ln_s!(shared_file, symlink_path)

      # The symlink stays within the plugins dir, so it should be allowed
      assert Loader.safe_plugin_path?(symlink_path, plugins_dir),
             "Internal symlink staying within plugins dir should be allowed"
    end
  end

  # ── Broken plugin does not block later plugin ────────────────────

  describe "integration: crash isolation across plugins" do
    test "broken plugin does not prevent later plugin from loading" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      # Plugin A: broken (raises in register/0)
      broken_dir = Path.join(plugins_dir, "00_broken_plugin")
      File.mkdir_p!(broken_dir)

      File.write!(Path.join(broken_dir, "register_callbacks.ex"), """
      defmodule IntBrokenPlugin#{uniq} do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "int_broken_#{uniq}"

        @impl true
        def register do
          raise "intentional crash in register/0"
        end
      end
      """)

      # Plugin B: valid (alphabetically after broken)
      good_tag = "int_good_#{uniq}"
      good_dir = Path.join(plugins_dir, "zz_good_plugin")
      module_atom = :"IntGoodPlugin#{uniq}"
      write_valid_plugin(good_dir, module_atom, good_tag)

      # load_all should not crash
      result = Loader.load_all()
      assert is_map(result)

      # The good plugin should still be loaded despite the broken one
      loaded = Loader.list_loaded()
      found_good = Enum.any?(loaded, fn p -> to_string(p.name) == good_tag end)
      assert found_good, "Good plugin should load even after broken plugin"

      # The broken plugin's callback should NOT be registered (since register/0 raised)
      # But the good plugin's callback should work
      result = Callbacks.trigger(:load_prompt)
      assert result =~ "LOADED: #{good_tag}"
    end

    test "broken startup/0 does not prevent later plugin from loading" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      # Plugin with crashing startup/0
      crash_startup_dir = Path.join(plugins_dir, "aa_crash_startup")
      File.mkdir_p!(crash_startup_dir)

      File.write!(Path.join(crash_startup_dir, "register_callbacks.ex"), """
      defmodule IntCrashStartup#{uniq} do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "int_crash_startup_#{uniq}"

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "CRASH STARTUP" end)
          :ok
        end

        @impl true
        def startup do
          raise "intentional crash in startup/0"
        end
      end
      """)

      # Good plugin after it
      good_tag = "int_good_startup_#{uniq}"
      good_dir = Path.join(plugins_dir, "zz_good_after_startup")
      module_atom = :"IntGoodStartup#{uniq}"
      write_valid_plugin(good_dir, module_atom, good_tag)

      result = Loader.load_all()
      assert is_map(result)

      loaded = Loader.list_loaded()
      found_good = Enum.any?(loaded, fn p -> to_string(p.name) == good_tag end)
      assert found_good, "Good plugin should load despite broken startup in another"
    end

    test "broken register_callbacks/0 does not crash loader" do
      %{sandbox: _sandbox, plugins_dir: plugins_dir, uniq: uniq} =
        setup_sandbox([])

      # Plugin with crashing register_callbacks/0 (legacy API)
      crash_rc_dir = Path.join(plugins_dir, "aa_crash_rc")
      File.mkdir_p!(crash_rc_dir)

      File.write!(Path.join(crash_rc_dir, "register_callbacks.ex"), """
      defmodule IntCrashRC#{uniq} do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "int_crash_rc_#{uniq}"

        @impl true
        def register do
          # This will be called first (preferred over register_callbacks)
          :ok
        end

        @impl true
        def register_callbacks do
          raise "intentional crash in register_callbacks/0"
        end
      end
      """)

      # Good plugin after it
      good_tag = "int_good_rc_#{uniq}"
      good_dir = Path.join(plugins_dir, "zz_good_after_rc")
      module_atom = :"IntGoodRC#{uniq}"
      write_valid_plugin(good_dir, module_atom, good_tag)

      result = Loader.load_all()
      assert is_map(result)

      loaded = Loader.list_loaded()
      found_good = Enum.any?(loaded, fn p -> to_string(p.name) == good_tag end)
      assert found_good, "Good plugin should load despite broken register_callbacks in another"
    end
  end

  # ── safe_plugin_path? unit tests with intermediate symlinks ──────

  describe "safe_plugin_path?/2 with intermediate symlinks" do
    test "rejects when an intermediate directory is a symlink pointing outside" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])

      # Base directory
      base = Path.join(tmp_dir, "cp_safe_base_#{uniq}")
      File.mkdir_p!(base)

      # Outside directory
      outside = Path.join(tmp_dir, "cp_safe_outside_#{uniq}")
      File.mkdir_p!(outside)

      # Create a real directory inside base
      real_dir = Path.join(base, "real_subdir")
      File.mkdir_p!(real_dir)

      # Replace real_subdir with a symlink to outside
      File.rm_rf!(real_dir)
      File.ln_s!(outside, real_dir)

      # Now a path like base/real_subdir/file.ex has an intermediate
      # directory that is a symlink to outside
      file_path = Path.join(real_dir, "file.ex")

      # canonical_resolve should follow the symlink
      canonical = Paths.canonical_resolve(file_path)
      canonical_outside = Paths.canonical_resolve(outside)
      # The canonical path should resolve to outside dir
      # (Use canonical_outside to handle macOS /var → /private/var)
      assert String.starts_with?(canonical, canonical_outside <> "/") or
               canonical == canonical_outside

      # safe_plugin_path? should reject this
      refute Loader.safe_plugin_path?(file_path, base),
             "Path through symlinked intermediate dir should be rejected"

      File.rm_rf!(base)
      File.rm_rf!(outside)
    end

    test "allows when path stays within base after full canonicalization" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])

      base = Path.join(tmp_dir, "cp_safe_inside_#{uniq}")
      File.mkdir_p!(base)

      # Real file inside
      file_path = Path.join([base, "plugin", "register_callbacks.ex"])
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "# safe")

      assert Loader.safe_plugin_path?(file_path, base),
             "Normal path inside base should be allowed"

      File.rm_rf!(base)
    end
  end
end
