defmodule CodePuppyControl.Tools.CpShell do
  @moduledoc """
  `:cp_`-prefixed Tool-behaviour wrapper for shell command execution.

  Exposes `CodePuppyControl.Tools.CommandRunner` through the Tool
  behaviour so the CodePuppy agent can call `cp_run_command` via
  the tool registry.

  ## Tools

  - `CpRunCommand` — Execute a shell command (standard, PTY, or background mode)

  Refs: code_puppy-mmk.6 (Phase E port)
  """

  defmodule CpRunCommand do
    @moduledoc """
    Executes a shell command in the project directory.

    Delegates to `CodePuppyControl.Tools.CommandRunner.run/2`.

    ## Modes

    - **Standard** (default) — Uses `sh -c` for shell interpretation
    - **PTY** (`pty: true`) — Uses PtyManager for interactive terminal emulation
    - **Background** (`background: true`) — Detached process with log file
    """

    use CodePuppyControl.Tool

    @impl true
    def name, do: :cp_run_command

    @impl true
    def description do
      "Execute a shell command with comprehensive monitoring and " <>
        "safety features. Supports streaming output, timeout " <>
        "handling, PTY execution, and background execution."
    end

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to execute"
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Timeout in seconds (default: 60, max: 270)"
          },
          "cwd" => %{
            "type" => "string",
            "description" => "Working directory for the command (optional)"
          },
          "pty" => %{
            "type" => "boolean",
            "description" =>
              "Use PTY execution for interactive terminal emulation (default: false)"
          },
          "background" => %{
            "type" => "boolean",
            "description" =>
              "Run command in background mode, returns immediately with log file path (default: false)"
          }
        },
        "required" => ["command"]
      }
    end

    @impl true
    def invoke(args, _context) do
      command = Map.get(args, "command", "")
      timeout = Map.get(args, "timeout")
      cwd = Map.get(args, "cwd")
      pty = Map.get(args, "pty", false)
      background = Map.get(args, "background", false)

      opts =
        []
        |> maybe_put(:timeout, timeout)
        |> maybe_put(:cwd, cwd)
        |> maybe_put(:pty, pty)
        |> maybe_put(:background, background)

      case CodePuppyControl.Tools.CommandRunner.run(command, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end

    @impl true
    def permission_check(_args, _context) do
      # Delegate to CommandRunner security pipeline
      # The Tool behaviour default :ok allows CommandRunner.run/2
      # to handle security internally (PolicyEngine + callbacks + validator)
      :ok
    end

    defp maybe_put(opts, _key, nil), do: opts
    defp maybe_put(opts, _key, false), do: opts
    defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
  end
end
