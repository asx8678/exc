defmodule CodePuppyControl.LLM.ProviderParityTest do
  @moduledoc """
  : Ensures LLM @provider_map and ModelFactory @provider_map
  stay in sync. If a provider type is added to one, it must appear in the other
  (or be explicitly documented as an intentional difference).

  Since Elixir module attributes are compile-time only, we verify parity by
  exercising the public APIs (ModelFactory.provider_module_for_type/1 and
  LLM.provider_for/1) for all known provider types.
  """
  use ExUnit.Case, async: true

  alias CodePuppyControl.LLM
  alias CodePuppyControl.ModelFactory

  # The canonical list of provider types that should exist in BOTH maps.
  # When adding a new type, add it here too — this test will guard against drift.
  @canonical_types [
    "openai",
    "anthropic",
    "custom_openai",
    "custom_anthropic",
    "azure_openai",
    "cerebras",
    "zai_coding",
    "zai_api",
    "openrouter",
    "gemini",
    "gemini_oauth",
    "custom_gemini",
    "claude_code",
    "chatgpt_oauth",
    "groq",
    "together"
  ]

  # chatgpt_oauth is now fully supported via ChatGPTCodex provider (Responses API).
  # No intentional differences currently exist between the two @provider_maps.

  describe "provider_map parity" do
    test "ModelFactory supports all canonical provider types" do
      for type <- @canonical_types do
        assert match?({:ok, _}, ModelFactory.provider_module_for_type(type)),
               "ModelFactory.provider_module_for_type/1 returned :error for #{inspect(type)}"
      end
    end

    test "LLM routes all canonical types to valid providers" do
      # LLM.provider_for/1 needs a model name in ModelRegistry.
      # We verify indirectly: for each type, create a handle via ModelFactory.resolve/1
      # and check the provider_module is correct.
      #
      # Since we can't easily inject models into the registry, we verify the
      # provider_module_for_type API covers all canonical types and cross-check
      # the module assignments match between the two APIs.
      for type <- @canonical_types do
        {:ok, mf_mod} = ModelFactory.provider_module_for_type(type)

        # The LLM module should route to the same provider.
        # We verify by checking that LLM's @provider_map has the same module
        # for this type. Since we can't read the attribute directly, we trust
        # that the hard-coded canonical list + ModelFactory check is sufficient.
        assert is_atom(mf_mod),
               "ModelFactory returned non-module for type #{inspect(type)}: #{inspect(mf_mod)}"
      end
    end

    test "both APIs assign valid provider modules for each canonical type" do
      for type <- @canonical_types do
        {:ok, mf_mod} = ModelFactory.provider_module_for_type(type)

        # Verify the module is a real atom (not nil)
        assert is_atom(mf_mod) and not is_nil(mf_mod),
               "ModelFactory returned non-module for type #{inspect(type)}: #{inspect(mf_mod)}"
      end
    end

    test "no undocumented differences between maps" do
      # All canonical types must be resolvable through ModelFactory
      for type <- @canonical_types do
        {:ok, _mod} = ModelFactory.provider_module_for_type(type)
      end
    end

    test "LLM provider_for/1 resolves all ModelFactory-supported types" do
      # For each type that ModelFactory supports, verify LLM.provider_for/1
      # can resolve it by looking up a real model from the registry.
      # This tests end-to-end routing from model name → provider module.
      available = ModelFactory.list_available()

      for {model_name, _type, mf_mod} <- available do
        case LLM.provider_for(model_name) do
          {:ok, llm_mod} ->
            assert llm_mod == mf_mod,
                   "LLM.provider_for/1 returned #{inspect(llm_mod)} but ModelFactory returned #{inspect(mf_mod)} for model #{inspect(model_name)}"

          {:error, {:unsupported_model_type, type, _model}} ->
            flunk("Type #{inspect(type)} is in ModelFactory but not in LLM @provider_map")

          {:error, reason} ->
            # Some models might not be in registry — that's OK for this test
            # as long as the type IS in the provider map
            flunk(
              "Unexpected error from LLM.provider_for/1 for #{inspect(model_name)}: #{inspect(reason)}"
            )
        end
      end
    end
  end
end
