defmodule CodePuppyControl.CLI.SlashCommands.Commands.AutosaveLoadTest do
  @moduledoc """
  Tests for /autosave_load (alias: /resume) slash command.

  Uses real SessionStorage with isolated directories under
  ~/.code_puppy_ex/sessions/ for test data.
  """

  use ExUnit.Case, async: false

  alias CodePuppyControl.CLI.SlashCommands.Commands.AutosaveLoad
  alias CodePuppyControl.REPL.Loop
  alias CodePuppyControl.SessionStorage

  # ── Setup ─────────────────────────────────────────────────────────────

  setup do
    # Create a unique test directory under the allowed base path
    base = Path.expand("~/.code_puppy_ex/sessions")
    test_dir = Path.join(base, "autosave_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)

    # (code_puppy-i1n) Ensure Agent.State.Supervisor is alive.
    CodePuppyControl.TestSupport.Reset.ensure_gen_server_started(
      CodePuppyControl.Agent.State.Supervisor
    )

    # Start RuntimeState if not running
    case Process.whereis(CodePuppyControl.RuntimeState) do
      nil -> start_supervised!(CodePuppyControl.RuntimeState)
      _pid -> :ok
    end

    {:ok, base_dir: test_dir}
  end

  defp make_state(session_id \\ nil, agent_name \\ "test-agent") do
    %Loop{
      agent: agent_name,
      model: "gpt-4",
      session_id: session_id,
      running: true
    }
  end

  defp save_autosave(name, messages, base_dir: dir, timestamp: ts) do
    SessionStorage.save_session(name, messages,
      base_dir: dir,
      auto_saved: true,
      total_tokens: 100,
      timestamp: ts
    )
  end

  defp save_autosave(name, messages, base_dir: dir) do
    SessionStorage.save_session(name, messages,
      base_dir: dir,
      auto_saved: true,
      total_tokens: 100,
      timestamp: "2025-06-15T12:00:00Z"
    )
  end

  defp save_regular_session(name, messages, base_dir: dir) do
    SessionStorage.save_session(name, messages,
      base_dir: dir,
      auto_saved: false,
      total_tokens: 50
    )
  end

  # ── No autosaves ──────────────────────────────────────────────────────

  describe "/autosave_load with no autosaves" do
    test "prints friendly message when no sessions exist at all", %{base_dir: dir} do
      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} =
                   AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert output =~ "No autosaved sessions found"
    end

    test "prints friendly message when only non-autosave sessions exist", %{base_dir: dir} do
      save_regular_session("manual_session", [%{"role" => "user", "content" => "hi"}],
        base_dir: dir
      )

      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert {:continue, ^state} =
                   AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert output =~ "No autosaved sessions found"
    end

    test "prints hint about starting a conversation", %{base_dir: dir} do
      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert output =~ "auto-saved"
    end
  end

  # ── Single autosave ───────────────────────────────────────────────────

  describe "/autosave_load with a single autosave" do
    test "loads the autosave directly", %{base_dir: dir} do
      session_name = "auto_session_20250615_120000"
      messages = [%{"role" => "user", "content" => "hello"}]

      {:ok, _} = save_autosave(session_name, messages, base_dir: dir)

      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          result = AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
          assert {:continue, _new_state} = result
        end)

      assert output =~ "Loading autosave"
      assert output =~ session_name
    end

    test "prints success with message count", %{base_dir: dir} do
      session_name = "auto_session_20250615_120000"
      messages = [%{"role" => "user", "content" => "hello"}]

      {:ok, _} = save_autosave(session_name, messages, base_dir: dir)

      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert output =~ "Loaded"
    end

    test "updates state with new session_id", %{base_dir: dir} do
      session_name = "auto_session_20250615_120000"
      messages = [%{"role" => "user", "content" => "hello"}]

      {:ok, _} = save_autosave(session_name, messages, base_dir: dir)

      state = make_state("old-session")

      {result, new_state} =
        ExUnit.CaptureIO.with_io(fn ->
          AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert {:continue, updated} = result
      assert updated.session_id == session_name
      # new_state is the captured IO output, not the return value
      _ = new_state
    end
  end

  # ── Multiple autosaves ────────────────────────────────────────────────

  describe "/autosave_load with multiple autosaves" do
    test "shows numbered list of autosaves", %{base_dir: dir} do
      {:ok, _} =
        save_autosave("auto_session_20250615_140000", [%{"role" => "user", "content" => "hi2"}],
          base_dir: dir,
          timestamp: "2025-06-15T14:00:00Z"
        )

      {:ok, _} =
        save_autosave("auto_session_20250615_120000", [%{"role" => "user", "content" => "hi1"}],
          base_dir: dir,
          timestamp: "2025-06-15T12:00:00Z"
        )

      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io([input: "1\n"], fn ->
          AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert output =~ "Multiple autosaved sessions found"
      assert output =~ "1."
      assert output =~ "2."
    end

    test "cancels on empty input", %{base_dir: dir} do
      {:ok, _} =
        save_autosave("auto_session_20250615_140000", [%{"role" => "user", "content" => "hi"}],
          base_dir: dir
        )

      {:ok, _} =
        save_autosave("auto_session_20250615_120000", [%{"role" => "user", "content" => "hi"}],
          base_dir: dir
        )

      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io([input: "\n"], fn ->
          assert {:continue, ^state} =
                   AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert output =~ "Cancelled"
    end

    test "shows error on invalid (non-numeric) selection", %{base_dir: dir} do
      {:ok, _} =
        save_autosave("auto_session_20250615_140000", [%{"role" => "user", "content" => "hi"}],
          base_dir: dir
        )

      {:ok, _} =
        save_autosave("auto_session_20250615_120000", [%{"role" => "user", "content" => "hi"}],
          base_dir: dir
        )

      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io([input: "abc\n"], fn ->
          assert {:continue, ^state} =
                   AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert output =~ "Invalid selection"
    end

    test "shows error on out-of-range selection", %{base_dir: dir} do
      {:ok, _} =
        save_autosave("auto_session_20250615_140000", [%{"role" => "user", "content" => "hi"}],
          base_dir: dir
        )

      {:ok, _} =
        save_autosave("auto_session_20250615_120000", [%{"role" => "user", "content" => "hi"}],
          base_dir: dir
        )

      state = make_state()

      output =
        ExUnit.CaptureIO.capture_io([input: "99\n"], fn ->
          assert {:continue, ^state} =
                   AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
        end)

      assert output =~ "Invalid selection"
    end

    test "loads selected autosave by number", %{base_dir: dir} do
      {:ok, _} =
        save_autosave("auto_session_20250615_140000", [%{"role" => "user", "content" => "hi2"}],
          base_dir: dir,
          timestamp: "2025-06-15T14:00:00Z"
        )

      {:ok, _} =
        save_autosave("auto_session_20250615_120000", [%{"role" => "user", "content" => "hi1"}],
          base_dir: dir,
          timestamp: "2025-06-15T12:00:00Z"
        )

      state = make_state()

      # Select the second autosave
      output =
        ExUnit.CaptureIO.capture_io([input: "2\n"], fn ->
          result = AutosaveLoad.handle_autosave_load("/autosave_load", state, base_dir: dir)
          assert {:continue, _new_state} = result
        end)

      assert output =~ "Loading autosave"
      assert output =~ "auto_session_20250615_120000"
    end
  end

  # ── Alias /resume ─────────────────────────────────────────────────────

  describe "registry integration" do
    setup do
      alias CodePuppyControl.CLI.SlashCommands.Registry

      # Start the Registry GenServer if not already running
      case Process.whereis(Registry) do
        nil -> start_supervised!({Registry, []})
        _pid -> :ok
      end

      Registry.clear()
      Registry.register_builtin_commands()

      :ok
    end

    test "/autosave_load is registered in the session category" do
      alias CodePuppyControl.CLI.SlashCommands.Registry

      assert {:ok, cmd} = Registry.get("autosave_load")
      assert cmd.name == "autosave_load"
      assert cmd.category == "session"
    end

    test "/resume resolves to autosave_load command" do
      alias CodePuppyControl.CLI.SlashCommands.Registry

      assert {:ok, cmd} = Registry.get("resume")
      assert cmd.name == "autosave_load"
      assert cmd.category == "session"
    end

    test "/autosave_load has correct handler reference" do
      alias CodePuppyControl.CLI.SlashCommands.Registry

      assert {:ok, cmd} = Registry.get("autosave_load")
      assert is_function(cmd.handler, 2)
    end
  end
end
