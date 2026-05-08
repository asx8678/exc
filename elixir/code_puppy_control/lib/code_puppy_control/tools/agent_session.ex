defmodule CodePuppyControl.Tools.AgentSession do
  @moduledoc """
  Session management for agent invocations.

  This module handles:
  - Session ID validation (kebab-case format)
  - Session ID sanitization (coerce arbitrary strings to valid IDs)
  - Session persistence (save/load message history)

  ## Session ID Format

  Valid session IDs must be kebab-case:
  - Lowercase letters (a-z)
  - Numbers (0-9)
  - Hyphens (-) to separate words
  - No uppercase, no underscores, no special characters
  - Length between 1 and 128 characters

  Examples:
    Valid: "my-session", "agent-session-1", "discussion-about-code"
    Invalid: "MySession", "my_session", "my session", "my--session"

  ## Session Storage

  Sessions are stored as JSON files in `.code_puppy/sessions/{session_id}.json`.
  Each session file contains message history and metadata including:
  - session_id
  - agent_name
  - initial_prompt (if available)
  - created_at
  - updated_at
  - message_count
  """

  require Logger

  @typedoc "Session ID - must be kebab-case"
  @type session_id :: String.t()

  @typedoc "Message in session history"
  @type message :: map()

  @typedoc "Session metadata"
  @type metadata :: %{
          session_id: String.t(),
          agent_name: String.t(),
          initial_prompt: String.t() | nil,
          created_at: String.t(),
          updated_at: String.t(),
          message_count: non_neg_integer()
        }

  @typedoc "Saved session data"
  @type session_data :: %{
          format: String.t(),
          payload: list(message()),
          metadata: metadata()
        }

  # Maximum length for session IDs
  @session_id_max_length 128

  # Regex pattern for valid kebab-case session IDs
  @session_id_pattern ~r/^[a-z0-9]+(-[a-z0-9]+)*$/

  # Regex patterns for sanitization
  @sanitize_non_alphanum_pattern ~r/[^a-z0-9-]+/
  @sanitize_dash_runs_pattern ~r/-+/

  @doc """
  Validates that a session ID follows kebab-case naming conventions.

  ## Parameters
  - `session_id`: The session identifier to validate

  ## Returns
  - `:ok` if valid
  - `{:error, reason}` if invalid

  ## Examples
      iex> AgentSession.validate_session_id("my-session")
      :ok

      iex> AgentSession.validate_session_id("MySession")
      {:error, "Invalid session_id 'MySession': must be kebab-case..."}

      iex> AgentSession.validate_session_id("")
      {:error, "session_id cannot be empty"}
  """
  @spec validate_session_id(session_id()) :: :ok | {:error, String.t()}
  def validate_session_id(session_id) when is_binary(session_id) do
    cond do
      session_id == "" ->
        {:error, "session_id cannot be empty"}

      String.length(session_id) > @session_id_max_length ->
        {:error,
         "Invalid session_id '#{session_id}': must be #{@session_id_max_length} characters or less"}

      not Regex.match?(@session_id_pattern, session_id) ->
        {:error,
         "Invalid session_id '#{session_id}': must be kebab-case " <>
           "(lowercase letters, numbers, and hyphens only). " <>
           "Examples: 'my-session', 'agent-session-1', 'discussion-about-code'"}

      true ->
        :ok
    end
  end

  def validate_session_id(_), do: {:error, "session_id must be a string"}

  @doc """
  Coerces an arbitrary string into a valid kebab-case session_id.

  Transformations applied:
  1. Lowercases the string
  2. Replaces any character not in [a-z0-9-] with '-'
  3. Collapses runs of '-' into a single '-'
  4. Strips leading/trailing '-'
  5. Truncates to SESSION_ID_MAX_LENGTH
  6. Falls back to 'session' if the result would be empty

  This is the defensive counterpart to `validate_session_id/1`: callers at
  public boundaries should sanitize untrusted input before passing it to
  internal helpers that still validate strictly.

  ## Examples
      iex> AgentSession.sanitize_session_id("code_puppy-rjl1.14-worktree")
      "code-puppy-rjl1-14-worktree"

      iex> AgentSession.sanitize_session_id("MySession")
      "mysession"

      iex> AgentSession.sanitize_session_id("!!!")
      "session"

      iex> AgentSession.sanitize_session_id("")
      "session"
  """
  @spec sanitize_session_id(String.t() | any()) :: session_id()
  def sanitize_session_id(raw) when is_binary(raw) do
    # Lowercase
    s = String.downcase(raw)

    # Replace non-alphanumeric chars with '-'
    s = Regex.replace(@sanitize_non_alphanum_pattern, s, "-")

    # Collapse runs of '-'
    s = Regex.replace(@sanitize_dash_runs_pattern, s, "-")

    # Strip leading/trailing '-'
    s = String.trim(s, "-")

    # Truncate
    s =
      if String.length(s) > @session_id_max_length do
        s
        |> String.slice(0, @session_id_max_length)
        |> String.trim_trailing("-")
      else
        s
      end

    # Empty fallback
    if s == "" do
      "session"
    else
      s
    end
  end

  def sanitize_session_id(raw), do: sanitize_session_id(to_string(raw))

  @doc """
  Gets the directory path for storing session data.

  Uses `.code_puppy/sessions/` directory, creating it if necessary.

  ## Returns
  - `{:ok, Path.t()}` - path to sessions directory
  - `{:error, reason}` - if directory creation fails
  """
  @spec get_sessions_dir() :: {:ok, Path.t()} | {:error, String.t()}
  def get_sessions_dir do
    data_dir =
      case System.get_env("XDG_DATA_HOME") do
        nil -> Path.expand("~/.local/share/code_puppy")
        xdg_base -> Path.join(xdg_base, "code_puppy")
      end

    sessions_dir = Path.join(data_dir, "subagent_sessions")

    case File.mkdir_p(sessions_dir) do
      :ok -> {:ok, sessions_dir}
      {:error, reason} -> {:error, "Failed to create sessions directory: #{inspect(reason)}"}
    end
  end

  @doc """
  Saves session history to filesystem.

  ## Parameters
  - `session_id`: The session identifier (must be kebab-case)
  - `messages`: List of messages to save
  - `agent_name`: Name of the agent being invoked
  - `initial_prompt`: The first prompt that started this session (optional)

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec save_session_history(
          session_id(),
          list(message()),
          String.t(),
          String.t() | nil
        ) :: :ok | {:error, String.t()}
  def save_session_history(session_id, messages, agent_name, initial_prompt \\ nil) do
    with :ok <- validate_session_id(session_id),
         {:ok, sessions_dir} <- get_sessions_dir() do
      session_path = Path.join(sessions_dir, "#{session_id}.json")

      now = DateTime.utc_now() |> DateTime.to_iso8601()

      # Load existing metadata if updating (single read for both values)
      {saved_initial_prompt, created_at} =
        if is_nil(initial_prompt) or File.exists?(session_path) do
          case load_session_file(session_path) do
            {:ok, %{"metadata" => meta}} ->
              existing_initial =
                if is_nil(initial_prompt), do: meta["initial_prompt"], else: initial_prompt

              existing_created = meta["created_at"] || now
              {existing_initial, existing_created}

            _ ->
              {initial_prompt, now}
          end
        else
          {initial_prompt, now}
        end

      payload = %{
        "format" => "code-puppy-json-v1",
        "payload" => messages,
        "metadata" => %{
          "session_id" => session_id,
          "agent_name" => agent_name,
          "initial_prompt" => saved_initial_prompt,
          "created_at" => created_at,
          "message_count" => length(messages),
          "updated_at" => now
        }
      }

      write_session_file(session_path, payload)
    end
  end

  @doc """
  Loads session history from filesystem.

  ## Parameters
  - `session_id`: The session identifier (must be kebab-case)

  ## Returns
  - `{:ok, %{messages: list(), metadata: map()}}` on success
  - `{:ok, %{messages: [], metadata: nil}}` if session doesn't exist
  - `{:error, reason}` on validation or read failure
  """
  @spec load_session_history(session_id()) ::
          {:ok, %{messages: list(message()), metadata: map() | nil}} | {:error, String.t()}
  def load_session_history(session_id) do
    with :ok <- validate_session_id(session_id),
         {:ok, sessions_dir} <- get_sessions_dir() do
      session_path = Path.join(sessions_dir, "#{session_id}.json")

      if File.exists?(session_path) do
        case load_session_file(session_path) do
          {:ok, data} ->
            messages = Map.get(data, "payload", [])
            metadata = Map.get(data, "metadata")
            {:ok, %{messages: messages, metadata: metadata}}

          {:error, reason} ->
            {:error, "Failed to load session '#{session_id}': #{reason}"}
        end
      else
        {:ok, %{messages: [], metadata: nil}}
      end
    end
  end

  @doc """
  Lists all available session IDs.

  ## Returns
  - `{:ok, list(String.t())}` - list of session IDs (without .json extension)
  """
  @spec list_sessions() :: {:ok, list(session_id())} | {:error, String.t()}
  def list_sessions do
    with {:ok, sessions_dir} <- get_sessions_dir() do
      sessions =
        case File.ls(sessions_dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.ends_with?(&1, ".json"))
            |> Enum.map(&String.replace_suffix(&1, ".json", ""))

          {:error, _reason} ->
            []
        end

      {:ok, sessions}
    end
  end

  @doc """
  Deletes a session file.

  ## Parameters
  - `session_id`: The session identifier to delete

  ## Returns
  - `:ok` on success or if session doesn't exist
  - `{:error, reason}` on failure
  """
  @spec delete_session(session_id()) :: :ok | {:error, String.t()}
  def delete_session(session_id) do
    with :ok <- validate_session_id(session_id),
         {:ok, sessions_dir} <- get_sessions_dir() do
      session_path = Path.join(sessions_dir, "#{session_id}.json")

      case File.rm(session_path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, "Failed to delete session: #{inspect(reason)}"}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # Private Functions
  # ----------------------------------------------------------------------------

  defp write_session_file(path, data) do
    json = Jason.encode!(data, pretty: true)

    # Atomic write: write to temp file then rename
    tmp_path = path <> ".tmp"

    result =
      case File.write(tmp_path, json) do
        :ok ->
          case File.rename(tmp_path, path) do
            :ok -> :ok
            {:error, reason} -> {:error, "Failed to finalize session save: #{inspect(reason)}"}
          end

        {:error, reason} ->
          {:error, "Failed to write session file: #{inspect(reason)}"}
      end

    # Clean up temp file if it still exists
    _ = File.rm(tmp_path)

    result
  end

  defp load_session_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, "JSON decode error: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "File read error: #{inspect(reason)}"}
    end
  end
end
