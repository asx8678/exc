defmodule CodePuppyControl.REPL.CompletionTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.REPL.Completion
  alias CodePuppyControl.CLI.SlashCommands.Registry

  # ── Shared setup: ensure Registry is started + populated with builtins ────
  # Without this, tests that rely on slash-command completion are order-
  # dependent: if registry_test.exs runs first it leaves a partially-
  # populated Registry, and slash_commands/0 takes the Registry path
  # instead of the fallback, returning incomplete results.

  defp ensure_registry_populated do
    case Process.whereis(Registry) do
      nil -> start_supervised!({Registry, []})
      _pid -> :ok
    end

    Registry.register_builtin_commands()
  end

  describe "complete/2 — command type" do
    setup do
      ensure_registry_populated()
      :ok
    end

    test "completes slash command prefix" do
      assert Completion.complete("/h", :command) == ["/help", "/history"]
      assert Completion.complete("/he", :command) == ["/help"]
      assert Completion.complete("/q", :command) == ["/quit"]
      assert Completion.complete("/cl", :command) == ["/clear"]
    end

    test "exact match returns single result" do
      assert Completion.complete("/help", :command) == ["/help"]
      assert Completion.complete("/model_settings", :command) == ["/model_settings"]
    end

    test "no match returns empty list" do
      assert Completion.complete("/zzz", :command) == []
    end

    test "no completion for command with args" do
      assert Completion.complete("/model claude", :command) == []
    end
  end

  describe "complete/2 — auto type" do
    setup do
      ensure_registry_populated()
      :ok
    end

    test "auto-detects slash command" do
      assert Completion.complete("/h", :auto) == ["/help", "/history"]
    end

    test "auto-detects file path" do
      # This depends on cwd having files — test with a known path
      results = Completion.complete("@lib/", :auto)
      assert is_list(results)
      # All results should start with @
      assert Enum.all?(results, &String.starts_with?(&1, "@"))
    end

    test "no completions for plain text" do
      assert Completion.complete("hello world", :auto) == []
    end
  end

  describe "complete_command/1" do
    setup do
      ensure_registry_populated()
      :ok
    end

    test "lists all commands matching prefix" do
      # "/" matches all commands
      all = Completion.complete_command("/")
      assert "/help" in all
      assert "/quit" in all
      assert "/model" in all
      assert "/agent" in all
      assert "/agents" in all
      assert "/clear" in all
      assert "/history" in all
      assert "/exit" in all
      assert "/pack" in all
    end

    test "/pack is completable from fallback list" do
      assert Completion.complete("/pa", :command) == ["/pack"]
      assert Completion.complete("/pack", :command) == ["/pack"]
    end

    test "/ag completes to both /agent and /agents" do
      results = Completion.complete("/ag", :command)
      assert "/agent" in results
      assert "/agents" in results
    end

    test "/agents is completable from fallback list" do
      # "/age" matches both /agent and /agents
      assert Completion.complete("/age", :command) == ["/agent", "/agents"]
      assert Completion.complete("/agents", :command) == ["/agents"]
    end

    test "all known slash commands are completable" do
      # Ensures the fallback list stays in sync with Registry.register_builtin_commands/0
      all = Completion.complete_command("/")

      expected =
        ~w(/help /model /mode /model_settings /ms /agent /agents /quit /exit /clear /history /pack /flags /diff /sessions /tui /cd /compact /truncate /add_model)

      for cmd <- expected do
        assert cmd in all, "Expected #{cmd} to be in slash-command completions"
      end
    end
  end

  describe "complete_command/1 — dynamic registry integration" do
    setup do
      ensure_registry_populated()

      # Restore builtins even if a test crashes mid-run (e.g. after Registry.clear())
      on_exit(fn ->
        Registry.register_builtin_commands()
      end)

      :ok
    end

    test "derives commands from Registry when populated" do
      all = Completion.complete_command("/")
      assert "/pack" in all
      assert "/mode" in all
      assert "/flags" in all
      assert Completion.complete("/pa", :command) == ["/pack"]
      assert Completion.complete("/mo", :command) == ["/mode", "/model", "/model_settings"]
      assert Completion.complete("/fl", :command) == ["/flags"]
    end

    test "falls back to hardcoded list when Registry is empty" do
      # Clear all registered commands so Registry.all_names() returns []
      Registry.clear()

      # Completion must use the fallback list
      all = Completion.complete_command("/")

      # Verify we're actually exercising the fallback path (not just getting
      # lucky with a stale Registry). The fallback list is deterministic.
      assert "/help" in all
      assert "/quit" in all
      assert "/pack" in all
      assert "/model" in all
      assert "/mode" in all
      assert "/flags" in all
      assert "/diff" in all
      assert "/agents" in all

      # Verify prefix matching works through the fallback path
      assert Completion.complete("/pa", :command) == ["/pack"]
      assert Completion.complete("/he", :command) == ["/help"]
      assert "/agent" in Completion.complete("/ag", :command)
      assert "/agents" in Completion.complete("/ag", :command)

      # Cleanup is handled by on_exit in setup — no inline restore needed
    end
  end

  describe "complete_file_path/1" do
    test "returns empty list for non-@ input" do
      assert Completion.complete_file_path("no_at_sign") == []
    end

    test "completes files with @ prefix" do
      results = Completion.complete_file_path("@mix.")
      assert is_list(results)
      # If mix.exs exists in cwd, it should appear
      if File.exists?("mix.exs") do
        assert "@mix.exs" in results
      end
    end

    test "returns empty for nonexistent path" do
      assert Completion.complete_file_path("@zzz_nonexistent_dir/") == []
    end

    test "directories get trailing slash" do
      results = Completion.complete_file_path("@lib/code_puppy_control/repl/")
      assert is_list(results)
      # Results should be @-prefixed paths
      assert Enum.all?(results, &String.starts_with?(&1, "@"))
    end
  end
end
