defmodule CodePuppyControl.HttpClient.Config do
  @moduledoc """
  Configuration and utility functions for the HTTP client.

  This module handles:
  - Finch pool child_spec for supervision trees
  - Environment variable resolution (proxy, SSL, HTTP/2 settings)
  - Header helpers for authentication and JSON content-type

  ## Environment Variables

  | Variable | Description | Default |
  |----------|-------------|---------|
  | `SSL_CERT_FILE` | Path to SSL certificate bundle | System default |
  | `HTTPS_PROXY` / `https_proxy` | HTTPS proxy URL | nil |
  | `HTTP_PROXY` / `http_proxy` | HTTP proxy URL | nil |
  | `PUP_HTTP2` | Enable HTTP/2 ("true"/"false") | "true" |
  | `PUP_DISABLE_RETRY_TRANSPORT` | Disable retry logic | "false" |
  """

  @default_pool_name :http_client_pool

  @doc """
  Child specification for starting the Finch pool in the supervision tree.

  Returns a supervisor child spec that can be added to the application's
  supervision tree.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    pool_name = Keyword.get(opts, :pool_name, @default_pool_name)
    pool_size = Keyword.get(opts, :pool_size, CodePuppyControl.Runtime.Limits.finch_pool_size())

    pool_count =
      Keyword.get(opts, :pool_count, CodePuppyControl.Runtime.Limits.finch_pool_count())

    {Finch,
     name: pool_name,
     pools: %{
       :default => [
         size: pool_size,
         count: pool_count,
         conn_opts: [
           connect_options: [
             transport_opts: [
               # Allow TLS 1.2 and 1.3
               versions: [:"tlsv1.2", :"tlsv1.3"]
             ]
           ]
         ]
       ]
     }}
  end

  @doc """
  Returns the default pool name used by this module.
  """
  @spec default_pool_name() :: atom()
  def default_pool_name, do: @default_pool_name

  @doc """
  Creates authorization headers for Bearer token authentication.
  """
  @spec auth_headers(String.t()) :: [{String.t(), String.t()}]
  def auth_headers(token), do: [{"authorization", "Bearer #{token}"}]

  @doc """
  Creates JSON content-type headers.
  """
  @spec json_headers() :: [{String.t(), String.t()}]
  def json_headers, do: [{"content-type", "application/json"}]

  @doc """
  Resolves proxy and SSL configuration from environment variables.

  Returns options suitable for passing to `HttpClient.request/3` or building custom requests.
  """
  @spec resolve_config_from_env() :: keyword()
  def resolve_config_from_env do
    # SSL cert file handling
    ssl_cert_file = System.get_env("SSL_CERT_FILE")

    verify_opts =
      if ssl_cert_file && File.exists?(ssl_cert_file) do
        [transport_opts: [cacertfile: ssl_cert_file]]
      else
        []
      end

    # Proxy detection (same env var names as Python)
    proxy_url =
      System.get_env("HTTPS_PROXY") ||
        System.get_env("https_proxy") ||
        System.get_env("HTTP_PROXY") ||
        System.get_env("http_proxy")

    # HTTP/2 detection (from config, defaults to true)
    http2_enabled =
      case System.get_env("PUP_HTTP2", "true") do
        "false" -> false
        "0" -> false
        _ -> true
      end

    # Retry transport toggle
    disable_retry = System.get_env("PUP_DISABLE_RETRY_TRANSPORT") in ["1", "true"]

    trust_env? = proxy_url != nil

    base =
      if verify_opts != [] do
        [connect_options: verify_opts]
      else
        []
      end

    proxy_opts = if proxy_url, do: [proxy: proxy_url], else: []

    [
      connect_options: base,
      proxy_options: proxy_opts,
      trust_env: trust_env?,
      http2: http2_enabled,
      disable_retry: disable_retry
    ]
  end
end
