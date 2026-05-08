defmodule CodePuppyControl.HookEngine.Executor do
  @moduledoc """
  Command execution engine for hooks.

  Handles command execution with timeout, variable substitution,
  and comprehensive error handling.

  Ported from `code_puppy/hook_engine/executor.py`.

  ## Exit Code Semantics (Claude Code compatible)

  - Exit code 0 => success, stdout shown in transcript
  - Exit code 1 => block the operation (stderr used as reason)
  - Exit code 2 => error feedback to Claude (stderr fed back as tool error)

  ## Non-Blocking Guarantee

  All execution runs in `Task.async` / `Task.await` with a timeout.
  Sequential execution uses `Enum.reduce_while` — each hook runs to
  completion before the next starts.  Parallel execution spawns one
  `Task.async` per hook and awaits all.

  No blocking I/O (e.g. `:timer.sleep/1`) is used inside async paths.
  """

  require Logger

  alias CodePuppyControl.HookEngine.{Matcher, Models}
  alias Models.{EventData, ExecutionResult, HookConfig}

  @doc """
  Executes a hook command with timeout and variable substitution.

  For `:prompt` hooks, returns the prompt text as stdout immediately.

  For `:command` hooks, runs via `System.cmd` in a `Task` with a
  hard timeout.  Stdin JSON is piped via shell redirect from a temp
  file (avoids shell-escaping hazards).
  """
  @spec execute_hook(HookConfig.t(), EventData.t(), keyword()) :: ExecutionResult.t()
  def execute_hook(hook, event_data, opts \\ [])

  def execute_hook(%HookConfig{type: :prompt} = hook, _event_data, _opts) do
    %ExecutionResult{
      blocked: false,
      hook_command: hook.command,
      stdout: hook.command,
      exit_code: 0,
      duration_ms: 0.0,
      hook_id: hook.id
    }
  end

  def execute_hook(%HookConfig{} = hook, %EventData{} = event_data, opts) do
    env_vars = Keyword.get(opts, :env_vars, %{})
    cwd = Keyword.get(opts, :cwd) || File.cwd!()

    command = substitute_variables(hook.command, event_data, env_vars)
    stdin_data = build_stdin_payload(event_data)
    env = build_environment(event_data, env_vars)
    start_time = System.monotonic_time(:millisecond)

    try do
      do_execute_command(hook, command, stdin_data, env, cwd, start_time)
    rescue
      e ->
        duration_ms = max(0.0, (System.monotonic_time(:millisecond) - start_time) * 1.0)
        Logger.error("Hook execution failed: #{Exception.message(e)}")

        %ExecutionResult{
          blocked: false,
          hook_command: hook.command,
          stdout: "",
          stderr: Exception.message(e),
          exit_code: -1,
          duration_ms: duration_ms,
          error: "Hook execution error: #{Exception.message(e)}",
          hook_id: hook.id
        }
    end
  end

  # Internal execution logic, separated so start_time scoping is explicit.
  @spec do_execute_command(HookConfig.t(), String.t(), String.t(), list(), String.t(), integer()) ::
          ExecutionResult.t()
  defp do_execute_command(hook, command, stdin_data, env, cwd, start_time) do
    # Create a private, unpredictable temp directory for this hook execution.
    # Uses 0700 perms so only the BEAM OS user can access it — prevents
    # symlink attacks and information leaks of hook JSON payloads.
    temp_dir = create_secure_temp_dir()

    try do
      do_execute_command_in_dir(hook, command, stdin_data, env, cwd, start_time, temp_dir)
    after
      # Clean up entire temp directory regardless of outcome.
      # This ensures hook JSON (stdin payload) never leaks to disk.
      File.rm_rf(temp_dir)
    end
  end

  @spec do_execute_command_in_dir(
          HookConfig.t(),
          String.t(),
          String.t(),
          list(),
          String.t(),
          integer(),
          String.t()
        ) :: ExecutionResult.t()
  defp do_execute_command_in_dir(hook, command, stdin_data, env, cwd, start_time, temp_dir) do
    # Write stdin data to a secure temp file (0600 perms, unpredictable name)
    stdin_path = write_temp_stdin(stdin_data, temp_dir)

    # Stderr capture path (same secure directory)
    stderr_path = secure_temp_path(temp_dir, "stderr")

    full_command =
      "( #{command} ) < #{shell_quote_path(stdin_path)} 2> #{shell_quote_path(stderr_path)}"

    task =
      Task.async(fn ->
        try do
          {stdout, exit_code} = System.cmd("sh", ["-c", full_command], env: env, cd: cwd)
          # Robust stderr read — handle :enoent and other error cases
          stderr = read_temp_file(stderr_path)
          {stdout, stderr, exit_code}
        rescue
          e ->
            {"", Exception.message(e), -1}
        catch
          kind, reason ->
            {"", Exception.format(kind, reason), -1}
        end
      end)

    result =
      case Task.yield(task, hook.timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {stdout, stderr, exit_code}} ->
          {:ok, stdout, stderr, exit_code}

        nil ->
          {:timeout}
      end

    duration_ms = max(0.0, (System.monotonic_time(:millisecond) - start_time) * 1.0)

    case result do
      {:ok, stdout, stderr, exit_code} ->
        blocked = exit_code == 1
        error = if exit_code != 0 and stderr != "", do: stderr, else: nil

        %ExecutionResult{
          blocked: blocked,
          hook_command: command,
          stdout: stdout,
          stderr: stderr,
          exit_code: exit_code,
          duration_ms: duration_ms,
          error: error,
          hook_id: hook.id
        }

      {:timeout} ->
        %ExecutionResult{
          blocked: true,
          hook_command: command,
          stdout: "",
          stderr: "Command timed out after #{hook.timeout}ms",
          exit_code: -1,
          duration_ms: duration_ms,
          error: "Hook execution timed out after #{hook.timeout}ms",
          hook_id: hook.id
        }
    end
  end

  @doc """
  Executes hooks sequentially with optional stop-on-block.

  Returns a list of `ExecutionResult` structs in registration order.
  """
  @spec execute_hooks_sequential([HookConfig.t()], EventData.t(), keyword()) ::
          [ExecutionResult.t()]
  def execute_hooks_sequential(hooks, event_data, opts \\ []) do
    stop_on_block = Keyword.get(opts, :stop_on_block, true)
    env_vars = Keyword.get(opts, :env_vars, %{})
    cwd = Keyword.get(opts, :cwd)

    Enum.reduce_while(hooks, [], fn hook, acc ->
      result =
        execute_hook(hook, event_data,
          env_vars: env_vars,
          cwd: cwd
        )

      if stop_on_block and result.blocked do
        Logger.debug("Hook blocked operation, stopping: #{hook.command}")
        {:halt, acc ++ [result]}
      else
        {:cont, acc ++ [result]}
      end
    end)
  end

  @doc """
  Executes hooks in parallel (async via Task).

  Returns a list of `ExecutionResult` structs in registration order.
  Each hook runs in its own Task with its own timeout.
  """
  @spec execute_hooks_parallel([HookConfig.t()], EventData.t(), keyword()) ::
          [ExecutionResult.t()]
  def execute_hooks_parallel(hooks, event_data, opts \\ []) do
    env_vars = Keyword.get(opts, :env_vars, %{})
    cwd = Keyword.get(opts, :cwd)

    tasks =
      Enum.map(hooks, fn hook ->
        Task.async(fn ->
          execute_hook(hook, event_data, env_vars: env_vars, cwd: cwd)
        end)
      end)

    # Await each task individually — preserves registration order
    tasks
    |> Enum.zip(hooks)
    |> Enum.map(fn {task, hook} ->
      case Task.yield(task, hook.timeout + 500) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          result

        nil ->
          %ExecutionResult{
            blocked: false,
            hook_command: hook.command,
            stdout: "",
            stderr: "Parallel hook timed out",
            exit_code: -1,
            duration_ms: 0.0,
            error: "Parallel hook execution timed out",
            hook_id: hook.id
          }
      end
    end)
  end

  @doc """
  Returns the first blocking result from a list, or nil.
  """
  @spec get_blocking_result([ExecutionResult.t()]) :: ExecutionResult.t() | nil
  def get_blocking_result(results) when is_list(results) do
    Enum.find(results, & &1.blocked)
  end

  @doc """
  Returns only the failed (unsuccessful) results.
  """
  @spec get_failed_results([ExecutionResult.t()]) :: [ExecutionResult.t()]
  def get_failed_results(results) when is_list(results) do
    Enum.reject(results, &ExecutionResult.success?/1)
  end

  @doc """
  Formats an execution summary string.
  """
  @spec format_execution_summary([ExecutionResult.t()]) :: String.t()
  def format_execution_summary([]), do: "No hooks executed"

  def format_execution_summary(results) when is_list(results) do
    total = length(results)
    successful = Enum.count(results, &ExecutionResult.success?/1)
    blocked_count = Enum.count(results, & &1.blocked)
    total_duration = Enum.reduce(results, 0.0, &(&1.duration_ms + &2))

    lines = [
      "Executed #{total} hook(s)",
      "Successful: #{successful}",
      "Blocked: #{blocked_count}",
      "Total duration: #{Float.round(total_duration, 2)}ms"
    ]

    lines =
      if blocked_count > 0 do
        blocking_hooks = Enum.filter(results, & &1.blocked)

        detail_lines =
          Enum.flat_map(blocking_hooks, fn result ->
            base = "  - #{result.hook_command}"
            if result.error, do: [base, "    Error: #{result.error}"], else: [base]
          end)

        lines ++ ["\nBlocking hooks:" | detail_lines]
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  # ── Private Helpers ─────────────────────────────────────────────

  @spec build_stdin_payload(EventData.t()) :: String.t()
  defp build_stdin_payload(%EventData{} = event_data) do
    payload = %{
      "session_id" => Map.get(event_data.context, "session_id", "codepuppy-session"),
      "hook_event_name" => event_data.event_type,
      "tool_name" => event_data.tool_name,
      "tool_input" => make_serializable(event_data.tool_args),
      "cwd" => File.cwd!(),
      "permission_mode" => "default"
    }

    payload =
      if Map.has_key?(event_data.context, "result") do
        Map.put(payload, "tool_result", make_serializable(event_data.context["result"]))
      else
        payload
      end

    payload =
      if Map.has_key?(event_data.context, "duration_ms") do
        Map.put(payload, "tool_duration_ms", event_data.context["duration_ms"])
      else
        payload
      end

    Jason.encode!(payload)
  end

  @spec substitute_variables(String.t(), EventData.t(), map()) :: String.t()
  defp substitute_variables(command, %EventData{} = event_data, env_vars) do
    substitutions = %{
      "CLAUDE_PROJECT_DIR" => File.cwd!(),
      "tool_name" => event_data.tool_name,
      "event_type" => event_data.event_type,
      "file" => Matcher.extract_file_path(event_data.tool_args) || "",
      "CLAUDE_TOOL_INPUT" => Jason.encode!(event_data.tool_args)
    }

    substitutions =
      if Map.has_key?(event_data.context, "result") do
        Map.put(substitutions, "result", to_string(event_data.context["result"]))
      else
        substitutions
      end

    substitutions =
      if Map.has_key?(event_data.context, "duration_ms") do
        Map.put(substitutions, "duration_ms", to_string(event_data.context["duration_ms"]))
      else
        substitutions
      end

    substitutions = Map.merge(substitutions, env_vars)

    Enum.reduce(substitutions, command, fn {var, value}, acc ->
      acc
      |> String.replace("${#{var}}", value)
      |> String.replace(~r/\$#{Regex.escape(var)}(?=\W|$)/, value)
    end)
  end

  @spec build_environment(EventData.t(), map()) :: [{String.t(), String.t()}]
  defp build_environment(%EventData{} = event_data, env_vars) do
    base = System.get_env() |> Enum.map(fn {k, v} -> {k, v} end)

    additions = %{
      "CLAUDE_PROJECT_DIR" => File.cwd!(),
      "CLAUDE_TOOL_INPUT" => Jason.encode!(event_data.tool_args),
      "CLAUDE_TOOL_NAME" => event_data.tool_name,
      "CLAUDE_HOOK_EVENT" => event_data.event_type,
      "CLAUDE_CODE_HOOK" => "1"
    }

    additions =
      case Matcher.extract_file_path(event_data.tool_args) do
        nil -> additions
        file_path -> Map.put(additions, "CLAUDE_FILE_PATH", file_path)
      end

    additions = Map.merge(additions, env_vars)

    Enum.reduce(additions, base, fn {key, val}, acc ->
      [{key, val} | Enum.reject(acc, fn {k, _} -> k == key end)]
    end)
  end

  @spec make_serializable(term()) :: term()
  defp make_serializable(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {make_serializable(k), make_serializable(v)} end)
  end

  defp make_serializable(value) when is_list(value) do
    Enum.map(value, &make_serializable/1)
  end

  defp make_serializable(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp make_serializable(value), do: inspect(value)

  # Create a private temp directory with restrictive permissions.
  # Uses :crypto.strong_rand_bytes for unpredictable naming and
  # chmod 0o700 so only the BEAM OS user can access it.
  @spec create_secure_temp_dir() :: String.t()
  defp create_secure_temp_dir do
    rand_suffix =
      :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower) |> String.slice(0, 24)

    dir = Path.join(System.tmp_dir!(), "codepuppy-hooks-#{rand_suffix}")
    File.mkdir_p!(dir)

    # Set 0700 permissions (owner-only access).
    # Gracefully handle platforms where chmod is unsupported (Windows).
    try do
      File.chmod!(dir, 0o700)
    rescue
      _ -> :ok
    end

    dir
  end

  # Generate a secure temp file path within the given directory.
  @spec secure_temp_path(String.t(), String.t()) :: String.t()
  defp secure_temp_path(temp_dir, prefix) do
    rand_suffix =
      :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower) |> String.slice(0, 12)

    Path.join(temp_dir, "#{prefix}_#{rand_suffix}")
  end

  # Write stdin payload to a secure temp file with 0600 permissions.
  @spec write_temp_stdin(String.t(), String.t()) :: String.t()
  defp write_temp_stdin(data, temp_dir) do
    path = secure_temp_path(temp_dir, "stdin")
    File.write!(path, data)

    # Set 0600 permissions (owner read/write only).
    # Gracefully handle platforms where chmod is unsupported.
    try do
      File.chmod!(path, 0o600)
    rescue
      _ -> :ok
    end

    path
  end

  # Read a temp file robustly — returns empty string on any error.
  @spec read_temp_file(String.t()) :: String.t()
  defp read_temp_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end

  # Quote a file path for safe embedding in a shell command.
  @spec shell_quote_path(String.t()) :: String.t()
  defp shell_quote_path(path) do
    # Replace single quotes with '\'' and wrap in single quotes
    "'" <> String.replace(path, "'", "'\\''") <> "'"
  end
end
