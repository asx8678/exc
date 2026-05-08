defmodule CodePuppyControl.Auth.ClaudeOAuth do
  @moduledoc """
  Claude Code OAuth core configuration and token management.

  Ported from `code_puppy/plugins/claude_code_oauth/config.py` and
  `utils.py`. Provides OAuth endpoints, client config, model config,
  token persistence, and model registry management for Claude Code
  OAuth-authenticated sessions.

  Model registry, filtering, and entry construction are delegated to
  `CodePuppyControl.Auth.ClaudeOAuth.Models` to keep this module
  under the 600-line hard cap.

  All file writes go through `CodePuppyControl.Config.Isolation.safe_write!/2`
  to comply with ADR-003 dual-home isolation.

  ## Config Access

  Use `config/1` to read any config value, or call the individual
  accessor functions directly. All values are also available as module
  attributes for compile-time use.
  """

  require Logger

  alias CodePuppyControl.Config.Paths
  alias CodePuppyControl.Config.Isolation
  alias CodePuppyControl.Auth.ClaudeOAuth.Models

  # ── OAuth Endpoints ─────────────────────────────────────────────────────

  @auth_url "https://claude.ai/oauth/authorize"
  @token_url "https://console.anthropic.com/v1/oauth/token"
  @api_base_url "https://api.anthropic.com"

  # ── OAuth Client Configuration ──────────────────────────────────────────

  @client_id System.get_env("CLAUDE_OAUTH_CLIENT_ID") ||
               "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @scope "org:create_api_key user:profile user:inference"
  @redirect_host "http://localhost"
  @redirect_path "callback"
  @callback_port_range {8765, 8795}
  @callback_timeout 180
  @console_redirect_uri "https://console.anthropic.com/oauth/code/callback"

  # ── Model Configuration ────────────────────────────────────────────────

  @prefix "claude-code-"
  @default_context_length 200_000
  @long_context_length 1_000_000
  @long_context_models ["claude-opus-4-6", "claude-opus-4-5"]
  @api_key_env_var "CLAUDE_CODE_ACCESS_TOKEN"
  @anthropic_version "2023-06-01"

  # ── Token Refresh ──────────────────────────────────────────────────────

  @token_refresh_buffer_seconds 300
  @min_refresh_buffer_seconds 30

  # ── Config Access ─────────────────────────────────────────────────────

  @doc """
  Retrieve a config value by key atom.

  Supported keys: `:auth_url`, `:token_url`, `:api_base_url`, `:client_id`,
  `:scope`, `:redirect_host`, `:redirect_path`, `:callback_port_range`,
  `:callback_timeout`, `:console_redirect_uri`, `:prefix`,
  `:default_context_length`, `:long_context_length`, `:long_context_models`,
  `:api_key_env_var`, `:anthropic_version`.
  """
  @spec config(atom()) :: term()
  def config(:auth_url), do: @auth_url
  def config(:token_url), do: @token_url
  def config(:api_base_url), do: @api_base_url
  def config(:client_id), do: @client_id
  def config(:scope), do: @scope
  def config(:redirect_host), do: @redirect_host
  def config(:redirect_path), do: @redirect_path
  def config(:callback_port_range), do: @callback_port_range
  def config(:callback_timeout), do: @callback_timeout
  def config(:console_redirect_uri), do: @console_redirect_uri
  def config(:prefix), do: @prefix
  def config(:default_context_length), do: @default_context_length
  def config(:long_context_length), do: @long_context_length
  def config(:long_context_models), do: @long_context_models
  def config(:api_key_env_var), do: @api_key_env_var
  def config(:anthropic_version), do: @anthropic_version
  def config(_), do: nil

  # Convenience accessors for the most commonly used values
  @spec auth_url() :: String.t()
  def auth_url, do: @auth_url
  @spec token_url() :: String.t()
  def token_url, do: @token_url
  @spec api_base_url() :: String.t()
  def api_base_url, do: @api_base_url
  @spec client_id() :: String.t()
  def client_id, do: @client_id
  @spec prefix() :: String.t()
  def prefix, do: @prefix
  @spec anthropic_version() :: String.t()
  def anthropic_version, do: @anthropic_version

  # ── Public API: Path Resolution ────────────────────────────────────────

  @doc """
  Path to the OAuth token storage file.

  Located in the data directory: `{data_dir}/claude_code_oauth.json`.
  Ensures the data directory exists before returning the path.
  """
  @spec token_storage_path() :: String.t()
  def token_storage_path do
    dir = Paths.data_dir()
    Isolation.safe_mkdir_p!(dir)
    Path.join(dir, "claude_code_oauth.json")
  end

  @doc """
  Path to the Claude models overlay JSON file.

  Delegates to `CodePuppyControl.Config.Paths.claude_models_file/0`.
  """
  @spec claude_models_path() :: String.t()
  def claude_models_path, do: Paths.claude_models_file()

  # ── Public API: Token Persistence ─────────────────────────────────────

  @doc """
  Load stored OAuth tokens from disk.

  Returns `{:ok, map}` if tokens exist and parse as JSON,
  `{:error, :not_found}` if the file doesn't exist, or
  `{:error, reason}` on any other failure.
  """
  @spec load_tokens() :: {:ok, map()} | {:error, :not_found | term()}
  def load_tokens do
    path = token_storage_path()

    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, tokens} when is_map(tokens) ->
            {:ok, tokens}

          {:error, reason} ->
            Logger.error("Failed to parse OAuth tokens: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.error("Failed to load OAuth tokens: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Save OAuth tokens to disk with restricted permissions.

  Uses `Isolation.safe_write!/2` for ADR-003 compliance.
  Returns `:ok` on success, raises on failure.
  """
  @spec save_tokens(map()) :: :ok
  def save_tokens(tokens) when is_map(tokens) do
    path = token_storage_path()
    json = Jason.encode!(tokens, pretty: true)
    Isolation.safe_write!(path, json)
    File.chmod(path, 0o600)
    :ok
  end

  # ── Public API: Token Expiry ───────────────────────────────────────────

  @doc "Check if tokens are expired (with proactive refresh buffer)."
  @spec token_expired?(map()) :: boolean()
  def token_expired?(tokens) when is_map(tokens) do
    case get_expires_at(tokens) do
      nil ->
        false

      expires_at ->
        buffer = calculate_refresh_buffer(tokens["expires_in"])
        System.system_time(:second) >= expires_at - buffer
    end
  end

  @doc "Check if tokens are actually expired (no buffer)."
  @spec token_actually_expired?(map()) :: boolean()
  def token_actually_expired?(tokens) when is_map(tokens) do
    case get_expires_at(tokens) do
      nil -> false
      expires_at -> System.system_time(:second) >= expires_at
    end
  end

  # ── Public API: Model Fetching ─────────────────────────────────────────

  @doc """
  Fetch available Claude models from the Anthropic API.

  Returns `{:ok, [model_name]}` on success or `{:error, reason}` on failure.
  Response bodies are never logged — they may contain sensitive data.
  """
  @spec fetch_models(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_models(access_token) when is_binary(access_token) do
    url = "#{@api_base_url}/v1/models"

    headers = [
      {"Authorization", "Bearer #{access_token}"},
      {"Content-Type", "application/json"},
      {"anthropic-beta", "oauth-2025-04-20"},
      {"anthropic-version", @anthropic_version}
    ]

    case :httpc.request(:get, {to_charlist(url), headers}, httpc_opts(), []) do
      {:ok, {{_version, 200, _reason}, _resp_headers, body}} ->
        parse_models_response(body)

      {:ok, {{_version, status, _reason}, _resp_headers, _body}} ->
        Logger.error("Failed to fetch models: status=#{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Error fetching Claude models: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Public API: Model Registry (delegated to Models) ──────────────────

  @doc "Filter model names to keep only the latest per family. Delegates to `Models.filter_latest_models/2`."
  @spec filter_latest_models([String.t()], Models.max_per_family()) :: [String.t()]
  def filter_latest_models(models, max_per_family \\ 2),
    do: Models.filter_latest_models(models, max_per_family)

  @doc "Load Claude models from the overlay JSON file, filtering blocked ones. Delegates to `Models.load_models/0`."
  @spec load_models() :: {:ok, map()}
  def load_models, do: Models.load_models()

  @doc "Save Claude models to the overlay JSON file. Delegates to `Models.save_models/1`."
  @spec save_models(map()) :: :ok
  def save_models(models), do: Models.save_models(models)

  @doc "Add model names to the registry. Delegates to `Models.add_models/1`."
  @spec add_models([String.t()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def add_models(model_names), do: Models.add_models(model_names)

  @doc "Load Claude models filtered to only the latest per family. Delegates to `Models.load_latest_models/0`."
  @spec load_latest_models() :: {:ok, map()}
  def load_latest_models, do: Models.load_latest_models()

  @doc "Remove all Claude Code OAuth models. Delegates to `Models.remove_models/0`."
  @spec remove_models() :: {:ok, non_neg_integer()} | {:error, term()}
  def remove_models, do: Models.remove_models()

  # ── Private: Token Helpers ─────────────────────────────────────────────

  defp get_expires_at(%{"expires_at" => val}) when is_number(val), do: trunc(val)
  defp get_expires_at(_), do: nil

  defp calculate_refresh_buffer(nil), do: @token_refresh_buffer_seconds

  defp calculate_refresh_buffer(expires_in) when is_number(expires_in) do
    min(
      @token_refresh_buffer_seconds,
      max(@min_refresh_buffer_seconds, trunc(expires_in * 0.1))
    )
  end

  defp calculate_refresh_buffer(_), do: @token_refresh_buffer_seconds

  # ── Private: HTTP ─────────────────────────────────────────────────────

  defp httpc_opts do
    [
      timeout: 30_000,
      connect_timeout: 10_000,
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
    ]
  end

  defp parse_models_response(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => models}} when is_list(models) ->
        names =
          models
          |> Enum.map(fn m -> m["id"] || m["name"] end)
          |> Enum.filter(&is_binary/1)

        {:ok, names}

      {:ok, _} ->
        Logger.error("Unexpected models response shape")
        {:error, :unexpected_response}

      {:error, reason} ->
        Logger.error("Failed to parse models response: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ── Public API: Token Refresh & Model Token Updates ───────────────────

  @doc """
  Run the interactive Claude Code OAuth browser flow.
  """
  @spec run_oauth_flow() :: :ok | {:error, term()}
  def run_oauth_flow do
    CodePuppyControl.Auth.ClaudeOAuth.Flow.run_oauth_flow()
  end

  @doc """
  Get a valid access token, refreshing if needed.
  """
  @spec get_valid_access_token() :: {:ok, String.t()} | {:error, term()}
  def get_valid_access_token do
    CodePuppyControl.Auth.ClaudeOAuth.Flow.get_valid_access_token()
  end

  @doc """
  Refresh the access token using the stored refresh token.
  """
  @spec refresh_access_token() :: {:ok, String.t()} | {:error, term()}
  def refresh_access_token do
    CodePuppyControl.Auth.ClaudeOAuth.Flow.refresh_access_token()
  end

  @doc "Update the access token in all saved Claude Code model entries. Delegates to `Models.update_model_tokens/1`."
  @spec update_model_tokens(String.t()) :: :ok | {:error, term()}
  def update_model_tokens(access_token) when is_binary(access_token),
    do: Models.update_model_tokens(access_token)
end
