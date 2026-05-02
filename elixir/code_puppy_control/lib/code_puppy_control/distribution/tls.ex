defmodule CodePuppyControl.Distribution.TLS do
  @moduledoc """
  TLS distribution helpers for Code Puppy cluster nodes.

  Provides utilities for checking TLS distribution status,
  validating certificate configuration, and verifying
  encrypted inter-node communication. (code_puppy-jqr.1)

  ## Enabling TLS Distribution

  1. Set `PUP_DIST_TLS=1` in your environment
  2. Uncomment the `-proto_dist inet_tls` line in `rel/overlays/vm.args.eex`
  3. Generate dev certs: `mix code_puppy.gen_dist_certs`
  4. Configure cert paths in `ssl_dist.conf.eex`

  ## Verification

      iex> CodePuppyControl.Distribution.TLS.tls_enabled?()
      false

      iex> CodePuppyControl.Distribution.TLS.verify_peer_config()
      :not_configured
  """

  require Logger

  @tls_env_var "PUP_DIST_TLS"

  @doc """
  Returns whether TLS distribution is enabled for this node.

  Checks the `PUP_DIST_TLS` environment variable AND whether
  the node is actually using `inet_tls` as its distribution
  protocol.
  """
  @spec tls_enabled?() :: boolean()
  def tls_enabled? do
    env_enabled?() && proto_dist_tls?()
  end

  @doc """
  Returns whether the PUP_DIST_TLS environment variable is set.
  """
  @spec env_enabled?() :: boolean()
  def env_enabled? do
    System.get_env(@tls_env_var) == "1"
  end

  @doc """
  Returns whether the current distribution protocol is inet_tls.

  Checks the `proto_dist` kernel environment variable.
  """
  @spec proto_dist_tls?() :: boolean()
  def proto_dist_tls? do
    case :application.get_env(:kernel, :proto_dist) do
      {:ok, :inet_tls} -> true
      {:ok, _} -> false
      :undefined ->
        # Check via the actual distribution module
        dist_module = :erlang.system_info(:dist)
        dist_module == :inet_tls
    end
  end

  @doc """
  Validates that TLS certificate configuration is present.

  Returns `:ok` if all required cert files exist, or
  `{:error, reasons}` with a list of missing/invalid items.
  """
  @spec verify_peer_config() :: :ok | :not_configured | {:error, [String.t()]}
  def verify_peer_config do
    if not env_enabled?() do
      :not_configured
    else
      errors =
        []
        |> check_cert_file("PUP_DIST_CERT_PATH", "/tmp/code_puppy_dist/server.pem")
        |> check_cert_file("PUP_DIST_KEY_PATH", "/tmp/code_puppy_dist/server.key")
        |> check_cert_file("PUP_DIST_CACERT_PATH", "/tmp/code_puppy_dist/ca.pem")

      if errors == [], do: :ok, else: {:error, errors}
    end
  end

  @doc """
  Returns the current distribution protocol as an atom.

  Possible values: `:inet_tcp`, `:inet_tls`, `:inet6_tcp`, `:undefined`.
  """
  @spec current_proto() :: atom()
  def current_proto do
    :erlang.system_info(:dist)
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp check_cert_file(errors, env_var, default_path) do
    path = System.get_env(env_var) || default_path

    if File.exists?(path) do
      errors
    else
      ["Missing cert file: #{path} (set #{env_var} to override)" | errors]
    end
  end
end
