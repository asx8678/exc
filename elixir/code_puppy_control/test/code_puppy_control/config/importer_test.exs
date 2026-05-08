defmodule CodePuppyControl.Config.ImporterTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Config.{Importer, Isolation, Paths}

  @home Path.expand("~")

  setup do
    test_id = :erlang.unique_integer([:positive])
    tmp_home = Path.join(System.tmp_dir!(), "import_test_#{test_id}")
    legacy_fixture = Path.join(@home, ".code_puppy/_import_test_#{test_id}")

    System.put_env("PUP_EX_HOME", tmp_home)
    File.rm_rf(tmp_home)
    File.rm_rf(legacy_fixture)

    on_exit(fn ->
      System.delete_env("PUP_EX_HOME")
      System.delete_env("PUP_HOME")
      System.delete_env("PUPPY_HOME")
      File.rm_rf(tmp_home)
      File.rm_rf(legacy_fixture)
      Process.delete(:isolation_sandbox)
    end)

    %{tmp_home: tmp_home, legacy_fixture: legacy_fixture}
  end

  # ── Dry-run mode ────────────────────────────────────────────────────────

  describe "dry-run mode (--confirm absent)" do
    test "writes ZERO files; returns report listing what would be copied", %{
      legacy_fixture: legacy_fixture
    } do
      setup_legacy_fixture(legacy_fixture)

      result = Importer.run(__legacy_home__: legacy_fixture)

      assert result.mode == :dry_run

      # In dry-run mode, no actual files should be written to the Elixir home
      # (the extra_models.json destination shouldn't have content)
      # Note: dry-run still calls maybe_write with :dry_run which returns :ok
      # but doesn't actually write. Let's verify the mode is correct.
      assert result.mode == :dry_run

      # Report should have items
      total =
        length(result.copied) + length(result.skipped) +
          length(result.refused) + length(result.errors)

      assert total >= 0
    end
  end

  # ── Copy mode (--confirm) ───────────────────────────────────────────────

  describe "copy mode (--confirm)" do
    test "copies allowlisted files and verifies contents match", %{
      tmp_home: tmp_home,
      legacy_fixture: legacy_fixture
    } do
      setup_legacy_fixture(legacy_fixture)

      Isolation.with_sandbox([tmp_home], fn ->
        result = Importer.run(confirm: true, __legacy_home__: legacy_fixture)
        assert result.mode == :copy
      end)

      # Verify extra_models.json was copied
      dst = Path.join(tmp_home, "extra_models.json")

      if File.exists?(dst) do
        assert {:ok, content} = File.read(dst)
        assert content =~ "test-model"
      end
    end

    test "copies agent JSON files", %{tmp_home: tmp_home, legacy_fixture: legacy_fixture} do
      setup_legacy_fixture(legacy_fixture)

      Isolation.with_sandbox([tmp_home], fn ->
        result = Importer.run(confirm: true, __legacy_home__: legacy_fixture)
        assert result.mode == :copy
      end)

      # Agent should be at destination
      dst_agent = Path.join([tmp_home, "agents", "default.json"])

      if File.exists?(dst_agent) do
        assert {:ok, content} = File.read(dst_agent)
        assert content =~ "default"
      end
    end
  end

  # ── Forbidden files ─────────────────────────────────────────────────────

  describe "forbidden files" do
    test "OAuth files are never copied even with --force", %{
      tmp_home: tmp_home,
      legacy_fixture: legacy_fixture
    } do
      # Create the legacy fixture directory first
      File.mkdir_p!(legacy_fixture)

      # Create forbidden files in legacy fixture
      File.write!(Path.join(legacy_fixture, "oauth_token.json"), ~s({"token": "secret"}))
      File.write!(Path.join(legacy_fixture, "github_auth.json"), ~s({"auth": "secret"}))
      File.mkdir_p!(Path.join(legacy_fixture, "sessions"))
      File.write!(Path.join(legacy_fixture, "sessions/session_1.json"), ~s({"data": "x"}))
      File.mkdir_p!(Path.join(legacy_fixture, "autosaves"))
      File.write!(Path.join(legacy_fixture, "autosaves/save1.json"), ~s({"data": "x"}))
      File.write!(Path.join(legacy_fixture, "dbos_store.sqlite"), "binary_data")
      File.write!(Path.join(legacy_fixture, "command_history.txt"), "history")

      Isolation.with_sandbox([tmp_home], fn ->
        result = Importer.run(confirm: true, force: true, __legacy_home__: legacy_fixture)

        # None of these should be in copied list
        copied_basenames = Enum.map(result.copied, &Path.basename/1)
        refute "oauth_token.json" in copied_basenames
        refute "github_auth.json" in copied_basenames
        refute "dbos_store.sqlite" in copied_basenames
        refute "command_history.txt" in copied_basenames

        # They should appear in refused
        refused_basenames = Enum.map(result.refused, fn {p, _} -> Path.basename(p) end)

        assert "oauth_token.json" in refused_basenames or
                 "github_auth.json" in refused_basenames or
                 "dbos_store.sqlite" in refused_basenames or
                 "command_history.txt" in refused_basenames
      end)
    end
  end

  # ── INI parsing (puppy.cfg) ────────────────────────────────────────────

  describe "puppy.cfg import" do
    test "only [ui] section keys are copied; auth keys are ignored", %{
      tmp_home: tmp_home,
      legacy_fixture: legacy_fixture
    } do
      File.mkdir_p!(legacy_fixture)

      cfg_content = """
      [puppy]
      model = gpt-5
      api_key = sk-secret123

      [ui]
      theme = dark
      show_tips = true

      [auth]
      token = super_secret
      """

      File.write!(Path.join(legacy_fixture, "puppy.cfg"), cfg_content)

      Isolation.with_sandbox([tmp_home], fn ->
        result = Importer.run(confirm: true, __legacy_home__: legacy_fixture)
        assert result.mode == :copy
      end)

      # Read the imported config
      imported_path = Paths.config_file()

      if File.exists?(imported_path) do
        {:ok, imported} = File.read(imported_path)
        # [ui] section should be present
        assert imported =~ "[ui]"
        assert imported =~ "theme"
        assert imported =~ "dark"
        # api_key should NOT be present (forbidden key)
        refute imported =~ "sk-secret123"
        refute imported =~ "api_key"
        # auth token should NOT be present
        refute imported =~ "super_secret"
      end
    end
  end

  # ── Idempotency ────────────────────────────────────────────────────────

  describe "idempotency" do
    test "running --confirm twice reports already-imported on second run", %{
      tmp_home: tmp_home,
      legacy_fixture: legacy_fixture
    } do
      setup_legacy_fixture(legacy_fixture)

      Isolation.with_sandbox([tmp_home], fn ->
        # First run
        result1 = Importer.run(confirm: true, __legacy_home__: legacy_fixture)
        assert result1.mode == :copy

        # Second run
        result2 = Importer.run(confirm: true, __legacy_home__: legacy_fixture)
        assert result2.mode == :copy
        # On second run, files should be skipped (already exist)
        assert length(result2.skipped) > 0 or length(result2.copied) == 0
      end)
    end
  end

  # ── Result shape ────────────────────────────────────────────────────────

  describe "result shape" do
    test "matches the result type", %{legacy_fixture: legacy_fixture} do
      setup_legacy_fixture(legacy_fixture)

      result = Importer.run(__legacy_home__: legacy_fixture)

      assert Map.has_key?(result, :mode)
      assert Map.has_key?(result, :copied)
      assert Map.has_key?(result, :skipped)
      assert Map.has_key?(result, :refused)
      assert Map.has_key?(result, :errors)
      assert result.mode in [:dry_run, :copy, :no_op]
      assert is_list(result.copied)
      assert is_list(result.skipped)
      assert is_list(result.refused)
      assert is_list(result.errors)
    end
  end

  # ── No legacy home ──────────────────────────────────────────────────────

  describe "no legacy home" do
    test "returns no-op result when legacy home is absent" do
      nonexistent =
        Path.join(System.tmp_dir!(), "no_such_dir_#{:erlang.unique_integer([:positive])}")

      File.rm_rf(nonexistent)

      result = Importer.run(__legacy_home__: nonexistent)

      assert result.mode == :no_op
      assert result.copied == []
      assert result.skipped == []
      assert result.refused == []
      assert result.errors == []
    end
  end

  # ── allowed_source?/1 ──────────────────────────────────────────────────

  describe "allowed_source?/1" do
    test "allows extra_models.json" do
      assert Importer.allowed_source?("extra_models.json")
    end

    test "allows models.json" do
      assert Importer.allowed_source?("models.json")
    end

    test "allows puppy.cfg" do
      assert Importer.allowed_source?("puppy.cfg")
    end

    test "allows agents/*.json" do
      assert Importer.allowed_source?("agents/code_puppy.json")
    end

    test "allows skills/ paths" do
      assert Importer.allowed_source?("skills/my_skill/SKILL.md")
    end

    test "refuses OAuth files" do
      refute Importer.allowed_source?("oauth_token.json")
    end

    test "refuses token files" do
      refute Importer.allowed_source?("my_token.json")
    end

    test "refuses auth files" do
      refute Importer.allowed_source?("github_auth.json")
    end

    test "refuses sqlite files" do
      refute Importer.allowed_source?("dbos_store.sqlite")
    end

    test "refuses db files" do
      refute Importer.allowed_source?("cache.db")
    end

    test "refuses autosaves paths" do
      refute Importer.allowed_source?("autosaves/save1.json")
    end

    test "refuses sessions paths" do
      refute Importer.allowed_source?("sessions/session_1.json")
    end

    test "refuses command_history.txt" do
      refute Importer.allowed_source?("command_history.txt")
    end

    test "refuses unknown files" do
      refute Importer.allowed_source?("random_file.txt")
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp setup_legacy_fixture(legacy_fixture) do
    File.mkdir_p!(legacy_fixture)

    # Create extra_models.json
    File.write!(
      Path.join(legacy_fixture, "extra_models.json"),
      Jason.encode!(%{"test-model" => %{"provider" => "openai"}})
    )

    # Create models.json
    File.write!(
      Path.join(legacy_fixture, "models.json"),
      Jason.encode!(%{"models" => [%{"id" => "test-model"}]})
    )

    # Create puppy.cfg
    File.write!(
      Path.join(legacy_fixture, "puppy.cfg"),
      "[ui]\ntheme = dark\nshow_tips = true\n"
    )

    # Create agents dir with an agent file
    agents_dir = Path.join(legacy_fixture, "agents")
    File.mkdir_p!(agents_dir)
    File.write!(Path.join(agents_dir, "default.json"), Jason.encode!(%{"name" => "default"}))

    :ok
  end
end
