defmodule CodePuppyControl.CLI.SessionResumeTestLoop do
  @moduledoc false

  def run(opts) do
    test_pid = Application.fetch_env!(:code_puppy_control, :cli_session_resume_test_pid)
    send(test_pid, {:loop_run, opts})
    :ok
  end
end

defmodule CodePuppyControl.CLI.SessionResumeTest do
  use ExUnit.Case, async: false

  alias CodePuppyControl.Agent.State
  alias CodePuppyControl.CLI
  alias CodePuppyControl.CLI.SessionResumeTestLoop
  alias CodePuppyControl.SessionStorage
  alias CodePuppyControl.SessionStorage.Format

  @telemetry_event [:code_puppy, :session, :resume]

  setup do
    base_dir =
      System.tmp_dir!()
      |> Path.join("code_puppy_session_resume_#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(base_dir)

    test_pid = self()
    previous_loop_module = Application.get_env(:code_puppy_control, :cli_repl_loop_module)
    previous_halt_fun = Application.get_env(:code_puppy_control, :cli_halt_fun)
    previous_test_pid = Application.get_env(:code_puppy_control, :cli_session_resume_test_pid)

    Application.put_env(:code_puppy_control, :cli_repl_loop_module, SessionResumeTestLoop)
    Application.put_env(:code_puppy_control, :cli_session_resume_test_pid, test_pid)

    Application.put_env(:code_puppy_control, :cli_halt_fun, fn status ->
      send(test_pid, {:cli_halt, status})
      throw({:cli_halt, status})
    end)

    handler_id = "session-resume-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      @telemetry_event,
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:session_resume_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler_id)
      restore_env(:cli_repl_loop_module, previous_loop_module)
      restore_env(:cli_halt_fun, previous_halt_fun)
      restore_env(:cli_session_resume_test_pid, previous_test_pid)
      File.rm_rf!(base_dir)
    end)

    {:ok, base_dir: base_dir}
  end

  describe "CLI.resolve_run_mode/1" do
    test "continue flag resolves independently of the side-effecting run path" do
      assert :continue_session = CLI.resolve_run_mode(%{continue: true})
    end
  end

  describe "CLI.run/1 with --continue" do
    test "restores the newest persisted session and starts the interactive loop", %{
      base_dir: base_dir
    } do
      old_messages = [message("old prompt")]
      latest_messages = [message("latest prompt"), assistant_message("latest reply")]

      {:ok, _meta} =
        SessionStorage.save_session("old-session", old_messages,
          base_dir: base_dir,
          timestamp: "2025-01-01T00:00:00Z"
        )

      {:ok, _meta} =
        SessionStorage.save_session("latest-session", latest_messages,
          base_dir: base_dir,
          timestamp: "2025-02-01T00:00:00Z"
        )

      output = run_continue(base_dir)

      refute output =~ "No previous session found"
      refute output =~ "Could not restore previous session"

      assert_received {:loop_run, loop_opts}
      assert loop_opts[:session_id] == "latest-session"
      refute Map.has_key?(loop_opts, :session_storage_opts)

      assert State.get_messages("latest-session", "code_puppy") == latest_messages

      assert_received {:session_resume_telemetry, measurements,
                       %{session_id: "latest-session", restored: true, reason: :latest}}

      assert is_integer(measurements.system_time)
      assert is_integer(measurements.monotonic_time)
    end

    test "falls back to fresh interactive mode with a friendly message when no session exists", %{
      base_dir: base_dir
    } do
      output = run_continue(base_dir)

      assert output =~ "No previous session found, starting fresh."
      assert_received {:loop_run, loop_opts}
      refute Map.has_key?(loop_opts, :session_id)

      assert_received {:session_resume_telemetry, _measurements,
                       %{session_id: nil, restored: false, reason: :no_sessions}}
    end

    test "falls back to fresh interactive mode when the latest session cannot be loaded", %{
      base_dir: base_dir
    } do
      write_corrupt_session(base_dir, "bad-session")

      output =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:captured_io, run_continue(base_dir)})
        end)
        |> then(fn _log -> receive_captured_io() end)

      assert output =~ "Could not restore previous session, starting fresh."
      assert_received {:loop_run, loop_opts}
      refute Map.has_key?(loop_opts, :session_id)

      assert_received {:session_resume_telemetry, _measurements,
                       %{session_id: "bad-session", restored: false, reason: :load_failed}}
    end
  end

  defp run_continue(base_dir) do
    ExUnit.CaptureIO.capture_io(fn ->
      assert catch_throw(CLI.run(%{continue: true, session_storage_opts: [base_dir: base_dir]})) ==
               {:cli_halt, 0}

      assert_received {:cli_halt, 0}
    end)
  end

  defp receive_captured_io do
    receive do
      {:captured_io, output} -> output
    after
      0 -> ""
    end
  end

  defp write_corrupt_session(base_dir, session_name) do
    paths = Format.build_paths(base_dir, session_name)

    metadata = %{
      "session_name" => session_name,
      "timestamp" => "2025-03-01T00:00:00Z",
      "message_count" => 1,
      "total_tokens" => 0,
      "auto_saved" => false
    }

    File.write!(paths.metadata_path, Jason.encode!(metadata))
    File.write!(paths.session_path, "{definitely-not-json")
  end

  defp message(text) do
    %{"role" => "user", "parts" => [%{"type" => "text", "text" => text}]}
  end

  defp assistant_message(text) do
    %{"role" => "assistant", "parts" => [%{"type" => "text", "text" => text}]}
  end

  defp restore_env(key, nil), do: Application.delete_env(:code_puppy_control, key)
  defp restore_env(key, value), do: Application.put_env(:code_puppy_control, key, value)
end
