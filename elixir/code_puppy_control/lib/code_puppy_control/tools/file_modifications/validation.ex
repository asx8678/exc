defmodule CodePuppyControl.Tools.FileModifications.Validation do
  @moduledoc """
  Post-edit syntax validation for file modifications.

  Validates file syntax after a successful edit operation and attaches
  advisory warnings to the result. The edit is NEVER blocked by validation
  failures — this is purely advisory for the agent to self-correct.

  ## Supported formats

  Only file types with **actual** validation logic are listed as validatable:

  - `.ex` / `.exs` — Full AST validation via `Code.string_to_quoted/2`
  - `.erl` / `.hrl` — Token-level validation via `:erl_scan.string/1`
  - `.json` — Decoded via `Jason.decode/1`

  All other extensions (`.py`, `.js`, `.ts`, `.tsx`, `.rs`, `.yaml`, `.yml`,
  `.toml`) return `{:ok, :valid}` immediately — no validation is performed
  for these types. They are NOT listed in `validatable_extensions/0` to avoid
  false advertising.

  ## Design

  - Validation is opt-in via configuration
  - Fail-open: validation errors are logged but never block writes
  - Timeout-bounded: each validation runs with a time limit
  - Extension-based: only validates files with parseable extensions
  """

  require Logger

  @validation_timeout_ms 500

  # Only extensions that have ACTUAL validation logic implemented
  @validatable_extensions ~w(.ex .exs .erl .hrl .json)

  @doc """
  Attach a syntax warning to the result if validation detects issues.

  This function adds a `:syntax_warning` key to the result map if
  post-edit validation finds syntax errors. The edit operation itself
  is NOT blocked — this is purely advisory.

  ## Returns

  The result map, potentially with a `:syntax_warning` key added.
  """
  @spec maybe_attach_warning(map(), Path.t()) :: map()
  def maybe_attach_warning(result, file_path) do
    unless result[:success] == true do
      result
    else
      do_maybe_attach(result, file_path)
    end
  end

  @doc """
  Check if a file extension has actual validation support.

  Only returns `true` for extensions with real validation logic
  (Elixir, Erlang, JSON). Other code extensions (.py, .js, .ts, .tsx, .rs)
  are NOT validatable — no parser is available in this module.

  ## Examples

      iex> Validation.validatable_extension?("/tmp/file.ex")
      true

      iex> Validation.validatable_extension?("/tmp/file.json")
      true

      iex> Validation.validatable_extension?("/tmp/file.py")
      false

      iex> Validation.validatable_extension?("/tmp/file.txt")
      false
  """
  @spec validatable_extension?(Path.t()) :: boolean()
  def validatable_extension?(file_path) do
    ext = Path.extname(file_path) |> String.downcase()
    ext in @validatable_extensions
  end

  @doc """
  Check if post-edit validation is enabled.

  Reads from application config. Default: `true`.
  """
  @spec validation_enabled?() :: boolean()
  def validation_enabled? do
    Application.get_env(:code_puppy_control, :post_edit_validation, true)
  end

  @doc """
  Validate file content for syntax errors.

  Returns `{:ok, :valid}` or `{:warning, message}`.
  Always returns `{:ok, :valid}` if validation is disabled, the extension
  is not validatable, or the extension lacks actual validation logic.
  This is the fail-open guarantee.

  ## Examples

      iex> Validation.validate_file("/tmp/test.ex", "def foo, do: :bar")
      {:ok, :valid}

      iex> Validation.validate_file("/tmp/test.py", "print('hello')")
      {:ok, :valid}
  """
  @spec validate_file(Path.t(), String.t()) :: {:ok, :valid} | {:warning, String.t()}
  def validate_file(file_path, content) do
    if not validation_enabled?() or not validatable_extension?(file_path) do
      {:ok, :valid}
    else
      do_validate(file_path, content)
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp do_maybe_attach(result, file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case validate_file(file_path, content) do
          {:ok, :valid} ->
            result

          {:warning, message} ->
            Map.put(result, :syntax_warning, message)
        end

      {:error, _} ->
        # Can't read file — fail-open
        result
    end
  rescue
    e ->
      # Never let validation failures break the edit operation
      Logger.debug("post-edit validation skipped for #{file_path}: #{inspect(e)}")
      result
  end

  # Extension-specific validation
  defp do_validate(file_path, content) do
    ext = Path.extname(file_path) |> String.downcase()

    # Try to use TaskSupervisor if available, otherwise run inline
    case Process.whereis(CodePuppyControl.TaskSupervisor) do
      nil ->
        # TaskSupervisor not available — validate inline (fail-open on crash)
        try do
          validate_extension(ext, content)
        rescue
          _ -> {:ok, :valid}
        end

      _pid ->
        validate_with_timeout(ext, content)
    end
  end

  defp validate_with_timeout(ext, content) do
    task =
      Task.Supervisor.async_nolink(
        CodePuppyControl.TaskSupervisor,
        fn -> validate_extension(ext, content) end
      )

    case Task.yield(task, @validation_timeout_ms) || Task.shutdown(task, 100) do
      {:ok, {:ok, :valid}} -> {:ok, :valid}
      {:ok, {:warning, msg}} -> {:warning, msg}
      {:exit, _reason} -> {:ok, :valid}
      nil -> {:ok, :valid}
    end
  end

  # Elixir validation — full AST parse
  defp validate_extension(ext, content) when ext in ~w(.ex .exs) do
    case Code.string_to_quoted(content, file: "validation_check") do
      {:ok, _} ->
        {:ok, :valid}

      {:error, {meta, error_msg, token}} ->
        line = Keyword.get(meta, :line, 0)
        {:warning, "Syntax error on line #{line}: #{error_msg} #{token}"}
    end
  end

  # Erlang validation — token-level scan
  # :erl_scan.string/1 returns {:ok, tokens, end_location} on success
  # or {:error, {location, module, info}, end_location} on failure
  # location can be an integer (line) or a tuple {line, col}
  defp validate_extension(ext, content) when ext in ~w(.erl .hrl) do
    charlist = String.to_charlist(content)

    case :erl_scan.string(charlist) do
      {:ok, _tokens, _end_location} ->
        {:ok, :valid}

      {:error, {location, _module, info}, _end_location} ->
        line =
          case location do
            {l, _col} -> l
            l when is_integer(l) -> l
          end

        {:warning, "Erlang scan error at line #{line}: #{inspect(info)}"}
    end
  end

  # JSON validation
  defp validate_extension(".json", content) do
    case Jason.decode(content) do
      {:ok, _} -> {:ok, :valid}
      {:error, %Jason.DecodeError{} = e} -> {:warning, "Invalid JSON: #{Exception.message(e)}"}
    end
  end

  # All other extensions — fail-open (no validation available in this module).
  # This includes .py, .js, .ts, .tsx, .rs, .yaml, .yml, .toml which have
  # no built-in parser here. The elixir_bridge could be used for external
  # parsing, but that is not currently integrated.
  defp validate_extension(_ext, _content) do
    {:ok, :valid}
  end
end
