defmodule CodePuppyControl.Plugins.TurboExecutor do
  @moduledoc """
  Turbo Executor Plugin — Batch file operation delegation.

  Provides the `/turbo` slash command and `turbo_execute` tool for
  delegating batch file operations (>5 files) to a sub-agent.

  Ported from Python: code_puppy/plugins/turbo_executor/register_callbacks.py

  ## v1 Scope

  - `/turbo status` — reports plugin availability
  - `/turbo help` — shows usage instructions
  - `/turbo plan <json>` — parses but does NOT execute plans (stub)
  - `turbo_execute` tool — returns a stub response
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  alias CodePuppyControl.Callbacks

  @supported_ops ~w(list_files grep read_files)a
  @version "0.1.0"

  @impl true
  def name, do: "turbo_executor"

  @impl true
  def description, do: "Batch file operation delegation via /turbo command and turbo_execute tool"

  @impl true
  def register do
    Callbacks.register(:custom_command, &__MODULE__.handle_custom_command/2)
    Callbacks.register(:custom_command_help, &__MODULE__.custom_command_help/0)
    Callbacks.register(:register_tools, &__MODULE__.register_tools/0)
    Callbacks.register(:load_prompt, &__MODULE__.load_prompt/0)
    :ok
  end

  # ── Custom Command Handler ───────────────────────────────────────

  @doc false
  @spec handle_custom_command(String.t(), String.t()) :: String.t() | nil
  def handle_custom_command(command, name) do
    case name do
      "turbo" -> handle_turbo(command)
      _ -> nil
    end
  end

  defp handle_turbo(command) do
    case parse_subcommand(command) do
      {"status", _} -> status_message()
      {"help", _} -> help_message()
      {"plan", json} -> handle_plan(json)
      _ -> "⚡ Unknown /turbo subcommand. Try `/turbo help`."
    end
  end

  defp parse_subcommand(command) do
    rest =
      command
      |> String.trim_leading("/turbo")
      |> String.trim()

    case String.split(rest, " ", parts: 2) do
      [""] -> {nil, nil}
      [sub] -> {sub, nil}
      [sub, rest] -> {sub, rest}
    end
  end

  defp status_message do
    ops = Enum.join(@supported_ops, ", ")

    """
    ⚡ Turbo Executor v#{@version}
    Status: available (stub mode)
    Supported ops: #{ops}
    Delegation: invoke_agent("turbo-executor", prompt)
    """
  end

  defp help_message do
    """
    ⚡ Turbo Executor — Batch File Operations

    Commands:
      /turbo status   Show plugin status and supported ops
      /turbo help     Show this help message
      /turbo plan <json>  Submit a plan JSON (stub — parsed but not executed)

    Tool:
      turbo_execute   Delegate batch file ops to turbo-executor agent

    Plan JSON format:
      {
        "operations": [
          {"op": "list_files", "path": "src/"},
          {"op": "grep", "pattern": "TODO", "path": "src/"},
          {"op": "read_files", "paths": ["src/main.ex"]}
        ]
      }

    Supported operations: #{Enum.join(@supported_ops, ", ")}
    """
  end

  defp handle_plan(json) when is_binary(json) and json != "" do
    case Jason.decode(json) do
      {:ok, plan} ->
        ops = Map.get(plan, "operations", [])
        count = length(ops)
        unsupported = find_unsupported(ops)

        if unsupported == [] do
          "⚡ Plan accepted (#{count} operations). Execution not yet implemented in v1."
        else
          bad = Enum.join(unsupported, ", ")
          "⚡ Plan has unsupported ops: #{bad}. Supported: #{Enum.join(@supported_ops, ", ")}"
        end

      {:error, _} ->
        "⚡ Invalid JSON in plan. Try `/turbo help` for format."
    end
  end

  defp handle_plan(_), do: "⚡ Usage: /turbo plan <json>. Try `/turbo help` for format."

  defp find_unsupported(ops) do
    supported_strings = Enum.map(@supported_ops, &Atom.to_string/1)

    ops
    |> Enum.map(&Map.get(&1, "op", ""))
    |> Enum.filter(fn op -> op != "" and op not in supported_strings end)
    |> Enum.uniq()
  end

  # ── Custom Command Help ──────────────────────────────────────────

  @doc false
  @spec custom_command_help() :: [{String.t(), String.t()}]
  def custom_command_help do
    [{"turbo", "Batch file operations: status, help, plan <json>"}]
  end

  # ── Tool Registration ────────────────────────────────────────────

  @doc false
  @spec register_tools() :: [map()]
  def register_tools do
    [
      %{
        "name" => "turbo_execute",
        "register_func" => fn ->
          %{
            name: "turbo_execute",
            description: "Delegate batch file operations (>5 files) to turbo-executor agent.",
            parameters: %{
              type: "object",
              properties: %{
                operations: %{
                  type: "array",
                  description: "List of file operations to execute in batch",
                  items: %{
                    type: "object",
                    properties: %{
                      op: %{
                        type: "string",
                        description: "Operation: list_files, grep, read_files"
                      },
                      path: %{type: "string", description: "Target path for the operation"},
                      pattern: %{type: "string", description: "Search pattern (grep only)"},
                      paths: %{
                        type: "array",
                        items: %{type: "string"},
                        description: "File paths (read_files only)"
                      }
                    },
                    required: ["op"]
                  }
                }
              },
              required: ["operations"]
            },
            handler: &__MODULE__.execute_tool/1
          }
        end
      }
    ]
  end

  @doc false
  @spec execute_tool(map()) :: map()
  def execute_tool(args) do
    operations = Map.get(args, "operations", [])
    count = length(operations)

    %{
      status: "stub",
      message: "⚡ Turbo execute received #{count} operation(s). Execution not implemented in v1.",
      operations_received: count,
      supported_ops: Enum.map(@supported_ops, &Atom.to_string/1)
    }
  end

  # ── Prompt Addition ─────────────────────────────────────────────

  @doc false
  @spec load_prompt() :: String.t()
  def load_prompt do
    """

    ## 🚀 Turbo Executor
    For batch file ops (>5 files), use `invoke_agent("turbo-executor", prompt)` or the `turbo_execute` tool. Run `/turbo help` for details.
    """
  end
end
