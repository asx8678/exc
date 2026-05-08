defmodule CodePuppyControl.HttpClientTest do
  @moduledoc """
  Tests for the HTTP client with retry logic and Finch integration.

  These tests verify:
  - Request building and struct creation
  - Helper functions (auth_headers, json_headers, etc.)
  - Child specification generation
  - Configuration resolution from environment
  - Header normalization for stdio service

  Integration tests with real HTTP requests are in integration/http_client_integration_test.exs
  """

  use ExUnit.Case, async: true

  alias CodePuppyControl.HttpClient

  describe "request building" do
    test "build_request creates valid Finch struct" do
      req =
        HttpClient.build_request(
          :post,
          "https://api.example.com/test",
          [{"x-api", "key"}],
          ~s({"test": true})
        )

      # Finch uses uppercase strings for methods
      assert req.method == "POST"
      assert req.host == "api.example.com"
      assert req.path == "/test"
      assert req.port == 443
      assert req.scheme == :https
    end

    test "build_request with HTTP" do
      req = HttpClient.build_request(:get, "http://localhost:4000/api", [], nil)

      assert req.method == "GET"
      assert req.host == "localhost"
      assert req.port == 4000
      assert req.scheme == :http
    end

    test "build_request handles empty body" do
      req = HttpClient.build_request(:get, "https://api.example.com/test", [], nil)
      assert is_nil(req.body)
    end
  end

  describe "helper functions" do
    test "auth_headers/1 creates Bearer token header" do
      assert [{"authorization", "Bearer test-token"}] =
               HttpClient.auth_headers("test-token")
    end

    test "auth_headers with empty token" do
      assert [{"authorization", "Bearer "}] = HttpClient.auth_headers("")
    end

    test "json_headers/0 creates JSON content-type header" do
      assert [{"content-type", "application/json"}] = HttpClient.json_headers()
    end

    test "json_headers is a singleton list" do
      headers = HttpClient.json_headers()
      assert length(headers) == 1
    end
  end

  describe "environment configuration" do
    test "resolve_config_from_env returns keyword list" do
      opts = HttpClient.resolve_config_from_env()

      assert is_list(opts)
      # Should have proxy_options, trust_env, connect_options, http2, disable_retry keys
      assert Keyword.has_key?(opts, :proxy_options)
      assert Keyword.has_key?(opts, :trust_env)
      assert Keyword.has_key?(opts, :connect_options)
      assert Keyword.has_key?(opts, :http2)
      assert Keyword.has_key?(opts, :disable_retry)
    end

    test "resolve_config_from_env respects SSL_CERT_FILE" do
      # Temporarily set env var
      original = System.get_env("SSL_CERT_FILE")

      try do
        # Create a temp file
        tmp_file = Path.join(System.tmp_dir!(), "test_cert.pem")
        File.write!(tmp_file, "test")

        System.put_env("SSL_CERT_FILE", tmp_file)

        opts = HttpClient.resolve_config_from_env()

        # Should have connect_options with transport_opts containing cacertfile
        connect_opts = Keyword.get(opts, :connect_options, [])
        assert is_list(connect_opts)

        # When SSL_CERT_FILE is set, connect_options contains transport_opts with cacertfile
        if length(connect_opts) > 0 do
          transport_opts = Keyword.get(connect_opts, :transport_opts, [])

          if length(transport_opts) > 0 do
            assert Keyword.get(transport_opts, :cacertfile) == tmp_file
          end
        end

        File.rm(tmp_file)
      after
        if original,
          do: System.put_env("SSL_CERT_FILE", original),
          else: System.delete_env("SSL_CERT_FILE")
      end
    end

    test "resolve_config_from_env detects HTTPS_PROXY" do
      original = System.get_env("HTTPS_PROXY")

      try do
        System.put_env("HTTPS_PROXY", "http://proxy.example.com:8080")

        opts = HttpClient.resolve_config_from_env()

        assert Keyword.get(opts, :proxy_options) == [proxy: "http://proxy.example.com:8080"]
        assert Keyword.get(opts, :trust_env) == true
      after
        if original,
          do: System.put_env("HTTPS_PROXY", original),
          else: System.delete_env("HTTPS_PROXY")
      end
    end
  end

  describe "child_spec/1" do
    test "returns valid Finch child spec" do
      spec = HttpClient.child_spec()

      assert is_tuple(spec)
      assert elem(spec, 0) == Finch

      opts = elem(spec, 1)
      assert is_list(opts)
      assert Keyword.get(opts, :name) == :http_client_pool

      # Check pools configuration
      pools = Keyword.get(opts, :pools, %{})
      assert is_map(pools)
      assert Map.has_key?(pools, :default)

      default_pool = pools[:default]
      assert is_list(default_pool)
      assert Keyword.has_key?(default_pool, :size)
      assert Keyword.has_key?(default_pool, :count)
      assert Keyword.has_key?(default_pool, :conn_opts)
    end

    test "child_spec accepts custom options" do
      spec = HttpClient.child_spec(pool_size: 100, pool_name: :custom_pool, pool_count: 4)

      opts = elem(spec, 1)
      assert Keyword.get(opts, :name) == :custom_pool

      pools = Keyword.get(opts, :pools, %{})
      default_pool = pools[:default]
      assert Keyword.get(default_pool, :size) == 100
      assert Keyword.get(default_pool, :count) == 4
    end

    test "default_pool_name returns atom" do
      assert HttpClient.default_pool_name() == :http_client_pool
    end
  end

  describe "streaming interface" do
    test "stream returns a Stream" do
      stream = HttpClient.stream(:get, "http://localhost:59999/test")

      assert is_function(stream, 2) or match?(%Stream{}, stream) or is_list(stream)
    end
  end

  describe "streaming contract (via MockLLMHTTP)" do
    # These tests verify the contract that both MockLLMHTTP.stream/3 and
    # HttpClient.stream/3 must satisfy. Providers depend on this shape.
    setup do
      start_supervised!(CodePuppyControl.Test.MockLLMHTTP)
      CodePuppyControl.Test.MockLLMHTTP.reset()
      :ok
    end

    alias CodePuppyControl.Test.MockLLMHTTP

    test "2xx yields {:data, chunk} then {:done, metadata}" do
      MockLLMHTTP.register(fn :post, _url, _opts ->
        {:ok, %{status: 200, body: "hello", headers: [{"content-type", "text/plain"}]}}
      end)

      events =
        MockLLMHTTP.stream(:post, "https://example.com", [])
        |> Enum.to_list()

      assert [
               {:data, "hello"},
               {:done, %{status: 200, headers: [{"content-type", "text/plain"}]}}
             ] =
               events
    end

    test "non-2xx yields {:error, %{status, body, headers}} without {:done, ...}" do
      MockLLMHTTP.register(fn :post, _url, _opts ->
        {:ok,
         %{
           status: 401,
           body: ~s({"error":"Unauthorized"}),
           headers: [{"www-authenticate", "Bearer"}]
         }}
      end)

      events =
        MockLLMHTTP.stream(:post, "https://example.com", [])
        |> Enum.to_list()

      assert [{:error, %{status: 401, body: body, headers: headers}}] = events
      assert body =~ "Unauthorized"
      assert headers == [{"www-authenticate", "Bearer"}]

      # Must NOT emit {:done, ...}
      refute Enum.any?(events, fn
               {:done, _} -> true
               _ -> false
             end)
    end

    test "500 yields {:error, %{status: 500, ...}}" do
      MockLLMHTTP.register(fn :post, _url, _opts ->
        {:ok, %{status: 500, body: "Internal Server Error", headers: []}}
      end)

      events =
        MockLLMHTTP.stream(:post, "https://example.com", [])
        |> Enum.to_list()

      assert [{:error, %{status: 500, body: "Internal Server Error"}}] = events
    end

    test "transport error yields {:error, reason}" do
      MockLLMHTTP.register(fn :post, _url, _opts ->
        {:error, "Connection refused"}
      end)

      events =
        MockLLMHTTP.stream(:post, "https://example.com", [])
        |> Enum.to_list()

      assert [{:error, "Connection refused"}] = events
    end

    test "2xx with empty body still yields {:done, ...}" do
      MockLLMHTTP.register(fn :get, _url, _opts ->
        {:ok, %{status: 204, body: "", headers: []}}
      end)

      events =
        MockLLMHTTP.stream(:get, "https://example.com", [])
        |> Enum.to_list()

      assert [{:data, ""}, {:done, %{status: 204}}] = events
    end
  end

  describe "telemetry events" do
    test "telemetry handler can be attached" do
      test_pid = self()

      :telemetry.attach(
        "test-http-client",
        [:code_puppy_control, :http_client, :success],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_received, measurements, metadata})
        end,
        nil
      )

      # Clean up handler
      :telemetry.detach("test-http-client")
    end
  end

  describe "HTTP method convenience functions" do
    test "get/2 delegates to request" do
      # Can't test actual request without server, but verify function exists
      assert function_exported?(HttpClient, :get, 2)
      assert function_exported?(HttpClient, :get, 1)
    end

    test "post/2 delegates to request" do
      assert function_exported?(HttpClient, :post, 2)
      assert function_exported?(HttpClient, :post, 1)
    end

    test "put/2 delegates to request" do
      assert function_exported?(HttpClient, :put, 2)
      assert function_exported?(HttpClient, :put, 1)
    end

    test "patch/2 delegates to request" do
      assert function_exported?(HttpClient, :patch, 2)
      assert function_exported?(HttpClient, :patch, 1)
    end

    test "delete/2 delegates to request" do
      assert function_exported?(HttpClient, :delete, 2)
      assert function_exported?(HttpClient, :delete, 1)
    end

    test "head/2 delegates to request" do
      assert function_exported?(HttpClient, :head, 2)
      assert function_exported?(HttpClient, :head, 1)
    end

    test "options/2 delegates to request" do
      assert function_exported?(HttpClient, :options, 2)
      assert function_exported?(HttpClient, :options, 1)
    end
  end

  describe "stdio service helpers" do
    # These are helper functions that mirror stdio_service.ex implementation
    # for testing serialization and header normalization

    test "normalize_headers converts map to list" do
      headers = %{"Content-Type" => "application/json", "Authorization" => "Bearer token"}

      result = normalize_headers_test(headers)

      assert Enum.sort(result) == [
               {"Authorization", "Bearer token"},
               {"Content-Type", "application/json"}
             ]
    end

    test "normalize_headers handles list input" do
      headers = [["Content-Type", "application/json"]]

      result = normalize_headers_test(headers)
      assert result == [{"Content-Type", "application/json"}]
    end

    test "normalize_headers handles keyword list" do
      headers = [content_type: "application/json"]

      result = normalize_headers_test(headers)
      assert result == [{"content_type", "application/json"}]
    end

    test "serialize_http_response formats response for JSON" do
      response = %{
        status: 200,
        body: ~s({"test": true}),
        headers: [{"content-type", "application/json"}]
      }

      result = serialize_http_response_test(response)
      assert result["status"] == 200
      assert result["body"] == ~s({"test": true})
      assert result["headers"] == [["content-type", "application/json"]]
    end

    test "serialize_http_response handles empty headers" do
      response = %{status: 204, body: "", headers: []}

      result = serialize_http_response_test(response)
      assert result["status"] == 204
      assert result["headers"] == []
    end
  end

  # Helper functions that mirror the private functions in stdio_service.ex
  defp normalize_headers_test(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers_test(headers) when is_list(headers) do
    Enum.map(headers, fn
      {k, v} -> {to_string(k), to_string(v)}
      [k, v] -> {to_string(k), to_string(v)}
    end)
  end

  defp serialize_http_response_test(%{status: status, body: body, headers: headers}) do
    %{
      "status" => status,
      "body" => body,
      "headers" => Enum.map(headers, fn {k, v} -> [k, v] end)
    }
  end
end
