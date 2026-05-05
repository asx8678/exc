defmodule CodePuppyControl.PythonWorker.Port do
  @moduledoc """
  GenServer that owns a Python Port for JSON-RPC communication.

  > **Bridge-mode only.** This module is only activated under explicit
  > `PUP_RUNTIME=python` / `--bridge-mode` / legacy PyPI compatibility
  > workflows. The default native Burrito runtime (`PUP_RUNTIME=auto`
  > or `:elixir`) never starts PythonWorker processes.

  This process:
  1. Spawns a Python worker via Port
  2. Sends JSON-RPC commands using Content-Length framing
  3. Receives notifications and responses
  4. Monitors the Python process for exit
  5. Handles restart via DynamicSupervisor

  When `python3` is not available on the system, `init/1` returns
  `{:stop, {:python_unavailable, _}}` gracefully rather than crashing
  the owning supervisor.

  ## Framing

  Messages are framed using Content-Length HTTP-style headers:

      Content-Length: 47\r\n

      \r\n

      {"jsonrpc":"2.0","id":1,"method":"initialize"}

  ## Batch Support

  Supports JSON-RPC 2.0 batch format for multiple messages in a single frame:

      Content-Length: <bytes>\r\n

      \r\n

      [{"jsonrpc":"2.0","id":1,"method":"file_read","params":{}},
       {"jsonrpc":"2.0","id":2,"method":"file_list","params":{}}]
  """

  use GenServer

  require Logger

  alias CodePuppyControl.FileOps
  alias CodePuppyControl.Protocol

  defstruct [:port, :run_id, :buffer, :request_counter, :parent_pid, ready: false]

  @type t :: %__MODULE__{
          port: port() | nil,
          run_id: String.t(),
          buffer: String.t(),
          request_counter: non_neg_integer(),
          parent_pid: pid(),
          ready: boolean()
        }

  # Client API

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(run_id))
  end

  def via_tuple(run_id) do
    {:via, Registry, {CodePuppyControl.Run.Registry, {:python_worker, run_id}}}
  end

  @spec call(String.t(), String.t(), map(), timeout()) :: {:ok, term()} | {:error, term()}
  def call(run_id, method, params, timeout \\ 30_000) do
    GenServer.call(via_tuple(run_id), {:call, method, params, timeout}, timeout + 5000)
  end

  @doc """
  Sends multiple JSON-RPC requests as a batch.
  Batching reduces IPC overhead by combining N requests into a single write.
  """
  @spec call_batch(String.t(), list({String.t(), map()}), timeout()) ::
          list({:ok, term()} | {:error, term()})
  def call_batch(run_id, calls, timeout \\ 30_000) do
    GenServer.call(via_tuple(run_id), {:call_batch, calls, timeout}, timeout + 5000)
  end

  @spec notify(String.t(), String.t(), map()) :: :ok
  def notify(run_id, method, params) do
    GenServer.cast(via_tuple(run_id), {:notify, method, params})
  end

  @spec start_run(String.t(), map()) :: :ok
  def start_run(run_id, params) do
    notify(run_id, "run/start", params)
  end

  @spec cancel_run(String.t()) :: :ok
  def cancel_run(run_id) do
    notify(run_id, "run/cancel", %{"run_id" => run_id})
  end

  @spec broadcast_event(String.t(), String.t(), map()) :: :ok
  def broadcast_event(run_id, event_type, data) do
    Phoenix.PubSub.broadcast(
      CodePuppyControl.PubSub,
      "run:#{run_id}",
      {:run_event,
       %{
         "type" => event_type,
         "run_id" => run_id,
         "data" => data,
         "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    )
  end

  @spec pid_to_run_id(pid()) :: {:ok, String.t()} | :error
  def pid_to_run_id(pid) do
    case Registry.keys(CodePuppyControl.Run.Registry, pid) do
      [{:python_worker, run_id} | _] -> {:ok, run_id}
      _ -> :error
    end
  end

  @spec shutdown(String.t()) :: :ok
  def shutdown(run_id) do
    GenServer.cast(via_tuple(run_id), :shutdown)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    parent_pid = Keyword.get(opts, :parent, self())

    # Resolve script path — return clean error tuple if not configured
    case resolve_script_path(opts) do
      {:error, reason} ->
        {:stop, reason}

      {:ok, script_path} ->
        # Resolve python3 executable — return clean error if not on PATH
        case resolve_python_exe() do
          {:error, reason} ->
            {:stop, reason}

          {:ok, python_exe} ->
            Process.monitor(parent_pid)

            Logger.info("Starting Python worker for run #{run_id}")

            port_opts = [
              :binary,
              :use_stdio,
              :exit_status,
              args: [script_path, "--run-id", run_id]
            ]

            try do
              port = Port.open({:spawn_executable, python_exe}, port_opts)

              state = %__MODULE__{
                port: port,
                run_id: run_id,
                buffer: "",
                request_counter: 0,
                parent_pid: parent_pid
              }

              send(self(), :send_initialize)

              {:ok, state}
            rescue
              e ->
                {:stop, {:python_worker_spawn_failed, Exception.message(e)}}
            end
        end
    end
  end

  @impl true
  def handle_call({:call, method, params, timeout}, from, state) do
    request_id = generate_request_id(state)

    :ok = CodePuppyControl.RequestTracker.register_request(request_id, method, timeout)

    message = Protocol.encode_request(method, params, request_id)
    framed = Protocol.frame(message)
    Port.command(state.port, framed)

    Task.start(fn ->
      case CodePuppyControl.RequestTracker.await_response(request_id, timeout) do
        {:ok, result} ->
          GenServer.reply(from, {:ok, result})

        {:error, reason} ->
          GenServer.reply(from, {:error, reason})
      end
    end)

    new_state = %{state | request_counter: state.request_counter + 1}
    {:noreply, new_state}
  end

  @impl true
  def handle_call({:call_batch, calls, timeout}, from, state) do
    # Batch request support
    {messages, request_ids} =
      Enum.map_reduce(calls, [], fn {method, params}, acc ->
        request_id = generate_request_id(state)
        :ok = CodePuppyControl.RequestTracker.register_request(request_id, method, timeout)
        message = Protocol.encode_request(method, params, request_id)
        {message, [{request_id, method} | acc]}
      end)

    # Send all requests in a single batch frame
    framed = Protocol.frame_batch(messages)
    Port.command(state.port, framed)

    Task.start(fn ->
      results =
        Enum.map(Enum.reverse(request_ids), fn {request_id, _method} ->
          case CodePuppyControl.RequestTracker.await_response(request_id, timeout) do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, reason}
          end
        end)

      GenServer.reply(from, results)
    end)

    new_state = %{state | request_counter: state.request_counter + length(calls)}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:notify, method, params}, state) do
    message = Protocol.encode_notification(method, params)
    framed = Protocol.frame(message)

    Port.command(state.port, framed)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:shutdown, state) do
    Logger.info("Shutting down Python worker for run #{state.run_id}")

    message = Protocol.encode_notification("exit", %{"code" => 0})
    framed = Protocol.frame(message)
    Port.command(state.port, framed)

    Port.close(state.port)

    {:stop, :normal, %{state | port: nil}}
  end

  @impl true
  def handle_info(:send_initialize, state) do
    message =
      Protocol.encode_notification("initialize", %{
        "run_id" => state.run_id,
        "elixir_pid" => :erlang.pid_to_list(self())
      })

    framed = Protocol.frame(message)
    Port.command(state.port, framed)

    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    new_buffer = state.buffer <> data
    {messages, rest} = Protocol.parse_framed(new_buffer)

    # Process each message
    for message <- messages do
      # Handle batch messages (list) or single message (map)
      handle_incoming_messages(message, state.run_id, state.port)
    end

    {:noreply, %{state | buffer: rest}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    if status != 0 do
      Logger.error("Python worker exited with status #{status} for run #{state.run_id}")
    else
      Logger.info("Python worker exited normally for run #{state.run_id}")
    end

    {:stop, {:port_exit, status}, %{state | port: nil}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{parent_pid: pid} = state) do
    Logger.info("Parent process #{inspect(pid)} exited (#{inspect(reason)}), stopping worker")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      Port.close(state.port)
    end

    :ok
  end

  # Private functions

  # Handle batch messages (list) or single message (map)
  defp handle_incoming_messages(messages, run_id, port) when is_list(messages) do
    for message <- messages do
      handle_incoming_message(message, run_id, port)
    end
  end

  defp handle_incoming_messages(message, run_id, port) when is_map(message) do
    handle_incoming_message(message, run_id, port)
  end

  defp handle_incoming_message(
         %{"id" => id, "method" => method, "params" => params},
         _run_id,
         port
       ) do
    response = handle_file_request(method, params)
    response_with_id = Map.put(response, "id", id)

    framed = Protocol.frame(response_with_id)
    Port.command(port, framed)
  end

  defp handle_incoming_message(%{"id" => id, "result" => result}, _run_id, _port) do
    CodePuppyControl.RequestTracker.complete_request(id, result)
  end

  defp handle_incoming_message(%{"id" => id, "error" => error}, _run_id, _port) do
    CodePuppyControl.RequestTracker.fail_request(id, {:python_error, error})
  end

  defp handle_incoming_message(message, run_id, _port) do
    handle_message(message, run_id)
  end

  # File operation request handlers (called by Python)

  defp handle_file_request("file_list", params) do
    directory = params["directory"] || "."
    opts = params_to_file_ops_opts(params)

    case FileOps.list_files(directory, opts) do
      {:ok, files} ->
        serializable_files =
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

        Protocol.encode_response(%{"files" => serializable_files}, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "File list failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("grep_search", params) do
    pattern = params["search_string"] || params["pattern"]
    directory = params["directory"] || "."
    opts = params_to_grep_opts(params)

    case FileOps.grep(pattern, directory, opts) do
      {:ok, matches} ->
        Protocol.encode_response(%{"matches" => matches}, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Grep search failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("file_read", params) do
    path = params["path"]
    opts = params_to_read_opts(params)

    case FileOps.read_file(path, opts) do
      {:ok, result} ->
        serializable_result =
          result
          |> Map.update(:error, nil, fn err -> err end)
          |> Map.update(:truncated, false, fn t -> t end)

        Protocol.encode_response(serializable_result, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "File read failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("file_read_batch", params) do
    paths = params["paths"] || []
    opts = params_to_read_opts(params)

    # FileOps.read_files/2 always returns {:ok, results} - errors are in the results
    {:ok, results} = FileOps.read_files(paths, opts)

    serializable_results =
      Enum.map(results, fn result ->
        result
        |> Map.update(:error, nil, fn err -> err end)
        |> Map.update(:truncated, false, fn t -> t end)
      end)

    Protocol.encode_response(%{"files" => serializable_results}, nil)
  end

  # Parse operation handlers using CodePuppyControl.Parsing.Parser
  # Updated from deprecated TurboParseNIF to use Parsing.Parser

  defp handle_file_request("parse_source", params) do
    source = params["source"]
    language = params["language"]

    case CodePuppyControl.Parser.parse_source(source, language) do
      {:ok, result} ->
        Protocol.encode_response(result, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Parse failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("parse_file", params) do
    path = params["path"]
    language = params["language"]

    case CodePuppyControl.Parser.parse_file(path, language) do
      {:ok, result} ->
        Protocol.encode_response(result, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Parse file failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("extract_symbols", params) do
    source = params["source"]
    language = params["language"]

    case CodePuppyControl.Parser.extract_symbols(source, language) do
      {:ok, outline} ->
        Protocol.encode_response(%{"symbols" => outline["symbols"] || []}, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Extract symbols failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("supported_languages", _params) do
    languages = CodePuppyControl.Parser.supported_languages()
    Protocol.encode_response(%{"languages" => languages}, nil)
  end

  # Added handlers for missing parse contract methods
  defp handle_file_request("is_language_supported", params) do
    language = params["language"]

    # Now using Parser.is_language_supported which routes to pure Elixir parsers
    supported = CodePuppyControl.Parser.is_language_supported(language)

    Protocol.encode_response(%{"supported" => supported}, nil)
  end

  defp handle_file_request("extract_syntax_diagnostics", params) do
    source = params["source"]
    language = params["language"]

    case CodePuppyControl.Parser.extract_syntax_diagnostics(source, language) do
      {:ok, result} ->
        Protocol.encode_response(result, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Extract diagnostics failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("get_folds", params) do
    source = params["source"]
    language = params["language"]

    case CodePuppyControl.Parser.get_folds(source, language) do
      {:ok, result} ->
        Protocol.encode_response(result, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Get folds failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("get_highlights", params) do
    source = params["source"]
    language = params["language"]

    case CodePuppyControl.Parser.get_highlights(source, language) do
      {:ok, result} ->
        Protocol.encode_response(result, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Get highlights failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("parse_batch", params) do
    paths = params["paths"] || []
    language = params["language"]

    results =
      paths
      |> Task.async_stream(
        fn path ->
          case CodePuppyControl.Parser.parse_file(path, language) do
            {:ok, result} -> %{"path" => path, "result" => result, "error" => nil}
            {:error, reason} -> %{"path" => path, "result" => nil, "error" => inspect(reason)}
          end
        end,
        max_concurrency: 4,
        timeout: 30_000
      )
      |> Enum.to_list()
      |> Enum.map(fn {:ok, result} -> result end)

    Protocol.encode_response(%{"results" => results, "count" => length(results)}, nil)
  end

  defp handle_file_request("index_directory", params) do
    root = Map.get(params, "root", ".")
    max_files = Map.get(params, "max_files", 40)
    max_symbols_per_file = Map.get(params, "max_symbols_per_file", 8)

    case CodePuppyControl.Indexer.index(root,
           max_files: max_files,
           max_symbols_per_file: max_symbols_per_file
         ) do
      {:ok, summaries} ->
        result = CodePuppyControl.Indexer.FileSummary.to_maps(summaries)
        Protocol.encode_response(%{"files" => result, "count" => length(result)}, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Index failed: #{inspect(reason)}", nil, nil)
    end
  end

  # Repo Compass compact indexing
  defp handle_file_request("repo_compass_index", params) do
    root = Map.get(params, "root", ".")
    max_files = Map.get(params, "max_files", 40)
    max_symbols_per_file = Map.get(params, "max_symbols_per_file", 8)

    case CodePuppyControl.Indexer.repo_compass_index(root,
           max_files: max_files,
           max_symbols_per_file: max_symbols_per_file
         ) do
      {:ok, summaries} ->
        result = CodePuppyControl.Indexer.FileSummary.to_maps(summaries)
        Protocol.encode_response(%{"files" => result, "count" => length(result)}, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Repo Compass index failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("history_get", params) do
    session_id = params["session_id"]
    opts = []
    opts = if params["limit"], do: Keyword.put(opts, :limit, params["limit"]), else: opts
    opts = if params["since"], do: Keyword.put(opts, :since, params["since"]), else: opts

    events = CodePuppyControl.EventStore.get_events(session_id, opts)
    Protocol.encode_response(%{"events" => events, "count" => length(events)}, nil)
  end

  defp handle_file_request("history_clear", params) do
    session_id = params["session_id"]
    CodePuppyControl.EventStore.clear(session_id)
    Protocol.encode_response(%{"cleared" => true}, nil)
  end

  defp handle_file_request("history_count", params) do
    session_id = params["session_id"]
    count = CodePuppyControl.EventStore.count(session_id)
    Protocol.encode_response(%{"count" => count}, nil)
  end

  defp handle_file_request("history_stats", _params) do
    stats = CodePuppyControl.EventStore.stats()
    Protocol.encode_response(stats, nil)
  end

  # Session storage handlers (Ecto/SQLite backed)

  defp handle_file_request("session_save", params) do
    name = params["name"]
    history = params["history"] || []

    opts = [
      compacted_hashes: params["compacted_hashes"] || [],
      total_tokens: params["total_tokens"] || 0,
      auto_saved: params["auto_saved"] || false,
      timestamp: params["timestamp"]
    ]

    case CodePuppyControl.Sessions.save_session(name, history, opts) do
      {:ok, session} ->
        Protocol.encode_response(
          %{
            "success" => true,
            "name" => session.name,
            "message_count" => session.message_count,
            "total_tokens" => session.total_tokens
          },
          nil
        )

      {:error, changeset} ->
        errors = traverse_changeset_errors(changeset)
        Protocol.encode_error(-32000, "Session save failed: #{inspect(errors)}", nil, nil)
    end
  end

  defp handle_file_request("session_load", params) do
    name = params["name"]

    case CodePuppyControl.Sessions.load_session(name) do
      {:ok, %{history: history, compacted_hashes: hashes}} ->
        Protocol.encode_response(
          %{
            "history" => history,
            "compacted_hashes" => hashes
          },
          nil
        )

      {:error, :not_found} ->
        Protocol.encode_error(-32000, "Session not found: #{name}", nil, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Session load failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("session_load_full", params) do
    name = params["name"]

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
            "created_at" => session.inserted_at && DateTime.to_iso8601(session.inserted_at),
            "updated_at" => session.updated_at && DateTime.to_iso8601(session.updated_at)
          },
          nil
        )

      {:error, :not_found} ->
        Protocol.encode_error(-32000, "Session not found: #{name}", nil, nil)

      {:error, reason} ->
        Protocol.encode_error(-32000, "Session load failed: #{inspect(reason)}", nil, nil)
    end
  end

  defp handle_file_request("session_list", _params) do
    {:ok, names} = CodePuppyControl.Sessions.list_sessions()
    Protocol.encode_response(%{"sessions" => names}, nil)
  end

  defp handle_file_request("session_list_with_metadata", _params) do
    {:ok, sessions} = CodePuppyControl.Sessions.list_sessions_with_metadata()
    Protocol.encode_response(%{"sessions" => sessions}, nil)
  end

  defp handle_file_request("session_delete", params) do
    name = params["name"]
    :ok = CodePuppyControl.Sessions.delete_session(name)
    Protocol.encode_response(%{"deleted" => true, "name" => name}, nil)
  end

  defp handle_file_request("session_cleanup", params) do
    max_sessions = params["max_sessions"] || 10
    {:ok, deleted} = CodePuppyControl.Sessions.cleanup_sessions(max_sessions)
    Protocol.encode_response(%{"deleted" => deleted, "count" => length(deleted)}, nil)
  end

  defp handle_file_request("session_exists", params) do
    name = params["name"]
    exists = CodePuppyControl.Sessions.session_exists?(name)
    Protocol.encode_response(%{"exists" => exists}, nil)
  end

  defp handle_file_request("session_count", _params) do
    count = CodePuppyControl.Sessions.count_sessions()
    Protocol.encode_response(%{"count" => count}, nil)
  end

  defp handle_file_request(method, _params) do
    Protocol.encode_error(-32601, "Method not found: #{method}", nil, nil)
  end

  defp traverse_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp params_to_file_ops_opts(params) do
    [
      recursive: Map.get(params, "recursive", true),
      include_hidden: Map.get(params, "include_hidden", false),
      ignore_patterns: Map.get(params, "ignore_patterns", []),
      max_files: Map.get(params, "max_files", 10_000)
    ]
  end

  defp params_to_grep_opts(params) do
    [
      case_sensitive: Map.get(params, "case_sensitive", true),
      max_matches: Map.get(params, "max_matches", 1_000),
      file_pattern: Map.get(params, "file_pattern", "*"),
      context_lines: Map.get(params, "context_lines", 0)
    ]
  end

  defp params_to_read_opts(params) do
    opts = []

    opts =
      if params["start_line"],
        do: Keyword.put(opts, :start_line, params["start_line"]),
        else: opts

    opts =
      if params["num_lines"], do: Keyword.put(opts, :num_lines, params["num_lines"]), else: opts

    opts
  end

  defp handle_message(%{"id" => id, "result" => result}, _run_id) do
    CodePuppyControl.RequestTracker.complete_request(id, result)
  end

  defp handle_message(%{"id" => id, "error" => error}, _run_id) do
    CodePuppyControl.RequestTracker.fail_request(id, {:python_error, error})
  end

  defp handle_message(%{"method" => "event", "params" => params}, run_id) do
    event_type = params["event_type"]
    session_id = params["session_id"]
    payload = params["payload"] || %{}

    case event_type do
      "agent_response" ->
        handle_agent_response_event(run_id, session_id, payload)

      "tool_call" ->
        handle_tool_call_event(run_id, session_id, payload)

      "tool_result" ->
        handle_tool_result_event(run_id, session_id, payload)

      "run_started" ->
        handle_run_started_event(run_id, session_id, payload)

      "run_completed" ->
        handle_run_completed_event(run_id, session_id, payload)

      "run_failed" ->
        handle_run_failed_event(run_id, session_id, payload)

      "status_update" ->
        handle_status_event(run_id, session_id, payload)

      "bridge_ready" ->
        Logger.info("Python bridge ready for run #{run_id}")
        {:ok, %{ready: true}}

      "bridge_closing" ->
        Logger.info("Python bridge closing for run #{run_id}")
        {:ok, %{}}

      unknown ->
        Logger.debug("Unknown event type from Python: #{unknown}")
        {:ok, %{}}
    end
  end

  defp handle_message(%{"method" => "run.event", "params" => params}, run_id) do
    event = %{
      "type" => params["type"] || "unknown",
      "run_id" => run_id,
      "session_id" => params["session_id"],
      "data" => params,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.EventStore.store(event)
    CodePuppyControl.EventBus.broadcast_event(event, store: false)

    broadcast_event(run_id, event["type"], params)
    {:ok, params}
  end

  defp handle_message(%{"method" => "run.status", "params" => params}, run_id) do
    event = %{
      "type" => "status",
      "run_id" => run_id,
      "session_id" => params["session_id"],
      "status" => params["status"],
      "data" => params,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.Run.State.set_status(
      run_id,
      CodePuppyControl.Run.State.safe_status_atom(params["status"])
    )

    CodePuppyControl.EventStore.store(event)
    CodePuppyControl.EventBus.broadcast_event(event, store: false)

    broadcast_event(run_id, "status", params)
    {:ok, params}
  end

  defp handle_message(%{"method" => "run.completed", "params" => params}, run_id) do
    event = %{
      "type" => "completed",
      "run_id" => run_id,
      "session_id" => params["session_id"],
      "result" => params["result"],
      "data" => params,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.Run.State.complete(run_id, params)

    CodePuppyControl.EventStore.store(event)
    CodePuppyControl.EventBus.broadcast_event(event, store: false)

    broadcast_event(run_id, "completed", params)
    {:ok, params}
  end

  defp handle_message(%{"method" => "run.failed", "params" => params}, run_id) do
    event = %{
      "type" => "failed",
      "run_id" => run_id,
      "session_id" => params["session_id"],
      "error" => params["error"],
      "data" => params,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.Run.State.set_status(run_id, :failed, params["error"])

    CodePuppyControl.EventStore.store(event)
    CodePuppyControl.EventBus.broadcast_event(event, store: false)

    broadcast_event(run_id, "failed", params)
    {:ok, params}
  end

  defp handle_message(%{"method" => "run.text", "params" => params}, run_id) do
    event = %{
      "type" => "text",
      "run_id" => run_id,
      "session_id" => params["session_id"],
      "content" => params["content"],
      "chunk" => params["chunk"] || false,
      "data" => params,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.EventStore.store(event)
    CodePuppyControl.EventBus.broadcast_event(event, store: false)

    broadcast_event(run_id, "text", params)
    {:ok, params}
  end

  defp handle_message(%{"method" => "run.tool_result", "params" => params}, run_id) do
    event = %{
      "type" => "tool_result",
      "run_id" => run_id,
      "session_id" => params["session_id"],
      "tool_name" => params["tool_name"],
      "result" => params["result"],
      "tool_call_id" => params["tool_call_id"],
      "data" => params,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.EventStore.store(event)
    CodePuppyControl.EventBus.broadcast_event(event, store: false)

    broadcast_event(run_id, "tool_result", params)
    {:ok, params}
  end

  defp handle_message(%{"method" => "run.prompt", "params" => params}, run_id) do
    event = %{
      "type" => "prompt",
      "run_id" => run_id,
      "session_id" => params["session_id"],
      "prompt_id" => params["prompt_id"],
      "data" => params,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.EventStore.store(event)
    CodePuppyControl.EventBus.broadcast_event(event, store: false)

    broadcast_event(run_id, "prompt", params)
    {:ok, params}
  end

  defp handle_message(message, run_id) when is_map(message) do
    event = %{
      "type" => "notification",
      "run_id" => run_id,
      "session_id" => message["session_id"],
      "data" => message,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.EventStore.store(event)
    CodePuppyControl.EventBus.broadcast_event(event, store: false)

    Phoenix.PubSub.broadcast(
      CodePuppyControl.PubSub,
      "run:#{run_id}",
      {:python_notification, run_id, message}
    )
  end

  defp generate_request_id(state) do
    "#{state.run_id}-#{state.request_counter}-#{System.unique_integer([:positive])}"
  end

  defp handle_agent_response_event(run_id, session_id, payload) do
    text = payload["text"] || ""
    finished = payload["finished"] || false

    event = %{
      "type" => "text",
      "run_id" => run_id,
      "session_id" => session_id,
      "content" => text,
      "finished" => finished,
      "data" => payload,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    broadcast_event(run_id, "text", event)
    {:ok, event}
  end

  defp handle_tool_call_event(run_id, session_id, payload) do
    event = %{
      "type" => "tool_call",
      "run_id" => run_id,
      "session_id" => session_id,
      "tool_name" => payload["tool_name"],
      "tool_args" => payload["tool_args"],
      "tool_call_id" => payload["tool_call_id"],
      "data" => payload,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    broadcast_event(run_id, "tool_call", event)
    {:ok, event}
  end

  defp handle_tool_result_event(run_id, session_id, payload) do
    event = %{
      "type" => "tool_result",
      "run_id" => run_id,
      "session_id" => session_id,
      "tool_name" => payload["tool_name"],
      "result" => payload["result"],
      "tool_call_id" => payload["tool_call_id"],
      "data" => payload,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    broadcast_event(run_id, "tool_result", event)
    {:ok, event}
  end

  defp handle_run_started_event(run_id, session_id, payload) do
    event = %{
      "type" => "started",
      "run_id" => run_id,
      "session_id" => session_id,
      "agent_name" => payload["agent_name"],
      "data" => payload,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.Run.State.set_status(run_id, :running)
    broadcast_event(run_id, "started", event)
    {:ok, event}
  end

  defp handle_run_completed_event(run_id, session_id, payload) do
    event = %{
      "type" => "completed",
      "run_id" => run_id,
      "session_id" => session_id,
      "result" => payload["result"],
      "data" => payload,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.Run.State.complete(run_id, payload)
    broadcast_event(run_id, "completed", event)
    {:ok, event}
  end

  defp handle_run_failed_event(run_id, session_id, payload) do
    event = %{
      "type" => "failed",
      "run_id" => run_id,
      "session_id" => session_id,
      "error" => payload["error"],
      "data" => payload,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    CodePuppyControl.Run.State.set_status(run_id, :failed, payload["error"])
    broadcast_event(run_id, "failed", event)
    {:ok, event}
  end

  defp handle_status_event(run_id, session_id, payload) do
    event = %{
      "type" => "status",
      "run_id" => run_id,
      "session_id" => session_id,
      "status" => payload["status"],
      "data" => payload,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    status_atom = CodePuppyControl.Run.State.safe_status_atom(payload["status"])
    CodePuppyControl.Run.State.set_status(run_id, status_atom)
    broadcast_event(run_id, "status", event)
    {:ok, event}
  end

  # Resolve the Python worker script path from opts, app env, or env vars.
  # Returns {:ok, path} or {:error, {:python_worker_script_not_configured, msg}}.
  defp resolve_script_path(opts) do
    path =
      Keyword.get(opts, :script_path) ||
        Application.get_env(:code_puppy_control, :python_worker_script) ||
        System.get_env("PUP_PYTHON_WORKER_SCRIPT") ||
        System.get_env("PYTHON_WORKER_SCRIPT")

    case path do
      nil ->
        {:error,
         {:python_worker_script_not_configured,
          "Python worker script path not configured. " <>
            "Set PUP_PYTHON_WORKER_SCRIPT or configure :python_worker_script in app env."}}

      "" ->
        {:error,
         {:python_worker_script_not_configured,
          "Python worker script path is empty. " <>
            "Set PUP_PYTHON_WORKER_SCRIPT or configure :python_worker_script in app env."}}

      path when is_binary(path) ->
        {:ok, path}
    end
  end

  # Resolve the python3 executable on PATH.
  # Returns {:ok, abs_path} or {:error, {:python_unavailable, msg}}.
  defp resolve_python_exe do
    case System.find_executable("python3") do
      nil ->
        {:error,
         {:python_unavailable,
          "python3 not found on PATH. " <>
            "Install Python 3 or set PUP_RUNTIME to a non-python mode."}}

      exe when is_binary(exe) ->
        {:ok, exe}
    end
  end
end
