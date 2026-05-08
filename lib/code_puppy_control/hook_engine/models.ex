defmodule CodePuppyControl.HookEngine.Models do
  @moduledoc """
  Data models for the hook engine.

  Defines all data structures used throughout the hook engine with
  validation and type safety. Ported from `code_puppy/hook_engine/models.py`.

  Each model is a nested submodule so that Elixir's single-defstruct-per-module
  constraint is respected while keeping the public API unified under
  `CodePuppyControl.HookEngine.Models`.
  """

  # ── Supported event types ──────────────────────────────────────

  @doc """
  Returns the list of supported event types.
  """
  @spec supported_event_types() :: [String.t()]
  def supported_event_types do
    [
      "PreToolUse",
      "PostToolUse",
      "SessionStart",
      "SessionEnd",
      "PreCompact",
      "UserPromptSubmit",
      "Notification",
      "Stop",
      "SubagentStop"
    ]
  end

  @doc """
  Normalizes a camelCase event type to snake_case.

  ## Examples

      iex> CodePuppyControl.HookEngine.Models.normalize_event_type("PreToolUse")
      "pre_tool_use"

      iex> CodePuppyControl.HookEngine.Models.normalize_event_type("UserPromptSubmit")
      "user_prompt_submit"
  """
  @spec normalize_event_type(String.t()) :: String.t()
  def normalize_event_type(event_type) when is_binary(event_type) do
    event_type
    |> String.replace(~r/([a-z])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
    |> String.downcase()
  end

  # ═══════════════════════════════════════════════════════════════
  # HookConfig
  # ═══════════════════════════════════════════════════════════════

  defmodule HookConfig do
    @moduledoc """
    Configuration for a single hook.

    - `matcher` — Pattern to match against events (e.g., "Edit && .py")
    - `type` — `:command` or `:prompt`
    - `command` — Command or prompt text to execute
    - `timeout` — Maximum execution time in ms (default: 5000)
    - `once` — Execute only once per session (default: false)
    - `enabled` — Whether this hook is enabled (default: true)
    - `id` — Unique identifier (auto-generated if not provided)
    """

    @type t :: %__MODULE__{
            matcher: String.t(),
            type: :command | :prompt,
            command: String.t(),
            timeout: pos_integer(),
            once: boolean(),
            enabled: boolean(),
            id: String.t()
          }

    defstruct [:matcher, :type, :command, :id, timeout: 5000, once: false, enabled: true]

    @doc """
    Creates a new HookConfig with validation and auto-generated ID.

    Raises `ArgumentError` if validation fails.
    """
    @spec new(keyword()) :: t()
    def new(opts) do
      matcher = Keyword.fetch!(opts, :matcher)
      type = Keyword.fetch!(opts, :type)
      command = Keyword.fetch!(opts, :command)

      unless is_binary(matcher) and matcher != "" do
        raise ArgumentError, "Hook matcher cannot be empty"
      end

      unless type in [:command, :prompt] do
        raise ArgumentError,
              "Hook type must be :command or :prompt, got: #{inspect(type)}"
      end

      unless is_binary(command) and command != "" do
        raise ArgumentError, "Hook command cannot be empty"
      end

      timeout = Keyword.get(opts, :timeout, 5000)

      if not is_integer(timeout) or timeout < 100 do
        raise ArgumentError, "Hook timeout must be >= 100ms, got: #{inspect(timeout)}"
      end

      id = Keyword.get(opts, :id) || generate_id(matcher, type, command)

      %__MODULE__{
        matcher: matcher,
        type: type,
        command: command,
        timeout: timeout,
        once: Keyword.get(opts, :once, false),
        enabled: Keyword.get(opts, :enabled, true),
        id: id
      }
    end

    @doc false
    @spec generate_id(String.t(), atom(), String.t()) :: String.t()
    def generate_id(matcher, type, command) do
      content = "#{matcher}:#{type}:#{command}"

      :crypto.hash(:sha256, content)
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # EventData
  # ═══════════════════════════════════════════════════════════════

  defmodule EventData do
    @moduledoc """
    Input data for hook processing.

    - `event_type` — Type of event (e.g., "PreToolUse")
    - `tool_name` — Name of the tool being called
    - `tool_args` — Arguments passed to the tool
    - `context` — Optional context metadata (result, duration, etc.)
    """

    @type t :: %__MODULE__{
            event_type: String.t(),
            tool_name: String.t(),
            tool_args: map(),
            context: map()
          }

    defstruct [:event_type, :tool_name, tool_args: %{}, context: %{}]

    @doc """
    Creates a new EventData struct.

    Raises `ArgumentError` if event_type or tool_name is empty.
    """
    @spec new(keyword()) :: t()
    def new(opts) do
      event_type = Keyword.fetch!(opts, :event_type)
      tool_name = Keyword.fetch!(opts, :tool_name)

      if is_nil(event_type) or event_type == "" do
        raise ArgumentError, "Event type cannot be empty"
      end

      if is_nil(tool_name) or tool_name == "" do
        raise ArgumentError, "Tool name cannot be empty"
      end

      %__MODULE__{
        event_type: event_type,
        tool_name: tool_name,
        tool_args: Keyword.get(opts, :tool_args, %{}),
        context: Keyword.get(opts, :context, %{})
      }
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # ExecutionResult
  # ═══════════════════════════════════════════════════════════════

  defmodule ExecutionResult do
    @moduledoc """
    Result from executing a hook.

    - `blocked` — Whether the hook blocked the operation
    - `hook_command` — The command that was executed
    - `stdout` / `stderr` — Command output streams
    - `exit_code` — Exit code (0=success, 1=block, 2=error feedback)
    - `duration_ms` — Execution duration
    - `error` — Error message if execution failed
    - `hook_id` — ID of the hook that was executed
    """

    @type t :: %__MODULE__{
            blocked: boolean(),
            hook_command: String.t(),
            stdout: String.t(),
            stderr: String.t(),
            exit_code: integer(),
            duration_ms: float(),
            error: String.t() | nil,
            hook_id: String.t() | nil
          }

    defstruct blocked: false,
              hook_command: "",
              stdout: "",
              stderr: "",
              exit_code: 0,
              duration_ms: 0.0,
              error: nil,
              hook_id: nil

    @doc """
    Returns true if the execution result indicates success.
    """
    @spec success?(t()) :: boolean()
    def success?(%__MODULE__{exit_code: 0, error: nil}), do: true
    def success?(%__MODULE__{}), do: false

    @doc """
    Returns combined stdout and stderr.
    """
    @spec output(t()) :: String.t()
    def output(%__MODULE__{stdout: stdout, stderr: stderr}) do
      [stdout, stderr]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  # ═══════════════════════════════════════════════════════════════
  # HookRegistry
  # ═══════════════════════════════════════════════════════════════

  defmodule HookRegistry do
    @moduledoc """
    Registry of all hooks organized by event type.

    Each event type maps to a list of `HookConfig` structs.
    Includes a set of already-executed `:once` hook IDs and a
    set of registered hook IDs for deduplication.
    """

    @type t :: %__MODULE__{
            entries: %{String.t() => [HookConfig.t()]},
            executed_once: MapSet.t(String.t()),
            registered_ids: MapSet.t(String.t())
          }

    defstruct entries: %{}, executed_once: MapSet.new(), registered_ids: MapSet.new()
  end

  # ═══════════════════════════════════════════════════════════════
  # ProcessEventResult
  # ═══════════════════════════════════════════════════════════════

  defmodule ProcessEventResult do
    @moduledoc """
    Result from processing an event through the hook engine.
    """

    @type t :: %__MODULE__{
            blocked: boolean(),
            executed_hooks: non_neg_integer(),
            results: [ExecutionResult.t()],
            blocking_reason: String.t() | nil,
            total_duration_ms: float()
          }

    defstruct blocked: false,
              executed_hooks: 0,
              results: [],
              blocking_reason: nil,
              total_duration_ms: 0.0

    @doc """
    Returns true if all results are successful.
    """
    @spec all_successful?(t()) :: boolean()
    def all_successful?(%__MODULE__{results: results}) do
      Enum.all?(results, &ExecutionResult.success?/1)
    end

    @doc """
    Returns only the failed results.
    """
    @spec failed_hooks(t()) :: [ExecutionResult.t()]
    def failed_hooks(%__MODULE__{results: results}) do
      Enum.reject(results, &ExecutionResult.success?/1)
    end

    @doc """
    Returns combined output from all results.
    """
    @spec get_combined_output(t()) :: String.t()
    def get_combined_output(%__MODULE__{results: results}) do
      results
      |> Enum.filter(fn r -> ExecutionResult.output(r) != "" end)
      |> Enum.map(fn r -> "[#{r.hook_command}]\n#{ExecutionResult.output(r)}" end)
      |> Enum.join("\n\n")
    end
  end
end
