defmodule CodePuppyControl.Auth.RuntimeConnection do
  @moduledoc """
  Resolve runtime connection details for registry-backed models.

  This centralizes custom-endpoint extraction and OAuth-specific runtime
  credentials so both `CodePuppyControl.LLM` and `CodePuppyControl.ModelFactory`
  can execute against the same resolved connection data.
  """

  alias CodePuppyControl.Auth.{ChatGptOAuth, ClaudeOAuth}
  alias CodePuppyControl.Config.Models
  alias CodePuppyControl.ModelFactory.Credentials
  alias CodePuppyControl.ModelRegistry

  @type resolved :: %{
          api_key: String.t() | nil,
          base_url: String.t() | nil,
          extra_headers: [{String.t(), String.t()}]
        }

  @spec resolve(map(), String.t() | nil) :: {:ok, resolved()} | {:error, term()}
  def resolve(config), do: resolve(config, nil)

  def resolve(config, model_name) when is_map(config) do
    base = resolve_custom_endpoint(Map.get(config, "custom_endpoint"))

    case ModelRegistry.get_model_type(config) do
      "claude_code" ->
        resolve_claude(base, config, model_name)

      "chatgpt_oauth" ->
        resolve_chatgpt(base)

      _ ->
        {:ok, base}
    end
  end

  def resolve(_, _), do: {:ok, %{api_key: nil, base_url: nil, extra_headers: []}}

  defp resolve_custom_endpoint(nil) do
    %{api_key: nil, base_url: nil, extra_headers: []}
  end

  defp resolve_custom_endpoint(custom_endpoint) do
    case Credentials.resolve_custom_endpoint(custom_endpoint) do
      {:ok, {url, headers, api_key}} ->
        %{
          api_key: blank_to_nil(api_key),
          base_url: blank_to_nil(url),
          extra_headers: headers
        }

      {:error, _reason} ->
        %{api_key: nil, base_url: nil, extra_headers: []}
    end
  end

  @context_1m_beta "context-1m-2025-08-07"

  defp resolve_claude(base, config, model_name) do
    with {:ok, access_token} <- ClaudeOAuth.get_valid_access_token() do
      interleaved_thinking = interleaved_thinking_enabled?(model_name)

      headers =
        base.extra_headers
        |> put_header("authorization", "Bearer #{access_token}")
        |> maybe_put_interleaved_thinking(interleaved_thinking)
        |> maybe_put_context_1m_beta(Map.get(config, "context_length", 0))

      {:ok,
       %{
         api_key: nil,
         base_url: base.base_url || ClaudeOAuth.api_base_url(),
         extra_headers: headers
       }}
    end
  end

  defp resolve_chatgpt(base) do
    with {:ok, access_token} <- ChatGptOAuth.get_valid_access_token(),
         tokens when is_map(tokens) <- ChatGptOAuth.load_stored_tokens(),
         {:ok, account_id} <- extract_account_id(tokens) do
      config = ChatGptOAuth.config()

      headers =
        base.extra_headers
        |> put_header("ChatGPT-Account-Id", account_id)
        |> put_header("originator", config.originator)
        |> put_header("User-Agent", user_agent_string(config))
        |> put_header("accept", "application/json")

      {:ok,
       %{
         api_key: access_token,
         base_url: base.base_url || config.api_base_url,
         extra_headers: headers
       }}
    else
      {:error, :not_authenticated} -> {:error, :not_authenticated}
      {:error, :missing_account_id} -> {:error, :missing_account_id}
      {:error, reason} -> {:error, reason}
      # load_stored_tokens returned nil (no file)
      nil -> {:error, :not_authenticated}
    end
  end

  defp extract_account_id(tokens) when is_map(tokens) do
    case Map.get(tokens, "account_id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :missing_account_id}
    end
  end

  defp interleaved_thinking_enabled?(nil), do: true

  defp interleaved_thinking_enabled?(model_name) when is_binary(model_name) do
    case Models.get_model_setting(model_name, "interleaved_thinking") do
      nil -> true
      value -> value == true
    end
  end

  defp maybe_put_interleaved_thinking(headers, enabled?) do
    update_beta_header(headers, fn beta_parts ->
      cleaned = Enum.reject(beta_parts, &String.contains?(&1, "interleaved-thinking"))

      if enabled? do
        append_unique(cleaned, "interleaved-thinking-2025-05-14")
      else
        cleaned
      end
    end)
  end

  defp maybe_put_context_1m_beta(headers, context_length) when is_number(context_length) do
    if context_length >= 1_000_000 do
      update_beta_header(headers, &append_unique(&1, @context_1m_beta))
    else
      headers
    end
  end

  defp maybe_put_context_1m_beta(headers, _), do: headers

  defp update_beta_header(headers, updater) do
    current =
      headers
      |> Enum.find_value(fn {name, value} ->
        if String.downcase(name) == "anthropic-beta", do: value, else: nil
      end)
      |> to_beta_parts()
      |> updater.()

    case current do
      [] -> remove_header(headers, "anthropic-beta")
      parts -> put_header(headers, "anthropic-beta", Enum.join(parts, ","))
    end
  end

  defp to_beta_parts(nil), do: []

  defp to_beta_parts(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp to_beta_parts(_), do: []

  defp append_unique(parts, value) do
    if value in parts, do: parts, else: parts ++ [value]
  end

  defp remove_header(headers, name) do
    downcased = String.downcase(name)

    Enum.reject(headers, fn {header_name, _header_value} ->
      String.downcase(header_name) == downcased
    end)
  end

  defp user_agent_string(config) do
    {os_type, os_name} = :os.type()
    os_str = if os_type == :unix and os_name == :darwin, do: "Mac OS", else: to_string(os_name)
    arch = to_string(:erlang.system_info(:system_architecture))

    config.originator <>
      "/" <> config.client_version <> " (" <> os_str <> "; " <> arch <> ") Terminal_Codex_CLI"
  end

  defp put_header(headers, name, value) do
    downcased = String.downcase(name)

    filtered =
      Enum.reject(headers, fn {header_name, _header_value} ->
        String.downcase(header_name) == downcased
      end)

    filtered ++ [{name, value}]
  end

  defp blank_to_nil(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp blank_to_nil(value), do: value
end
