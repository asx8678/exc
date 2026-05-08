defmodule CodePuppyControl.Tools.CpUniversalConstructor do
  @moduledoc """
  `:cp_`-prefixed Tool-behaviour wrapper for the Universal Constructor.

  Exposes `CodePuppyControl.Tools.UniversalConstructor.run/1` through
  the Tool behaviour so agents can call `cp_universal_constructor` via
  the tool registry.

  ## Actions

  The Universal Constructor supports five actions via the `action` parameter:

  - `list` — List all available UC tools
  - `call` — Execute a specific UC tool with arguments
  - `create` — Create a new UC tool from Elixir code
  - `update` — Modify an existing UC tool
  - `info` — Get detailed info about a specific tool

  ## Python Compatibility

  The `python_code` parameter is accepted as an alias for `elixir_code`
  to maintain compatibility with agents that were trained on the Python
  tool interface. When `python_code` is provided and `elixir_code` is not,
  the tool returns an error explaining that only Elixir code is supported
  in this environment.

  Refs: code_puppy-mmk.2 (Phase E port)
  """

  use CodePuppyControl.Tool

  alias CodePuppyControl.Tools.UniversalConstructor

  @impl true
  def name, do: :cp_universal_constructor

  @impl true
  def description do
    "Universal Constructor - Your gateway to unlimited capabilities. " <>
      "Create, manage, and call custom tools dynamically. " <>
      "Actions: list, call, create, update, info."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ["list", "call", "create", "update", "info"],
          "description" => "The operation to perform: list, call, create, update, or info"
        },
        "tool_name" => %{
          "type" => "string",
          "description" =>
            "Name of the tool (for call/update/info). " <>
              "Supports namespaced format like 'namespace.tool_name'."
        },
        "tool_args" => %{
          "type" => "object",
          "description" => "Arguments to pass when calling a tool (for call action)"
        },
        "elixir_code" => %{
          "type" => "string",
          "description" => "Elixir source code for the tool (for create/update actions)"
        },
        "python_code" => %{
          "type" => "string",
          "description" =>
            "Alias for elixir_code (Python compatibility). " <>
              "Note: Only Elixir code is supported in this environment."
        },
        "description" => %{
          "type" => "string",
          "description" => "Human-readable description (for create action)"
        }
      },
      "required" => ["action"]
    }
  end

  @impl true
  def invoke(args, _context) do
    # Check if UC is enabled
    unless CodePuppyControl.Config.Debug.universal_constructor_enabled?() do
      {:ok,
       %{
         action: Map.get(args, "action", "list"),
         success: false,
         error:
           "Universal Constructor is disabled. Enable it with /set enable_universal_constructor=true",
         list_result: nil,
         call_result: nil,
         create_result: nil,
         update_result: nil,
         info_result: nil
       }}
    else
      do_invoke(args)
    end
  end

  defp do_invoke(args) do
    action = Map.get(args, "action", "list")
    tool_name = Map.get(args, "tool_name")
    tool_args = Map.get(args, "tool_args")
    elixir_code = resolve_code_arg(args)
    description = Map.get(args, "description")

    result =
      UniversalConstructor.run(
        action: action,
        tool_name: tool_name,
        tool_args: tool_args,
        elixir_code: elixir_code,
        description: description
      )

    # Emit event via EventBus
    emit_uc_event(result)

    # Always return {:ok, result} to preserve UniversalConstructorOutput shape.
    # Expected operation failures (unknown action, tool not found, validation
    # errors) have success: false with error field populated.
    # Reserve {:error, reason} only for unexpected infrastructure failures.
    {:ok, result}
  end

  # Handle python_code → elixir_code compatibility bridge
  defp resolve_code_arg(args) do
    elixir_code = Map.get(args, "elixir_code")
    python_code = Map.get(args, "python_code")

    cond do
      is_binary(elixir_code) and elixir_code != "" ->
        elixir_code

      is_binary(python_code) and python_code != "" ->
        # Python code was provided but we only accept Elixir.
        # Return it as-is; the UC validator will reject it if it's
        # not valid Elixir syntax, giving a clear error message.
        python_code

      true ->
        nil
    end
  end

  defp emit_uc_event(result) do
    event = %{
      type: "tool_output",
      tool: "universal_constructor",
      data: %{
        action: result.action,
        success: result.success,
        error: result.error
      }
    }

    CodePuppyControl.EventBus.broadcast_event(event)
  end
end
