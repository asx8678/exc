defmodule CodePuppyControl.Auth.ChatGptOAuth do
  @moduledoc """
  ChatGPT OAuth flow with PKCE support for OpenAI/ChatGPT authentication.
  """

  require Logger
  alias CodePuppyControl.Config.{Isolation, Paths}
  alias CodePuppyControl.Auth.{BrowserHelper, OAuthHtml}

  @config %{
    issuer: "https://auth.openai.com",
    auth_url: "https://auth.openai.com/oauth/authorize",
    token_url: "https://auth.openai.com/oauth/token",
    api_base_url: "https://chatgpt.com/backend-api/codex",
    client_id: System.get_env("CHATGPT_OAUTH_CLIENT_ID", "app_EMoamEEZ73f0CkXaXp7hrann"),
    scope: "openid profile email offline_access",
    redirect_host: "http://localhost",
    redirect_path: "auth/callback",
    required_port: 1455,
    callback_timeout: 120,
    prefix: "chatgpt-",
    default_context_length: 272_000,
    client_version: "0.72.0",
    originator: "codex_cli_rs"
  }

  @doc "Returns the OAuth configuration map."
  @spec config() :: map()
  def config, do: @config

  @type oauth_context :: %{
          state: String.t(),
          code_verifier: String.t(),
          code_challenge: String.t(),
          redirect_uri: String.t() | nil,
          created_at: integer(),
          expires_at: integer()
        }

  @doc """
  Generate a fresh OAuth PKCE context.
  """
  @spec prepare_oauth_context() :: oauth_context()
  def prepare_oauth_context do
    now = System.system_time(:second)
    state = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    code_verifier = :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)
    code_challenge = compute_code_challenge(code_verifier)

    %{
      state: state,
      code_verifier: code_verifier,
      code_challenge: code_challenge,
      redirect_uri: nil,
      created_at: now,
      expires_at: now + 240
    }
  end

  @doc """
  Assign the redirect URI for the given OAuth context.
  """
  @spec assign_redirect_uri(oauth_context(), integer()) :: oauth_context()
  def assign_redirect_uri(context, port) do
    required = @config.required_port

    if port != required do
      raise "OAuth flow must use port " <>
              Integer.to_string(required) <>
              "; attempted to assign port " <> Integer.to_string(port)
    end

    host = String.trim_trailing(@config.redirect_host, "/")
    path = String.trim_leading(@config.redirect_path, "/")
    %{context | redirect_uri: host <> ":" <> Integer.to_string(port) <> "/" <> path}
  end

  @doc """
  Build the OpenAI authorization URL with PKCE parameters.
  """
  @spec build_authorization_url(oauth_context()) :: String.t()
  def build_authorization_url(context) do
    unless context.redirect_uri do
      raise "Redirect URI has not been assigned for this OAuth context"
    end

    params = [
      {"response_type", "code"},
      {"client_id", @config.client_id},
      {"redirect_uri", context.redirect_uri},
      {"scope", @config.scope},
      {"code_challenge", context.code_challenge},
      {"code_challenge_method", "S256"},
      {"id_token_add_organizations", "true"},
      {"codex_cli_simplified_flow", "true"},
      {"state", context.state}
    ]

    @config.auth_url <> "?" <> URI.encode_query(params)
  end

  @doc """
  Exchange an authorization code for access tokens.
  """
  @spec exchange_code_for_tokens(String.t(), oauth_context()) :: {:ok, map()} | {:error, term()}
  def exchange_code_for_tokens(auth_code, context) do
    unless context.redirect_uri, do: raise("Redirect URI missing from OAuth context")

    if context_expired?(context) do
      {:error, :context_expired}
    else
      payload = [
        {"grant_type", "authorization_code"},
        {"code", auth_code},
        {"redirect_uri", context.redirect_uri},
        {"client_id", @config.client_id},
        {"code_verifier", context.code_verifier}
      ]

      headers = [{"content-type", "application/x-www-form-urlencoded"}]

      case http_post(@config.token_url, payload, headers) do
        {:ok, %{"access_token" => _} = token_data} ->
          {:ok, Map.put(token_data, "last_refresh", DateTime.utc_now() |> DateTime.to_iso8601())}

        {:ok, %{"error" => error} = resp} ->
          desc = Map.get(resp, "error_description", error)
          Logger.error("OAuth error: " <> desc)
          {:error, {:oauth_error, error}}

        {:ok, other} ->
          {:error, {:unexpected_response, other}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @unrecoverable_oauth_errors MapSet.new([
                                "invalid_grant",
                                "invalid_token",
                                "token_expired",
                                "unauthorized_client",
                                "access_denied",
                                "invalid_client"
                              ])
  @unrecoverable_error_phrases MapSet.new([
                                 "token expired",
                                 "refresh token expired",
                                 "token has expired",
                                 "could not validate your token",
                                 "invalid grant"
                               ])

  @doc """
  Refresh the access token using the stored refresh token.
  On unrecoverable errors, stored tokens are cleared.
  """
  @spec refresh_access_token() :: {:ok, String.t()} | {:error, term()}
  def refresh_access_token do
    case load_stored_tokens() do
      nil ->
        {:error, :no_tokens}

      tokens ->
        refresh_token = Map.get(tokens, "refresh_token")

        if is_nil(refresh_token) or refresh_token == "" do
          {:error, :no_refresh_token}
        else
          do_refresh(tokens, refresh_token)
        end
    end
  end

  defp do_refresh(tokens, refresh_token) do
    payload = [
      {"grant_type", "refresh_token"},
      {"refresh_token", refresh_token},
      {"client_id", @config.client_id}
    ]

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    case http_post(@config.token_url, payload, headers) do
      {:ok, %{"access_token" => new_access} = new_tokens} ->
        updated =
          tokens
          |> Map.put("access_token", new_access)
          |> Map.put("refresh_token", Map.get(new_tokens, "refresh_token", refresh_token))
          |> Map.put("id_token", Map.get(new_tokens, "id_token", Map.get(tokens, "id_token")))
          |> Map.put("api_key", new_access)
          |> Map.put("last_refresh", DateTime.utc_now() |> DateTime.to_iso8601())

        :ok = save_tokens(updated)
        Logger.info("Successfully refreshed ChatGPT OAuth token")
        {:ok, new_access}

      {:ok, %{"error" => _} = error_data} ->
        if unrecoverable_error?(error_data) do
          Logger.warning("Unrecoverable token error - clearing token cache")
          clear_stored_tokens()
          {:error, :unrecoverable}
        else
          {:error, :transient}
        end

      {:error, %{status: 401}} ->
        clear_stored_tokens()
        {:error, :unrecoverable}

      {:error, reason} ->
        {:error, {:transient, reason}}
    end
  end

  @doc "Get a valid access token, refreshing if expired."
  @spec get_valid_access_token() :: {:ok, String.t()} | {:error, term()}
  def get_valid_access_token do
    case load_stored_tokens() do
      nil ->
        {:error, :not_authenticated}

      tokens ->
        access_token = Map.get(tokens, "access_token")

        cond do
          is_nil(access_token) or access_token == "" ->
            {:error, :no_access_token}

          token_expired?(access_token) ->
            case refresh_access_token() do
              {:ok, new_token} -> {:ok, new_token}
              {:error, _} = err -> err
            end

          true ->
            {:ok, access_token}
        end
    end
  end

  @doc "Path to the OAuth token file."
  @spec token_storage_path() :: String.t()
  def token_storage_path, do: Path.join(auth_dir(), "chatgpt_oauth.json")

  @doc """
  Path to the legacy OAuth token file in the Python pup's home.

  READ-ONLY fallback path. Used by `load_stored_tokens/0` when the primary
  Elixir token file doesn't exist. Never written to — complies with ADR-003.
  """
  @spec legacy_token_storage_path() :: String.t()
  def legacy_token_storage_path do
    # Use Application.get_env to allow test overrides, matching the pattern
    # in ModelFactory.Credentials.legacy_home_dir/0.
    legacy_home =
      Application.get_env(:code_puppy_control, :legacy_home_dir) ||
        Paths.legacy_home_dir()

    Path.join(legacy_home, "chatgpt_oauth.json")
  end

  @doc "Path to the auth directory."
  @spec auth_dir() :: String.t()
  def auth_dir, do: Path.join(Paths.home_dir(), "auth")

  @doc "Save OAuth tokens to disk via Isolation.safe_write!/2."
  @spec save_tokens(map()) :: :ok
  def save_tokens(tokens) when is_map(tokens) do
    path = token_storage_path()
    Isolation.safe_mkdir_p!(Path.dirname(path))
    Isolation.safe_write!(path, Jason.encode!(tokens, pretty: true))
    File.chmod(path, 0o600)
    :ok
  end

  @doc """
  Load stored OAuth tokens from disk.

  Resolution order:
  1. Primary Elixir token file (`~/.code_puppy_ex/auth/chatgpt_oauth.json`)
  2. READ-ONLY fallback to legacy Python home (`~/.code_puppy/chatgpt_oauth.json`)

  This is a runtime bridge, NOT an import. Tokens are never written to the
  legacy home — ADR-003 compliance is maintained.
  """
  @spec load_stored_tokens() :: map() | nil
  def load_stored_tokens do
    # Try primary Elixir token file first
    case read_token_file(token_storage_path()) do
      {:ok, tokens} when is_map(tokens) ->
        tokens

      _ ->
        # Fallback to legacy Python home (READ-ONLY)
        read_legacy_token_fallback()
    end
  end

  # Read and decode a token file. Returns {:ok, map} or {:error, reason}.
  defp read_token_file(path) do
    case File.read(path) do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
          {:error, _} -> {:error, :invalid_json}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # READ-ONLY fallback to legacy Python home. Uses Isolation.read_only_legacy/1
  # when the path is under the real legacy home to satisfy ADR-003 compliance.
  # For test override paths (outside legacy home), uses File.read/1 directly.
  defp read_legacy_token_fallback do
    legacy_path = legacy_token_storage_path()
    Logger.debug("Primary token file absent, trying legacy fallback: #{legacy_path}")

    result =
      if Paths.in_legacy_home?(legacy_path) do
        # Real legacy home — use sanctioned read-only path
        Isolation.read_only_legacy(legacy_path)
      else
        # Test override path — read directly
        File.read(legacy_path)
      end

    case result do
      {:ok, data} ->
        case Jason.decode(data) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @doc """
  Clear stored OAuth tokens from the Elixir home.

  WARNING: After clearing, `load_stored_tokens/0` will fall back to
  the legacy token file (`~/.code_puppy/chatgpt_oauth.json`) if it
  exists. To fully disable ChatGPT OAuth while a legacy token is
  present, you must also remove the legacy token file.
  """
  @spec clear_stored_tokens() :: :ok
  def clear_stored_tokens do
    path = token_storage_path()
    if File.exists?(path), do: Isolation.safe_rm!(path)
    :ok
  rescue
    e in Isolation.IsolationViolation ->
      Logger.warning("Cannot clear tokens: " <> Exception.message(e))
      :ok
  end

  @doc "Parse JWT token claims without signature verification."
  @spec parse_jwt_claims(String.t()) :: map() | nil
  def parse_jwt_claims(token) when is_binary(token) do
    parts = String.split(token, ".")

    if length(parts) == 3 do
      [_header, payload, _sig] = parts

      case Base.url_decode64(padding_payload(payload)) do
        {:ok, decoded} ->
          case Jason.decode(decoded) do
            {:ok, claims} -> claims
            _ -> nil
          end

        :error ->
          nil
      end
    else
      nil
    end
  end

  def parse_jwt_claims(_), do: nil

  defp padding_payload(payload) do
    rem = rem(byte_size(payload), 4)
    if rem == 0, do: payload, else: payload <> String.duplicate("=", 4 - rem)
  end

  @default_codex_models ["gpt-5.4", "gpt-5.3-instant", "gpt-5.3-codex-spark", "gpt-5.3-codex"]
  @required_codex_models ["gpt-5.4", "gpt-5.3-instant", "gpt-5.3-codex-spark", "gpt-5.3-codex"]
  @blocked_models MapSet.new([
                    "gpt-5",
                    "gpt-5-codex",
                    "gpt-5-codex-mini",
                    "gpt-5.1",
                    "gpt-5.1-codex",
                    "gpt-5.1-codex-max",
                    "gpt-5.1-codex-mini",
                    "gpt-5.2",
                    "gpt-5.2-codex",
                    "gpt-4o",
                    "gpt-3.5-turbo",
                    "claude-3-opus"
                  ])
  @codex_model_context_lengths %{"gpt-5.3-codex-spark" => 131_000, "gpt-5.3-instant" => 192_000}

  @doc "Check if a model name is blocked."
  @spec blocked_model?(String.t()) :: boolean()
  def blocked_model?(model_name) when is_binary(model_name) do
    bare = strip_prefix(model_name)
    MapSet.member?(@blocked_models, bare) or MapSet.member?(@blocked_models, model_name)
  end

  def blocked_model?(_), do: false

  @doc "Fetch available models from ChatGPT Codex API, with default fallback."
  @spec fetch_chatgpt_models(String.t(), String.t()) :: [String.t()]
  def fetch_chatgpt_models(access_token, account_id) do
    base_url = String.trim_trailing(@config.api_base_url, "/")

    headers = [
      {"authorization", "Bearer " <> access_token},
      {"chatgpt-account-id", account_id},
      {"user-agent", user_agent_string()},
      {"originator", @config.originator},
      {"accept", "application/json"}
    ]

    params = [{"client_version", @config.client_version}]

    case http_get(base_url <> "/models", headers, params) do
      {:ok, %{"models" => models}} when is_list(models) ->
        model_ids =
          models
          |> Enum.filter(&(&1 != nil))
          |> Enum.map(fn m -> m["slug"] || m["id"] || m["name"] end)
          |> Enum.filter(&(&1 != nil))

        if model_ids != [], do: model_ids, else: default_models()

      _ ->
        Logger.info("Models endpoint unavailable, using default model list")
        default_models()
    end
  end

  @doc "Add ChatGPT models to the chatgpt_models.json configuration."
  @spec add_models_to_extra_config([String.t()]) :: :ok | {:error, term()}
  def add_models_to_extra_config(models) do
    existing = load_chatgpt_models()
    cleaned = existing |> Enum.reject(fn {name, _} -> blocked_model?(name) end) |> Map.new()
    filtered = Enum.filter(models, &(not blocked_model?(&1)))

    updated =
      Enum.reduce(filtered, cleaned, fn model_name, acc ->
        prefixed = @config.prefix <> model_name
        normalized = String.downcase(model_name)

        supports_xhigh =
          String.contains?(normalized, "codex") or String.starts_with?(normalized, "gpt-5.4")

        context_length =
          Map.get(@codex_model_context_lengths, model_name, @config.default_context_length)

        Map.put(acc, prefixed, %{
          "type" => "chatgpt_oauth",
          "name" => model_name,
          "custom_endpoint" => %{"url" => @config.api_base_url},
          "context_length" => context_length,
          "oauth_source" => "chatgpt-oauth-plugin",
          "supported_settings" => ["reasoning_effort", "summary", "verbosity"],
          "supports_xhigh_reasoning" => supports_xhigh
        })
      end)

    save_chatgpt_models(updated)
  end

  @doc "Remove all ChatGPT OAuth models from the configuration."
  @spec remove_chatgpt_models() :: non_neg_integer()
  def remove_chatgpt_models do
    existing = load_chatgpt_models()

    {to_remove, to_keep} =
      Enum.split_with(existing, fn {_name, cfg} ->
        Map.get(cfg, "oauth_source") == "chatgpt-oauth-plugin"
      end)

    case save_chatgpt_models(Map.new(to_keep)) do
      :ok -> length(to_remove)
      {:error, _} -> 0
    end
  end

  @doc "Load ChatGPT models from chatgpt_models.json."
  @spec load_chatgpt_models() :: map()
  def load_chatgpt_models do
    path = Paths.chatgpt_models_file()

    with {:ok, data} <- File.read(path),
         {:ok, decoded} <- Jason.decode(data),
         true <- is_map(decoded),
         do: decoded
  end

  @doc "Save ChatGPT models to chatgpt_models.json."
  @spec save_chatgpt_models(map()) :: :ok | {:error, term()}
  def save_chatgpt_models(models) when is_map(models) do
    path = Paths.chatgpt_models_file()
    Isolation.safe_mkdir_p!(Path.dirname(path))
    Isolation.safe_write!(path, Jason.encode!(models, pretty: true))
    :ok
  rescue
    e ->
      Logger.error("Failed to save ChatGPT models: " <> Exception.message(e))
      {:error, e}
  end

  @doc "Return the default Codex model list."
  @spec default_models() :: [String.t()]
  def default_models do
    @default_codex_models |> ensure_required_models() |> Enum.filter(&(not blocked_model?(&1)))
  end

  @doc """
  Run the full OAuth flow: start callback server, open browser, and wait for the callback.
  """
  @spec run_oauth_flow() :: :ok | {:error, term()}
  def run_oauth_flow do
    existing = load_stored_tokens()

    if existing && Map.get(existing, "access_token") do
      Logger.warning("Existing ChatGPT tokens will be overwritten.")
    end

    context = prepare_oauth_context() |> assign_redirect_uri(@config.required_port)
    auth_url = build_authorization_url(context)

    case start_callback_server(context) do
      {:ok, server_ref} ->
        Logger.info("Open this URL in your browser: " <> auth_url)
        BrowserHelper.open_url(auth_url)
        Logger.info("Waiting for authentication callback...")

        case wait_for_callback(server_ref, @config.callback_timeout) do
          {:ok, tokens} ->
            :ok = save_tokens(tokens)
            api_key = Map.get(tokens, "api_key")

            if api_key do
              Logger.info("Successfully obtained OAuth access token for API access.")
              register_models(api_key, Map.get(tokens, "account_id", ""))
            else
              Logger.warning("No API key obtained from OAuth flow.")
            end

            :ok

          {:error, reason} ->
            Logger.error("Authentication failed: " <> inspect(reason))
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error(
          "Could not start OAuth server on port " <>
            Integer.to_string(@config.required_port) <> ": " <> inspect(reason)
        )

        {:error, reason}
    end
  end

  defp start_callback_server(context) do
    parent = self()

    Task.start(fn ->
      case :gen_tcp.listen(@config.required_port, [
             :binary,
             packet: :raw,
             active: false,
             reuseaddr: true
           ]) do
        {:ok, listen_sock} ->
          send(parent, {:server_ready, self()})
          serve_one(listen_sock, context, parent)

        {:error, reason} ->
          send(parent, {:server_error, reason})
      end
    end)

    receive do
      {:server_ready, _pid} -> {:ok, parent}
      {:server_error, reason} -> {:error, reason}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp serve_one(listen_sock, context, parent) do
    case :gen_tcp.accept(listen_sock, 120_000) do
      {:ok, sock} ->
        :gen_tcp.close(listen_sock)

        case :gen_tcp.recv(sock, 0, 10_000) do
          {:ok, request} -> handle_request(sock, request, context, parent)
          {:error, reason} -> send(parent, {:auth_error, reason})
        end

        :gen_tcp.close(sock)

      {:error, reason} ->
        Logger.error("Failed to accept on callback socket: " <> inspect(reason))
        send(parent, {:auth_error, reason})
    end
  end

  defp handle_request(sock, request, context, parent) do
    case parse_http_request(request) do
      {:ok, "/auth/callback", query} ->
        handle_callback(sock, query, context, parent)

      {:ok, "/success", _query} ->
        respond_html(sock, 200, OAuthHtml.success_html("ChatGPT"))
        send(parent, :auth_displayed)

      _ ->
        respond_html(sock, 404, "Not found")
        send(parent, {:auth_error, :not_found})
    end
  end

  defp handle_callback(sock, query, context, parent) do
    case URI.decode_query(query) do
      %{"code" => code} ->
        case exchange_code_for_tokens(code, context) do
          {:ok, token_data} ->
            id_token = Map.get(token_data, "id_token", "")
            claims = parse_jwt_claims(id_token) || %{}
            auth_claims = get_in(claims, ["https://api.openai.com/auth"]) || %{}
            account_id = Map.get(auth_claims, "chatgpt_account_id", "")

            final_tokens =
              token_data
              |> Map.put("account_id", account_id)
              |> Map.put_new("api_key", Map.get(token_data, "access_token"))

            success_url =
              "http://localhost:" <> Integer.to_string(@config.required_port) <> "/success"

            respond_redirect(sock, success_url)
            send(parent, {:auth_success, final_tokens})

          {:error, reason} ->
            respond_html(
              sock,
              500,
              OAuthHtml.failure_html("ChatGPT", "Token exchange failed: " <> inspect(reason))
            )

            send(parent, {:auth_error, reason})
        end

      _ ->
        respond_html(sock, 400, OAuthHtml.failure_html("ChatGPT", "Missing auth code"))
        send(parent, {:auth_error, :missing_code})
    end
  end

  defp parse_http_request(request) do
    case String.split(request, "
", parts: 2) do
      [first_line | _] ->
        case String.split(String.trim(first_line), " ") do
          [_method, full_path, _version] ->
            %{path: path, query: query} = URI.parse(full_path)
            {:ok, path, query || ""}

          _ ->
            {:error, :malformed}
        end

      _ ->
        {:error, :malformed}
    end
  end

  defp respond_html(sock, status, body) do
    reason =
      case status do
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        500 -> "Internal Server Error"
        _ -> "Unknown"
      end

    header = "HTTP/1.1 " <> Integer.to_string(status) <> " " <> reason
    cl = Integer.to_string(byte_size(body))
    response = header <> "
content-type: text/html; charset=utf-8
content-length: " <> cl <> "
connection: close

" <> body
    :gen_tcp.send(sock, response)
  end

  defp respond_redirect(sock, url) do
    response = "HTTP/1.1 302 Found
location: " <> url <> "
content-length: 0
connection: close

"
    :gen_tcp.send(sock, response)
  end

  defp wait_for_callback(_server_ref, timeout_secs) do
    receive do
      {:auth_success, tokens} -> {:ok, tokens}
      {:auth_error, reason} -> {:error, reason}
      :auth_displayed -> wait_for_callback(nil, timeout_secs)
    after
      timeout_secs * 1_000 -> {:error, :timeout}
    end
  end

  defp register_models(api_key, account_id) do
    Logger.info("Registering ChatGPT Codex models...")
    models = fetch_chatgpt_models(api_key, account_id)

    case add_models_to_extra_config(models) do
      :ok -> Logger.info("ChatGPT models registered. Use the chatgpt- prefix in /model.")
      {:error, reason} -> Logger.warning("Failed to register models: " <> inspect(reason))
    end
  end

  defp compute_code_challenge(code_verifier) do
    :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)
  end

  defp context_expired?(context), do: System.system_time(:second) > context.expires_at

  defp token_expired?(access_token) do
    case parse_jwt_claims(access_token) do
      %{"exp" => exp} when is_number(exp) -> System.system_time(:second) > exp - 30
      _ -> false
    end
  end

  defp strip_prefix(name) do
    prefix_len = String.length(@config.prefix)

    if String.starts_with?(name, @config.prefix),
      do: String.slice(name, prefix_len..-1//1),
      else: name
  end

  defp ensure_required_models(models) do
    existing = MapSet.new(models)
    missing = Enum.filter(@required_codex_models, &(not MapSet.member?(existing, &1)))
    missing ++ models
  end

  defp user_agent_string do
    {os_type, os_name} = :os.type()
    os_str = if os_type == :unix and os_name == :darwin, do: "Mac OS", else: to_string(os_name)
    arch = to_string(:erlang.system_info(:system_architecture))

    @config.originator <>
      "/" <> @config.client_version <> " (" <> os_str <> "; " <> arch <> ") Terminal_Codex_CLI"
  end

  defp unrecoverable_error?(%{"error" => error_code} = data) when is_binary(error_code) do
    lower = String.downcase(error_code)

    if MapSet.member?(@unrecoverable_oauth_errors, lower) do
      true
    else
      desc = String.downcase(Map.get(data, "error_description", ""))
      Enum.any?(@unrecoverable_error_phrases, &String.contains?(desc, &1))
    end
  end

  defp unrecoverable_error?(%{"error" => %{"code" => code} = nested}) when is_binary(code) do
    lower = String.downcase(code)

    if MapSet.member?(@unrecoverable_oauth_errors, lower) do
      true
    else
      msg = String.downcase(Map.get(nested, "message", ""))
      Enum.any?(@unrecoverable_error_phrases, &String.contains?(msg, &1))
    end
  end

  defp unrecoverable_error?(_), do: false

  defp http_post(url, payload, headers) do
    body = URI.encode_query(payload)
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, :http_client_pool, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :json_decode_error}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, decoded} -> {:ok, Map.put(decoded, :status, status)}
          {:error, _} -> {:error, %{status: status, body: resp_body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp http_get(url, headers, params) do
    full_url = url <> "?" <> URI.encode_query(params)
    request = Finch.build(:get, full_url, headers)

    case Finch.request(request, :http_client_pool, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, _} -> {:error, :json_decode_error}
        end

      {:ok, %Finch.Response{}} ->
        {:error, :api_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
end
