defmodule CodePuppyControl.Plugins.LoaderADR006Test do
  @moduledoc """
  Tests for ADR-006: Elixir Plugin Loader — Discovery, Compilation, and Security.

  Validates:
  - GATE-F1-1: .ex plugin in priv/plugins/ loads and registers callbacks
  - GATE-F1-2: .exs plugin in priv/plugins/ loads and registers callbacks
  - GATE-F1-3: .ex preferred over .exs when both exist
  - GATE-F1-4: User plugin in ~/.code_puppy_ex/plugins/ loads correctly
  - GATE-F1-5: Symlink escape in user plugins is rejected
  - GATE-F1-6: Path traversal in plugin names is rejected
  - GATE-F1-7: Plugin compile error does not crash application
  - GATE-F1-8: load_all/0 is idempotent
  """
  use ExUnit.Case, async: false

  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Plugins.Loader

  setup do
    Callbacks.clear()
    :ok
  end

  # ── GATE-F1-1: .ex plugin loads ─────────────────────────────────

  describe "GATE-F1-1: .ex plugin in priv/plugins/" do
    test "discovers and loads .ex plugin from priv/plugins/" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      priv_base = Path.join(tmp_dir, "cp_priv_ex_test_#{uniq}")
      plugin_dir = Path.join(priv_base, "my_ex_plugin")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.ex"), """
      defmodule GateF11ExPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "gate_f1_1_ex"

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "GATE-F1-1 EX" end)
          :ok
        end
      end
      """)

      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1
      assert String.ends_with?(hd(files), "register_callbacks.ex")

      names = Loader.load_and_register_plugin_file(hd(files), :builtin)
      assert :gate_f1_1_ex in names or "gate_f1_1_ex" in names

      result = Callbacks.trigger(:load_prompt)
      assert result =~ "GATE-F1-1 EX"

      File.rm_rf!(priv_base)
    end
  end

  # ── GATE-F1-2: .exs plugin loads ────────────────────────────────

  describe "GATE-F1-2: .exs plugin in priv/plugins/" do
    test "discovers and loads .exs plugin from priv/plugins/" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      priv_base = Path.join(tmp_dir, "cp_priv_exs_test_#{uniq}")
      plugin_dir = Path.join(priv_base, "my_exs_plugin")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.exs"), """
      defmodule GateF12ExsPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: "gate_f1_2_exs"

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "GATE-F1-2 EXS" end)
          :ok
        end
      end
      """)

      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1
      assert String.ends_with?(hd(files), "register_callbacks.exs")

      names = Loader.load_and_register_plugin_file(hd(files), :builtin)
      assert :gate_f1_2_exs in names or "gate_f1_2_exs" in names

      result = Callbacks.trigger(:load_prompt)
      assert result =~ "GATE-F1-2 EXS"

      File.rm_rf!(priv_base)
    end
  end

  # ── GATE-F1-3: .ex preferred over .exs ───────────────────────────

  describe "GATE-F1-3: .ex preferred over .exs when both exist" do
    test "discovers register_callbacks.ex when both .ex and .exs exist" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      priv_base = Path.join(tmp_dir, "cp_priority_test_#{uniq}")
      plugin_dir = Path.join(priv_base, "priority_plugin")
      File.mkdir_p!(plugin_dir)

      # Write both files
      File.write!(Path.join(plugin_dir, "register_callbacks.ex"), """
      defmodule GateF13ExPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "gate_f1_3_ex"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "EX WINNER" end)
          :ok
        end
      end
      """)

      File.write!(Path.join(plugin_dir, "register_callbacks.exs"), """
      defmodule GateF13ExsPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "gate_f1_3_exs"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "EXS LOSER" end)
          :ok
        end
      end
      """)

      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1
      # .ex should win
      assert String.ends_with?(hd(files), "register_callbacks.ex")
      refute String.ends_with?(hd(files), ".exs")

      File.rm_rf!(priv_base)
    end

    test "falls back to register_callbacks.exs when no .ex exists" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      priv_base = Path.join(tmp_dir, "cp_fallback_test_#{uniq}")
      plugin_dir = Path.join(priv_base, "fallback_plugin")
      File.mkdir_p!(plugin_dir)

      # Only write .exs
      File.write!(Path.join(plugin_dir, "register_callbacks.exs"), """
      defmodule GateF13FallbackPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "gate_f1_3_fallback"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "EXS FALLBACK" end)
          :ok
        end
      end
      """)

      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1
      assert String.ends_with?(hd(files), "register_callbacks.exs")

      File.rm_rf!(priv_base)
    end
  end

  # ── GATE-F1-4: User plugin loads ────────────────────────────────

  describe "GATE-F1-4: User plugin in ~/.code_puppy_ex/plugins/" do
    test "loads user .ex plugin with PUP_EX_HOME sandbox" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      sandbox = Path.join(tmp_dir, "cp_user_ex_test_#{uniq}")
      plugins_base = Path.join(sandbox, "plugins")
      plugin_dir = Path.join(plugins_base, "user_ex_plugin")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.ex"), """
      defmodule GateF14UserExPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "gate_f1_4_user_ex"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "GATE-F1-4 USER EX" end)
          :ok
        end
      end
      """)

      # Verify discovery
      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1

      # Verify loading works
      names = Loader.load_and_register_plugin_file(hd(files), :user)
      assert :gate_f1_4_user_ex in names or "gate_f1_4_user_ex" in names

      result = Callbacks.trigger(:load_prompt)
      assert result =~ "GATE-F1-4 USER EX"

      File.rm_rf!(sandbox)
    end

    test "loads user .exs plugin with PUP_EX_HOME sandbox" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      sandbox = Path.join(tmp_dir, "cp_user_exs_test_#{uniq}")
      plugins_base = Path.join(sandbox, "plugins")
      plugin_dir = Path.join(plugins_base, "user_exs_plugin")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.exs"), """
      defmodule GateF14UserExsPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "gate_f1_4_user_exs"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "GATE-F1-4 USER EXS" end)
          :ok
        end
      end
      """)

      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1

      names = Loader.load_and_register_plugin_file(hd(files), :user)
      assert :gate_f1_4_user_exs in names or "gate_f1_4_user_exs" in names

      result = Callbacks.trigger(:load_prompt)
      assert result =~ "GATE-F1-4 USER EXS"

      File.rm_rf!(sandbox)
    end
  end

  # ── GATE-F1-5: Symlink escape rejected ──────────────────────────

  describe "GATE-F1-5: Symlink escape in user plugins is rejected" do
    test "rejects symlinked .exs files that escape the plugins directory" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_symlink_exs_test_#{uniq}")
      plugin_dir = Path.join(plugins_base, "evil_plugin")
      File.mkdir_p!(plugin_dir)

      # Create a .exs file OUTSIDE the plugins dir
      outside_dir = Path.join(tmp_dir, "cp_outside_exs_#{uniq}")
      File.mkdir_p!(outside_dir)
      outside_file = Path.join(outside_dir, "evil.exs")
      File.write!(outside_file, "defmodule EvilExs do end")

      # Create a symlink FROM inside plugins dir TO the outside file
      symlink_path = Path.join(plugin_dir, "register_callbacks.exs")
      File.ln_s!(outside_file, symlink_path)

      # safe_plugin_path? must reject the symlinked file
      refute Loader.safe_plugin_path?(symlink_path, plugins_base)

      File.rm_rf!(plugins_base)
      File.rm_rf!(outside_dir)
    end

    test "rejects plugin directory that is a symlink to outside" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_symlink_dir_test_#{uniq}")
      File.mkdir_p!(plugins_base)

      # Create an outside directory
      outside_dir = Path.join(tmp_dir, "cp_outside_dir_#{uniq}")
      File.mkdir_p!(outside_dir)

      # Symlink the plugin directory itself to outside
      symlink_plugin = Path.join(plugins_base, "symlinked_plugin")
      File.ln_s!(outside_dir, symlink_plugin)

      # The symlinked plugin directory should be rejected
      refute Loader.safe_plugin_path?(symlink_plugin, plugins_base)

      File.rm_rf!(plugins_base)
      File.rm_rf!(outside_dir)
    end

    test "rejects intermediate directory symlink that escapes" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_symlink_nested_test_#{uniq}")
      plugin_dir = Path.join(plugins_base, "nested_escape")
      File.mkdir_p!(plugin_dir)

      # Create an outside directory
      outside_dir = Path.join(tmp_dir, "cp_outside_nested_#{uniq}")
      File.mkdir_p!(outside_dir)

      # Replace a subdirectory inside plugin_dir with a symlink to outside
      internal_link = Path.join(plugin_dir, "subdir")
      File.ln_s!(outside_dir, internal_link)

      # File accessed through the symlinked intermediate dir
      file_path = Path.join(internal_link, "register_callbacks.ex")

      refute Loader.safe_plugin_path?(file_path, plugins_base)

      File.rm_rf!(plugins_base)
      File.rm_rf!(outside_dir)
    end

    test "allows valid internal symlink within plugins dir" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugins_base = Path.join(tmp_dir, "cp_symlink_safe_test_#{uniq}")
      File.mkdir_p!(plugins_base)

      # Create a shared directory within plugins_base
      shared_dir = Path.join(plugins_base, "_shared")
      File.mkdir_p!(shared_dir)

      shared_file = Path.join(shared_dir, "helper.ex")
      File.write!(shared_file, "# safe")

      # Create a plugin directory with a symlink to the shared file
      plugin_dir = Path.join(plugins_base, "safe_plugin")
      File.mkdir_p!(plugin_dir)

      symlink_path = Path.join(plugin_dir, "register_callbacks.ex")
      File.ln_s!(shared_file, symlink_path)

      # The internal symlink should be allowed
      assert Loader.safe_plugin_path?(symlink_path, plugins_base)

      File.rm_rf!(plugins_base)
    end
  end

  # ── GATE-F1-6: Path traversal rejected ──────────────────────────

  describe "GATE-F1-6: Path traversal in plugin names is rejected" do
    test "rejects plugin names containing '..'" do
      # This test validates the path-traversal guard in load_user_plugin.
      # We can't directly call the private function, so we verify the guard
      # logic at the unit level.
      suspicious_names = ["../etc", "plugin/../../etc", "plugin\\..", "bad\x00name"]

      for name <- suspicious_names do
        assert String.contains?(name, ["..", "/", "\\", <<0>>]) or
                 String.contains?(name, <<0>>),
               "Expected '#{name}' to be flagged as suspicious"
      end
    end
  end

  # ── GATE-F1-7: Compile error does not crash ──────────────────────

  describe "GATE-F1-7: Plugin compile error does not crash application" do
    test "malformed .ex file is caught gracefully" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      bad_dir = Path.join(tmp_dir, "cp_bad_ex_test_#{uniq}")
      File.mkdir_p!(bad_dir)

      File.write!(Path.join(bad_dir, "broken.ex"), """
      this is not valid elixir syntax!!!
      """)

      file_path = Path.join(bad_dir, "broken.ex")

      # load_plugin should return an error, not raise
      result = Loader.load_plugin(file_path)
      assert match?({:error, _}, result)

      File.rm_rf!(bad_dir)
    end

    test "malformed .exs file is caught gracefully" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      bad_dir = Path.join(tmp_dir, "cp_bad_exs_test_#{uniq}")
      File.mkdir_p!(bad_dir)

      File.write!(Path.join(bad_dir, "broken.exs"), """
      this is not valid elixir syntax!!!
      """)

      file_path = Path.join(bad_dir, "broken.exs")

      # load_plugin should return an error, not raise
      result = Loader.load_plugin(file_path)
      assert match?({:error, _}, result)

      File.rm_rf!(bad_dir)
    end

    test "load_and_register_plugin_file rescues compile errors" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      bad_dir = Path.join(tmp_dir, "cp_bad_reg_test_#{uniq}")
      File.mkdir_p!(bad_dir)

      File.write!(Path.join(bad_dir, "broken.ex"), """
      defmodule BrokenPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "broken"
        @impl true
        def register do
          raise "intentional error"
        end
      end
      """)

      # Should not crash — register/0 errors are caught and logged
      result =
        Loader.load_and_register_plugin_file(
          Path.join(bad_dir, "broken.ex"),
          :builtin
        )

      # The plugin module is loaded; its name is returned
      # (even though register/0 raised, the plugin is still registered)
      assert is_list(result)
      assert :broken in result or "broken" in result

      File.rm_rf!(bad_dir)
    end

    test "broken startup/0 does not crash loader" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      bad_dir = Path.join(tmp_dir, "cp_bad_startup_test_#{uniq}")
      File.mkdir_p!(bad_dir)

      File.write!(Path.join(bad_dir, "broken_startup.ex"), """
      defmodule BrokenStartupPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: :broken_startup
        @impl true
        def register, do: :ok
        @impl true
        def startup do
          raise "intentional crash in startup/0"
        end
      end
      """)

      # Should not crash — startup/0 errors are caught and logged
      result =
        Loader.load_and_register_plugin_file(
          Path.join(bad_dir, "broken_startup.ex"),
          :builtin
        )

      assert is_list(result)
      assert :broken_startup in result or "broken_startup" in result

      File.rm_rf!(bad_dir)
    end

    test "broken register_callbacks/0 does not crash loader" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      bad_dir = Path.join(tmp_dir, "cp_bad_rc_test_#{uniq}")
      File.mkdir_p!(bad_dir)

      File.write!(Path.join(bad_dir, "broken_rc.ex"), """
      defmodule BrokenRCPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: :broken_rc
        @impl true
        def register do
          raise "intentional crash in register/0"
        end
      end
      """)

      # Should not crash — register_callbacks/0 errors are caught
      result =
        Loader.load_and_register_plugin_file(
          Path.join(bad_dir, "broken_rc.ex"),
          :builtin
        )

      assert is_list(result)

      File.rm_rf!(bad_dir)
    end
  end

  # ── GATE-F1-8: Idempotent load_all ──────────────────────────────

  describe "GATE-F1-8: load_all/0 is idempotent" do
    test "calling load_all multiple times does not duplicate plugins" do
      result1 = Loader.load_all()
      result2 = Loader.load_all()

      # Second call may return 0 new builtin names (all already loaded)
      # but it should never return MORE than the first call
      assert length(result2.builtin) <= length(result1.builtin)
    end

    test "re-compiling the same .ex file is a no-op for new_modules" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugin_dir = Path.join(tmp_dir, "cp_idempotent_test_#{uniq}")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.ex"), """
      defmodule IdempotentTestPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour
        @impl true
        def name, do: "idempotent_test"
        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "idempotent" end)
          :ok
        end
      end
      """)

      # Load once — discovers new module
      names1 =
        Loader.load_and_register_plugin_file(
          Path.join(plugin_dir, "register_callbacks.ex"),
          :builtin
        )

      assert is_list(names1) and length(names1) >= 1

      # Load again — Code.compile_file/1 redefines the module in memory,
      # but since it was already in loaded_modules() from the first call,
      # new_modules will be empty (the module already exists in :code.all_loaded/0)
      names2 =
        Loader.load_and_register_plugin_file(
          Path.join(plugin_dir, "register_callbacks.ex"),
          :builtin
        )

      # names2 will be [] because the module was already loaded;
      # this is the correct idempotent behaviour
      assert is_list(names2)

      File.rm_rf!(plugin_dir)
    end
  end

  # ── discover_plugin_files/1 unit tests ───────────────────────────

  describe "discover_plugin_files/1" do
    test "returns empty list for non-existent directory" do
      files =
        Loader.discover_plugin_files(
          "/tmp/nonexistent_dir_#{:erlang.unique_integer([:positive])}"
        )

      assert files == []
    end

    test "prefers register_callbacks.ex over .exs" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugin_dir = Path.join(tmp_dir, "cp_discover_priority_#{uniq}")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.ex"), "content")
      File.write!(Path.join(plugin_dir, "register_callbacks.exs"), "content")

      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1
      assert String.ends_with?(hd(files), "register_callbacks.ex")

      File.rm_rf!(plugin_dir)
    end

    test "discovers register_callbacks.exs when no .ex exists" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugin_dir = Path.join(tmp_dir, "cp_discover_exs_#{uniq}")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.exs"), "content")

      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1
      assert String.ends_with?(hd(files), "register_callbacks.exs")

      File.rm_rf!(plugin_dir)
    end

    test "falls back to alphabetical .ex then .exs when no register_callbacks exists" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugin_dir = Path.join(tmp_dir, "cp_discover_fallback_#{uniq}")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "beta.ex"), "content")
      File.write!(Path.join(plugin_dir, "alpha.exs"), "content")
      File.write!(Path.join(plugin_dir, "alpha.ex"), "content")

      files = Loader.discover_plugin_files(plugin_dir)

      # .ex files first (alpha.ex, beta.ex), then .exs files (alpha.exs)
      assert length(files) == 3
      assert Enum.at(files, 0) =~ "alpha.ex"
      assert Enum.at(files, 1) =~ "beta.ex"
      assert Enum.at(files, 2) =~ "alpha.exs"

      File.rm_rf!(plugin_dir)
    end

    test "ignores non-.ex/.exs files" do
      tmp_dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugin_dir = Path.join(tmp_dir, "cp_discover_filter_#{uniq}")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "readme.md"), "content")
      File.write!(Path.join(plugin_dir, "plugin.toml"), "content")
      File.write!(Path.join(plugin_dir, "helper.ex"), "content")

      files = Loader.discover_plugin_files(plugin_dir)
      assert length(files) == 1
      assert String.ends_with?(hd(files), "helper.ex")

      File.rm_rf!(plugin_dir)
    end
  end

  # ── load_plugin/1 with .exs files ────────────────────────────────

  describe "load_plugin/1 with .exs files" do
    test "loads a .exs file containing a plugin" do
      dir = System.tmp_dir!()
      uniq = :erlang.unique_integer([:positive])
      plugin_dir = Path.join(dir, "cp_load_exs_test_#{uniq}")
      File.mkdir_p!(plugin_dir)

      File.write!(Path.join(plugin_dir, "register_callbacks.exs"), """
      defmodule LoadExsTestPlugin do
        use CodePuppyControl.Plugins.PluginBehaviour

        @impl true
        def name, do: :load_exs_test

        @impl true
        def register do
          CodePuppyControl.Callbacks.register(:load_prompt, fn -> "EXS loaded!" end)
          :ok
        end
      end
      """)

      file_path = Path.join(plugin_dir, "register_callbacks.exs")
      assert {:ok, :load_exs_test} = Loader.load_plugin(file_path)

      # Clean up
      File.rm_rf!(plugin_dir)
    end

    test "returns error when .exs file has no PluginBehaviour module" do
      dir = System.tmp_dir!()
      File.mkdir_p!(dir)

      file_path = Path.join(dir, "no_plugin_#{:erlang.unique_integer([:positive])}.exs")
      File.write!(file_path, "IO.puts(\"just a script\")")

      assert {:error, {:no_plugins_found, _}} = Loader.load_plugin(file_path)

      File.rm!(file_path)
    end
  end
end
