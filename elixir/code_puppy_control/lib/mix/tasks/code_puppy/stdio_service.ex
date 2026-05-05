defmodule Mix.Tasks.CodePuppy.StdioService do
  @moduledoc """
  Run the standalone stdio JSON-RPC transport service.

  This task starts the CodePuppyControl.Transport.StdioService as a
  standalone process, reading JSON-RPC requests from stdin and writing
  responses to stdout.

  ## Usage

      mix code_puppy.stdio_service

  ## Environment Variables

  - `PUP_LOG_LEVEL` - Set log level (debug, info, warn, error). Default: info

  ## Protocol

  The service uses newline-delimited JSON-RPC 2.0:

  **Input (stdin):**
      {"jsonrpc":"2.0","id":1,"method":"file_list","params":{"directory":"."}}\n
  **Output (stdout):**
      {"jsonrpc":"2.0","id":1,"result":{"files":[{"path":"lib","type":"directory"}]}}\n
  ## Supported Methods

  ### Core File Operations
  - `file_list` - List files in a directory
      - params: `{"directory": ".", "recursive": true, "include_hidden": false, "ignore_patterns": [], "max_files": 10000}`
      - returns: `{"files": [{"path": "...", "type": "file|directory", "size": 123, "modified": "..."}]}`

  - `file_read` - Read a single file
      - params: `{"path": "/path/to/file", "start_line": 1, "num_lines": 100}`
      - returns: `{"path": "...", "content": "...", "num_lines": 10, "size": 123, "truncated": false}`

  - `file_read_batch` - Read multiple files
      - params: `{"paths": ["/path/1", "/path/2"], "start_line": 1, "num_lines": 100}`
      - returns: `{"files": [{"path": "...", "content": "...", ...}]}`

  - `grep_search` - Search for patterns in files
      - params: `{"pattern": "regex", "directory": ".", "case_sensitive": true, "max_matches": 1000}`
      - returns: `{"matches": [{"file": "...", "line_number": 1, "line_content": "..."}]}`

  ### Utility
  - `ping` - Health check ping
      - returns: `{"pong": true, "timestamp": "..."}`

  - `health_check` - Detailed health status
      - returns: `{"status": "healthy", "version": "...", "elixir_version": "..."}`

  ## Examples

  Interactive test:
      $ mix code_puppy.stdio_service
      {"jsonrpc":"2.0","id":1,"method":"ping"}
      {"jsonrpc":"2.0","id":1,"result":{"pong":true}}

  From another process:
      $ echo '{"jsonrpc":"2.0","id":1,"method":"ping"}' | mix code_puppy.stdio_service

  ## Comparison with Bridge Mode

  This standalone mode is ideal for:
  - Simple scripts that need fast file operations
  - Testing and development
  - Environments without the full Phoenix application
  - Integration with non-Python languages

  Use the bridge mode (PythonWorker.Port) for — **only under `PUP_RUNTIME=python`**:
  - Production with PubSub event distribution (legacy bridge flows)
  - Web UI integration (legacy bridge flows)
  - Complex run management with Oban jobs (legacy bridge flows)
  - Full OTP supervision (legacy bridge flows)

  ## Exit Codes

  - 0 - Normal shutdown (EOF on stdin)
  - 1 - Startup error
  - 130 - Interrupted (Ctrl+C)
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    # Silence Mix output to keep stdout clean for JSON-RPC messages
    # This must happen before any app startup that might emit to stdout
    Mix.shell(Mix.Shell.Quiet)

    # Start required applications without the full Phoenix stack.
    # Order matters: start ALL apps first, then redirect Logger to stderr.
    # Any Application.ensure_all_started call can reinitialize the console
    # backend from application config, resetting device to :user (stdout).
    Application.ensure_all_started(:logger)
    Application.ensure_all_started(:jason)
    Application.ensure_all_started(:ecto)
    Application.ensure_all_started(:ecto_sql)
    Application.ensure_all_started(:ecto_sqlite3)
    Application.ensure_all_started(:phoenix_pubsub)

    # Redirect all logging to stderr AFTER all app startups.
    # All logging must go to stderr for JSON-RPC protocol compliance —
    # stdout is reserved exclusively for newline-delimited JSON-RPC.
    #
    # Elixir's Logger uses the Erlang :logger subsystem under the hood.
    # The default handler (:logger_std_h, type: :standard_io) writes to
    # stdout regardless of Logger.configure_backend(:console, device: :stderr).
    # We must remove the default Erlang handler and replace it with one
    # that targets :standard_error instead.
    :logger.remove_handler(:default)

    :logger.add_handler(
      :code_puppy_stderr_handler,
      :logger_std_h,
      %{config: %{type: :standard_error}}
    )

    Logger.put_application_level(:code_puppy_control, :none)

    # Start the Ecto repo (SQLite) - required for session save/load
    {:ok, _} = CodePuppyControl.Repo.start_link([])

    # Run pending migrations (creates chat_sessions table, etc.)
    # Migrator uses Logger internally; now that stderr redirect is active,
    # its output won't pollute stdout.
    Ecto.Migrator.run(CodePuppyControl.Repo, :up, all: true)

    # Start PubSub for event distribution
    {:ok, _} =
      Supervisor.start_link([Phoenix.PubSub.child_spec(name: CodePuppyControl.PubSub)],
        strategy: :one_for_one
      )

    # Ensure the required modules are available
    Code.ensure_loaded(CodePuppyControl.FileOps)
    Code.ensure_loaded(CodePuppyControl.Protocol)
    Code.ensure_loaded(CodePuppyControl.RuntimeState)

    # Start RuntimeState GenServer for runtime state management
    {:ok, _} = CodePuppyControl.RuntimeState.start_link([])

    # Start model services for RPC handlers
    {:ok, _} = CodePuppyControl.ModelRegistry.start_link([])
    {:ok, _} = CodePuppyControl.ModelAvailability.start_link([])
    {:ok, _} = CodePuppyControl.ModelPacks.start_link([])

    # Flush any stale Logger messages that might still land on stdout
    # due to the brief window before we redirected the backend to stderr.
    Logger.flush()

    # Emit startup handshake banner
    # This JSON-RPC notification signals that the service is ready to accept requests.
    # Clients should drop all output before this line to avoid processing startup noise.
    handshake = %{"jsonrpc" => "2.0", "method" => "_ready", "params" => %{}}
    IO.puts(:stdio, Jason.encode!(handshake))

    # Run the stdio service (blocks until EOF)
    CodePuppyControl.Transport.StdioService.run()

    # Normal exit
    System.halt(0)
  end
end
