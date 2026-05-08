defmodule CodePuppyControl.ModelFactory.Handle do
  @moduledoc """
  Resolved model handle — an opaque struct carrying everything needed
  to execute an LLM API call against a specific model.

  Created by `ModelFactory.resolve/1` from a model name. The handle
  bundles the provider module, credentials, endpoint, headers, and
  model-specific options into a single value that can be passed
  directly to `LLM.chat/2` or `LLM.stream_chat/3`.

  ## Fields

  - `model_name` — Original registry name (e.g. `"wafer-glm-5.1"`)
  - `provider_module` — The LLM provider module (e.g. `Providers.OpenAI`)
  - `provider_config` — The raw model config map from ModelRegistry
  - `api_key` — Resolved API key string (or `nil` for OAuth models)
  - `base_url` — API base URL (from config or provider default)
  - `extra_headers` — Additional HTTP headers (from custom endpoint config)
  - `model_opts` — Keyword list of model-specific options (`:model`, `:temperature`, etc.)
  - `role_config` — Optional role-specific config from model packs

  ## Examples

      iex> handle = ModelFactory.resolve!("gpt-4o")
      iex> handle.provider_module
      CodePuppyControl.LLM.Providers.OpenAI

      iex> handle.model_opts[:model]
      "gpt-4o"
  """

  @enforce_keys [:model_name, :provider_module, :provider_config]
  defstruct [
    :model_name,
    :provider_module,
    :provider_config,
    :api_key,
    :base_url,
    extra_headers: [],
    model_opts: [],
    role_config: nil
  ]

  @type t :: %__MODULE__{
          model_name: String.t(),
          provider_module: module(),
          provider_config: map(),
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          extra_headers: [{String.t(), String.t()}],
          model_opts: keyword(),
          role_config: map() | nil
        }

  @doc """
  Convert a handle to the keyword options expected by provider `chat/3` and
  `stream_chat/4` callbacks. Merges model_opts with api_key and base_url so
  the provider gets everything it needs.
  """
  @spec to_provider_opts(t()) :: keyword()
  def to_provider_opts(%__MODULE__{} = handle) do
    handle.model_opts
    |> maybe_put_opt(:api_key, handle.api_key)
    |> maybe_put_opt(:base_url, handle.base_url)
    |> maybe_put_opt(:extra_headers, handle.extra_headers)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, :extra_headers, []), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
