defmodule CodePuppyControl.ModelFactory.Credentials do
  @moduledoc """
  API key and credential resolution for model providers.

  Validation priority (first matching rule wins):

    1. Model config `api_key_env` field -> require that env var
    2. `$VAR`/`${VAR}` references in `custom_endpoint.api_key` -> require those vars
    3. Literal `custom_endpoint.api_key` (no `$` references) -> no env var needed
    4. Provider-specific default env var (e.g. `OPENAI_API_KEY`)
    5. OS keychain (future extension)

  Credential lookup (`env_or_store/1`) resolution chain:

    1. Environment variable (`System.get_env/1`)
    2. Encrypted credential store (`CodePuppyControl.Credentials`)
    3. Legacy `~/.code_puppy/puppy.cfg` (read-only, via `Isolation.read_only_legacy/1`)

  Also handles custom endpoint header value substitution with
  `${VAR_NAME}` and `$VAR_NAME` patterns. Substitution resolves
  via env first, then encrypted credential store fallback (same
  `env_or_store/1` path as API key resolution).

  ## Examples

      iex> Credentials.resolve_api_key("openai", %{"api_key_env" => "MY_OPENAI_KEY"})
      # Looks up MY_OPENAI_KEY env var first, falls back to OPENAI_API_KEY

      iex> Credentials.resolve_api_key("anthropic", %{})
      # Looks up ANTHROPIC_API_KEY env var
  """

  require Logger

  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Config.Paths

  # Provider type -> default env var mapping
  @provider_env_vars %{
    "openai" => "OPENAI_API_KEY",
    "anthropic" => "ANTHROPIC_API_KEY",
    "custom_openai" => "OPENAI_API_KEY",
    "custom_anthropic" => "ANTHROPIC_API_KEY",
    "azure_openai" => "AZURE_OPENAI_API_KEY",
    "cerebras" => "CEREBRAS_API_KEY",
    "zai_coding" => "OPENAI_API_KEY",
    "zai_api" => "OPENAI_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY",
    "gemini" => "GEMINI_API_KEY",
    "gemini_oauth" => "GEMINI_API_KEY",
    "custom_gemini" => "GEMINI_API_KEY",
    "groq" => "GROQ_API_KEY",
    "together" => "TOGETHER_API_KEY"
  }

  @doc """
  Resolve the API key for a model given its provider type and config map.

  Resolution order:
  1. If config has `"api_key_env"`, look up that env var
  2. Fall back to the provider's default env var
  3. Check the encrypted credential store (`CodePuppyControl.Credentials`)
  4. Return `nil` if neither is set (OAuth models like claude_code intentionally have no key)

  ## Examples

      iex> Credentials.resolve_api_key("openai", %{})
      System.get_env("OPENAI_API_KEY")
  """
  @spec resolve_api_key(String.t(), map()) :: String.t() | nil
  def resolve_api_key(provider_type, model_config \\ %{}) do
    # 1. Check model-specific api_key_env (env first, then credential store)
    custom =
      case Map.get(model_config, "api_key_env") do
        nil -> nil
        var_name -> env_or_store(var_name)
      end

    # 2. Fall back to the provider's default env var (env first, then store)
    custom ||
      case Map.get(@provider_env_vars, provider_type) do
        nil -> nil
        default_var -> env_or_store(default_var)
      end
  end

  @doc """
  Resolve a named credential by looking at the environment first, then the
  encrypted credential store, then `nil`.

  This is the canonical lookup path for API keys and tokens. It lets users
  either export the env var (e.g. `OPENAI_API_KEY=sk-...`) or save it in
  the credential store with `mix pup_ex.auth.set OPENAI_API_KEY` — both
  work without any code changes at the call site.

  Returns `nil` when no source provides a value. An empty-string env
  var is treated as "unset" so the store and legacy cfg still get a chance.

  ## Examples

      # Environment wins if set
      System.put_env("OPENAI_API_KEY", "sk-env")
      Credentials.env_or_store("OPENAI_API_KEY")
      #=> "sk-env"

      # Store fallback when env is unset
      System.delete_env("OPENAI_API_KEY")
      CodePuppyControl.Credentials.set("OPENAI_API_KEY", "sk-store")
      Credentials.env_or_store("OPENAI_API_KEY")
      #=> "sk-store"

      # Nil if neither is set
      Credentials.env_or_store("NEVER_SET_KEY")
      #=> nil
  """
  @spec env_or_store(String.t()) :: String.t() | nil
  def env_or_store(key_name) when is_binary(key_name) do
    case System.get_env(key_name) do
      nil -> credential_store_get(key_name) || legacy_cfg_get(key_name)
      "" -> credential_store_get(key_name) || legacy_cfg_get(key_name)
      value -> value
    end
  end

  @doc """
  Check which credentials are present for a given provider type.

  Returns `:ok` if required credentials are available, or
  `{:missing, [env_var_names]}` listing which env vars are missing.

  For OAuth-only models (claude_code, chatgpt_oauth), validates that
  OAuth tokens exist in the token storage file with a non-empty access_token.

  ## Examples

      iex> Credentials.validate("openai", %{})
      :ok # if OPENAI_API_KEY is set

      iex> Credentials.validate("openai", %{})
      {:missing, ["OPENAI_API_KEY"]} # if not set

      iex> Credentials.validate("claude_code", %{})
      :ok # if OAuth token file exists with valid access_token

      iex> Credentials.validate("claude_code", %{})
      {:missing, ["CLAUDE_CODE_OAUTH_TOKEN"]} # if no token file or empty access_token
  """
  @spec validate(String.t(), map()) :: :ok | {:missing, [String.t()]}
  def validate(provider_type, model_config \\ %{}) do
    case provider_type do
      "claude_code" ->
        validate_claude_code_oauth()

      "chatgpt_oauth" ->
        validate_chatgpt_oauth()

      _ ->
        required_vars = required_env_vars(provider_type, model_config)

        missing =
          Enum.filter(required_vars, fn var ->
            is_nil(env_or_store(var))
          end)

        case missing do
          [] -> :ok
          vars -> {:missing, vars}
        end
    end
  end

  @doc """
  Resolve custom endpoint headers with environment variable substitution.

  Supports both `${VAR_NAME}` and `$VAR_NAME` syntax.
  Resolution order: env var first, then encrypted credential store fallback.
  If neither source provides a value, substitutes empty string and logs a warning.

  ## Examples

      iex> Credentials.resolve_headers(%{"Authorization" => "Bearer $MY_TOKEN"})
      [{"Authorization", "Bearer the-token-value"}]
  """
  @spec resolve_headers(map()) :: [{String.t(), String.t()}]
  def resolve_headers(headers_map) when is_map(headers_map) do
    Enum.map(headers_map, fn {key, value} ->
      {key, substitute_env_vars(value)}
    end)
  end

  def resolve_headers(_), do: []

  @doc """
  Resolve a custom endpoint configuration into `{url, headers, api_key}`.

  Returns `{:ok, {url, headers, api_key}}` or `{:error, reason}`.
  """
  @spec resolve_custom_endpoint(map()) ::
          {:ok, {String.t(), [{String.t(), String.t()}], String.t() | nil}}
          | {:error, term()}
  def resolve_custom_endpoint(custom_config) when is_map(custom_config) do
    with {:ok, url} <- Map.fetch(custom_config, "url") do
      headers = resolve_headers(Map.get(custom_config, "headers", %{}))

      api_key =
        case Map.get(custom_config, "api_key") do
          nil -> nil
          key_template -> substitute_env_vars(key_template)
        end

      {:ok, {url, headers, api_key}}
    else
      :error -> {:error, :missing_custom_endpoint_url}
    end
  end

  def resolve_custom_endpoint(_), do: {:error, :no_custom_endpoint}

  # ── Private ───────────────────────────────────────────────────────────────

  # Two separate regexes for clean capture group handling.
  # ${VAR_NAME} syntax (braced)
  @braced_regex ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/
  # $VAR_NAME syntax (unbraced)
  @unbraced_regex ~r/\$([A-Za-z_][A-Za-z0-9_]*)/

  defp substitute_env_vars(value) when is_binary(value) do
    value
    |> do_substitute(@braced_regex)
    |> do_substitute(@unbraced_regex)
  end

  defp substitute_env_vars(_), do: ""

  defp do_substitute(value, regex) do
    Regex.replace(regex, value, fn _full, var_name ->
      case env_or_store(var_name) do
        nil ->
          Logger.warning(
            "Credentials: env var or credential store key '#{var_name}' not set; " <>
              "using empty string in header value"
          )

          ""

        val ->
          val
      end
    end)
  end

  defp required_env_vars(provider_type, model_config) do
    # 1. Highest priority: explicit api_key_env
    case Map.get(model_config, "api_key_env") do
      var_name when is_binary(var_name) and byte_size(var_name) > 0 ->
        [var_name]

      _ ->
        # 2. Check custom_endpoint.api_key for $VAR/${VAR} references
        case extract_custom_endpoint_vars(model_config) do
          [_ | _] = vars ->
            vars

          [] ->
            # 3. If custom_endpoint.api_key is a literal key, no env var needed
            if has_literal_api_key?(model_config) do
              []
            else
              # 4. Fall back to provider default
              case Map.get(@provider_env_vars, provider_type) do
                nil -> []
                var -> [var]
              end
            end
        end
    end
  end

  # Extract env var names referenced in custom_endpoint.api_key via
  # $VAR or ${VAR} syntax. Braced patterns are extracted first to avoid
  # double-counting.
  defp extract_custom_endpoint_vars(model_config) do
    case model_config do
      %{"custom_endpoint" => %{"api_key" => api_key}} when is_binary(api_key) ->
        stripped = Regex.replace(@braced_regex, api_key, "")

        braced =
          Regex.scan(@braced_regex, api_key, capture: :all_but_first)
          |> List.flatten()

        unbraced =
          Regex.scan(@unbraced_regex, stripped, capture: :all_but_first)
          |> List.flatten()

        Enum.uniq(braced ++ unbraced)

      _ ->
        []
    end
  end

  # A literal api_key is a non-empty string without $VAR / ${VAR} references.
  # When present, validation should not require the provider default env var.
  defp has_literal_api_key?(model_config) do
    case model_config do
      %{"custom_endpoint" => %{"api_key" => api_key}} when is_binary(api_key) ->
        api_key != "" and
          not Regex.match?(@braced_regex, api_key) and
          not Regex.match?(@unbraced_regex, api_key)

      _ ->
        false
    end
  end

  # ── OAuth Validation ─────────────────────────────────────────────────────

  @doc false
  @spec validate_claude_code_oauth() :: :ok | {:missing, [String.t()]}
  defp validate_claude_code_oauth do
    case CodePuppyControl.Auth.ClaudeOAuth.load_tokens() do
      {:ok, tokens} ->
        case Map.get(tokens, "access_token") do
          nil -> {:missing, ["CLAUDE_CODE_OAUTH_TOKEN"]}
          "" -> {:missing, ["CLAUDE_CODE_OAUTH_TOKEN"]}
          _token -> :ok
        end

      {:error, :not_found} ->
        {:missing, ["CLAUDE_CODE_OAUTH_TOKEN"]}

      {:error, _reason} ->
        {:missing, ["CLAUDE_CODE_OAUTH_TOKEN"]}
    end
  end

  @doc false
  @spec validate_chatgpt_oauth() :: :ok | {:missing, [String.t()]}
  defp validate_chatgpt_oauth do
    case CodePuppyControl.Auth.ChatGptOAuth.load_stored_tokens() do
      nil ->
        {:missing, ["CHATGPT_OAUTH_TOKEN"]}

      tokens ->
        case Map.get(tokens, "access_token") do
          nil -> {:missing, ["CHATGPT_OAUTH_TOKEN"]}
          "" -> {:missing, ["CHATGPT_OAUTH_TOKEN"]}
          _token -> :ok
        end
    end
  end

  # Check the encrypted credential store as a fallback.
  # Silently returns nil if the store is unavailable (not initialized,
  # corrupted, key mismatch, etc.). The store is optional.
  defp credential_store_get(key_name) do
    case CodePuppyControl.Credentials.get(key_name) do
      {:ok, value} -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ── Legacy puppy.cfg Fallback (read-only) ────────────────────────────────
  #
  # When neither env var nor credential store provides a value, try the
  # legacy Python home's puppy.cfg. This is a READ-ONLY fallback; we never
  # write to ~/.code_puppy.
  #
  # Resolution within puppy.cfg:
  #   1. Try exact key name (e.g. `WAFER_API_KEY`)
  #   2. Try lowercase key name (e.g. `wafer_api_key`)
  #
  # Value interpretation:
  #   - `!` prefix → refuse to execute (shell command), return nil
  #   - Bare env-var name (ALL_CAPS + underscores) → resolve from env if set
  #   - Anything else → treat as literal credential value
  #
  # Test override: Application.get_env(:code_puppy_control, :legacy_home_dir)
  # avoids touching the real ~/.code_puppy in tests.

  defp legacy_home_dir do
    Application.get_env(:code_puppy_control, :legacy_home_dir) ||
      Paths.legacy_home_dir()
  end

  defp legacy_cfg_get(key_name) do
    cfg_path = Path.join(legacy_home_dir(), "puppy.cfg")

    with {:ok, contents} <- safe_read_legacy_file(cfg_path) do
      # Try exact key, then lowercase (e.g. WAFER_API_KEY / wafer_api_key)
      value =
        parse_ini_value(contents, key_name) ||
          parse_ini_value(contents, String.downcase(key_name))

      resolve_legacy_value(value)
    else
      {:error, _} -> nil
    end
  end

  # Read a legacy-home file, routing through Isolation.read_only_legacy/1
  # when the path is under the real legacy home (~/.code_puppy). For paths
  # outside the legacy home (e.g. test override dirs), uses File.read/1
  # directly. This satisfies ADR-003 compliance while preserving test
  # overrides via Application.get_env(:code_puppy_control, :legacy_home_dir).
  defp safe_read_legacy_file(path) do
    if Paths.in_legacy_home?(path) do
      Isolation.read_only_legacy(path)
    else
      File.read(path)
    end
  end

  defp resolve_legacy_value(nil), do: nil

  # Values starting with ! look like shell commands — refuse to execute.
  defp resolve_legacy_value("!" <> _rest) do
    Logger.warning("Credentials: legacy cfg value starts with '!' — refusing to execute")
    nil
  end

  # A bare env-var name: ALL_CAPS with underscores. Try resolving from env.
  # If the env var is set, use its value; otherwise treat the string as a
  # literal credential (e.g. someone literally named a key "API_KEY").
  defp resolve_legacy_value(value) when is_binary(value) do
    if env_var_name?(value) do
      System.get_env(value) || value
    else
      value
    end
  end

  # Heuristic: a value is a "bare env-var name" if it looks like an
  # identifier in ALL_CAPS with at least one underscore and no lowercase
  # letters. This avoids treating actual API keys (like sk-abc123) as
  # env var names.
  defp env_var_name?(value) do
    Regex.match?(~r/^[A-Z][A-Z0-9_]{1,}$/, value)
  end

  # Parse a simple INI-style value from puppy.cfg.
  # Format: KEY=value (one per line, no section headers for API keys).
  # Matches the same regex used by CodePuppyControl.Credentials.parse_ini_value/2.
  defp parse_ini_value(contents, key_name) do
    case Regex.run(~r/^#{Regex.escape(key_name)}=(.*)$/m, contents) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end
end
