defmodule CodePuppyControl.Plugins.ErrorClassifier do
  @moduledoc """
  Exception classification and user-facing messaging plugin.

  Provides a central registry for mapping exception types to structured
  metadata (ExInfo), enabling automatic error classification into
  retryable vs permanent, with actionable guidance for users.

  ## Hooks Registered

    * `:agent_exception` - classifies and formats agent exceptions
    * `:agent_run_end` - classifies errors at end of agent runs
  """

  use CodePuppyControl.Plugins.PluginBehaviour
  alias CodePuppyControl.Callbacks
  require Logger
  @ets_registry :error_classifier_registry
  @ets_patterns :error_classifier_patterns
  @ets_seen :error_classifier_seen
  defmodule ExInfo do
    defstruct [
      :name,
      :retry,
      :description,
      :suggestion,
      :severity,
      :retry_after_seconds,
      :callback
    ]

    def format_message(%__MODULE__{} = info, _exc) do
      msg = "[#{info.name}] #{info.description}"

      msg =
        if info.suggestion,
          do: "#{msg}
Suggestion: #{info.suggestion}",
          else: msg

      msg =
        if info.retry,
          do: "#{msg}
This error may be transient - retry recommended.",
          else: msg

      msg
    end

    def to_map(%__MODULE__{} = info) do
      %{
        name: info.name,
        retry: info.retry,
        description: info.description,
        suggestion: info.suggestion,
        severity: info.severity,
        retry_after_seconds: info.retry_after_seconds
      }
    end
  end

  @impl true
  def name, do: "error_classifier"
  @impl true
  def description, do: "Exception classification and user-facing messaging"
  @impl true
  def register do
    Callbacks.register(:agent_exception, &__MODULE__.on_agent_exception/2)
    Callbacks.register(:agent_run_end, &__MODULE__.on_agent_run_end/7)
    :ok
  end

  @impl true
  def startup do
    ensure_ets_tables()
    register_builtin_exceptions()
    :ok
  end

  @impl true
  def shutdown do
    try do
      :ets.delete(@ets_registry)
    rescue
      ArgumentError -> :ok
    end

    try do
      :ets.delete(@ets_patterns)
    rescue
      ArgumentError -> :ok
    end

    try do
      :ets.delete(@ets_seen)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp ensure_ets_tables do
    for {table, opts} <- [
          {@ets_registry, [:set, :named_table, :public, read_concurrency: true]},
          {@ets_patterns, [:bag, :named_table, :public, read_concurrency: true]},
          {@ets_seen, [:set, :named_table, :public]}
        ] do
      case :ets.whereis(table) do
        :undefined -> :ets.new(table, opts)
        _ -> :ok
      end
    end
  end

  @doc """
  See module docs.
  """
  def register_exception(module, %ExInfo{} = info) do
    ensure_ets_tables()
    :ets.insert(@ets_registry, {module, info})
    :ok
  end

  @doc """
  See module docs.
  """
  def register_pattern(pattern, %ExInfo{} = info) do
    ensure_ets_tables()

    case Regex.compile(pattern, [:caseless]) do
      {:ok, regex} ->
        :ets.insert(@ets_patterns, {regex, info})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  See module docs.
  """
  def get_ex_info(exc) do
    ensure_ets_tables()
    module = exc.__struct__

    case :ets.lookup(@ets_registry, module) do
      [{^module, info}] -> info
      [] -> lookup_via_pattern(exc)
    end
  end

  defp lookup_via_pattern(exc) do
    exc_string = Exception.message(exc)

    try do
      :ets.tab2list(@ets_patterns)
      |> Enum.find_value(fn {regex, info} -> if Regex.match?(regex, exc_string), do: info end)
    rescue
      ArgumentError -> nil
    end
  end

  @doc """
  See module docs.
  """
  def classify(exc) do
    case get_ex_info(exc) do
      nil -> {false, nil}
      info -> {info.retry, info}
    end
  end

  @doc """
  See module docs.
  """
  def should_retry?(exc) do
    {retry?, _} = classify(exc)
    retry?
  end

  @doc """
  See module docs.
  """
  def get_retry_delay(exc) do
    case get_ex_info(exc) do
      %ExInfo{retry: true, retry_after_seconds: seconds} when seconds != nil -> seconds
      _ -> 0
    end
  end

  @doc """
  See module docs.
  """
  def clear do
    try do
      :ets.delete_all_objects(@ets_registry)
      :ets.delete_all_objects(@ets_patterns)
      :ets.delete_all_objects(@ets_seen)
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  def on_agent_exception(exc, _args) do
    ensure_ets_tables()

    case get_ex_info(exc) do
      nil ->
        Logger.debug("Unhandled exception: #{inspect(exc.__struct__)}")
        :ok

      info ->
        exc_id = :erlang.phash2(exc)

        case :ets.lookup(@ets_seen, exc_id) do
          [{^exc_id, _}] ->
            :ok

          [] ->
            :ets.insert(@ets_seen, {exc_id, true})
            emit_classified_error(info, exc)
            run_callback(info, exc)
            :ok
        end
    end
  end

  def on_agent_run_end(
        _agent_name,
        _model_name,
        _session_id,
        true,
        _error,
        _response_text,
        _metadata
      ),
      do: :ok

  def on_agent_run_end(
        _agent_name,
        _model_name,
        _session_id,
        false,
        nil,
        _response_text,
        _metadata
      ),
      do: :ok

  def on_agent_run_end(
        _agent_name,
        _model_name,
        _session_id,
        false,
        error,
        _response_text,
        _metadata
      ) do
    ensure_ets_tables()
    if is_binary(error), do: :ok, else: handle_run_end_error(error)
  end

  defp handle_run_end_error(error) do
    case get_ex_info(error) do
      nil ->
        :ok

      info ->
        exc_id = :erlang.phash2(error)

        case :ets.lookup(@ets_seen, exc_id) do
          [{^exc_id, _}] ->
            :ok

          [] ->
            :ets.insert(@ets_seen, {exc_id, true})
            emit_classified_error(info, error)
            run_callback(info, error)
            :ok
        end
    end
  end

  defp emit_classified_error(info, exc) do
    message = ExInfo.format_message(info, exc)

    case info.severity do
      :critical -> Logger.error("CRITICAL: #{message}")
      :error -> Logger.error("#{message}")
      :warning -> Logger.warning("#{message}")
      :info -> Logger.info("#{message}")
    end
  end

  defp run_callback(%ExInfo{callback: nil}, _exc), do: :ok

  defp run_callback(%ExInfo{callback: callback}, exc) do
    try do
      callback.(exc)
    rescue
      e -> Logger.error("Callback failed: #{Exception.message(e)}")
    end
  end

  defp register_builtin_exceptions do
    register_exception(RuntimeError, %ExInfo{
      name: "Runtime Error",
      retry: true,
      description: "A runtime error occurred.",
      suggestion: "The issue may be transient - retry with backoff.",
      severity: :warning,
      retry_after_seconds: 5
    })

    register_exception(ArgumentError, %ExInfo{
      name: "Invalid Argument",
      retry: false,
      description: "An invalid argument was provided.",
      suggestion: "Check the input values.",
      severity: :warning
    })

    register_exception(KeyError, %ExInfo{
      name: "Key Not Found",
      retry: false,
      description: "A required key was not found.",
      suggestion: "Check that the expected key exists.",
      severity: :warning
    })

    register_exception(File.Error, %ExInfo{
      name: "File Error",
      retry: false,
      description: "A file operation failed.",
      suggestion: "Check file permissions and path.",
      severity: :warning
    })

    register_pattern("rate.?limit|429|too many requests", %ExInfo{
      name: "Rate Limited",
      retry: true,
      description: "API rate limit exceeded.",
      suggestion: "Wait and retry with exponential backoff.",
      severity: :warning,
      retry_after_seconds: 60
    })

    register_pattern("5\d{2}|server error|bad gateway", %ExInfo{
      name: "Server Error",
      retry: true,
      description: "The server encountered an error.",
      suggestion: "This is typically temporary.",
      severity: :warning,
      retry_after_seconds: 30
    })

    register_pattern("timeout|timed out", %ExInfo{
      name: "Timeout",
      retry: true,
      description: "The request timed out.",
      suggestion: "Retry with increased timeout.",
      severity: :warning,
      retry_after_seconds: 10
    })

    register_pattern("unauthorized|401|auth", %ExInfo{
      name: "Unauthorized",
      retry: false,
      description: "Authentication failed.",
      suggestion: "Check your API key.",
      severity: :warning
    })

    register_pattern("forbidden|403", %ExInfo{
      name: "Access Forbidden",
      retry: false,
      description: "Permission denied.",
      suggestion: "Check your account permissions.",
      severity: :warning
    })

    :ok
  end
end
