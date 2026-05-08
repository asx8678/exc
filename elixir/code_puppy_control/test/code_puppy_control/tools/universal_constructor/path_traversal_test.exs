defmodule CodePuppyControl.Tools.UniversalConstructor.PathTraversalTest do
  @moduledoc """
  Regression tests for code_puppy-mmk.2: path-traversal and atom-safety hardening
  in Universal Constructor CreateAction and Validator.

  These tests verify that:
  1. Path traversal via tool_name, namespace, or metadata is blocked
  2. Absolute paths are rejected
  3. Containment checks prevent escape from UC tools directory
  4. Arbitrary UC tool names do not create atoms
  """

  # async: false — we mutate PUP_EX_HOME (global env var) for filesystem
  # isolation; async: true would race with other test modules.
  use ExUnit.Case, async: false

  alias CodePuppyControl.Tools.UniversalConstructor.CreateAction
  alias CodePuppyControl.Tools.UniversalConstructor.Validator

  # ---------------------------------------------------------------------------
  # Sandbox: redirect all UC writes to a throwaway temp dir.
  # Without this, CreateAction.execute/3 writes to the REAL
  # ~/.code_puppy_ex/plugins/universal_constructor/ (code_puppy-mmk.2).
  #
  # We must also repoint the Registry GenServer's tools_dir because
  # UniversalConstructor.run/1 calls Registry.ensure_tools_dir() which
  # creates the directory from the Registry's *stored* tools_dir — not
  # from Paths.universal_constructor_dir() (which reads PUP_EX_HOME).
  # ---------------------------------------------------------------------------
  setup_all do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "uc_path_traversal_#{:erlang.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(tmp)

    prev_ex_home = System.get_env("PUP_EX_HOME")
    System.put_env("PUP_EX_HOME", tmp)

    # Repoint the Registry GenServer so ensure_tools_dir uses the sandbox
    uc_registry = CodePuppyControl.Tools.UniversalConstructor.Registry

    orig_tools_dir =
      case Process.whereis(uc_registry) do
        nil -> nil
        _pid -> :sys.get_state(uc_registry).tools_dir
      end

    sandbox_uc_dir = CodePuppyControl.Config.Paths.universal_constructor_dir()

    if Process.whereis(uc_registry) do
      CodePuppyControl.Tools.UniversalConstructor.Registry.set_tools_dir(sandbox_uc_dir)
    end

    on_exit(fn ->
      # Restore Registry tools_dir before env var so it points to the
      # real path when env is restored.
      if orig_tools_dir != nil and Process.whereis(uc_registry) do
        try do
          CodePuppyControl.Tools.UniversalConstructor.Registry.set_tools_dir(orig_tools_dir)
        catch
          :exit, _ -> :ok
        end
      end

      case prev_ex_home do
        nil -> System.delete_env("PUP_EX_HOME")
        v -> System.put_env("PUP_EX_HOME", v)
      end

      File.rm_rf(tmp)
    end)

    :ok
  end

  # ==========================================================================
  # Safe-Identifier Validation (CreateAction.validate_safe_identifier/1)
  # ==========================================================================

  describe "validate_safe_identifier/1 — path-traversal blocking (code_puppy-mmk.2)" do
    test "rejects parent-directory traversal '..'" do
      assert {:error, msg} = CreateAction.validate_safe_identifier("../evil")
      # May be caught by '/' or '..' check — both are path-traversal vectors
      assert msg =~ ".." or msg =~ "/"
    end

    test "rejects double parent-directory traversal" do
      assert {:error, _} = CreateAction.validate_safe_identifier("../../evil")
    end

    test "rejects forward slash" do
      assert {:error, msg} = CreateAction.validate_safe_identifier("namespace/evil")
      assert msg =~ "/"
    end

    test "rejects backslash" do
      assert {:error, msg} = CreateAction.validate_safe_identifier("namespace\\evil")
      assert msg =~ "\\"
    end

    test "rejects absolute Unix path" do
      assert {:error, _} = CreateAction.validate_safe_identifier("/etc/passwd")
    end

    test "rejects empty string" do
      assert {:error, _} = CreateAction.validate_safe_identifier("")
    end

    test "rejects names starting with dot" do
      assert {:error, _} = CreateAction.validate_safe_identifier(".hidden")
    end

    test "rejects names with spaces" do
      assert {:error, _} = CreateAction.validate_safe_identifier("my tool")
    end

    test "rejects names with special shell characters" do
      assert {:error, _} = CreateAction.validate_safe_identifier("tool;rm")
      assert {:error, _} = CreateAction.validate_safe_identifier("tool$(cmd)")
      assert {:error, _} = CreateAction.validate_safe_identifier("tool`whoami`")
    end

    test "accepts simple alphanumeric names" do
      assert :ok = CreateAction.validate_safe_identifier("my_tool")
      assert :ok = CreateAction.validate_safe_identifier("tool123")
      assert :ok = CreateAction.validate_safe_identifier("Tool-Name")
    end

    test "accepts namespaced dot-separated names" do
      assert :ok = CreateAction.validate_safe_identifier("api.weather")
      assert :ok = CreateAction.validate_safe_identifier("ns.sub.tool_name")
    end

    test "accepts names with underscores and hyphens" do
      assert :ok = CreateAction.validate_safe_identifier("my_tool_v2")
      assert :ok = CreateAction.validate_safe_identifier("my-tool-v2")
    end

    test "rejects non-string input" do
      assert {:error, _} = CreateAction.validate_safe_identifier(nil)
      assert {:error, _} = CreateAction.validate_safe_identifier(123)
    end
  end

  # ==========================================================================
  # CreateAction.execute/3 — end-to-end path-traversal rejection
  # ==========================================================================

  describe "CreateAction.execute/3 — path-traversal rejection (code_puppy-mmk.2)" do
    # Code WITHOUT @uc_tool so tool_name is actually used for path construction
    @no_meta_code """
    defmodule PathTestTool do
      def run(_), do: :ok
    end
    """

    test "rejects tool_name with parent-directory traversal" do
      result =
        CreateAction.execute(
          "../evil",
          @no_meta_code,
          "Traversal test"
        )

      assert result.success == false

      assert result.error =~ ".." or result.error =~ "/" or
               result.error =~ "Identifier"
    end

    test "rejects tool_name with forward slash" do
      result =
        CreateAction.execute(
          "namespace/evil",
          @no_meta_code,
          "Traversal test"
        )

      assert result.success == false
      assert result.error =~ "/" or result.error =~ "Identifier"
    end

    test "rejects tool_name that is an absolute path" do
      result =
        CreateAction.execute(
          "/etc/passwd",
          @no_meta_code,
          "Traversal test"
        )

      assert result.success == false
    end

    test "rejects code with @uc_tool name containing traversal" do
      traversal_code = """
      defmodule TraversalTool do
        @uc_tool %{name: "../../evil", description: "Traversal"}
        def run(_), do: :ok
      end
      """

      result =
        CreateAction.execute(
          nil,
          traversal_code,
          "Traversal test"
        )

      assert result.success == false

      assert result.error =~ ".." or result.error =~ "traversal" or
               result.error =~ "Identifier"
    end

    test "rejects code with @uc_tool namespace containing traversal" do
      traversal_ns_code = """
      defmodule TraversalNSTool do
        @uc_tool %{name: "safe_name", namespace: "../evil", description: "Traversal NS"}
        def run(_), do: :ok
      end
      """

      result =
        CreateAction.execute(
          nil,
          traversal_ns_code,
          "Traversal NS test"
        )

      assert result.success == false

      assert result.error =~ ".." or result.error =~ "traversal" or
               result.error =~ "Identifier"
    end

    test "accepts safe tool name" do
      safe_code = """
      defmodule SafeTool do
        @uc_tool %{name: "safe_tool_xyz", description: "Safe"}
        def run(_), do: :ok
      end
      """

      result =
        CreateAction.execute(
          "safe_tool_xyz",
          safe_code,
          "Safe test"
        )

      # With PUP_EX_HOME sandboxed, the file write should succeed;
      # regardless, it must NOT fail due to identifier / path-traversal
      # validation.
      if result.success do
        # Verify the file landed inside the sandbox, not the real home
        uc_dir = CodePuppyControl.Config.Paths.universal_constructor_dir()
        assert String.starts_with?(uc_dir, System.get_env("PUP_EX_HOME"))
      else
        refute result.error =~ "traversal"
        refute result.error =~ "Identifier"
      end
    end
  end

  # ==========================================================================
  # Atom Safety (Validator.find_main_function/2)
  # ==========================================================================

  describe "Validator.find_main_function/2 — atom safety (code_puppy-mmk.2)" do
    test "arbitrary unique tool names do not create new atoms" do
      # Generate a name guaranteed not to be an atom
      unique_name = "atom_safety_test_#{:erlang.unique_integer([:positive])}"

      # Pre-check: not an atom yet
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique_name) end

      functions = [
        %{name: :run, arity: 1, signature: "run/1", docstring: nil, line_number: 0}
      ]

      # Call find_main_function with the unique name — it should NOT
      # create the atom
      result = Validator.find_main_function(functions, unique_name)

      # Should fall back to :run
      assert result.name == :run

      # Post-check: the atom still doesn't exist
      assert_raise ArgumentError, fn -> String.to_existing_atom(unique_name) end
    end

    test "known existing atoms still match correctly" do
      # :run is always an existing atom
      functions = [
        %{name: :run, arity: 1, signature: "run/1", docstring: nil, line_number: 0}
      ]

      result = Validator.find_main_function(functions, "run")
      assert result.name == :run
    end
  end
end
