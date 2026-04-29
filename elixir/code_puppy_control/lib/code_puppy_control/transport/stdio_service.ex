defmodule CodePuppyControl.Transport.StdioService do
  @moduledoc """
  Standalone stdio JSON-RPC transport service for FileOps.

  This module provides a standalone Elixir transport that can be run
  outside of the full Phoenix/Web application stack. It communicates
  via stdin/stdout using newline-delimited JSON-RPC 2.0 messages.

  ## Usage

  Run from command line:
      mix code_puppy.stdio_service

  Or as an escript (if configured):
      code_puppy_stdio

  ## Protocol

  Uses newline-delimited JSON-RPC 2.0:

  **Request:**
      {"jsonrpc":"2.0","id":1,"method":"file_list","params":{"directory":"."}}

  **Response:**
      {"jsonrpc":"2.0","id":1,"result":{"files":[{"path":"lib","type":"directory",...}]}}

  **Error:**
      {"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"Path not found"}}

  ## Comparison with Bridge Mode

  | Aspect | Bridge Mode (Port) | Standalone (StdioService) |
  |--------|-------------------|---------------------------|
  | Runtime | Inside Phoenix app | Independent process |
  | Framing | Content-Length | Newline-delimited |
  | Start | Supervisor-managed | CLI/manual |
  | Use case | Production with PubSub | Scripts, simple workflows |
  | Dependencies | Full OTP app | Minimal (FileOps, Protocol) |

  ## Supported Methods

  ### File Operations
  - `file_list` - List files in directory
  - `file_read` - Read single file contents
  - `file_read_batch` - Read multiple files
  - `grep_search` - Search for patterns in files

  ### Agent Model Pinning
  - `agent_pinning.get` - Get pinned model for an agent
  - `agent_pinning.set` - Set pinned model for an agent
  - `agent_pinning.clear` - Clear pin for an agent
  - `agent_pinning.list` - List all agent-to-model pins

  ### Agent Session Operations
  - `agent.session.save` - Save session history with metadata (filesystem)
  - `agent.session.load` - Load session history from storage (filesystem)
  - `agent.session.validate_id` - Validate session ID format (kebab-case)
  - `agent.session.sanitize_id` - Sanitize arbitrary string to valid session ID

  ### Session Storage - SQLite/Ecto Backend
  - `session_save` - Save session to SQLite database
  - `session_load` - Load session from database (history + hashes)
  - `session_load_full` - Load session with full metadata
  - `session_list` - List all session names
  - `session_list_with_metadata` - List sessions with metadata
  - `session_delete` - Delete a session by name
  - `session_cleanup` - Clean up old sessions keeping N most recent
  - `session_exists` - Check if session exists
  - `session_count` - Get total session count

  ### Session Storage - Terminal Tracking (code_puppy-ctj.1)
  - `session_register_terminal` - Register a terminal session for crash recovery
  - `session_unregister_terminal` - Unregister a terminal session
  - `session_list_terminals` - List all tracked terminal sessions
  - `agent.list` - List all available agents
  - `agent.get_info` - Get info about a specific agent
  - `agent.context.filter` - Filter context for sub-agent (remove parent-specific keys)

  ### Text Operations
  - `text_fuzzy_match` - Find best matching window using fuzzy matching
  - `text_unified_diff` - Generate unified diff between two strings
  - `text_replace` - Apply replacements with exact/fuzzy matching
  - `hashline_compute` - Compute 2-char hash anchor for a line
  - `hashline_format` - Format text with hashline prefixes
  - `hashline_strip` - Strip hashline prefixes from text
  - `hashline_validate` - Validate hashline anchor

  ### Round-Robin Model
  - `round_robin.get_next` - Get next model, advancing rotation
  - `round_robin.get_current` - Get current model without advancing
  - `round_robin.reset` - Reset rotation to initial position
  - `round_robin.get_state` - Get full rotation state
  - `round_robin.configure` - Configure models and rotation settings
  - `round_robin.list_models` - List configured models

  ### Scheduler Tools
  - `scheduler.list_tasks` - List all scheduled tasks with status
  - `scheduler.create_task` - Create a new scheduled task
  - `scheduler.delete_task` - Delete a task by ID or name
  - `scheduler.toggle_task` - Toggle task enabled/disabled state
  - `scheduler.status` - Get scheduler status
  - `scheduler.run_task` - Run a task immediately
  - `scheduler.view_log` - View task execution history
  - `scheduler.force_check` - Force immediate schedule evaluation

  ### Pack Parallelism / Run Limiter
  - `run_limiter.acquire` - Acquire a pack run slot (blocking with timeout)
  - `run_limiter.release` - Release a pack run slot
  - `run_limiter.status` - Return current pack limiter status
  - `run_limiter.set_limit` - Update the concurrency limit
  - `run_limiter.reset` - Emergency force-reset of limiter state

  ### Models Dev Parser
  - `models_dev.get_providers` - Get all model providers
  - `models_dev.get_provider` - Get specific provider by ID
  - `models_dev.get_models` - Get models (optionally filtered by provider)
  - `models_dev.get_model` - Get specific model by provider and model ID
  - `models_dev.search` - Search models by query and capabilities
  - `models_dev.filter_by_cost` - Filter models by cost constraints
  - `models_dev.filter_by_context` - Filter models by context length
  - `models_dev.to_config` - Convert model to Code Puppy config format
  - `models_dev.data_source` - Get data source info

  ### Model Services
  - `model_registry.get_config` - Get model configuration by name
  - `model_registry.list_models` - List all available models with configs
  - `model_registry.get_all_configs` - Get all model configs as map
  - `model_availability.check` - Check if model is available
  - `model_availability.snapshot` - Get full availability snapshot
  - `model_packs.get_pack` - Get model pack by name
  - `model_packs.get_current` - Get current model pack
  - `model_packs.list_packs` - List all available packs
  - `model_packs.get_model_for_role` - Get primary model for role
  - `model_utils.resolve_model` - Resolve model name to config

  ### Universal Constructor
  - `uc.list` - List all UC tools with metadata
  - `uc.call` - Execute a UC tool with arguments
  - `uc.create` - Create a new UC tool from Elixir code
  - `uc.update` - Update an existing UC tool
  - `uc.info` - Get detailed info about a UC tool

  ### HTTP Client
  - `http.request` - Make HTTP request with retry logic
  - `http.get` - Simple GET request
  - `http.post` - POST request with body

  ### Shell Command Runner
  - `shell.run` - Execute a shell command with streaming output
  - `shell.run_batch` - Execute multiple shell commands
  - `shell.kill_all` - Kill all running shell processes
  - `shell.running_count` - Get count of running processes

  ### Message Processing
  - `message.prune_and_filter` - Prune orphaned tool calls and oversized messages
  - `message.truncation_indices` - Calculate which messages to keep within token budget
  - `message.split_for_summarization` - Split messages into summarize vs protected groups
  - `message.serialize_session` - Serialize messages to base64-encoded MessagePack
  - `message.deserialize_session` - Deserialize base64-encoded MessagePack to messages
  - `message.serialize_incremental` - Append new messages to existing serialized data
  - `message.hash` - Compute content hash for a message (for deduplication)
  - `message.hash_batch` - Compute hashes for multiple messages
  - `message.stringify_part` - Get canonical string representation of a message part

  ### Utility
  - `health_check` - Service health status
  - `ping` - Simple ping/pong

  ## Security

  All file operations use the same `FileOps.sensitive_path?/1` validation
  as the bridge mode. Access to SSH keys, cloud credentials, and system
  secrets is blocked.

  ## Configuration

  Set via environment variable:
  - `PUP_LOG_LEVEL` - Service log level (default: info)
  """

  use GenServer

  require Logger

  alias CodePuppyControl.AgentModelPinning
  alias CodePuppyControl.FileOps
  alias CodePuppyControl.ModelAvailability
  alias CodePuppyControl.ModelPacks
  alias CodePuppyControl.ModelRegistry
  alias CodePuppyControl.Protocol
  alias CodePuppyControl.RoundRobinModel
  alias CodePuppyControl.Tools.CommandRunner
  alias CodePuppyControl.Tools.SchedulerTools

  alias CodePuppyControl.Messages.Hasher
  alias CodePuppyControl.Messages.Pruner
  alias CodePuppyControl.Messages.Serializer

  defstruct [:io_device, :buffer, :request_counter]

  @type t :: %__MODULE__{
          io_device: pid() | nil,
          buffer: String.t(),
          request_counter: non_neg_integer()
        }

  @default_io_device :stdio

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the stdio service.

  Options:
  - `:io_device` - The IO device to use (default: :stdio for stdin/stdout)
  - `:buffer` - Initial buffer content for testing
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Starts the stdio service in a blocking mode suitable for CLI execution.
  Waits for the service to complete (EOF on stdin).
  """
  def run(opts \\ []) do
    {:ok, pid} = start_link(opts)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        :ok
    end
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    io_device = Keyword.get(opts, :io_device, @default_io_device)
    buffer = Keyword.get(opts, :buffer, "")

    # Set up logger from environment
    configure_logging()

    # Request stdin line mode for efficient reading
    if io_device == :stdio do
      :io.setopts(:standard_io, encoding: :unicode, binary: true)
    end

    # Schedule initial read
    send(self(), :read_line)

    state = %__MODULE__{
      io_device: io_device,
      buffer: buffer,
      request_counter: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:read_line, %{io_device: io_device} = state) do
    # Read a line from stdin
    case read_line(io_device) do
      {:ok, line} ->
        new_state = process_line(line, state)
        # Schedule next read
        send(self(), :read_line)
        {:noreply, new_state}

      :eof ->
        Logger.info("StdioService received EOF, shutting down")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.error("Error reading from stdin: #{inspect(reason)}")
        send(self(), :read_line)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("Linked process exited: #{inspect(reason)}")
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp read_line(:stdio) do
    case :io.get_line(~c"") do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      line -> {:ok, to_string(line)}
    end
  end

  defp read_line(device) when is_pid(device) do
    case :file.read_line(device) do
      :eof -> :eof
      {:error, reason} -> {:error, reason}
      {:ok, line} -> {:ok, to_string(line)}
    end
  end

  defp process_line(line, state) do
    line = String.trim_trailing(line, "\n")

    if line == "" do
      state
    else
      case Protocol.decode(line) do
        {:ok, message} ->
          response = handle_message(message)
          # Per JSON-RPC 2.0 spec: "The Server MUST NOT reply to a Notification"
          # Notifications have no "id" field
          unless notification?(message) do
            write_response(response, state.io_device)
          end

          %{state | request_counter: state.request_counter + 1}

        {:error, reason} ->
          error_response =
            Protocol.encode_error(
              -32700,
              "Parse error: #{inspect(reason)}",
              nil,
              extract_id(line)
            )

          write_response(error_response, state.io_device)
          state
      end
    end
  end

  # Check if message is a notification (no "id" field per JSON-RPC 2.0 spec)
  defp notification?(%{"id" => _}), do: false
  defp notification?(%{}), do: true
  defp notification?(messages) when is_list(messages), do: false
  defp notification?(_), do: true

  # Batch request handling (array of messages)
  defp handle_message(messages) when is_list(messages) do
    Enum.map(messages, &handle_single_message/1)
  end

  # Single message handling
  defp handle_message(message) when is_map(message) do
    handle_single_message(message)
  end

  defp handle_single_message(%{"id" => id, "method" => method, "params" => params}) do
    handle_request(method, params, id)
  end

  defp handle_single_message(%{"id" => id, "method" => method}) do
    # Handle methods with no params
    handle_request(method, %{}, id)
  end

  defp handle_single_message(%{"method" => method, "params" => params}) do
    # Notification (no id) - handle but don't send response
    Logger.debug("Received notification: #{method}")
    handle_request(method, params, nil)
  end

  defp handle_single_message(%{"method" => method}) do
    Logger.debug("Received notification: #{method}")
    handle_request(method, %{}, nil)
  end

  defp handle_single_message(message) do
    Protocol.encode_error(
      -32600,
      "Invalid Request",
      %{"received" => message},
      nil
    )
  end

  # ============================================================================
  # Request Handlers
  # ============================================================================

  defp handle_request("ping", _params, id) do
    Protocol.encode_response(%{"pong" => true, "timestamp" => now_iso8601()}, id)
  end

  defp handle_request("health_check", _params, id) do
    health = %{
      "status" => "healthy",
      "version" => version(),
      "elixir_version" => System.version(),
      "otp_version" => :erlang.system_info(:otp_release) |> to_string(),
      "timestamp" => now_iso8601()
    }

    Protocol.encode_response(health, id)
  end

  # file_list - List files in directory
  defp handle_request("file_list", params, id) do
    directory = params["directory"] || "."
    opts = params_to_list_opts(params)

    case FileOps.list_files(directory, opts) do
      {:ok, files} ->
        serializable = serialize_file_list(files)
        Protocol.encode_response(%{"files" => serializable}, id)

      {:error, reason} ->
        Protocol.encode_error(
          -32000,
          "File list failed: #{format_error(reason)}",
          nil,
          id
        )
    end
  end

  # file_read - Read single file
  defp handle_request("file_read", params, id) do
    path = params["path"]

    if is_nil(path) do
      Protocol.encode_error(-32602, "Missing required param: path", nil, id)
    else
      opts = params_to_read_opts(params)

      case FileOps.read_file(path, opts) do
        {:ok, result} ->
          Protocol.encode_response(serialize_read_result(result), id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "File read failed: #{format_error(reason)}",
            nil,
            id
          )
      end
    end
  end

  # file_read_batch - Read multiple files
  defp handle_request("file_read_batch", params, id) do
    paths = params["paths"] || []

    if paths == [] do
      Protocol.encode_error(-32602, "Missing or empty param: paths", nil, id)
    else
      opts = params_to_read_opts(params)

      # FileOps.read_files/2 always returns {:ok, results} - errors are in the results
      {:ok, results} = FileOps.read_files(paths, opts)
      serialized = Enum.map(results, &serialize_read_result/1)
      Protocol.encode_response(%{"files" => serialized}, id)
    end
  end

  # grep_search - Search for patterns
  defp handle_request("grep_search", params, id) do
    pattern = params["search_string"] || params["pattern"]
    directory = params["directory"] || "."

    if is_nil(pattern) do
      Protocol.encode_error(-32602, "Missing required param: pattern", nil, id)
    else
      opts = params_to_grep_opts(params)

      case FileOps.grep(pattern, directory, opts) do
        {:ok, matches} ->
          Protocol.encode_response(%{"matches" => serialize_grep_matches(matches)}, id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "Grep search failed: #{format_error(reason)}",
            nil,
            id
          )
      end
    end
  end

  # text_replace - Apply replacements with exact/fuzzy matching
  defp handle_request("text_replace", params, id) do
    content = params["content"]
    replacements_raw = params["replacements"]

    cond do
      is_nil(content) ->
        Protocol.encode_error(-32602, "Missing required param: content", nil, id)

      is_nil(replacements_raw) or not is_list(replacements_raw) ->
        Protocol.encode_error(-32602, "Missing or invalid param: replacements", nil, id)

      true ->
        replacements =
          Enum.map(replacements_raw, fn rep ->
            {rep["old_str"] || "", rep["new_str"] || ""}
          end)

        alias CodePuppyControl.Text.ReplaceEngine

        case ReplaceEngine.replace_in_content(content, replacements) do
          {:ok, %{modified: modified, diff: diff, jw_score: jw_score}} ->
            Protocol.encode_response(
              %{
                "modified" => modified,
                "diff" => diff,
                "success" => true,
                "error" => nil,
                "jw_score" => jw_score
              },
              id
            )

          {:error, %{reason: reason, jw_score: jw_score, original: original}} ->
            Protocol.encode_response(
              %{
                "modified" => original,
                "diff" => "",
                "success" => false,
                "error" => reason,
                "jw_score" => jw_score
              },
              id
            )
        end
    end
  end

  # text_fuzzy_match - Find best matching window using fuzzy matching
  defp handle_request("text_fuzzy_match", params, id) do
    haystack_lines = params["haystack_lines"]
    needle = params["needle"]

    cond do
      is_nil(haystack_lines) or not is_list(haystack_lines) ->
        Protocol.encode_error(-32602, "Missing or invalid param: haystack_lines", nil, id)

      is_nil(needle) or not is_binary(needle) ->
        Protocol.encode_error(-32602, "Missing or invalid param: needle", nil, id)

      true ->
        alias CodePuppyControl.Text.FuzzyMatch

        case FuzzyMatch.fuzzy_match_window(haystack_lines, needle) do
          {:ok,
           %{
             matched_text: matched_text,
             start_line: start_line,
             end_line: end_line,
             similarity: similarity
           }} ->
            Protocol.encode_response(
              %{
                "matched_text" => matched_text,
                "start" => start_line,
                "end" => end_line,
                "score" => similarity
              },
              id
            )

          :no_match ->
            Protocol.encode_response(
              %{"matched_text" => nil, "start" => 0, "end" => nil, "score" => 0.0},
              id
            )
        end
    end
  end

  # text_unified_diff - Generate unified diff between two strings
  defp handle_request("text_unified_diff", params, id) do
    old = params["old"]
    new = params["new"]

    cond do
      is_nil(old) or not is_binary(old) ->
        Protocol.encode_error(-32602, "Missing or invalid param: old", nil, id)

      is_nil(new) or not is_binary(new) ->
        Protocol.encode_error(-32602, "Missing or invalid param: new", nil, id)

      true ->
        alias CodePuppyControl.Text.Diff

        context_lines = params["context_lines"] || 3
        from_file = params["from_file"] || ""
        to_file = params["to_file"] || ""

        result =
          Diff.unified_diff(old, new,
            context_lines: context_lines,
            from_file: from_file,
            to_file: to_file
          )

        Protocol.encode_response(%{"diff" => result}, id)
    end
  end

  # hashline_compute - Compute 2-char hash anchor for a line
  defp handle_request("hashline_compute", params, id) do
    idx = params["idx"]
    line = params["line"]

    cond do
      is_nil(idx) or not is_integer(idx) ->
        Protocol.encode_error(-32602, "Missing or invalid param: idx", nil, id)

      is_nil(line) or not is_binary(line) ->
        Protocol.encode_error(-32602, "Missing or invalid param: line", nil, id)

      true ->
        hash = CodePuppyControl.HashlineNif.compute_line_hash(idx, line)
        Protocol.encode_response(%{"hash" => hash}, id)
    end
  end

  # hashline_format - Format text with hashline prefixes
  defp handle_request("hashline_format", params, id) do
    text = params["text"]
    start_line = params["start_line"] || 1

    cond do
      is_nil(text) or not is_binary(text) ->
        Protocol.encode_error(-32602, "Missing or invalid param: text", nil, id)

      true ->
        result = CodePuppyControl.HashlineNif.format_hashlines(text, start_line)
        Protocol.encode_response(%{"formatted" => result}, id)
    end
  end

  # hashline_strip - Strip hashline prefixes from text
  defp handle_request("hashline_strip", params, id) do
    text = params["text"]

    cond do
      is_nil(text) or not is_binary(text) ->
        Protocol.encode_error(-32602, "Missing or invalid param: text", nil, id)

      true ->
        result = CodePuppyControl.HashlineNif.strip_hashline_prefixes(text)
        Protocol.encode_response(%{"stripped" => result}, id)
    end
  end

  # hashline_validate - Validate hashline anchor
  defp handle_request("hashline_validate", params, id) do
    idx = params["idx"]
    line = params["line"]
    expected_hash = params["expected_hash"]

    cond do
      is_nil(idx) or not is_integer(idx) ->
        Protocol.encode_error(-32602, "Missing or invalid param: idx", nil, id)

      is_nil(line) or not is_binary(line) ->
        Protocol.encode_error(-32602, "Missing or invalid param: line", nil, id)

      is_nil(expected_hash) or not is_binary(expected_hash) ->
        Protocol.encode_error(-32602, "Missing or invalid param: expected_hash", nil, id)

      true ->
        valid = CodePuppyControl.HashlineNif.validate_hashline_anchor(idx, line, expected_hash)
        Protocol.encode_response(%{"valid" => valid}, id)
    end
  end

  # ============================================================================
  # Runtime State Operations
  # ============================================================================

  # runtime_get_autosave_id - Get current autosave session ID
  defp handle_request("runtime_get_autosave_id", _params, id) do
    autosave_id = CodePuppyControl.RuntimeState.get_current_autosave_id()
    Protocol.encode_response(%{"autosave_id" => autosave_id}, id)
  end

  # runtime_get_autosave_session_name - Get full session name
  defp handle_request("runtime_get_autosave_session_name", _params, id) do
    session_name = CodePuppyControl.RuntimeState.get_current_autosave_session_name()
    Protocol.encode_response(%{"session_name" => session_name}, id)
  end

  # runtime_rotate_autosave_id - Force new autosave ID
  defp handle_request("runtime_rotate_autosave_id", _params, id) do
    new_id = CodePuppyControl.RuntimeState.rotate_autosave_id()
    Protocol.encode_response(%{"autosave_id" => new_id}, id)
  end

  # runtime_set_autosave_from_session - Set ID from session name
  defp handle_request("runtime_set_autosave_from_session", params, id) do
    session_name = params["session_name"]

    if is_nil(session_name) or not is_binary(session_name) do
      Protocol.encode_error(-32602, "Missing or invalid param: session_name", nil, id)
    else
      set_id = CodePuppyControl.RuntimeState.set_current_autosave_from_session_name(session_name)
      Protocol.encode_response(%{"autosave_id" => set_id}, id)
    end
  end

  # runtime_reset_autosave_id - Reset autosave ID to nil
  defp handle_request("runtime_reset_autosave_id", _params, id) do
    :ok = CodePuppyControl.RuntimeState.reset_autosave_id()
    Protocol.encode_response(%{"reset" => true}, id)
  end

  # runtime_get_session_model - Get cached session model
  defp handle_request("runtime_get_session_model", _params, id) do
    model = CodePuppyControl.RuntimeState.get_session_model()
    Protocol.encode_response(%{"session_model" => model}, id)
  end

  # runtime_set_session_model - Set session model
  defp handle_request("runtime_set_session_model", params, id) do
    model = params["model"]

    if not (is_nil(model) or is_binary(model)) do
      Protocol.encode_error(-32602, "Invalid param: model must be string or nil", nil, id)
    else
      :ok = CodePuppyControl.RuntimeState.set_session_model(model)
      Protocol.encode_response(%{"session_model" => model}, id)
    end
  end

  # runtime_reset_session_model - Reset session model cache
  defp handle_request("runtime_reset_session_model", _params, id) do
    :ok = CodePuppyControl.RuntimeState.reset_session_model()
    Protocol.encode_response(%{"reset" => true}, id)
  end

  # runtime_get_state - Get full runtime state for introspection
  defp handle_request("runtime_get_state", _params, id) do
    state = CodePuppyControl.RuntimeState.get_state()

    result = %{
      "autosave_id" => state.autosave_id,
      "session_model" => state.session_model,
      "session_start_time" =>
        case DateTime.to_iso8601(state.session_start_time) do
          {:ok, str} -> str
          str when is_binary(str) -> str
          _ -> nil
        end
    }

    Protocol.encode_response(result, id)
  end

  # runtime_finalize_autosave_session - Persist snapshot and rotate to fresh session
  defp handle_request("runtime_finalize_autosave_session", _params, id) do
    new_id = CodePuppyControl.RuntimeState.finalize_autosave_session()
    Protocol.encode_response(%{"autosave_id" => new_id}, id)
  end

  # runtime_invalidate_caches - Invalidate ephemeral caches (context overhead, tool IDs)
  defp handle_request("runtime_invalidate_caches", _params, id) do
    :ok = CodePuppyControl.RuntimeState.invalidate_caches()
    Protocol.encode_response(%{"reset" => true}, id)
  end

  # runtime_invalidate_all_token_caches - Invalidate ALL token-related caches
  defp handle_request("runtime_invalidate_all_token_caches", _params, id) do
    :ok = CodePuppyControl.RuntimeState.invalidate_all_token_caches()
    Protocol.encode_response(%{"reset" => true}, id)
  end

  # runtime_invalidate_system_prompt_cache - Invalidate system prompt + context overhead
  defp handle_request("runtime_invalidate_system_prompt_cache", _params, id) do
    :ok = CodePuppyControl.RuntimeState.invalidate_system_prompt_cache()
    Protocol.encode_response(%{"reset" => true}, id)
  end

  # runtime_get_cached_system_prompt - Get cached system prompt
  defp handle_request("runtime_get_cached_system_prompt", _params, id) do
    prompt = CodePuppyControl.RuntimeState.get_cached_system_prompt()
    Protocol.encode_response(%{"cached_system_prompt" => prompt}, id)
  end

  # runtime_set_cached_system_prompt - Set cached system prompt
  defp handle_request("runtime_set_cached_system_prompt", params, id) do
    prompt = params["prompt"]

    if not (is_nil(prompt) or is_binary(prompt)) do
      Protocol.encode_error(-32602, "Invalid param: prompt must be string or nil", nil, id)
    else
      :ok = CodePuppyControl.RuntimeState.set_cached_system_prompt(prompt)
      Protocol.encode_response(%{"cached_system_prompt" => prompt}, id)
    end
  end

  # runtime_get_cached_tool_defs - Get cached tool definitions
  defp handle_request("runtime_get_cached_tool_defs", _params, id) do
    defs = CodePuppyControl.RuntimeState.get_cached_tool_defs()
    Protocol.encode_response(%{"cached_tool_defs" => defs}, id)
  end

  # runtime_set_cached_tool_defs - Set cached tool definitions
  defp handle_request("runtime_set_cached_tool_defs", params, id) do
    defs = params["tool_defs"]

    if not (is_nil(defs) or is_list(defs)) do
      Protocol.encode_error(-32602, "Invalid param: tool_defs must be list or nil", nil, id)
    else
      :ok = CodePuppyControl.RuntimeState.set_cached_tool_defs(defs)
      Protocol.encode_response(%{"cached_tool_defs" => defs}, id)
    end
  end

  # runtime_get_model_name_cache - Get cached model name
  defp handle_request("runtime_get_model_name_cache", _params, id) do
    name = CodePuppyControl.RuntimeState.get_model_name_cache()
    Protocol.encode_response(%{"model_name_cache" => name}, id)
  end

  # runtime_set_model_name_cache - Set cached model name
  defp handle_request("runtime_set_model_name_cache", params, id) do
    name = params["model_name"]

    if not (is_nil(name) or is_binary(name)) do
      Protocol.encode_error(-32602, "Invalid param: model_name must be string or nil", nil, id)
    else
      :ok = CodePuppyControl.RuntimeState.set_model_name_cache(name)
      Protocol.encode_response(%{"model_name_cache" => name}, id)
    end
  end

  # runtime_get_delayed_compaction_requested - Get delayed compaction flag
  defp handle_request("runtime_get_delayed_compaction_requested", _params, id) do
    value = CodePuppyControl.RuntimeState.get_delayed_compaction_requested()
    Protocol.encode_response(%{"delayed_compaction_requested" => value}, id)
  end

  # runtime_set_delayed_compaction_requested - Set delayed compaction flag
  defp handle_request("runtime_set_delayed_compaction_requested", params, id) do
    value = params["value"]

    if not is_boolean(value) do
      Protocol.encode_error(-32602, "Invalid param: value must be boolean", nil, id)
    else
      :ok = CodePuppyControl.RuntimeState.set_delayed_compaction_requested(value)
      Protocol.encode_response(%{"delayed_compaction_requested" => value}, id)
    end
  end

  # runtime_get_tool_ids_cache - Get tool IDs cache
  defp handle_request("runtime_get_tool_ids_cache", _params, id) do
    cache = CodePuppyControl.RuntimeState.get_tool_ids_cache()
    Protocol.encode_response(%{"tool_ids_cache" => cache}, id)
  end

  # runtime_set_tool_ids_cache - Set tool IDs cache
  defp handle_request("runtime_set_tool_ids_cache", params, id) do
    cache = params["cache"]
    :ok = CodePuppyControl.RuntimeState.set_tool_ids_cache(cache)
    Protocol.encode_response(%{"tool_ids_cache" => cache}, id)
  end

  # runtime_get_cached_context_overhead - Get cached context overhead
  defp handle_request("runtime_get_cached_context_overhead", _params, id) do
    value = CodePuppyControl.RuntimeState.get_cached_context_overhead()
    Protocol.encode_response(%{"cached_context_overhead" => value}, id)
  end

  # runtime_set_cached_context_overhead - Set cached context overhead
  defp handle_request("runtime_set_cached_context_overhead", params, id) do
    value = params["value"]

    if not (is_nil(value) or is_integer(value)) do
      Protocol.encode_error(-32602, "Invalid param: value must be integer or nil", nil, id)
    else
      :ok = CodePuppyControl.RuntimeState.set_cached_context_overhead(value)
      Protocol.encode_response(%{"cached_context_overhead" => value}, id)
    end
  end

  # runtime_get_resolved_model_components_cache - Get resolved model components cache
  defp handle_request("runtime_get_resolved_model_components_cache", _params, id) do
    cache = CodePuppyControl.RuntimeState.get_resolved_model_components_cache()
    Protocol.encode_response(%{"resolved_model_components_cache" => cache}, id)
  end

  # runtime_set_resolved_model_components_cache - Set resolved model components cache
  defp handle_request("runtime_set_resolved_model_components_cache", params, id) do
    cache = params["cache"]

    if not (is_nil(cache) or is_map(cache)) do
      Protocol.encode_error(-32602, "Invalid param: cache must be map or nil", nil, id)
    else
      :ok = CodePuppyControl.RuntimeState.set_resolved_model_components_cache(cache)
      Protocol.encode_response(%{"resolved_model_components_cache" => cache}, id)
    end
  end

  # runtime_get_puppy_rules_cache - Get cached puppy rules content
  defp handle_request("runtime_get_puppy_rules_cache", _params, id) do
    rules = CodePuppyControl.RuntimeState.get_puppy_rules_cache()
    Protocol.encode_response(%{"puppy_rules_cache" => rules}, id)
  end

  # runtime_set_puppy_rules_cache - Set cached puppy rules content
  defp handle_request("runtime_set_puppy_rules_cache", params, id) do
    rules = params["rules"]

    if not (is_nil(rules) or is_binary(rules)) do
      Protocol.encode_error(-32602, "Invalid param: rules must be string or nil", nil, id)
    else
      :ok = CodePuppyControl.RuntimeState.set_puppy_rules_cache(rules)
      Protocol.encode_response(%{"puppy_rules_cache" => rules}, id)
    end
  end

  # ============================================================================
  # Agent Model Pinning Operations
  # ============================================================================

  # agent_pinning.get - Get pinned model for an agent
  defp handle_request("agent_pinning.get", params, id) do
    agent_name = params["agent_name"]

    if is_nil(agent_name) or not is_binary(agent_name) do
      Protocol.encode_error(-32602, "Missing or invalid param: agent_name", nil, id)
    else
      model = AgentModelPinning.get_pinned_model(agent_name)
      Protocol.encode_response(%{"agent_name" => agent_name, "model" => model}, id)
    end
  end

  # agent_pinning.set - Set pinned model for an agent
  defp handle_request("agent_pinning.set", params, id) do
    agent_name = params["agent_name"]
    model = params["model"]

    cond do
      is_nil(agent_name) or not is_binary(agent_name) ->
        Protocol.encode_error(-32602, "Missing or invalid param: agent_name", nil, id)

      is_nil(model) or not is_binary(model) ->
        Protocol.encode_error(-32602, "Missing or invalid param: model", nil, id)

      true ->
        :ok = AgentModelPinning.set_pinned_model(agent_name, model)
        Protocol.encode_response(%{"agent_name" => agent_name, "model" => model}, id)
    end
  end

  # agent_pinning.clear - Clear pin for an agent
  defp handle_request("agent_pinning.clear", params, id) do
    agent_name = params["agent_name"]

    if is_nil(agent_name) or not is_binary(agent_name) do
      Protocol.encode_error(-32602, "Missing or invalid param: agent_name", nil, id)
    else
      :ok = AgentModelPinning.clear_pinned_model(agent_name)
      Protocol.encode_response(%{"agent_name" => agent_name, "cleared" => true}, id)
    end
  end

  # agent_pinning.list - List all agent-to-model pins
  defp handle_request("agent_pinning.list", _params, id) do
    pins = AgentModelPinning.list_pins()
    pin_list = Enum.map(pins, fn {agent, model} -> %{"agent_name" => agent, "model" => model} end)
    Protocol.encode_response(%{"pins" => pin_list, "count" => length(pin_list)}, id)
  end

  # ============================================================================
  # Agent Session Operations
  # ============================================================================

  alias CodePuppyControl.Tools.AgentSession
  alias CodePuppyControl.Tools.AgentCatalogue
  alias CodePuppyControl.Tools.ContextFilter

  # agent.session.save - Save session history
  defp handle_request("agent.session.save", params, id) do
    session_id = params["session_id"]
    messages = params["messages"] || []
    agent_name = params["agent_name"]
    initial_prompt = params["initial_prompt"]

    cond do
      is_nil(session_id) or not is_binary(session_id) ->
        Protocol.encode_error(-32602, "Missing or invalid param: session_id", nil, id)

      is_nil(agent_name) or not is_binary(agent_name) ->
        Protocol.encode_error(-32602, "Missing or invalid param: agent_name", nil, id)

      true ->
        case AgentSession.save_session_history(session_id, messages, agent_name, initial_prompt) do
          :ok ->
            Protocol.encode_response(%{"saved" => true, "session_id" => session_id}, id)

          {:error, reason} ->
            Protocol.encode_error(-32000, "Failed to save session: #{reason}", nil, id)
        end
    end
  end

  # agent.session.load - Load session history
  defp handle_request("agent.session.load", params, id) do
    session_id = params["session_id"]

    if is_nil(session_id) or not is_binary(session_id) do
      Protocol.encode_error(-32602, "Missing or invalid param: session_id", nil, id)
    else
      case AgentSession.load_session_history(session_id) do
        {:ok, result} ->
          Protocol.encode_response(
            %{
              "messages" => result.messages,
              "metadata" => result.metadata
            },
            id
          )

        {:error, reason} ->
          Protocol.encode_error(-32000, "Failed to load session: #{reason}", nil, id)
      end
    end
  end

  # agent.session.validate_id - Validate session ID format
  defp handle_request("agent.session.validate_id", params, id) do
    session_id = params["session_id"]

    if is_nil(session_id) or not is_binary(session_id) do
      Protocol.encode_response(%{"valid" => false, "error" => "session_id must be a string"}, id)
    else
      case AgentSession.validate_session_id(session_id) do
        :ok -> Protocol.encode_response(%{"valid" => true}, id)
        {:error, reason} -> Protocol.encode_response(%{"valid" => false, "error" => reason}, id)
      end
    end
  end

  # agent.session.sanitize_id - Sanitize arbitrary string to valid session ID
  defp handle_request("agent.session.sanitize_id", params, id) do
    raw = params["raw"]

    if is_nil(raw) do
      Protocol.encode_error(-32602, "Missing param: raw", nil, id)
    else
      sanitized = AgentSession.sanitize_session_id(raw)
      Protocol.encode_response(%{"sanitized" => sanitized}, id)
    end
  end

  # agent.list - List all available agents
  defp handle_request("agent.list", _params, id) do
    agents =
      AgentCatalogue.list_agents()
      |> Enum.map(fn info ->
        %{
          "name" => info.name,
          "display_name" => info.display_name,
          "description" => info.description
        }
      end)

    Protocol.encode_response(%{"agents" => agents, "count" => length(agents)}, id)
  end

  # agent.get_info - Get info about a specific agent
  defp handle_request("agent.get_info", params, id) do
    agent_name = params["agent_name"] || params["name"]

    if is_nil(agent_name) or not is_binary(agent_name) do
      Protocol.encode_error(-32602, "Missing or invalid param: agent_name", nil, id)
    else
      case AgentCatalogue.get_agent_info(agent_name) do
        {:ok, info} ->
          Protocol.encode_response(
            %{
              "name" => info.name,
              "display_name" => info.display_name,
              "description" => info.description
            },
            id
          )

        :not_found ->
          Protocol.encode_response(%{"error" => "Agent not found", "name" => agent_name}, id)
      end
    end
  end

  # agent.context.filter - Filter context for sub-agent
  defp handle_request("agent.context.filter", params, id) do
    context = params["context"]

    if is_nil(context) do
      Protocol.encode_response(%{"filtered" => %{}}, id)
    else
      filtered = ContextFilter.filter_context(context)
      Protocol.encode_response(%{"filtered" => filtered}, id)
    end
  end

  # ============================================================================
  # Agent Tools (Phase E: code_puppy-mmk.4)
  # ============================================================================

  # agent_tools.list - List available agents (matches Python ListAgentsOutput)
  defp handle_request("agent_tools.list", _params, id) do
    result = CodePuppyControl.Tools.AgentInvocation.list_agents()

    Protocol.encode_response(
      %{
        "agents" => result.agents,
        "error" => result.error
      },
      id
    )
  end

  # agent_tools.invoke - Invoke a sub-agent (matches Python AgentInvokeOutput)
  defp handle_request("agent_tools.invoke", params, id) do
    agent_name = params["agent_name"]
    prompt = params["prompt"]
    session_id = params["session_id"]
    context = params["context"]

    cond do
      is_nil(agent_name) or not is_binary(agent_name) ->
        Protocol.encode_error(-32602, "Missing or invalid param: agent_name", nil, id)

      is_nil(prompt) or not is_binary(prompt) ->
        Protocol.encode_error(-32602, "Missing or invalid param: prompt", nil, id)

      true ->
        opts = [session_id: session_id, context: context]

        result = CodePuppyControl.Tools.AgentInvocation.invoke(agent_name, prompt, opts)

        Protocol.encode_response(
          %{
            "response" => result.response,
            "agent_name" => result.agent_name,
            "session_id" => result.session_id,
            "error" => result.error
          },
          id
        )
    end
  end

  # agent_tools.invoke_headless - Headless invocation for plugin use
  defp handle_request("agent_tools.invoke_headless", params, id) do
    agent_name = params["agent_name"]
    prompt = params["prompt"]

    cond do
      is_nil(agent_name) or not is_binary(agent_name) ->
        Protocol.encode_error(-32602, "Missing or invalid param: agent_name", nil, id)

      is_nil(prompt) or not is_binary(prompt) ->
        Protocol.encode_error(-32602, "Missing or invalid param: prompt", nil, id)

      true ->
        opts = [session_id: params["session_id"], model: params["model"]]

        case CodePuppyControl.Tools.AgentInvocation.invoke_headless(agent_name, prompt, opts) do
          {:ok, response} ->
            Protocol.encode_response(
              %{"response" => response, "agent_name" => agent_name},
              id
            )

          {:error, reason} ->
            Protocol.encode_error(
              -32000,
              "Headless invocation failed: #{inspect(reason)}",
              nil,
              id
            )
        end
    end
  end

  # agent_tools.generate_session_id - Generate a unique session ID
  defp handle_request("agent_tools.generate_session_id", params, id) do
    agent_name = params["agent_name"] || "agent"
    session_id = CodePuppyControl.Tools.AgentInvocation.generate_session_id(agent_name)
    Protocol.encode_response(%{"session_id" => session_id}, id)
  end

  # ============================================================================
  # Scheduler Tools
  # ============================================================================

  # scheduler.list_tasks - List all scheduled tasks with status
  defp handle_request("scheduler.list_tasks", _params, id) do
    result = SchedulerTools.list_tasks()
    Protocol.encode_response(%{"result" => result, "type" => "markdown"}, id)
  end

  # ============================================================================
  # HTTP Client Operations
  # ============================================================================

  # http.get - Simple GET request
  defp handle_request("http.get", params, id) do
    url = params["url"]

    if is_nil(url) or not is_binary(url) do
      Protocol.encode_error(-32602, "Missing or invalid param: url", nil, id)
    else
      opts = params_to_http_opts(params)

      case CodePuppyControl.HttpClient.get(url, opts) do
        {:ok, response} ->
          Protocol.encode_response(serialize_http_response(response), id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "HTTP request failed: #{format_error(reason)}",
            nil,
            id
          )
      end
    end
  end

  # http.post - POST request
  defp handle_request("http.post", params, id) do
    url = params["url"]
    body = params["body"]

    if is_nil(url) or not is_binary(url) do
      Protocol.encode_error(-32602, "Missing or invalid param: url", nil, id)
    else
      opts = params_to_http_opts(params)
      opts = if body, do: Keyword.put(opts, :body, body), else: opts

      case CodePuppyControl.HttpClient.post(url, opts) do
        {:ok, response} ->
          Protocol.encode_response(serialize_http_response(response), id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "HTTP request failed: #{format_error(reason)}",
            nil,
            id
          )
      end
    end
  end

  # http.request - Full request with method selection
  defp handle_request("http.request", params, id) do
    method_str = params["method"] || "GET"
    url = params["url"]
    body = params["body"]

    if is_nil(url) or not is_binary(url) do
      Protocol.encode_error(-32602, "Missing or invalid param: url", nil, id)
    else
      method = parse_http_method(method_str)
      opts = params_to_http_opts(params)
      opts = if body, do: Keyword.put(opts, :body, body), else: opts

      case CodePuppyControl.HttpClient.request(method, url, opts) do
        {:ok, response} ->
          Protocol.encode_response(serialize_http_response(response), id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "HTTP request failed: #{format_error(reason)}",
            nil,
            id
          )
      end
    end
  end

  # scheduler.create_task - Create a new scheduled task
  defp handle_request("scheduler.create_task", params, id) do
    attrs =
      %{
        name: params["name"],
        prompt: params["prompt"],
        agent_name: params["agent_name"] || params["agent"],
        model: params["model"],
        schedule_type: params["schedule_type"] || "interval",
        schedule_value: params["schedule_value"],
        working_directory: params["working_directory"] || "."
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    result = SchedulerTools.create_task(attrs)
    Protocol.encode_response(%{"result" => result, "type" => "markdown"}, id)
  end

  # scheduler.delete_task - Delete a task by ID or name
  defp handle_request("scheduler.delete_task", params, id) do
    task_id = params["task_id"] || params["id"]

    if is_nil(task_id) do
      Protocol.encode_error(-32602, "Missing required param: task_id", nil, id)
    else
      result = SchedulerTools.delete_task(task_id)
      Protocol.encode_response(%{"result" => result, "type" => "markdown"}, id)
    end
  end

  # scheduler.toggle_task - Toggle task enabled/disabled state
  defp handle_request("scheduler.toggle_task", params, id) do
    task_id = params["task_id"] || params["id"]

    if is_nil(task_id) do
      Protocol.encode_error(-32602, "Missing required param: task_id", nil, id)
    else
      result = SchedulerTools.toggle_task(task_id)
      Protocol.encode_response(%{"result" => result, "type" => "markdown"}, id)
    end
  end

  # scheduler.status - Get scheduler status
  defp handle_request("scheduler.status", _params, id) do
    result = SchedulerTools.scheduler_status()
    Protocol.encode_response(%{"result" => result, "type" => "markdown"}, id)
  end

  # scheduler.run_task - Run a task immediately
  defp handle_request("scheduler.run_task", params, id) do
    task_id = params["task_id"] || params["id"]

    if is_nil(task_id) do
      Protocol.encode_error(-32602, "Missing required param: task_id", nil, id)
    else
      result = SchedulerTools.run_task(task_id)
      Protocol.encode_response(%{"result" => result, "type" => "markdown"}, id)
    end
  end

  # scheduler.view_log - View task execution history
  defp handle_request("scheduler.view_log", params, id) do
    task_id = params["task_id"] || params["id"]
    lines = params["lines"] || 10

    if is_nil(task_id) do
      Protocol.encode_error(-32602, "Missing required param: task_id", nil, id)
    else
      result = SchedulerTools.view_log(task_id, lines)
      Protocol.encode_response(%{"result" => result, "type" => "markdown"}, id)
    end
  end

  # scheduler.force_check - Force immediate schedule evaluation
  defp handle_request("scheduler.force_check", _params, id) do
    result = SchedulerTools.force_check()
    Protocol.encode_response(%{"result" => result, "type" => "markdown"}, id)
  end

  # ============================================================================
  # Universal Constructor Operations
  # ============================================================================

  alias CodePuppyControl.Tools.UniversalConstructor

  # uc.list - List all UC tools
  defp handle_request("uc.list", _params, id) do
    tools = UniversalConstructor.run(action: "list")

    result = %{
      "success" => tools.success,
      "action" => tools.action,
      "tools" =>
        if tools.list_result do
          Enum.map(tools.list_result.tools, fn t ->
            %{
              "full_name" => t.full_name,
              "name" => t.meta.name,
              "namespace" => t.meta.namespace,
              "description" => t.meta.description,
              "enabled" => t.meta.enabled,
              "version" => t.meta.version,
              "signature" => t.signature,
              "source_path" => t.source_path
            }
          end)
        else
          []
        end,
      "total_count" => if(tools.list_result, do: tools.list_result.total_count, else: 0),
      "enabled_count" => if(tools.list_result, do: tools.list_result.enabled_count, else: 0),
      "formatted" =>
        if tools.list_result do
          UniversalConstructor.format_tools(tools.list_result.tools)
        else
          ""
        end
    }

    Protocol.encode_response(result, id)
  end

  # uc.call - Execute a UC tool
  defp handle_request("uc.call", params, id) do
    tool_name = params["tool_name"] || params["name"]
    tool_args = params["tool_args"] || params["args"] || %{}

    if is_nil(tool_name) do
      Protocol.encode_error(-32602, "Missing required param: tool_name", nil, id)
    else
      result =
        UniversalConstructor.run(action: "call", tool_name: tool_name, tool_args: tool_args)

      Protocol.encode_response(
        %{
          "success" => result.success,
          "action" => result.action,
          "tool_name" => if(result.call_result, do: result.call_result.tool_name, else: nil),
          "result" => if(result.call_result, do: result.call_result.result, else: nil),
          "execution_time" =>
            if(result.call_result, do: result.call_result.execution_time, else: nil),
          "error" => result.error
        },
        id
      )
    end
  end

  # uc.create - Create a new UC tool
  defp handle_request("uc.create", params, id) do
    tool_name = params["tool_name"] || params["name"]
    elixir_code = params["elixir_code"] || params["code"]
    description = params["description"]

    if is_nil(elixir_code) do
      Protocol.encode_error(-32602, "Missing required param: elixir_code", nil, id)
    else
      result =
        UniversalConstructor.run(
          action: "create",
          tool_name: tool_name,
          elixir_code: elixir_code,
          description: description
        )

      Protocol.encode_response(
        %{
          "success" => result.success,
          "action" => result.action,
          "tool_name" => if(result.create_result, do: result.create_result.tool_name, else: nil),
          "source_path" =>
            if(result.create_result, do: result.create_result.source_path, else: nil),
          "preview" => if(result.create_result, do: result.create_result.preview, else: nil),
          "validation_warnings" =>
            if(result.create_result, do: result.create_result.validation_warnings, else: []),
          "error" => result.error
        },
        id
      )
    end
  end

  # uc.update - Update an existing UC tool
  defp handle_request("uc.update", params, id) do
    tool_name = params["tool_name"] || params["name"]
    elixir_code = params["elixir_code"] || params["code"]

    cond do
      is_nil(tool_name) ->
        Protocol.encode_error(-32602, "Missing required param: tool_name", nil, id)

      is_nil(elixir_code) ->
        Protocol.encode_error(-32602, "Missing required param: elixir_code", nil, id)

      true ->
        result =
          UniversalConstructor.run(
            action: "update",
            tool_name: tool_name,
            elixir_code: elixir_code
          )

        Protocol.encode_response(
          %{
            "success" => result.success,
            "action" => result.action,
            "tool_name" =>
              if(result.update_result, do: result.update_result.tool_name, else: nil),
            "source_path" =>
              if(result.update_result, do: result.update_result.source_path, else: nil),
            "preview" => if(result.update_result, do: result.update_result.preview, else: nil),
            "changes_applied" =>
              if(result.update_result, do: result.update_result.changes_applied, else: []),
            "error" => result.error
          },
          id
        )
    end
  end

  # uc.info - Get info about a UC tool
  defp handle_request("uc.info", params, id) do
    tool_name = params["tool_name"] || params["name"]

    if is_nil(tool_name) do
      Protocol.encode_error(-32602, "Missing required param: tool_name", nil, id)
    else
      result = UniversalConstructor.run(action: "info", tool_name: tool_name)

      response =
        if result.success and result.info_result do
          tool = result.info_result.tool
          source_code = result.info_result.source_code

          %{
            "success" => true,
            "formatted" => UniversalConstructor.format_tool(tool, source_code),
            "tool" =>
              if tool do
                %{
                  "full_name" => tool.full_name,
                  "name" => tool.meta.name,
                  "namespace" => tool.meta.namespace,
                  "description" => tool.meta.description,
                  "enabled" => tool.meta.enabled,
                  "version" => tool.meta.version,
                  "author" => tool.meta.author,
                  "created_at" => tool.meta.created_at,
                  "signature" => tool.signature,
                  "function_name" => tool.function_name,
                  "source_path" => tool.source_path,
                  "docstring" => tool.docstring
                }
              else
                nil
              end,
            "source_code" => source_code
          }
        else
          %{"success" => false, "error" => result.error}
        end

      Protocol.encode_response(response, id)
    end
  end

  # ============================================================================
  # Round-Robin Model Operations
  # ============================================================================

  # round_robin.get_next - Get next model, advancing rotation
  defp handle_request("round_robin.get_next", _params, id) do
    model = RoundRobinModel.advance_and_get()
    Protocol.encode_response(%{"model" => model}, id)
  end

  # round_robin.get_current - Get current model without advancing
  defp handle_request("round_robin.get_current", _params, id) do
    model = RoundRobinModel.get_current_model()
    Protocol.encode_response(%{"model" => model}, id)
  end

  # round_robin.reset - Reset rotation to initial position
  defp handle_request("round_robin.reset", _params, id) do
    :ok = RoundRobinModel.reset()
    Protocol.encode_response(%{"reset" => true}, id)
  end

  # round_robin.get_state - Get full rotation state
  defp handle_request("round_robin.get_state", _params, id) do
    state = RoundRobinModel.get_state()

    result =
      if state do
        %{
          "models" => state.models,
          "current_index" => state.current_index,
          "rotate_every" => state.rotate_every,
          "request_count" => state.request_count,
          "current_model" => Enum.at(state.models, state.current_index)
        }
      else
        %{
          "models" => [],
          "current_index" => 0,
          "rotate_every" => 1,
          "request_count" => 0,
          "current_model" => nil
        }
      end

    Protocol.encode_response(result, id)
  end

  # round_robin.configure - Configure models and rotation settings
  defp handle_request("round_robin.configure", params, id) do
    models = params["models"]
    rotate_every = params["rotate_every"] || 1

    cond do
      is_nil(models) or not is_list(models) ->
        Protocol.encode_error(
          -32602,
          "Missing or invalid param: models (must be a list)",
          nil,
          id
        )

      models == [] ->
        Protocol.encode_error(-32602, "Invalid param: models cannot be empty", nil, id)

      rotate_every < 1 ->
        Protocol.encode_error(-32602, "Invalid param: rotate_every must be >= 1", nil, id)

      true ->
        case RoundRobinModel.configure(models: models, rotate_every: rotate_every) do
          :ok ->
            Protocol.encode_response(
              %{"configured" => true, "models" => models, "rotate_every" => rotate_every},
              id
            )

          {:error, reason} ->
            Protocol.encode_error(-32602, "Configuration failed: #{reason}", nil, id)
        end
    end
  end

  # round_robin.list_models - List configured models
  defp handle_request("round_robin.list_models", _params, id) do
    models = RoundRobinModel.list_models()
    Protocol.encode_response(%{"models" => models, "count" => length(models)}, id)
  end

  # ============================================================================
  # Code Context Operations
  # ============================================================================

  # code_context.explore_file - Explore a single file with symbols
  defp handle_request("code_context.explore_file", params, id) do
    file_path = params["file_path"] || params["path"]

    if is_nil(file_path) do
      Protocol.encode_error(-32602, "Missing required param: file_path", nil, id)
    else
      opts = params_to_code_context_opts(params)

      case CodePuppyControl.CodeContext.explore_file(file_path, opts) do
        {:ok, result} ->
          Protocol.encode_response(serialize_code_context_result(result), id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "Code context explore failed: #{format_error(reason)}",
            nil,
            id
          )
      end
    end
  end

  # code_context.get_outline - Get hierarchical symbol outline
  defp handle_request("code_context.get_outline", params, id) do
    file_path = params["file_path"] || params["path"]

    if is_nil(file_path) do
      Protocol.encode_error(-32602, "Missing required param: file_path", nil, id)
    else
      max_depth = params["max_depth"]
      opts = if max_depth, do: [max_depth: max_depth], else: []

      case CodePuppyControl.CodeContext.get_outline(file_path, opts) do
        {:ok, result} ->
          Protocol.encode_response(%{"outline" => result}, id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "Outline extraction failed: #{format_error(reason)}",
            nil,
            id
          )
      end
    end
  end

  # code_context.explore_directory - Explore directory with symbol extraction
  defp handle_request("code_context.explore_directory", params, id) do
    directory = params["directory"] || "."
    opts = params_to_code_context_directory_opts(params)

    case CodePuppyControl.CodeContext.explore_directory(directory, opts) do
      {:ok, results} ->
        serialized = Enum.map(results, &serialize_code_context_result/1)
        Protocol.encode_response(%{"files" => serialized, "count" => length(serialized)}, id)

      {:error, reason} ->
        Protocol.encode_error(
          -32000,
          "Directory exploration failed: #{format_error(reason)}",
          nil,
          id
        )
    end
  end

  # code_context.find_symbol_definitions - Find symbol across directory
  defp handle_request("code_context.find_symbol_definitions", params, id) do
    directory = params["directory"] || "."
    symbol_name = params["symbol_name"] || params["symbol"]

    cond do
      is_nil(symbol_name) ->
        Protocol.encode_error(-32602, "Missing required param: symbol_name", nil, id)

      not is_binary(symbol_name) or symbol_name == "" ->
        Protocol.encode_error(
          -32602,
          "Invalid param: symbol_name must be non-empty string",
          nil,
          id
        )

      true ->
        case CodePuppyControl.CodeContext.find_symbol_definitions(directory, symbol_name) do
          {:ok, matches} ->
            Protocol.encode_response(%{"matches" => matches, "count" => length(matches)}, id)

          {:error, reason} ->
            Protocol.encode_error(
              -32000,
              "Symbol search failed: #{format_error(reason)}",
              nil,
              id
            )
        end
    end
  end

  # code_context.cache_stats - Get cache statistics
  defp handle_request("code_context.cache_stats", _params, id) do
    stats = CodePuppyControl.CodeContext.cache_stats()
    Protocol.encode_response(%{"stats" => stats}, id)
  end

  # code_context.invalidate_cache - Invalidate cache entries
  defp handle_request("code_context.invalidate_cache", params, id) do
    file_path = params["file_path"]
    removed = CodePuppyControl.CodeContext.invalidate_cache(file_path)
    Protocol.encode_response(%{"removed" => removed, "file_path" => file_path}, id)
  end

  # ============================================================================
  # Models Dev Parser Operations
  # ============================================================================

  # models_dev.get_providers - Get all providers
  defp handle_request("models_dev.get_providers", _params, id) do
    providers =
      CodePuppyControl.ModelsDevParser.Registry.get_providers()
      |> Enum.map(fn p ->
        %{
          "id" => p.id,
          "name" => p.name,
          "env" => p.env,
          "api" => p.api,
          "npm" => p.npm,
          "doc" => p.doc,
          "model_count" => CodePuppyControl.ModelsDevParser.ProviderInfo.model_count(p)
        }
      end)

    Protocol.encode_response(%{"providers" => providers, "count" => length(providers)}, id)
  end

  # models_dev.get_provider - Get a specific provider
  defp handle_request("models_dev.get_provider", params, id) do
    provider_id = params["provider_id"]

    if is_nil(provider_id) or not is_binary(provider_id) do
      Protocol.encode_error(-32602, "Missing or invalid param: provider_id", nil, id)
    else
      case CodePuppyControl.ModelsDevParser.Registry.get_provider(provider_id) do
        nil ->
          Protocol.encode_response(%{"provider" => nil}, id)

        p ->
          provider = %{
            "id" => p.id,
            "name" => p.name,
            "env" => p.env,
            "api" => p.api,
            "npm" => p.npm,
            "doc" => p.doc,
            "model_count" => CodePuppyControl.ModelsDevParser.ProviderInfo.model_count(p)
          }

          Protocol.encode_response(%{"provider" => provider}, id)
      end
    end
  end

  # models_dev.get_models - Get models, optionally filtered by provider
  defp handle_request("models_dev.get_models", params, id) do
    provider_id = params["provider_id"]

    models =
      CodePuppyControl.ModelsDevParser.Registry.get_models(provider_id)
      |> Enum.map(&serialize_model/1)

    Protocol.encode_response(%{"models" => models, "count" => length(models)}, id)
  end

  # models_dev.get_model - Get a specific model
  defp handle_request("models_dev.get_model", params, id) do
    provider_id = params["provider_id"]
    model_id = params["model_id"]

    cond do
      is_nil(provider_id) or not is_binary(provider_id) ->
        Protocol.encode_error(-32602, "Missing or invalid param: provider_id", nil, id)

      is_nil(model_id) or not is_binary(model_id) ->
        Protocol.encode_error(-32602, "Missing or invalid param: model_id", nil, id)

      true ->
        case CodePuppyControl.ModelsDevParser.Registry.get_model(provider_id, model_id) do
          nil ->
            Protocol.encode_response(%{"model" => nil}, id)

          m ->
            Protocol.encode_response(%{"model" => serialize_model(m)}, id)
        end
    end
  end

  # models_dev.search - Search models by query and capabilities
  defp handle_request("models_dev.search", params, id) do
    query = params["query"]
    capability_filters = params["capability_filters"] || %{}

    opts =
      [capability_filters: capability_filters] ++
        if query, do: [query: query], else: []

    models =
      CodePuppyControl.ModelsDevParser.Registry.search_models(opts)
      |> Enum.map(&serialize_model/1)

    Protocol.encode_response(%{"models" => models, "count" => length(models)}, id)
  end

  # models_dev.filter_by_cost - Filter models by cost
  defp handle_request("models_dev.filter_by_cost", params, id) do
    # Get all models first, then filter
    models = CodePuppyControl.ModelsDevParser.Registry.get_models()
    max_input_cost = params["max_input_cost"]
    max_output_cost = params["max_output_cost"]

    filtered =
      CodePuppyControl.ModelsDevParser.Registry.filter_by_cost(
        models,
        max_input_cost,
        max_output_cost
      )
      |> Enum.map(&serialize_model/1)

    Protocol.encode_response(%{"models" => filtered, "count" => length(filtered)}, id)
  end

  # models_dev.filter_by_context - Filter by minimum context
  defp handle_request("models_dev.filter_by_context", params, id) do
    models = CodePuppyControl.ModelsDevParser.Registry.get_models()
    min_context = params["min_context_length"] || 0

    filtered =
      CodePuppyControl.ModelsDevParser.Registry.filter_by_context(models, min_context)
      |> Enum.map(&serialize_model/1)

    Protocol.encode_response(%{"models" => filtered, "count" => length(filtered)}, id)
  end

  # models_dev.to_config - Convert model to config format
  defp handle_request("models_dev.to_config", params, id) do
    provider_id = params["provider_id"]
    model_id = params["model_id"]

    cond do
      is_nil(provider_id) or not is_binary(provider_id) ->
        Protocol.encode_error(-32602, "Missing or invalid param: provider_id", nil, id)

      is_nil(model_id) or not is_binary(model_id) ->
        Protocol.encode_error(-32602, "Missing or invalid param: model_id", nil, id)

      true ->
        case CodePuppyControl.ModelsDevParser.Registry.get_model(provider_id, model_id) do
          nil ->
            Protocol.encode_response(%{"config" => nil}, id)

          m ->
            config = CodePuppyControl.ModelsDevParser.Registry.to_config(m)
            Protocol.encode_response(%{"config" => config}, id)
        end
    end
  end

  # models_dev.data_source - Get data source info
  defp handle_request("models_dev.data_source", _params, id) do
    source = CodePuppyControl.ModelsDevParser.Registry.data_source()
    Protocol.encode_response(%{"data_source" => source}, id)
  end

  # ============================================================================
  # Model Services
  # ============================================================================

  # model_registry.get_config - Get model configuration by name
  defp handle_request("model_registry.get_config", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      model_name = params["model_name"]

      if is_nil(model_name) or not is_binary(model_name) do
        Protocol.encode_error(-32602, "Missing or invalid param: model_name", nil, id)
      else
        config = ModelRegistry.get_config(model_name)

        if config do
          Protocol.encode_response(%{"model_name" => model_name, "config" => config}, id)
        else
          Protocol.encode_response(
            %{"model_name" => model_name, "config" => nil, "error" => "not_found"},
            id
          )
        end
      end
    end
  end

  # model_registry.list_models - List all available models with configs
  defp handle_request("model_registry.list_models", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      models =
        ModelRegistry.get_all_configs()
        |> Enum.map(fn {name, config} ->
          %{
            "name" => name,
            "type" => ModelRegistry.get_model_type(config),
            "enabled" => Map.get(config, "enabled", true)
          }
        end)
        |> Enum.sort_by(& &1["name"])

      Protocol.encode_response(%{"models" => models, "count" => length(models)}, id)
    end
  end

  # model_registry.get_all_configs - Get all model configs as map
  defp handle_request("model_registry.get_all_configs", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      configs = ModelRegistry.get_all_configs()
      Protocol.encode_response(%{"configs" => configs, "count" => map_size(configs)}, id)
    end
  end

  # model_availability.check - Check if model is available
  defp handle_request("model_availability.check", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      model_name = params["model_name"]

      if is_nil(model_name) or not is_binary(model_name) do
        Protocol.encode_error(-32602, "Missing or invalid param: model_name", nil, id)
      else
        snapshot = ModelAvailability.snapshot(model_name)

        Protocol.encode_response(
          %{
            "model_name" => model_name,
            "available" => snapshot.available,
            "reason" => snapshot.reason
          },
          id
        )
      end
    end
  end

  # model_availability.snapshot - Get full availability snapshot
  defp handle_request("model_availability.snapshot", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      model_name = params["model_name"]

      if is_nil(model_name) or not is_binary(model_name) do
        Protocol.encode_error(-32602, "Missing or invalid param: model_name", nil, id)
      else
        snapshot = ModelAvailability.snapshot(model_name)
        last_resort = ModelAvailability.is_last_resort(model_name)

        Protocol.encode_response(
          %{
            "model_name" => model_name,
            "available" => snapshot.available,
            "reason" => snapshot.reason,
            "is_last_resort" => last_resort
          },
          id
        )
      end
    end
  end

  # model_packs.get_pack - Get model pack by name (returns current pack if name is nil)
  defp handle_request("model_packs.get_pack", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      pack_name = params["pack_name"]

      # If pack_name is nil, return current pack; if invalid type, return error
      pack =
        cond do
          is_nil(pack_name) ->
            ModelPacks.get_current_pack()

          is_binary(pack_name) ->
            ModelPacks.get_pack(pack_name)

          true ->
            nil
        end

      if is_nil(pack) do
        Protocol.encode_error(-32602, "Missing or invalid param: pack_name", nil, id)
      else
        serialized = %{
          "name" => pack.name,
          "description" => pack.description,
          "default_role" => pack.default_role,
          "roles" =>
            Map.new(pack.roles, fn {role_name, role_config} ->
              {role_name,
               %{
                 "primary" => role_config.primary,
                 "fallbacks" => role_config.fallbacks,
                 "trigger" => role_config.trigger
               }}
            end),
          "is_builtin" => ModelPacks.builtin_pack?(pack.name)
        }

        Protocol.encode_response(%{"pack" => serialized}, id)
      end
    end
  end

  # model_packs.get_current - Get current model pack
  defp handle_request("model_packs.get_current", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      pack = ModelPacks.get_current_pack()

      serialized = %{
        "name" => pack.name,
        "description" => pack.description,
        "default_role" => pack.default_role,
        "roles" =>
          Map.new(pack.roles, fn {role_name, role_config} ->
            {role_name,
             %{
               "primary" => role_config.primary,
               "fallbacks" => role_config.fallbacks,
               "trigger" => role_config.trigger
             }}
          end),
        "is_builtin" => ModelPacks.builtin_pack?(pack.name)
      }

      Protocol.encode_response(%{"pack" => serialized}, id)
    end
  end

  # model_packs.list_packs - List all available packs
  defp handle_request("model_packs.list_packs", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      packs =
        ModelPacks.list_packs()
        |> Enum.map(fn pack ->
          %{
            "name" => pack.name,
            "description" => pack.description,
            "default_role" => pack.default_role,
            "role_count" => map_size(pack.roles),
            "is_builtin" => ModelPacks.builtin_pack?(pack.name)
          }
        end)

      Protocol.encode_response(%{"packs" => packs, "count" => length(packs)}, id)
    end
  end

  # model_packs.get_model_for_role - Get primary model for role
  defp handle_request("model_packs.get_model_for_role", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      role = params["role"] || "coder"

      if not is_binary(role) do
        Protocol.encode_error(-32602, "Invalid param: role must be a string", nil, id)
      else
        model = ModelPacks.get_model_for_role(role)
        Protocol.encode_response(%{"role" => role, "model" => model}, id)
      end
    end
  end

  # model_utils.resolve_model - Resolve model name to config
  defp handle_request("model_utils.resolve_model", params, id) do
    with :ok <- validate_params_is_map(params, id) do
      model_name = params["model_name"]

      if is_nil(model_name) or not is_binary(model_name) do
        Protocol.encode_error(-32602, "Missing or invalid param: model_name", nil, id)
      else
        # First check the registry
        config = ModelRegistry.get_config(model_name)

        # If not found directly, try current pack role resolution
        resolved_config =
          if config do
            config
          else
            # Check if it's a role alias
            pack = ModelPacks.get_current_pack()
            resolved = ModelPacks.ModelPack.get_model_for_role(pack, model_name)

            if resolved && resolved != "auto" do
              ModelRegistry.get_config(resolved)
            else
              nil
            end
          end

        if resolved_config do
          Protocol.encode_response(
            %{
              "model_name" => model_name,
              "config" => resolved_config,
              "type" => ModelRegistry.get_model_type(resolved_config)
            },
            id
          )
        else
          Protocol.encode_response(
            %{
              "model_name" => model_name,
              "config" => nil,
              "type" => nil,
              "error" => "not_found"
            },
            id
          )
        end
      end
    end
  end

  # ============================================================================
  # Shell Command Runner
  # ============================================================================

  # shell.run - Execute a shell command with streaming output
  defp handle_request("shell.run", params, id) do
    command = params["command"]

    if is_nil(command) or not is_binary(command) do
      Protocol.encode_error(-32602, "Missing or invalid param: command", nil, id)
    else
      opts = params_to_shell_opts(params)

      case CommandRunner.run(command, opts) do
        {:ok, result} ->
          Protocol.encode_response(serialize_shell_result(result), id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "Shell command failed: #{format_error(reason)}",
            nil,
            id
          )
      end
    end
  end

  # shell.run_batch - Execute multiple shell commands
  defp handle_request("shell.run_batch", params, id) do
    commands = params["commands"]

    if is_nil(commands) or not is_list(commands) do
      Protocol.encode_error(
        -32602,
        "Missing or invalid param: commands (must be a list)",
        nil,
        id
      )
    else
      opts = params_to_shell_opts(params)

      # Run commands sequentially and collect results
      results =
        Enum.map(commands, fn cmd ->
          if is_binary(cmd) do
            case CommandRunner.run(cmd, opts) do
              {:ok, result} ->
                serialize_shell_result(result)

              {:error, reason} ->
                %{"command" => cmd, "error" => to_string(reason), "success" => false}
            end
          else
            %{"command" => inspect(cmd), "error" => "Invalid command type", "success" => false}
          end
        end)

      Protocol.encode_response(%{"results" => results, "count" => length(results)}, id)
    end
  end

  # shell.kill_all - Kill all running shell processes
  defp handle_request("shell.kill_all", _params, id) do
    count = CommandRunner.kill_all()
    Protocol.encode_response(%{"killed_count" => count}, id)
  end

  # shell.running_count - Get count of running processes
  defp handle_request("shell.running_count", _params, id) do
    count = CommandRunner.running_count()
    Protocol.encode_response(%{"count" => count}, id)
  end

  # ============================================================================
  # Message Processing
  # ============================================================================

  # message.prune_and_filter - Prune orphaned tool calls and oversized messages
  defp handle_request("message.prune_and_filter", params, id) do
    messages = params["messages"]

    if is_nil(messages) or not is_list(messages) do
      Protocol.encode_error(-32602, "Missing or invalid param: messages", nil, id)
    else
      max_tokens = params["max_tokens_per_message"] || 50_000
      result = Pruner.prune_and_filter(messages, max_tokens)
      Protocol.encode_response(result, id)
    end
  end

  # message.truncation_indices - Calculate which messages to keep within token budget
  defp handle_request("message.truncation_indices", params, id) do
    per_message_tokens = params["per_message_tokens"]
    protected_tokens = params["protected_tokens"]

    cond do
      is_nil(per_message_tokens) or not is_list(per_message_tokens) ->
        Protocol.encode_error(-32602, "Missing or invalid param: per_message_tokens", nil, id)

      is_nil(protected_tokens) or not is_integer(protected_tokens) ->
        Protocol.encode_error(-32602, "Missing or invalid param: protected_tokens", nil, id)

      true ->
        second_has_thinking = params["second_has_thinking"] || false

        indices =
          Pruner.truncation_indices(
            per_message_tokens,
            protected_tokens,
            second_has_thinking
          )

        Protocol.encode_response(%{"indices" => indices}, id)
    end
  end

  # message.split_for_summarization - Split messages into summarize vs protected groups
  defp handle_request("message.split_for_summarization", params, id) do
    per_message_tokens = params["per_message_tokens"]
    messages = params["messages"]
    protected_tokens_limit = params["protected_tokens_limit"]

    cond do
      is_nil(per_message_tokens) or not is_list(per_message_tokens) ->
        Protocol.encode_error(-32602, "Missing or invalid param: per_message_tokens", nil, id)

      is_nil(messages) or not is_list(messages) ->
        Protocol.encode_error(-32602, "Missing or invalid param: messages", nil, id)

      is_nil(protected_tokens_limit) or not is_integer(protected_tokens_limit) ->
        Protocol.encode_error(-32602, "Missing or invalid param: protected_tokens_limit", nil, id)

      true ->
        result =
          Pruner.split_for_summarization(
            per_message_tokens,
            messages,
            protected_tokens_limit
          )

        Protocol.encode_response(result, id)
    end
  end

  # message.serialize_session - Serialize messages to MessagePack
  defp handle_request("message.serialize_session", params, id) do
    messages = params["messages"]

    if is_nil(messages) or not is_list(messages) do
      Protocol.encode_error(-32602, "Missing or invalid param: messages", nil, id)
    else
      case Serializer.serialize_session(messages) do
        {:ok, binary} ->
          # Base64 encode for JSON transport
          Protocol.encode_response(%{"data" => Base.encode64(binary)}, id)

        {:error, reason} ->
          Protocol.encode_error(-32000, "Serialization failed: #{reason}", nil, id)
      end
    end
  end

  # message.deserialize_session - Deserialize MessagePack to messages
  defp handle_request("message.deserialize_session", params, id) do
    data = params["data"]

    if is_nil(data) or not is_binary(data) do
      Protocol.encode_error(-32602, "Missing or invalid param: data", nil, id)
    else
      case Base.decode64(data) do
        {:ok, binary} ->
          case Serializer.deserialize_session(binary) do
            {:ok, messages} ->
              Protocol.encode_response(%{"messages" => messages}, id)

            {:error, reason} ->
              Protocol.encode_error(-32000, "Deserialization failed: #{reason}", nil, id)
          end

        :error ->
          Protocol.encode_error(-32602, "Invalid base64 encoding in param: data", nil, id)
      end
    end
  end

  # message.serialize_incremental - Append messages to existing serialized data
  defp handle_request("message.serialize_incremental", params, id) do
    new_messages = params["new_messages"]
    existing_data = params["existing_data"]

    if is_nil(new_messages) or not is_list(new_messages) do
      Protocol.encode_error(-32602, "Missing or invalid param: new_messages", nil, id)
    else
      # Decode existing data if provided
      decoded_existing =
        cond do
          is_nil(existing_data) ->
            {:ok, nil}

          is_binary(existing_data) ->
            case Base.decode64(existing_data) do
              {:ok, binary} -> {:ok, binary}
              :error -> {:error, "Invalid base64 encoding"}
            end

          true ->
            {:error, "Invalid existing_data type"}
        end

      case decoded_existing do
        {:ok, existing_binary} ->
          case Serializer.serialize_session_incremental(
                 new_messages,
                 existing_binary
               ) do
            {:ok, binary} ->
              Protocol.encode_response(%{"data" => Base.encode64(binary)}, id)

            {:error, reason} ->
              Protocol.encode_error(
                -32000,
                "Incremental serialization failed: #{reason}",
                nil,
                id
              )
          end

        {:error, reason} ->
          Protocol.encode_error(-32602, reason, nil, id)
      end
    end
  end

  # message.hash - Compute content hash for a message
  defp handle_request("message.hash", params, id) do
    message = params["message"]

    if is_nil(message) or not is_map(message) do
      Protocol.encode_error(-32602, "Missing or invalid param: message", nil, id)
    else
      hash = Hasher.hash_message(message)
      Protocol.encode_response(%{"hash" => hash}, id)
    end
  end

  # message.hash_batch - Compute hashes for multiple messages
  defp handle_request("message.hash_batch", params, id) do
    messages = params["messages"]

    if is_nil(messages) or not is_list(messages) do
      Protocol.encode_error(-32602, "Missing or invalid param: messages", nil, id)
    else
      hashes =
        Enum.map(messages, fn msg ->
          if is_map(msg) do
            Hasher.hash_message(msg)
          else
            nil
          end
        end)

      Protocol.encode_response(%{"hashes" => hashes}, id)
    end
  end

  # message.stringify_part - Get canonical string for a message part
  defp handle_request("message.stringify_part", params, id) do
    part = params["part"]

    if is_nil(part) or not is_map(part) do
      Protocol.encode_error(-32602, "Missing or invalid param: part", nil, id)
    else
      stringified = Hasher.stringify_part_for_hash(part)
      Protocol.encode_response(%{"stringified" => stringified}, id)
    end
  end

  # Session Storage API (ETS-cached + SQLite-backed + PubSub)
  # (code_puppy-ctj.1) Routes through SessionStorage.Store for ETS caching
  # and PubSub notifications when the Store is available; falls back to
  # direct Sessions calls otherwise.

  defp handle_request("session_save", params, id) do
    name = params["name"]
    history = params["history"] || []

    opts = [
      compacted_hashes: params["compacted_hashes"] || [],
      total_tokens: params["total_tokens"] || 0,
      auto_saved: params["auto_saved"] || false,
      timestamp: params["timestamp"],
      has_terminal: params["has_terminal"] || false,
      terminal_meta: params["terminal_meta"]
    ]

    if store_available?() do
      case CodePuppyControl.SessionStorage.Store.save_session(name, history, opts) do
        {:ok, result} ->
          Protocol.encode_response(
            %{
              "success" => true,
              "name" => result.name,
              "message_count" => result.message_count,
              "total_tokens" => result.total_tokens
            },
            id
          )

        {:error, reason} ->
          Protocol.encode_error(-32000, "Session save failed: #{inspect(reason)}", nil, id)
      end
    else
      case CodePuppyControl.Sessions.save_session(name, history, opts) do
        {:ok, session} ->
          Protocol.encode_response(
            %{
              "success" => true,
              "name" => session.name,
              "message_count" => session.message_count,
              "total_tokens" => session.total_tokens
            },
            id
          )

        {:error, changeset} ->
          errors = traverse_changeset_errors(changeset)
          Protocol.encode_error(-32000, "Session save failed: #{inspect(errors)}", nil, id)
      end
    end
  end

  defp handle_request("session_load", params, id) do
    name = params["name"]

    if store_available?() do
      case CodePuppyControl.SessionStorage.Store.load_session(name) do
        {:ok, %{history: history, compacted_hashes: hashes}} ->
          Protocol.encode_response(
            %{"history" => history, "compacted_hashes" => hashes},
            id
          )

        {:error, :not_found} ->
          Protocol.encode_error(-32000, "Session not found: #{name}", nil, id)

        {:error, reason} ->
          Protocol.encode_error(-32000, "Session load failed: #{inspect(reason)}", nil, id)
      end
    else
      case CodePuppyControl.Sessions.load_session(name) do
        {:ok, %{history: history, compacted_hashes: hashes}} ->
          Protocol.encode_response(
            %{"history" => history, "compacted_hashes" => hashes},
            id
          )

        {:error, :not_found} ->
          Protocol.encode_error(-32000, "Session not found: #{name}", nil, id)

        {:error, reason} ->
          Protocol.encode_error(-32000, "Session load failed: #{inspect(reason)}", nil, id)
      end
    end
  end

  defp handle_request("session_load_full", params, id) do
    name = params["name"]

    if store_available?() do
      case CodePuppyControl.SessionStorage.Store.load_session_full(name) do
        {:ok, entry} ->
          Protocol.encode_response(
            %{
              "name" => entry.name,
              "history" => entry.history || [],
              "compacted_hashes" => entry.compacted_hashes || [],
              "message_count" => entry.message_count,
              "total_tokens" => entry.total_tokens,
              "auto_saved" => entry.auto_saved,
              "timestamp" => entry.timestamp,
              "has_terminal" => entry.has_terminal,
              "terminal_meta" => entry.terminal_meta
            },
            id
          )

        {:error, :not_found} ->
          Protocol.encode_error(-32000, "Session not found: #{name}", nil, id)

        {:error, reason} ->
          Protocol.encode_error(-32000, "Session load failed: #{inspect(reason)}", nil, id)
      end
    else
      case CodePuppyControl.Sessions.load_session_full(name) do
        {:ok, session} ->
          Protocol.encode_response(
            %{
              "name" => session.name,
              "history" => session.history || [],
              "compacted_hashes" => session.compacted_hashes || [],
              "message_count" => session.message_count,
              "total_tokens" => session.total_tokens,
              "auto_saved" => session.auto_saved,
              "timestamp" => session.timestamp,
              "created_at" =>
                if(session.inserted_at, do: DateTime.to_iso8601(session.inserted_at)),
              "updated_at" => if(session.updated_at, do: DateTime.to_iso8601(session.updated_at))
            },
            id
          )

        {:error, :not_found} ->
          Protocol.encode_error(-32000, "Session not found: #{name}", nil, id)

        {:error, reason} ->
          Protocol.encode_error(-32000, "Session load failed: #{inspect(reason)}", nil, id)
      end
    end
  end

  defp handle_request("session_list", _params, id) do
    if store_available?() do
      {:ok, names} = CodePuppyControl.SessionStorage.Store.list_sessions()
      Protocol.encode_response(%{"sessions" => names}, id)
    else
      {:ok, names} = CodePuppyControl.Sessions.list_sessions()
      Protocol.encode_response(%{"sessions" => names}, id)
    end
  end

  defp handle_request("session_list_with_metadata", _params, id) do
    if store_available?() do
      {:ok, entries} = CodePuppyControl.SessionStorage.Store.list_sessions_with_metadata()

      sessions =
        Enum.map(entries, fn e ->
          %{
            "name" => e.name,
            "message_count" => e.message_count,
            "total_tokens" => e.total_tokens,
            "auto_saved" => e.auto_saved,
            "timestamp" => e.timestamp,
            "has_terminal" => e.has_terminal,
            "terminal_meta" => e.terminal_meta
          }
        end)

      Protocol.encode_response(%{"sessions" => sessions}, id)
    else
      {:ok, sessions} = CodePuppyControl.Sessions.list_sessions_with_metadata()
      Protocol.encode_response(%{"sessions" => sessions}, id)
    end
  end

  defp handle_request("session_delete", params, id) do
    name = params["name"]

    if store_available?() do
      :ok = CodePuppyControl.SessionStorage.Store.delete_session(name)
    else
      :ok = CodePuppyControl.Sessions.delete_session(name)
    end

    Protocol.encode_response(%{"deleted" => true, "name" => name}, id)
  end

  defp handle_request("session_cleanup", params, id) do
    max_sessions = params["max_sessions"] || 10

    if store_available?() do
      {:ok, deleted} = CodePuppyControl.SessionStorage.Store.cleanup_sessions(max_sessions)
      Protocol.encode_response(%{"deleted" => deleted, "count" => length(deleted)}, id)
    else
      {:ok, deleted} = CodePuppyControl.Sessions.cleanup_sessions(max_sessions)
      Protocol.encode_response(%{"deleted" => deleted, "count" => length(deleted)}, id)
    end
  end

  defp handle_request("session_exists", params, id) do
    name = params["name"]

    exists =
      if store_available?() do
        CodePuppyControl.SessionStorage.Store.session_exists?(name)
      else
        CodePuppyControl.Sessions.session_exists?(name)
      end

    Protocol.encode_response(%{"exists" => exists}, id)
  end

  defp handle_request("session_count", _params, id) do
    count =
      if store_available?() do
        CodePuppyControl.SessionStorage.Store.count_sessions()
      else
        CodePuppyControl.Sessions.count_sessions()
      end

    Protocol.encode_response(%{"count" => count}, id)
  end

  # (code_puppy-ctj.1) Terminal session tracking via PubSub + ETS
  defp handle_request("session_register_terminal", params, id) do
    name = params["name"]

    meta = %{
      session_id: params["session_id"] || name,
      cols: params["cols"] || 80,
      rows: params["rows"] || 24,
      shell: params["shell"],
      attached_at: System.monotonic_time(:millisecond)
    }

    if store_available?() do
      case CodePuppyControl.SessionStorage.Store.register_terminal(name, meta) do
        :ok ->
          Protocol.encode_response(%{"registered" => true, "name" => name}, id)

        {:error, :session_not_found} ->
          Protocol.encode_error(-32001, "Session not found: #{name}", nil, id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "Failed to register terminal: #{inspect(reason)}",
            nil,
            id
          )
      end
    else
      Protocol.encode_error(-32000, "Session Store not available", nil, id)
    end
  end

  defp handle_request("session_unregister_terminal", params, id) do
    name = params["name"]

    if store_available?() do
      case CodePuppyControl.SessionStorage.Store.unregister_terminal(name) do
        :ok ->
          Protocol.encode_response(%{"unregistered" => true, "name" => name}, id)

        {:error, :session_not_found} ->
          Protocol.encode_error(-32001, "Session not found: #{name}", nil, id)

        {:error, reason} ->
          Protocol.encode_error(
            -32000,
            "Failed to unregister terminal: #{inspect(reason)}",
            nil,
            id
          )
      end
    else
      Protocol.encode_error(-32000, "Session Store not available", nil, id)
    end
  end

  defp handle_request("session_list_terminals", _params, id) do
    if store_available?() do
      terminals = CodePuppyControl.SessionStorage.Store.list_terminal_sessions()
      Protocol.encode_response(%{"terminals" => terminals}, id)
    else
      Protocol.encode_response(%{"terminals" => []}, id)
    end
  end

  # (code_puppy-ctj.1) Check if the SessionStorage.Store GenServer is running
  defp store_available? do
    Process.whereis(CodePuppyControl.SessionStorage.Store) != nil
  end

  # --- Workflow methods (: DBOS replacement) ---

  defp handle_request("workflow.invoke_agent", params, id) do
    # params is string-keyed (JSON-RPC); Workflow.invoke_agent normalizes
    # atom/string keys internally, so we pass params through as-is.
    case CodePuppyControl.Workflow.invoke_agent(params) do
      {:ok, job} ->
        Protocol.encode_response(
          %{
            "job_id" => job.id,
            "workflow_id" => job.args["workflow_id"],
            "state" => job.state,
            "queue" => job.queue
          },
          id
        )

      {:error, reason} ->
        Protocol.encode_error(-32_000, "Workflow invocation failed: #{inspect(reason)}", nil, id)
    end
  end

  defp handle_request("workflow.get_status", params, id) do
    workflow_id = params["workflow_id"]

    if is_nil(workflow_id) or not is_binary(workflow_id) do
      Protocol.encode_error(-32602, "Missing or invalid param: workflow_id", nil, id)
    else
      case CodePuppyControl.Workflow.get_status(workflow_id) do
        {:ok, status} ->
          Protocol.encode_response(
            %{
              "workflow_id" => status.workflow_id,
              "state" => status.state,
              "steps" =>
                Enum.map(status.steps, fn step ->
                  %{"name" => step.step_name, "state" => step.state, "attempt" => step.attempt}
                end)
            },
            id
          )

        {:error, :not_found} ->
          Protocol.encode_error(-32_001, "Workflow not found", nil, id)
      end
    end
  end

  defp handle_request("workflow.cancel", params, id) do
    workflow_id = params["workflow_id"]

    if is_nil(workflow_id) or not is_binary(workflow_id) do
      Protocol.encode_error(-32602, "Missing or invalid param: workflow_id", nil, id)
    else
      case CodePuppyControl.Workflow.cancel(workflow_id) do
        :ok ->
          Protocol.encode_response(%{"cancelled" => true, "workflow_id" => workflow_id}, id)

        {:error, :not_found} ->
          Protocol.encode_error(-32_001, "Workflow not found", nil, id)
      end
    end
  end

  defp handle_request("workflow.list_recent", params, id) do
    limit = Map.get(params, "limit", 20)
    workflows = CodePuppyControl.Workflow.list_recent(limit: limit)
    Protocol.encode_response(%{"workflows" => workflows}, id)
  end

  defp handle_request("workflow.get_history", params, id) do
    workflow_id = params["workflow_id"]

    if is_nil(workflow_id) or not is_binary(workflow_id) do
      Protocol.encode_error(-32602, "Missing or invalid param: workflow_id", nil, id)
    else
      history = CodePuppyControl.Workflow.get_history(workflow_id)
      Protocol.encode_response(%{"history" => history}, id)
    end
  end

  # Method not found handler
  # ── Pack Parallelism / Run Limiter ────────────────────────────────
  # These handlers delegate to CodePuppyControl.Plugins.PackParallelism,
  # the Elixir GenServer that replaces the Python _async_active HACK.
  # When the Elixir control plane is active, these methods bypass the
  # Python bridge_controller entirely.

  defp handle_request("run_limiter.acquire", params, id) do
    result = CodePuppyControl.Plugins.PackParallelism.JSONRPC.handle_jsonrpc_acquire(params)
    Protocol.encode_response(result, id)
  end

  defp handle_request("run_limiter.release", params, id) do
    result = CodePuppyControl.Plugins.PackParallelism.JSONRPC.handle_jsonrpc_release(params)
    Protocol.encode_response(result, id)
  end

  defp handle_request("run_limiter.status", params, id) do
    result = CodePuppyControl.Plugins.PackParallelism.JSONRPC.handle_jsonrpc_status(params)
    Protocol.encode_response(result, id)
  end

  defp handle_request("run_limiter.set_limit", params, id) do
    result = CodePuppyControl.Plugins.PackParallelism.JSONRPC.handle_jsonrpc_set_limit(params)
    Protocol.encode_response(result, id)
  end

  defp handle_request("run_limiter.reset", params, id) do
    result = CodePuppyControl.Plugins.PackParallelism.JSONRPC.handle_jsonrpc_reset(params)
    Protocol.encode_response(result, id)
  end

  defp handle_request(method, _params, id) do
    Protocol.encode_error(
      -32601,
      "Method not found: #{method}",
      nil,
      id
    )
  end

  defp traverse_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {_key, value}, acc ->
        String.replace(acc, "%{\#{_key}}", to_string(value))
      end)
    end)
  end

  # Validates that params is a map (JSON-RPC object). Returns encoded error if not.
  defp validate_params_is_map(params, id) when not is_map(params) do
    Protocol.encode_error(-32602, "Invalid params: expected object", nil, id)
  end

  defp validate_params_is_map(_params, _id), do: :ok

  # ============================================================================
  # HTTP Helpers
  # ============================================================================

  # Map of known HTTP methods - prevents atom exhaustion from user input
  @http_methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete,
    "head" => :head,
    "options" => :options
  }

  defp parse_http_method(method) when is_binary(method) do
    # Use safe mapping instead of String.to_atom to prevent atom exhaustion
    Map.get(@http_methods, String.downcase(method), :get)
  end

  defp parse_http_method(method) when is_atom(method), do: method

  defp params_to_http_opts(params) do
    opts = []

    opts =
      if params["headers"],
        do: [{:headers, normalize_headers(params["headers"])} | opts],
        else: opts

    opts = if params["timeout"], do: [{:timeout, params["timeout"]} | opts], else: opts
    opts = if params["retries"], do: [{:retries, params["retries"]} | opts], else: opts
    opts = if params["model_name"], do: [{:model_name, params["model_name"]} | opts], else: opts
    opts
  end

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn
      {k, v} -> {to_string(k), to_string(v)}
      [k, v] -> {to_string(k), to_string(v)}
    end)
  end

  defp normalize_headers(_), do: []

  defp serialize_http_response(%{status: status, body: body, headers: headers}) do
    %{
      "status" => status,
      "body" => body,
      "headers" => Enum.map(headers, fn {k, v} -> [k, v] end)
    }
  end

  # ============================================================================
  # Shell Helpers
  # ============================================================================

  defp params_to_shell_opts(params) do
    opts = []

    # Timeout in seconds (default 60, max 270)
    timeout = params["timeout"] || 60
    opts = [{:timeout, min(timeout, 270)} | opts]

    # Working directory
    opts = if params["cwd"], do: [{:cwd, params["cwd"]} | opts], else: opts

    # Silent mode (no streaming)
    opts = if params["silent"], do: [{:silent, true} | opts], else: opts

    # Environment variables as keyword list
    opts =
      if params["env"] and is_map(params["env"]) do
        env_list = Enum.map(params["env"], fn {k, v} -> {to_string(k), to_string(v)} end)
        [{:env, env_list} | opts]
      else
        opts
      end

    opts
  end

  defp serialize_shell_result(result) do
    %{
      "success" => result.success,
      "command" => result.command,
      "stdout" => result.stdout,
      "stderr" => result.stderr,
      "exit_code" => result.exit_code,
      "execution_time_ms" => result.execution_time_ms,
      "timeout" => result.timeout,
      "error" => result.error,
      "user_interrupted" => result.user_interrupted
    }
  end

  # ============================================================================
  # Serialization Helpers
  # ============================================================================

  defp serialize_file_list(files) do
    Enum.map(files, fn file ->
      file
      |> Map.update(:modified, nil, fn dt ->
        case DateTime.to_iso8601(dt) do
          {:ok, str} -> str
          str when is_binary(str) -> str
          _ -> nil
        end
      end)
      |> Map.update(:type, nil, fn t ->
        if is_atom(t), do: Atom.to_string(t), else: t
      end)
    end)
  end

  defp serialize_read_result(result) do
    %{
      "path" => result.path,
      "content" => result.content,
      "num_lines" => result.num_lines,
      "size" => result.size,
      "truncated" => result.truncated,
      "error" => result.error
    }
  end

  defp serialize_grep_matches(matches) do
    Enum.map(matches, fn m ->
      %{
        "file" => m.file,
        "line_number" => m.line_number,
        "line_content" => m.line_content,
        "match_start" => m.match_start,
        "match_end" => m.match_end
      }
    end)
  end

  # Models Dev Parser serialization
  defp serialize_model(%CodePuppyControl.ModelsDevParser.ModelInfo{} = m) do
    %{
      "provider_id" => m.provider_id,
      "model_id" => m.model_id,
      "full_id" => CodePuppyControl.ModelsDevParser.ModelInfo.full_id(m),
      "name" => m.name,
      "attachment" => m.attachment,
      "reasoning" => m.reasoning,
      "tool_call" => m.tool_call,
      "temperature" => m.temperature,
      "structured_output" => m.structured_output,
      "cost_input" => m.cost_input,
      "cost_output" => m.cost_output,
      "cost_cache_read" => m.cost_cache_read,
      "context_length" => m.context_length,
      "max_output" => m.max_output,
      "input_modalities" => m.input_modalities,
      "output_modalities" => m.output_modalities,
      "has_vision" => CodePuppyControl.ModelsDevParser.ModelInfo.has_vision?(m),
      "is_multimodal" => CodePuppyControl.ModelsDevParser.ModelInfo.multimodal?(m),
      "knowledge" => m.knowledge,
      "release_date" => m.release_date,
      "last_updated" => m.last_updated,
      "open_weights" => m.open_weights
    }
  end

  # ============================================================================
  # Parameter Conversion
  # ============================================================================

  defp params_to_list_opts(params) do
    [
      recursive: Map.get(params, "recursive", true),
      include_hidden: Map.get(params, "include_hidden", false),
      ignore_patterns: Map.get(params, "ignore_patterns", []),
      max_files: Map.get(params, "max_files", 10_000)
    ]
  end

  defp params_to_read_opts(params) do
    opts = []
    opts = if params["start_line"], do: [{:start_line, params["start_line"]} | opts], else: opts
    opts = if params["num_lines"], do: [{:num_lines, params["num_lines"]} | opts], else: opts
    opts
  end

  defp params_to_grep_opts(params) do
    [
      case_sensitive: Map.get(params, "case_sensitive", true),
      max_matches: Map.get(params, "max_matches", 1_000),
      file_pattern: Map.get(params, "file_pattern", "*"),
      context_lines: Map.get(params, "context_lines", 0)
    ]
  end

  # Code Context parameter conversion
  defp params_to_code_context_opts(params) do
    opts = []

    opts =
      if params["include_content"],
        do: [{:include_content, params["include_content"]} | opts],
        else: [{:include_content, true} | opts]

    opts =
      if params["force_refresh"],
        do: [{:force_refresh, params["force_refresh"]} | opts],
        else: opts

    opts
  end

  defp params_to_code_context_directory_opts(params) do
    opts = []

    opts =
      if params["pattern"],
        do: [{:pattern, params["pattern"]} | opts],
        else: [{:pattern, "*"} | opts]

    opts =
      if params["recursive"],
        do: [{:recursive, params["recursive"]} | opts],
        else: [{:recursive, true} | opts]

    opts =
      if params["max_files"],
        do: [{:max_files, params["max_files"]} | opts],
        else: [{:max_files, 50} | opts]

    opts =
      if params["include_content"],
        do: [{:include_content, params["include_content"]} | opts],
        else: [{:include_content, false} | opts]

    opts
  end

  defp serialize_code_context_result(result) do
    %{
      "file_path" => result.file_path,
      "content" => result.content,
      "language" => result.language,
      "outline" => result.outline,
      "file_size" => result.file_size,
      "num_lines" => result.num_lines,
      "num_tokens" => result.num_tokens,
      "parse_time_ms" => result.parse_time_ms,
      "has_errors" => result.has_errors,
      "error_message" => result.error_message
    }
  end

  # ============================================================================
  # Output
  # ============================================================================

  defp write_response(response, io_device) do
    framed = Protocol.frame_newline(response)
    write_line(framed, io_device)
  end

  defp write_line(data, :stdio) do
    IO.write(data)
    :ok
  end

  defp write_line(data, device) when is_pid(device) do
    :file.write(device, data)
  end

  # ============================================================================
  # Utilities
  # ============================================================================

  defp extract_id(line) do
    case Jason.decode(line) do
      {:ok, %{"id" => id}} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp version do
    Application.spec(:code_puppy_control, :vsn)
    |> to_string()
  end

  # Map of known log levels - prevents atom exhaustion from user input
  @log_levels %{
    "debug" => :debug,
    "info" => :info,
    "warn" => :warn,
    "warning" => :warn,
    "error" => :error
  }

  defp configure_logging do
    level_str = System.get_env("PUP_LOG_LEVEL", "info")
    # Use safe mapping instead of String.to_atom to prevent atom exhaustion
    log_level = Map.get(@log_levels, String.downcase(level_str), :info)
    Logger.configure(level: log_level)

    # Ensure logs go to stderr, not stdout, to avoid interfering with JSON-RPC protocol
    Logger.configure_backend(:console,
      device: :standard_error,
      format: "$time [$level] $message\n"
    )
  end
end
