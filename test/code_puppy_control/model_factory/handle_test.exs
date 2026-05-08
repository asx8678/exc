defmodule CodePuppyControl.ModelFactory.HandleTest do
  use ExUnit.Case, async: true

  alias CodePuppyControl.ModelFactory.Handle
  alias CodePuppyControl.LLM.Providers.OpenAI

  describe "struct creation" do
    test "creates a handle with required fields" do
      handle = %Handle{
        model_name: "gpt-4o",
        provider_module: OpenAI,
        provider_config: %{"type" => "openai", "name" => "gpt-4o"}
      }

      assert handle.model_name == "gpt-4o"
      assert handle.provider_module == OpenAI
      assert handle.provider_config["type"] == "openai"
    end

    test "defaults optional fields" do
      handle = %Handle{
        model_name: "test",
        provider_module: OpenAI,
        provider_config: %{}
      }

      assert handle.api_key == nil
      assert handle.base_url == nil
      assert handle.extra_headers == []
      assert handle.model_opts == []
      assert handle.role_config == nil
    end

    test "enforces required keys" do
      assert_raise ArgumentError, ~r/must also be given when building struct/, fn ->
        struct!(Handle, %{})
      end
    end
  end

  describe "to_provider_opts/1" do
    test "includes api_key when present" do
      handle = %Handle{
        model_name: "gpt-4o",
        provider_module: OpenAI,
        provider_config: %{},
        api_key: "sk-test123"
      }

      opts = Handle.to_provider_opts(handle)
      assert opts[:api_key] == "sk-test123"
    end

    test "includes base_url when present" do
      handle = %Handle{
        model_name: "gpt-4o",
        provider_module: OpenAI,
        provider_config: %{},
        base_url: "https://custom.api.com"
      }

      opts = Handle.to_provider_opts(handle)
      assert opts[:base_url] == "https://custom.api.com"
    end

    test "merges model_opts" do
      handle = %Handle{
        model_name: "gpt-4o",
        provider_module: OpenAI,
        provider_config: %{},
        model_opts: [model: "gpt-4o", temperature: 0.7]
      }

      opts = Handle.to_provider_opts(handle)
      assert opts[:model] == "gpt-4o"
      assert opts[:temperature] == 0.7
    end

    test "does not include nil api_key or base_url" do
      handle = %Handle{
        model_name: "gpt-4o",
        provider_module: OpenAI,
        provider_config: %{}
      }

      opts = Handle.to_provider_opts(handle)
      refute Keyword.has_key?(opts, :api_key)
      refute Keyword.has_key?(opts, :base_url)
    end

    test "full handle produces complete opts" do
      handle = %Handle{
        model_name: "custom-model",
        provider_module: OpenAI,
        provider_config: %{"type" => "custom_openai"},
        api_key: "sk-key",
        base_url: "https://my-proxy.com",
        extra_headers: [{"x-custom", "value"}],
        model_opts: [model: "gpt-4", max_tokens: 1000]
      }

      opts = Handle.to_provider_opts(handle)
      assert opts[:api_key] == "sk-key"
      assert opts[:base_url] == "https://my-proxy.com"
      assert opts[:model] == "gpt-4"
      assert opts[:max_tokens] == 1000
      assert opts[:extra_headers] == [{"x-custom", "value"}]
    end

    test "includes extra_headers when present" do
      handle = %Handle{
        model_name: "custom-model",
        provider_module: OpenAI,
        provider_config: %{},
        extra_headers: [{"x-api-source", "custom"}, {"x-trace-id", "abc123"}]
      }

      opts = Handle.to_provider_opts(handle)
      assert opts[:extra_headers] == [{"x-api-source", "custom"}, {"x-trace-id", "abc123"}]
    end

    test "does not include empty extra_headers" do
      handle = %Handle{
        model_name: "test",
        provider_module: OpenAI,
        provider_config: %{}
      }

      opts = Handle.to_provider_opts(handle)
      refute Keyword.has_key?(opts, :extra_headers)
    end
  end
end
