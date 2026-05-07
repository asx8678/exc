defmodule CodePuppyControl.Plugins.ChatGptOAuth do
  @moduledoc """
  ChatGPT OAuth plugin.

  Registers startup refresh behavior, the `/chatgpt-auth`, `/chatgpt-status`,
  and `/chatgpt-logout` custom commands, and the `chatgpt_oauth` model type
  handler.

  The core OAuth flow and token/model management live in
  `CodePuppyControl.Auth.ChatGptOAuth`.

  Originally ported from the legacy Python plugin system.

  ## Registered Callbacks

  - `:startup` — Proactively refresh tokens at boot
  - `:custom_command` — `/chatgpt-auth`, `/chatgpt-status`, `/chatgpt-logout`
  - `:custom_command_help` — Help text for custom commands
  - `:register_model_type` — Register `chatgpt_oauth` model type handler
  """

  use CodePuppyControl.Plugins.PluginBehaviour

  require Logger

  alias CodePuppyControl.Auth.ChatGptOAuth
  alias CodePuppyControl.Callbacks
  alias CodePuppyControl.Config.Models

  @impl true
  def name, do: "chatgpt_oauth"

  @impl true
  def description, do: "ChatGPT OAuth authentication and model registration"

  @impl true
  def register do
    Callbacks.register(:startup, &__MODULE__.on_startup/0)
    Callbacks.register(:custom_command, &__MODULE__.handle_custom_command/2)
    Callbacks.register(:custom_command_help, &__MODULE__.custom_help/0)
    Callbacks.register(:register_model_type, &__MODULE__.register_model_types/0)
    :ok
  end

  @doc false
  @spec on_startup() :: :ok
  def on_startup do
    tokens = ChatGptOAuth.load_stored_tokens()

    if tokens && Map.get(tokens, "access_token") do
      case ChatGptOAuth.get_valid_access_token() do
        {:ok, _} ->
          :ok

        {:error, _} ->
          IO.puts(
            :stderr,
            "Warning: ChatGPT OAuth token expired and refresh failed. Run /chatgpt-auth to re-authenticate."
          )

          :ok
      end
    else
      :ok
    end
  end

  @doc false
  @spec custom_help() :: [{String.t(), String.t()}]
  def custom_help do
    [
      {"chatgpt-auth", "Authenticate with ChatGPT via OAuth and import available models"},
      {"chatgpt-status", "Check ChatGPT OAuth authentication status and configured models"},
      {"chatgpt-logout", "Remove ChatGPT OAuth tokens and imported models"}
    ]
  end

  @doc false
  @spec handle_custom_command(String.t(), String.t()) :: true | nil
  def handle_custom_command(_command, name) when is_binary(name) do
    case name do
      "chatgpt-auth" ->
        case ChatGptOAuth.run_oauth_flow() do
          :ok ->
            auto_switch_model("chatgpt-gpt-5.4")

          {:error, reason} ->
            IO.puts("❌ ChatGPT OAuth failed: #{inspect(reason)}")
        end

        true

      "chatgpt-status" ->
        show_status()
        true

      "chatgpt-logout" ->
        do_logout()
        true

      _ ->
        nil
    end
  end

  def handle_custom_command(_command, _name), do: nil

  @doc false
  @spec register_model_types() :: [%{type: String.t(), handler: function()}]
  def register_model_types do
    [
      %{type: "chatgpt_oauth", handler: &__MODULE__.create_chatgpt_model/3}
    ]
  end

  @doc false
  @spec create_chatgpt_model(String.t(), map(), map()) :: map() | nil
  def create_chatgpt_model(model_name, model_config, _config) do
    case ChatGptOAuth.get_valid_access_token() do
      {:ok, access_token} ->
        tokens = ChatGptOAuth.load_stored_tokens()
        account_id = if tokens, do: Map.get(tokens, "account_id", ""), else: ""

        if account_id == "" do
          IO.puts(
            "⚠️ No account_id found in ChatGPT OAuth tokens; skipping model '#{Map.get(model_config, "name")}'."
          )

          IO.puts("Run /chatgpt-auth to re-authenticate.")
          nil
        else
          config = ChatGptOAuth.config()

          %{
            type: "chatgpt_oauth",
            name: model_name,
            api_key: access_token,
            base_url:
              Map.get(model_config, "custom_endpoint", %{}) |> Map.get("url", config.api_base_url),
            account_id: account_id,
            extra_headers: [
              {"ChatGPT-Account-Id", account_id},
              {"originator", config.originator},
              {"User-Agent", user_agent_string(config)},
              {"accept", "application/json"}
            ]
          }
        end

      {:error, _reason} ->
        IO.puts(
          "⚠️ Failed to get valid ChatGPT OAuth token; skipping model '#{Map.get(model_config, "name")}'."
        )

        IO.puts("Run /chatgpt-auth to authenticate.")
        nil
    end
  end

  defp show_status do
    tokens = ChatGptOAuth.load_stored_tokens()

    if tokens && Map.get(tokens, "access_token") do
      account_id = Map.get(tokens, "account_id")

      if is_nil(account_id) or account_id == "" do
        IO.puts("🔐 ChatGPT OAuth: Access token present, but account_id is missing")
        IO.puts("⚠️ Run /chatgpt-auth to re-authenticate and obtain account_id.")
      else
        IO.puts("🔐 ChatGPT OAuth: Authenticated")
        IO.puts("✅ OAuth access token and account_id available for API requests")
      end

      chatgpt_models = ChatGptOAuth.load_chatgpt_models()

      oauth_models =
        for {name, cfg} <- chatgpt_models,
            Map.get(cfg, "oauth_source") == "chatgpt-oauth-plugin",
            do: name

      if oauth_models != [] do
        IO.puts("🎯 Configured ChatGPT models: #{Enum.join(oauth_models, ", ")}")
      else
        IO.puts("⚠️ No ChatGPT models configured yet.")
      end
    else
      IO.puts("🔓 ChatGPT OAuth: Not authenticated")
      IO.puts("🌐 Run /chatgpt-auth to launch the browser sign-in flow.")
    end
  end

  defp do_logout do
    ChatGptOAuth.clear_stored_tokens()
    removed = ChatGptOAuth.remove_chatgpt_models()
    IO.puts("Removed ChatGPT OAuth tokens")

    if removed > 0,
      do:
        IO.puts("Removed " <> Integer.to_string(removed) <> " ChatGPT models from configuration")

    IO.puts("ChatGPT logout complete")
    :ok
  end

  defp auto_switch_model(model_name) do
    try do
      Models.set_global_model(model_name)
      IO.puts("Switched to model: #{model_name}")
    rescue
      e ->
        Logger.debug("Auto-switch model failed: #{inspect(e)}")
        :ok
    end
  end

  defp user_agent_string(config) do
    {os_type, os_name} = :os.type()
    os_str = if os_type == :unix and os_name == :darwin, do: "Mac OS", else: to_string(os_name)
    arch = to_string(:erlang.system_info(:system_architecture))

    config.originator <>
      "/" <> config.client_version <> " (" <> os_str <> "; " <> arch <> ") Terminal_Codex_CLI"
  end
end
