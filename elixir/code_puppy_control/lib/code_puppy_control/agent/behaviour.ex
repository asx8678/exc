defmodule CodePuppyControl.Agent.Behaviour do
  @moduledoc """
  Behaviour that all Code Puppy agents must implement.

  This defines the contract for agent modules — the "what" of an agent.
  The "how" (the run loop, tool dispatch, streaming) lives in `Agent.Loop`.

  ## Behaviour vs Protocol

  - **Behaviour** (`@behaviour CodePuppyControl.Agent.Behaviour`) — compile-time
    contract for modules. Every agent module MUST implement the mandatory
    callbacks and MAY override the optional ones.

  - **Protocol** (`CodePuppyControl.Agent.Protocol`) — runtime polymorphism
    for any data type. Use this when you need to dispatch on structs, maps,
    or JSON-deserialized agents without requiring a module definition.

  | Concern | Behaviour | Protocol |
  |---------|-----------|----------|
  | When | Static module definition | Runtime data dispatch |
  | Example | `MyApp.Agents.ElixirDev` | `%MyApp.JsonAgent{prompt: "..."}` |
  | Compile-time | Yes (dialyzer checks) | No (runtime dispatch) |
  | Extensibility | Override callbacks | `defimpl` for any type |

  ## Mandatory callbacks

  - `name/0` — unique atom identifier
  - `system_prompt/1` — base prompt given context
  - `allowed_tools/0` — tool whitelist
  - `model_preference/0` — preferred LLM model

  ## Optional callbacks

  - `get_system_prompt/0` — convenience 0-arity version
  - `get_full_system_prompt/0` — base + platform + identity + plugin additions
  - `run/2` — execute agent with user prompt and context
  - `display_name/0` — human-readable name
  - `description/0` — what the agent does
  - `user_prompt/0` — custom prefix
  - `tools_config/0` — tool overrides
  - `response_schema/0` — validation schema
  - `on_before_run/1`, `on_after_run/2` — lifecycle hooks
  - `on_tool_result/3` — tool result inspector

  ## Example

      defmodule MyApp.Agents.ElixirDev do
        use CodePuppyControl.Agent.Behaviour

        @impl true
        def name, do: :elixir_dev

        @impl true
        def system_prompt(_context) do
          "You are an expert Elixir developer..."
        end

        @impl true
        def allowed_tools, do: [:file_read, :file_write, :shell]

        @impl true
        def model_preference, do: "claude-sonnet-4-20250514"

        @impl true
        def on_tool_result(_tool_name, _result, state), do: {:cont, state}
      end
  """

  @typedoc """
  Context map passed to callbacks. Contains runtime information about
  the current run, including session, messages, and caller-supplied opts.
  """
  @type context :: %{
          optional(:session_id) => String.t(),
          optional(:run_id) => String.t(),
          optional(:messages) => [map()],
          optional(:metadata) => map(),
          optional(atom()) => term()
        }

  @typedoc """
  Mutable state carried through a run. Agents can extend this via
  `on_tool_result/3` to track domain-specific state across turns.
  """
  @type agent_state :: %{
          optional(:turn_number) => non_neg_integer(),
          optional(:tool_results) => [map()],
          optional(atom()) => term()
        }

  @typedoc """
  Result of running an agent via `run/2`.
  """
  @type run_result :: {:ok, %{messages: [map()], response: String.t()}} | {:error, term()}

  # ── Mandatory callbacks ─────────────────────────────────────────────────

  @doc """
  Returns the unique atom name for this agent.

  Used for registration, logging, and telemetry.
  """
  @callback name() :: atom()

  @doc """
  Returns the system prompt for this agent, given the current context.

  The context includes session_id, run_id, and any caller-supplied metadata.
  The returned string becomes the system message in the LLM conversation.
  """
  @callback system_prompt(context()) :: String.t()

  @doc """
  Returns the list of tool names this agent is allowed to call.

  Tool dispatch in the loop will reject calls to tools not in this list.
  """
  @callback allowed_tools() :: [atom()]

  @doc """
  Returns the preferred model for this agent.

  Can be a model name string (e.g. `"claude-sonnet-4-20250514"`) or
  a `{:pack, :role}` tuple for model pack resolution.
  """
  @callback model_preference() :: String.t() | {:pack, atom()}

  # ── Optional callbacks ──────────────────────────────────────────────────

  @doc """
  Returns the base system prompt with default (empty) context.

  Convenience 0-arity wrapper around `system_prompt/1`.
  """
  @callback get_system_prompt() :: String.t()

  @doc """
  Returns the complete system prompt with platform info, identity, and plugins.

  Assembles: base prompt + plugin additions + platform context + agent identity.
  """
  @callback get_full_system_prompt() :: String.t()

  @doc """
  Runs the agent with a user prompt and context.

  Default implementation delegates to `Agent.Loop`. Agents may override
  this to customize execution strategy (e.g., pre-processing prompts,
  post-processing responses, or using a different loop implementation).

  Returns `{:ok, %{messages: [...], response: text}}` on success or
  `{:error, reason}` on failure.
  """
  @callback run(user_prompt :: String.t(), context()) :: run_result()

  @doc """
  Returns the human-readable display name for this agent.

  Used in the TUI agent selector and log messages.
  Default: title-cased version of `name/0` atom.
  """
  @callback display_name() :: String.t()

  @doc """
  Returns a brief description of what this agent does.

  Shown in `/agents` output and the agent selector.
  Default: empty string.
  """
  @callback description() :: String.t()

  @doc """
  Returns an optional custom user prompt prefix.

  When defined, this text is prepended to the user's message.
  Return `nil` to use the user's message as-is (default).
  """
  @callback user_prompt() :: String.t() | nil

  @doc """
  Returns optional tool configuration overrides.

  When defined, returns a map of tool-specific configuration
  (e.g. timeouts, permission modes). Return `nil` for defaults.
  """
  @callback tools_config() :: map() | nil

  @doc """
  Called before the agent run starts.

  Receives the run context. Return `{:ok, context}` to proceed
  (possibly with modified context) or `{:error, reason}` to abort.

  Plugins can use this to inject runtime dependencies or veto runs.
  Default: always proceed.
  """
  @callback on_before_run(context()) :: {:ok, context()} | {:error, term()}

  @doc """
  Called after the agent run completes (success or failure).

  Receives the final context and result summary. Return value is ignored.
  Useful for cleanup, logging, and side effects.
  Default: no-op.
  """
  @callback on_after_run(context(), result :: map()) :: :ok

  @doc """
  Returns an optional Ecto schema module for validating text responses.

  When defined and returning a module, the agent loop will pass text-only
  responses (no tool calls) through `ResponseValidator.validate/2`. This
  enables typed, validated structured output from LLMs.

  Return `nil` to skip validation (default).

  ## Example

      @impl true
      def response_schema, do: MyAgent.PlanResponse

  See `CodePuppyControl.Agent.ResponseValidator` for schema requirements.
  """
  @callback response_schema() :: module() | nil

  @doc """
  Called after a tool execution completes.

  The agent can inspect the result and either:
  - `{:cont, state}` — continue the run loop
  - `{:halt, reason}` — stop the run early (e.g. user interrupt, fatal error)

  The `state` map is agent-owned mutable state that persists across turns.
  Default implementation: always continue.
  """
  @callback on_tool_result(tool_name :: atom(), result :: term(), agent_state()) ::
              {:cont, agent_state()} | {:halt, term()}

  @optional_callbacks [
    get_system_prompt: 0,
    get_full_system_prompt: 0,
    run: 2,
    display_name: 0,
    description: 0,
    user_prompt: 0,
    tools_config: 0,
    response_schema: 0,
    on_before_run: 1,
    on_after_run: 2
  ]

  # ── Using macro ─────────────────────────────────────────────────────────

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour CodePuppyControl.Agent.Behaviour

      @impl true
      def get_system_prompt, do: system_prompt(%{})

      @impl true
      def get_full_system_prompt do
        base_prompt = system_prompt(%{})
        identity = CodePuppyControl.Agent.PromptMixin.get_identity(name(), "")
        CodePuppyControl.Agent.PromptMixin.get_full_system_prompt(base_prompt, identity)
      end

      @impl true
      def run(user_prompt, context) do
        messages = [
          %{"role" => "system", "content" => get_full_system_prompt()},
          %{"role" => "user", "content" => user_prompt}
        ]

        opts =
          Map.take(context, [:session_id, :run_id, :metadata])
          |> Enum.to_list()

        {:ok, pid} = CodePuppyControl.Agent.Loop.start_link(__MODULE__, messages, opts)
        :ok = CodePuppyControl.Agent.Loop.run_until_done(pid)

        final_messages = CodePuppyControl.Agent.Loop.get_messages(pid)
        # Extract the last assistant response as the text result
        response =
          final_messages
          |> Enum.reverse()
          |> Enum.find_value("", fn
            %{"role" => "assistant", "content" => text} when is_binary(text) -> text
            _ -> nil
          end)

        {:ok, %{messages: final_messages, response: response}}
      end

      @impl true
      def on_tool_result(_tool_name, _result, state), do: {:cont, state}

      @impl true
      def response_schema, do: nil

      @impl true
      def display_name do
        name()
        |> Atom.to_string()
        |> String.replace("_", " ")
        |> String.split(" ")
        |> Enum.map(&String.capitalize/1)
        |> Enum.join(" ")
      end

      @impl true
      def description, do: ""

      @impl true
      def user_prompt, do: nil

      @impl true
      def tools_config, do: nil

      @impl true
      def on_before_run(context), do: {:ok, context}

      @impl true
      def on_after_run(_context, _result), do: :ok

      defoverridable get_system_prompt: 0,
                     get_full_system_prompt: 0,
                     run: 2,
                     on_tool_result: 3,
                     response_schema: 0,
                     display_name: 0,
                     description: 0,
                     user_prompt: 0,
                     tools_config: 0,
                     on_before_run: 1,
                     on_after_run: 2
    end
  end
end
