defmodule CodePuppyControl.LLM.ProviderTest do
  @moduledoc """
  Tests for Provider behaviour compliance.

  Verifies that OpenAI and Anthropic providers implement all required callbacks
  and conform to the expected interface.

  Also tests contract validation patterns ported from Python (G37–G44):
  - Interface compliance (valid, missing callbacks, non-callable)
  - Model config validation (valid, missing fields)
  - ContractViolation exception attributes
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.LLM.Provider
  alias CodePuppyControl.LLM.Providers.{OpenAI, Anthropic}
  alias CodePuppyControl.Test.ProviderContract
  alias CodePuppyControl.Test.ContractViolation

  # ── Test-Only Provider Modules ──────────────────────────────────────────

  # A valid provider that implements every Provider callback.
  defmodule ValidProvider do
    @behaviour Provider

    @impl Provider
    def chat(_messages, _tools, _opts), do: {:ok, %{}}

    @impl Provider
    def stream_chat(_messages, _tools, _opts, _callback), do: :ok

    @impl Provider
    def supports_tools?, do: true

    @impl Provider
    def supports_vision?, do: true
  end

  # A provider missing chat/3 entirely.
  defmodule MissingChatProvider do
    def stream_chat(_messages, _tools, _opts, _callback), do: :ok
    def supports_tools?, do: true
    def supports_vision?, do: true
  end

  # A provider missing supports_tools?/0.
  defmodule MissingAvailabilityProvider do
    def chat(_messages, _tools, _opts), do: {:ok, %{}}
    def stream_chat(_messages, _tools, _opts, _callback), do: :ok
    def supports_vision?, do: true
  end

  # A provider with chat/1 instead of chat/3 — wrong arity is the
  # Elixir equivalent of Python's "not callable" edge-case.
  defmodule NonCallableProvider do
    def chat(_msg), do: :ok
    def stream_chat(_messages, _tools, _opts, _callback), do: :ok
    def supports_tools?, do: true
    def supports_vision?, do: true
  end

  describe "behaviour callbacks" do
    test "OpenAI implements all Provider callbacks" do
      assert {:module, OpenAI} = Code.ensure_loaded(OpenAI)
      assert function_exported?(OpenAI, :chat, 3)
      assert function_exported?(OpenAI, :stream_chat, 4)
      assert function_exported?(OpenAI, :supports_tools?, 0)
      assert function_exported?(OpenAI, :supports_vision?, 0)
    end

    test "Anthropic implements all Provider callbacks" do
      assert {:module, Anthropic} = Code.ensure_loaded(Anthropic)
      assert function_exported?(Anthropic, :chat, 3)
      assert function_exported?(Anthropic, :stream_chat, 4)
      assert function_exported?(Anthropic, :supports_tools?, 0)
      assert function_exported?(Anthropic, :supports_vision?, 0)
    end

    test "both providers declare @behaviour Provider" do
      # Check that the modules have the behaviour attribute
      openai_behaviours =
        OpenAI.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Provider in openai_behaviours

      anthropic_behaviours =
        Anthropic.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Provider in anthropic_behaviours
    end
  end

  describe "supports_tools?/0" do
    test "OpenAI supports tools" do
      assert OpenAI.supports_tools?() == true
    end

    test "Anthropic supports tools" do
      assert Anthropic.supports_tools?() == true
    end
  end

  describe "supports_vision?/0" do
    test "OpenAI supports vision" do
      assert OpenAI.supports_vision?() == true
    end

    test "Anthropic supports vision" do
      assert Anthropic.supports_vision?() == true
    end
  end

  describe "type specs" do
    test "Provider.message type exists" do
      # Verify the types are defined by checking the module doc
      {:docs_v1, _, _, _, _, _, _} = Code.fetch_docs(Provider)
    end
  end

  # ── Contract Validation Tests (G37–G44) ──────────────────────────────

  describe "provider interface validation" do
    test "valid provider passes validation (G37)" do
      assert :ok = ProviderContract.validate_provider_interface(ValidProvider, "valid")
    end

    test "missing chat callback fails validation (G38)" do
      assert_raise ContractViolation, ~r/chat/, fn ->
        ProviderContract.validate_provider_interface(MissingChatProvider, "bad")
      end
    end

    test "missing supports_tools? callback fails validation (G39)" do
      assert_raise ContractViolation, ~r/supports_tools/, fn ->
        ProviderContract.validate_provider_interface(MissingAvailabilityProvider, "bad")
      end
    end

    test "non-callable (wrong arity) callback fails validation (G40)" do
      error =
        assert_raise ContractViolation, fn ->
          ProviderContract.validate_provider_interface(NonCallableProvider, "bad")
        end

      assert error.issue =~ "not callable"
    end
  end

  describe "model config validation" do
    test "valid config passes validation (G41)" do
      config = %{"model_name" => "gpt-4", "provider" => "openai", "temperature" => 0.7}

      assert :ok = ProviderContract.validate_model_config(config, "openai")
    end

    test "missing model_name fails validation (G42)" do
      config = %{"provider" => "openai"}

      assert_raise ContractViolation, ~r/model_name/, fn ->
        ProviderContract.validate_model_config(config, "openai")
      end
    end

    test "missing provider fails validation (G43)" do
      config = %{"model_name" => "gpt-4"}

      assert_raise ContractViolation, ~r/provider/, fn ->
        ProviderContract.validate_model_config(config, "openai")
      end
    end
  end

  describe "ContractViolation exception" do
    test "exception has correct attributes (G44)" do
      violation =
        assert_raise ContractViolation, fn ->
          raise ContractViolation,
            component: "test:component",
            issue: "Something went wrong",
            details: %{detail: "info"}
        end

      assert violation.component == "test:component"
      assert violation.issue == "Something went wrong"
      assert violation.details == %{detail: "info"}
    end

    test "exception message includes component and issue (G44)" do
      violation =
        assert_raise ContractViolation, fn ->
          raise ContractViolation,
            component: "test:component",
            issue: "Something went wrong"
        end

      message = Exception.message(violation)
      assert message =~ "test:component"
      assert message =~ "Something went wrong"
    end

    test "exception details default to empty map" do
      violation =
        assert_raise ContractViolation, fn ->
          raise ContractViolation,
            component: "x",
            issue: "y"
        end

      assert violation.details == %{}
    end
  end
end
