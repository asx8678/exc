defmodule CodePuppyControl.Auth.ClaudeOAuth.Flow do
  @moduledoc """
  Claude Code OAuth flow implementation.

  Handles the full PKCE-based OAuth2 authorization code flow:
  context generation, localhost callback server, browser launch,
  code exchange, token persistence, and model registration.

  This module is a submodule of `CodePuppyControl.Auth.ClaudeOAuth`
  and delegates config/token/model operations to it.
  """

  require Logger

  alias CodePuppyControl.Auth.ClaudeOAuth
  alias CodePuppyControl.Auth.{BrowserHelper, OAuthHtml}

  @type oauth_context :: %{
          state: String.t(),
          code_verifier: String.t(),
          code_challenge: String.t(),
          redirect_uri: String.t() | nil,
          created_at: integer()
        }

  @spec run_oauth_flow() :: :ok | {:error, term()}
  def run_oauth_flow do
    existing = ClaudeOAuth.load_tokens()

    if existing != {:error, :not_found} do
      case existing do
        {:ok, %{"access_token" => _}} ->
          Logger.warning("Existing Claude Code tokens found. Continuing will overwrite them.")

        _ ->
          :ok
      end
    end

    context = prepare_oauth_context()

    case start_callback_server(context) do
      {:ok, port, server_ref} ->
        context = %{context | redirect_uri: redirect_uri(port)}
        auth_url = build_authorization_url(context)

        Logger.info("Open this URL in your browser: #{auth_url}")
        BrowserHelper.open_url(auth_url)
        Logger.info("Listening for callback on #{context.redirect_uri}")

        Logger.info(
          "If Claude redirects you to the console callback page, copy the full URL and paste it back into Code Puppy."
        )

        case wait_for_callback(server_ref, ClaudeOAuth.config(:callback_timeout)) do
          {:ok, code, received_state} ->
            if received_state != context.state do
              Logger.error("State mismatch detected; aborting authentication.")
              {:error, :state_mismatch}
            else
              exchange_and_register(code, context)
            end

          {:error, reason} ->
            Logger.error("OAuth callback failed: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Could not start OAuth callback server: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec get_valid_access_token() :: {:ok, String.t()} | {:error, term()}
  def get_valid_access_token do
    case ClaudeOAuth.load_tokens() do
      {:ok, tokens} ->
        access_token = tokens["access_token"]

        cond do
          access_token in [nil, ""] ->
            {:error, :no_access_token}

          ClaudeOAuth.token_expired?(tokens) ->
            case refresh_access_token() do
              {:ok, new_token} ->
                {:ok, new_token}

              {:error, _} = err ->
                if not ClaudeOAuth.token_actually_expired?(tokens) do
                  Logger.debug("Refresh failed; using existing token until expiry")
                  {:ok, access_token}
                else
                  err
                end
            end

          true ->
            {:ok, access_token}
        end

      {:error, :not_found} ->
        {:error, :not_authenticated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec refresh_access_token() :: {:ok, String.t()} | {:error, term()}
  def refresh_access_token do
    case ClaudeOAuth.load_tokens() do
      {:ok, %{"refresh_token" => refresh_token}}
      when is_binary(refresh_token) and refresh_token != "" ->
        do_refresh(refresh_token)

      {:ok, _} ->
        {:error, :no_refresh_token}

      {:error, _} = err ->
        err
    end
  end

  # PKCE + URL building

  defp prepare_oauth_context do
    state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    code_verifier = :crypto.strong_rand_bytes(64) |> Base.url_encode64(padding: false)
    code_challenge = :crypto.hash(:sha256, code_verifier) |> Base.url_encode64(padding: false)

    %{
      state: state,
      code_verifier: code_verifier,
      code_challenge: code_challenge,
      redirect_uri: nil,
      created_at: System.system_time(:second)
    }
  end

  defp redirect_uri(port) do
    host = String.trim_trailing(ClaudeOAuth.config(:redirect_host), "/")
    path = String.trim_leading(ClaudeOAuth.config(:redirect_path), "/")
    "#{host}:#{port}/#{path}"
  end

  defp build_authorization_url(context) do
    unless context.redirect_uri, do: raise("Redirect URI not assigned")

    params = %{
      "response_type" => "code",
      "client_id" => ClaudeOAuth.config(:client_id),
      "redirect_uri" => context.redirect_uri,
      "scope" => ClaudeOAuth.config(:scope),
      "state" => context.state,
      "code" => "true",
      "code_challenge" => context.code_challenge,
      "code_challenge_method" => "S256"
    }

    "#{ClaudeOAuth.config(:auth_url)}?#{URI.encode_query(params)}"
  end

  # Callback server

  defp start_callback_server(_context) do
    {lo, hi} = ClaudeOAuth.config(:callback_port_range)
    parent = self()

    Enum.find_value(lo..hi, {:error, :all_ports_in_use}, fn port ->
      case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true]) do
        {:ok, listen_sock} ->
          pid = spawn(fn -> serve_one(listen_sock, parent) end)
          {:ok, port, pid}

        {:error, :eaddrinuse} ->
          nil

        {:error, reason} ->
          Logger.warning("Port #{port} failed: #{inspect(reason)}")
          nil
      end
    end)
  end

  defp serve_one(listen_sock, parent) do
    case :gen_tcp.accept(listen_sock, ClaudeOAuth.config(:callback_timeout) * 1000) do
      {:ok, sock} ->
        :gen_tcp.close(listen_sock)

        case :gen_tcp.recv(sock, 0, 10_000) do
          {:ok, request} -> handle_callback_request(sock, request, parent)
          {:error, reason} -> send(parent, {:oauth_error, reason})
        end

        :gen_tcp.close(sock)

      {:error, reason} ->
        Logger.error("Callback accept failed: #{inspect(reason)}")
        send(parent, {:oauth_error, reason})
    end
  end

  defp handle_callback_request(sock, request, parent) do
    case parse_http_request(request) do
      {:ok, "/callback", query} ->
        handle_callback_query(sock, query, parent)

      {:ok, "/" <> _path, query} ->
        handle_callback_query(sock, query, parent)

      _ ->
        respond_html(sock, 404, "Not found")
        send(parent, {:oauth_error, :not_found})
    end
  end

  defp handle_callback_query(sock, query, parent) do
    case URI.decode_query(query) do
      %{"code" => code, "state" => state} ->
        html =
          OAuthHtml.success_html("Claude Code", "You are totally synced with Claude Code now!")

        respond_html(sock, 200, html)
        send(parent, {:oauth_code, code, state})

      %{"code" => code} ->
        html =
          OAuthHtml.success_html("Claude Code", "You are totally synced with Claude Code now!")

        respond_html(sock, 200, html)
        send(parent, {:oauth_code, code, ""})

      %{"error" => error} ->
        desc = Map.get(URI.decode_query(query), "error_description", error)
        html = OAuthHtml.failure_html("Claude Code", desc)
        respond_html(sock, 400, html)
        send(parent, {:oauth_error, desc})

      _ ->
        html = OAuthHtml.failure_html("Claude Code", "Missing code or state parameter")
        respond_html(sock, 400, html)
        send(parent, {:oauth_error, :missing_code})
    end
  end

  defp wait_for_callback(_server_ref, timeout_secs) do
    receive do
      {:oauth_code, code, state} -> {:ok, code, state}
      {:oauth_error, reason} -> {:error, reason}
    after
      timeout_secs * 1000 -> {:error, :timeout}
    end
  end

  # Token exchange

  defp exchange_and_register(code, context) do
    Logger.info("Exchanging authorization code for tokens...")

    case exchange_code_for_tokens(code, context) do
      {:ok, tokens} ->
        :ok = ClaudeOAuth.save_tokens(tokens)
        Logger.info("Claude Code OAuth authentication successful!")
        access_token = tokens["access_token"]

        if access_token do
          :ok = ClaudeOAuth.update_model_tokens(access_token)
          register_models(access_token)
        else
          Logger.warning("No access token returned; skipping model discovery.")
        end

        :ok

      {:error, reason} ->
        Logger.error("Token exchange failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp exchange_code_for_tokens(code, context) do
    unless context.redirect_uri, do: raise("Redirect URI missing")

    payload = %{
      "grant_type" => "authorization_code",
      "client_id" => ClaudeOAuth.config(:client_id),
      "code" => code,
      "state" => context.state,
      "code_verifier" => context.code_verifier,
      "redirect_uri" => context.redirect_uri
    }

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"anthropic-beta", "oauth-2025-04-20"}
    ]

    body = Jason.encode!(payload)

    case Finch.build(:post, ClaudeOAuth.config(:token_url), headers, body)
         |> Finch.request(:http_client_pool, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, token_data} when is_map(token_data) ->
            expires_in = token_data["expires_in"]
            expires_at = if expires_in, do: System.system_time(:second) + expires_in, else: nil
            {:ok, Map.put(token_data, "expires_at", expires_at)}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Refresh

  defp do_refresh(refresh_token) do
    payload = %{
      "grant_type" => "refresh_token",
      "client_id" => ClaudeOAuth.config(:client_id),
      "refresh_token" => refresh_token
    }

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"anthropic-beta", "oauth-2025-04-20"}
    ]

    case Finch.build(:post, ClaudeOAuth.config(:token_url), headers, Jason.encode!(payload))
         |> Finch.request(:http_client_pool, receive_timeout: 30_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(resp_body) do
          {:ok, new_tokens} when is_map(new_tokens) ->
            new_access = new_tokens["access_token"]
            {:ok, existing} = ClaudeOAuth.load_tokens()

            merged =
              existing
              |> Map.put("access_token", new_access)
              |> Map.put("refresh_token", Map.get(new_tokens, "refresh_token", refresh_token))
              |> Map.put("expires_in", Map.get(new_tokens, "expires_in", existing["expires_in"]))

            expires_in = merged["expires_in"]

            merged =
              Map.put(
                merged,
                "expires_at",
                if(expires_in, do: System.system_time(:second) + expires_in, else: nil)
              )

            :ok = ClaudeOAuth.save_tokens(merged)
            :ok = ClaudeOAuth.update_model_tokens(new_access)
            Logger.info("Successfully refreshed Claude Code OAuth token")
            {:ok, new_access}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:ok, %Finch.Response{status: 401}} ->
        Logger.warning("Unrecoverable token error - token may need re-authentication")
        {:error, :unrecoverable}

      {:ok, %Finch.Response{status: status}} when status >= 500 ->
        Logger.debug("Claude token refresh failed (transient)")
        {:error, :transient}

      {:ok, %Finch.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, _reason} ->
        Logger.debug("Claude token refresh connection error (transient)")
        {:error, :transient}
    end
  end

  # Model registration

  defp register_models(access_token) do
    Logger.info("Fetching available Claude Code models...")

    case ClaudeOAuth.fetch_models(access_token) do
      {:ok, models} ->
        Logger.info("Discovered #{length(models)} models")

        case ClaudeOAuth.add_models(models) do
          {:ok, _count} ->
            Logger.info("Claude Code models added. Use the claude-code- prefix!")

          {:error, reason} ->
            Logger.warning("Failed to register models: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to fetch models: #{inspect(reason)}")
    end
  end

  # HTTP helpers

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
        _ -> "Unknown"
      end

    cl = Integer.to_string(byte_size(body))

    response =
      "HTTP/1.1 #{status} #{reason}
" <>
        "content-type: text/html; charset=utf-8
" <>
        "content-length: #{cl}
" <>
        "connection: close
" <>
        "
" <> body

    :gen_tcp.send(sock, response)
  end
end
