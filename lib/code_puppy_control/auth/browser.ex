defmodule CodePuppyControl.Auth.Browser do
  @moduledoc """
  Shared helpers for best-effort browser launches in local OAuth flows.
  """

  require Logger

  @truthy ~w(1 true yes on)

  @spec suppress_browser?() :: boolean()
  def suppress_browser? do
    env_true?("PUP_HEADLESS") or
      env_true?("HEADLESS") or
      env_true?("PUP_BROWSER_HEADLESS") or
      env_true?("BROWSER_HEADLESS") or
      env_true?("CI") or
      not is_nil(System.get_env("PYTEST_CURRENT_TEST"))
  end

  @spec open_url(String.t()) :: :ok | {:suppressed, String.t()} | {:error, term()}
  def open_url(url) when is_binary(url) do
    if suppress_browser?() do
      {:suppressed, url}
    else
      case :os.type() do
        {:unix, :darwin} -> run_command("open", [url])
        {:unix, _} -> run_command("xdg-open", [url])
        {:win32, _} -> run_command("cmd", ["/c", "start", url])
      end
    end
  rescue
    error ->
      {:error, error}
  end

  defp run_command(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        trimmed = String.trim(output)

        if trimmed != "" do
          Logger.warning(
            "Browser launch command #{command} exited with status #{status}: #{trimmed}"
          )
        end

        {:error, {:command_failed, command, status}}
    end
  rescue
    error ->
      {:error, error}
  end

  defp env_true?(name) do
    name
    |> System.get_env()
    |> truthy?()
  end

  defp truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in @truthy
  end

  defp truthy?(_), do: false
end
