defmodule CodePuppyControlWeb.Plugs.AdminAuth do
  @moduledoc """
  Trust boundary for the admin LiveView UI.

  The admin UI is a **local companion UI** — it watches the local control
  plane and is not designed to be exposed to the public internet. By
  default, this plug only allows requests originating from loopback
  (`127.0.0.1`, `::1`).

  ## Configuration

      # Default — loopback only
      config :code_puppy_control, :admin_ui, allowed_ips: :loopback

      # Allow specific extra IPs (e.g. on a trusted LAN)
      config :code_puppy_control, :admin_ui,
        allowed_ips: ["10.0.0.42", "::1"]

      # Allow everything (NOT recommended; e.g. behind a trusted proxy)
      config :code_puppy_control, :admin_ui, allowed_ips: :any

  ## How it works

  Pull the `remote_ip` off the `Plug.Conn` (`x-forwarded-for` is NOT
  trusted here — if you put this behind a proxy you must configure the
  proxy to set `remote_ip` correctly via `RemoteIp` or your endpoint).
  Reject with `403 Forbidden` if the IP isn't on the allowlist.

  This plug is also reused as a LiveView `on_mount` hook
  (`on_mount/4`) so Live navigation between admin LiveViews is checked
  on every mount, not just the first HTTP hit.
  """

  import Plug.Conn

  require Logger

  @loopback_v4 {127, 0, 0, 1}
  @loopback_v6 {0, 0, 0, 0, 0, 0, 0, 1}

  # ── Plug ─────────────────────────────────────────────────────────────

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if allowed?(conn.remote_ip) do
      conn
    else
      Logger.warning(
        "AdminAuth rejected request from #{format_ip(conn.remote_ip)} for #{conn.request_path}"
      )

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "Admin UI is restricted to local connections.")
      |> halt()
    end
  end

  # ── LiveView on_mount hook ────────────────────────────────────────────

  @doc """
  LiveView `on_mount` hook. Re-checks the IP allowlist on every Live
  mount (HTTP-driven mount has the conn.remote_ip; the connected mount
  has it via `connect_info.peer_data`).

  Returns `{:cont, socket}` if allowed, `{:halt, redirect(...)}` if not.
  """
  @spec on_mount(term(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    ip = remote_ip_from_socket(socket)

    if allowed?(ip) do
      {:cont, socket}
    else
      Logger.warning("AdminAuth (LiveView) rejected mount from #{format_ip(ip)}")

      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(
         :error,
         "Admin UI is restricted to local connections."
       )
       |> Phoenix.LiveView.redirect(to: "/")}
    end
  end

  defp remote_ip_from_socket(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: ip} -> ip
      _ -> nil
    end
  end

  # ── Allowlist logic ──────────────────────────────────────────────────

  @doc """
  Returns true if the given IP tuple is allowed by the current config.

  `nil` is treated as the dead-mount case (LiveView's first render before
  `connect_info` is available) and allowed; the second (connected) mount
  is the real check.
  """
  @spec allowed?(:inet.ip_address() | nil) :: boolean()
  def allowed?(nil), do: true

  def allowed?(ip) do
    case allowed_ips_config() do
      :any ->
        true

      :loopback ->
        loopback?(ip)

      list when is_list(list) ->
        loopback?(ip) or Enum.any?(list, &ip_matches?(ip, &1))

      _ ->
        loopback?(ip)
    end
  end

  defp allowed_ips_config do
    :code_puppy_control
    |> Application.get_env(:admin_ui, [])
    |> Keyword.get(:allowed_ips, :loopback)
  end

  defp loopback?(@loopback_v4), do: true
  defp loopback?(@loopback_v6), do: true
  defp loopback?(_), do: false

  defp ip_matches?(ip, candidate) when is_binary(candidate) do
    case :inet.parse_address(String.to_charlist(candidate)) do
      {:ok, parsed} -> parsed == ip
      _ -> false
    end
  end

  defp ip_matches?(ip, candidate) when is_tuple(candidate), do: candidate == ip
  defp ip_matches?(_ip, _other), do: false

  defp format_ip(nil), do: "<unknown>"

  defp format_ip(ip) do
    ip
    |> :inet.ntoa()
    |> case do
      {:error, _} -> "<unknown>"
      charlist -> to_string(charlist)
    end
  end
end
