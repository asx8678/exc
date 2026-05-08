defmodule CodePuppyControl.Tool do
  @moduledoc """
  Behaviour for CodePuppy tools.

  Every tool module that participates in the tool registry must implement
  this behaviour. It defines the contract for tool discovery, schema
  declaration, invocation, and permission checks.

  ## Quick Start

      defmodule MyApp.Tools.Greeter do
        use CodePuppyControl.Tool

        @impl true
        def name, do: :greeter

        @impl true
        def description, do: "Greets a user by name"

        @impl true
        def parameters do
          %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string", "description" => "Name to greet"}
            },
            "required" => ["name"]
          }
        end

        @impl true
        def invoke(args, _context) do
          {:ok, "Hello, \#{args["name"]}!"}
        end
      end

  ## Default Implementations

  When you `use CodePuppyControl.Tool`, the following defaults are provided:

  - `permission_check/2` — always returns `:ok` (allow all)
  - `tool_schema/0` — returns a default tool schema map for LLM consumption
  - `invoke/2` — delegates to `execute/1` if the module defines it (legacy compat)

  Override any of these by defining your own `@impl true` version.
  """

  # ── Callbacks ────────────────────────────────────────────────────────────

  @doc "The unique atom name for this tool, used for lookup and telemetry."
  @callback name() :: atom()

  @doc "Human-readable description of what this tool does."
  @callback description() :: String.t()

  @doc "JSON Schema map describing the tool's parameters."
  @callback parameters() :: map()

  @doc """
  Invokes the tool with parsed arguments and a context map.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  The context map includes `:run_id`, `:agent_module`, and other
  runtime metadata from the agent loop.
  """
  @callback invoke(args :: map(), context :: map()) :: {:ok, term()} | {:error, term()}

  @doc """
  Permission check called before invocation.

  Return `:ok` to allow or `{:deny, reason}` to block. The default
  implementation always allows.
  """
  @callback permission_check(args :: map(), context :: map()) :: :ok | {:deny, term()}

  @doc """
  Returns a tool definition map suitable for LLM function-calling APIs.

  Default implementation builds it from `name/0`, `description/0`, and
  `parameters/0`.
  """
  @callback tool_schema() :: map()

  # ── __using__ Macro ──────────────────────────────────────────────────────

  defmacro __using__(_opts) do
    quote do
      @behaviour CodePuppyControl.Tool

      # Default permission_check: allow everything
      @impl true
      def permission_check(_args, _context), do: :ok

      # Default tool_schema: build from name, description, parameters
      @impl true
      def tool_schema do
        %{
          type: "function",
          function: %{
            name: to_string(name()),
            description: description(),
            parameters: parameters()
          }
        }
      end

      # Default invoke: delegate to execute/1 if defined (legacy compat)
      @impl true
      def invoke(args, _context) do
        if function_exported?(__MODULE__, :execute, 1) do
          apply(__MODULE__, :execute, [args])
        else
          {:error, "#{inspect(name())} does not implement invoke/2 or execute/1"}
        end
      end

      defoverridable permission_check: 2, tool_schema: 0, invoke: 2
    end
  end

  # ── Helper Functions ─────────────────────────────────────────────────────

  @doc """
  Converts a tool module into the LLM provider tool format.

  This is the format expected by `CodePuppyControl.LLM.Provider`:
  `%{type: "function", function: %{name: "...", description: "...", parameters: %{}}}`

  ## Examples

      iex> Tool.to_llm_format(MyApp.Tools.Greeter)
      %{type: "function", function: %{name: "greeter", description: "Greets a user", parameters: %{...}}}
  """
  @spec to_llm_format(module()) :: map()
  def to_llm_format(tool_module) when is_atom(tool_module) do
    if function_exported?(tool_module, :tool_schema, 0) do
      tool_module.tool_schema()
    else
      # Fallback for modules without the behaviour
      %{
        type: "function",
        function: %{
          name: to_string(tool_module.name()),
          description: tool_module.description(),
          parameters: tool_module.parameters()
        }
      }
    end
  end
end
