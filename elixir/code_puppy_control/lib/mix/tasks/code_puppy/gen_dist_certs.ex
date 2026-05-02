defmodule Mix.Tasks.CodePuppy.GenDistCerts do
  @moduledoc """
  Generate self-signed TLS certificates for Erlang distribution.

  Creates a CA cert, server cert, and client cert in the target
  directory. These are suitable for development only — do NOT use
  in production.

  ## Usage

      mix code_puppy.gen_dist_certs
      mix code_puppy.gen_dist_certs --output /custom/path

  ## Output

  By default, certs are written to `/tmp/code_puppy_dist/`:

    * `ca.pem` / `ca.key` — Certificate Authority
    * `server.pem` / `server.key` — Server (node) certificate
    * `client.pem` / `client.key` — Client (connecting node) certificate

  After generation, enable TLS distribution by:

    1. Setting `PUP_DIST_TLS=1`
    2. Uncommenting TLS lines in `rel/overlays/vm.args.eex`
    3. Starting nodes with `--sname` and connecting via `Node.connect/1`

  See docs/distributed-packs.md §9 for full setup instructions.

  (code_puppy-jqr.1)
  """

  use Mix.Task

  @shortdoc "Generate self-signed TLS certs for Erlang distribution"

  @default_output "/tmp/code_puppy_dist"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [output: :string],
        aliases: [o: :output]
      )

    output_dir = Keyword.get(opts, :output, @default_output)

    unless function_exported?(:public_key, :pkix_sign, 3) do
      Mix.raise(
        "code_puppy.gen_dist_certs requires Erlang/OTP 25+ " <>
          "with :public_key.pkix_sign/3 support"
      )
    end

    File.mkdir_p!(output_dir)

    ca_key = generate_key()
    ca_cert = generate_ca_cert(ca_key)

    server_key = generate_key()
    server_cert = generate_node_cert(server_key, ca_cert, ca_key, "server")

    client_key = generate_key()
    client_cert = generate_node_cert(client_key, ca_cert, ca_key, "client")

    write_cert(output_dir, "ca", ca_cert, ca_key)
    write_cert(output_dir, "server", server_cert, server_key)
    write_cert(output_dir, "client", client_cert, client_key)

    Mix.shell().info("""
    Generated self-signed distribution certs in #{output_dir}/

    To enable TLS distribution:
      1. Set PUP_DIST_TLS=1
      2. Uncomment TLS lines in rel/overlays/vm.args.eex
      3. Ensure ssl_dist.conf.eex points to these cert paths

    ⚠  These are self-signed certs for DEVELOPMENT ONLY.
    """)
  end

  defp generate_key do
    {_pub, priv} = :crypto.generate_key(:rsa, 2048)
    priv
  end

  defp generate_ca_cert(key) do
    {:Subject, {:rdnSequence, subject_attrs}} = ca_subject()

    :public_key.pkix_sign(
      {:OTPTBSCertificate,
       :v3,
       generate_serial(),
       {:AlgorithmIdentifier, {:rsaEncryption, 1}, :asn1_NO_VALUE},
       {:AlgorithmIdentifier, {:rsaEncryption, 1}, :asn1_NO_VALUE},
       subject_attrs,
       {:Validity, from_time(), to_time()},
       subject_attrs,
       {:SubjectPublicKeyInfo, {:AlgorithmIdentifier, {:rsaEncryption, 1}, :asn1_NO_VALUE}, key},
       :asn1_NO_VALUE,
       [
         basic_constraints_extension(true),
         key_usage_extension([:digitalSignature, :keyCertSign, :cRLSign])
       ]},
      key
    )
  end

  defp generate_node_cert(key, _ca_cert, ca_key, name) do
    {:Subject, {:rdnSequence, subject_attrs}} = node_subject(name)

    :public_key.pkix_sign(
      {:OTPTBSCertificate,
       :v3,
       generate_serial(),
       {:AlgorithmIdentifier, {:rsaEncryption, 1}, :asn1_NO_VALUE},
       {:AlgorithmIdentifier, {:rsaEncryption, 1}, :asn1_NO_VALUE},
       subject_attrs,
       {:Validity, from_time(), to_time()},
       ca_subject_attrs(),
       {:SubjectPublicKeyInfo, {:AlgorithmIdentifier, {:rsaEncryption, 1}, :asn1_NO_VALUE}, key},
       :asn1_NO_VALUE,
       [
         basic_constraints_extension(false),
         key_usage_extension([:digitalSignature, :keyEncipherment]),
         ext_key_usage_extension([:serverAuth, :clientAuth])
       ]},
      ca_key
    )
  end

  defp ca_subject do
    {:Subject,
     {:rdnSequence,
      [
        [{:AttributeTypeAndValue, {2, 5, 4, 3}, ~c"CodePuppy Dist CA"}],
        [{:AttributeTypeAndValue, {2, 5, 4, 10}, ~c"Code Puppy"}],
        [{:AttributeTypeAndValue, {2, 5, 4, 7}, ~c"localhost"}]
      ]}}
  end

  defp ca_subject_attrs do
    {:rdnSequence,
     [
       [{:AttributeTypeAndValue, {2, 5, 4, 3}, ~c"CodePuppy Dist CA"}],
       [{:AttributeTypeAndValue, {2, 5, 4, 10}, ~c"Code Puppy"}],
       [{:AttributeTypeAndValue, {2, 5, 4, 7}, ~c"localhost"}]
     ]}
  end

  defp node_subject(name) do
    {:Subject,
     {:rdnSequence,
      [
        [{:AttributeTypeAndValue, {2, 5, 4, 3}, ~c"CodePuppy Dist #{name}"}],
        [{:AttributeTypeAndValue, {2, 5, 4, 10}, ~c"Code Puppy"}],
        [{:AttributeTypeAndValue, {2, 5, 4, 7}, ~c"localhost"}]
      ]}}
  end

  defp from_time, do: :erlang.system_time(:seconds) - 60
  defp to_time, do: :erlang.system_time(:seconds) + 365 * 24 * 3600

  defp generate_serial do
    # Simple positive integer serial — unique per invocation
    :erlang.system_time(:nanosecond) + :rand.uniform(1_000_000)
  end

  defp basic_constraints_extension(ca?) do
    {:Extension, {2, 5, 29, 19}, true, ca?}
  end

  defp key_usage_extension(usages) do
    # Convert usage atoms to bit pattern
    bits =
      usages
      |> Enum.map(fn
        :digitalSignature -> 128
        :keyCertSign -> 4
        :cRLSign -> 2
        :keyEncipherment -> 64
        _ -> 0
      end)
      |> Enum.sum()

    {:Extension, {2, 5, 29, 15}, true, <<bits>>}
  end

  defp ext_key_usage_extension(oids) do
    {:Extension, {2, 5, 29, 37}, false, oids}
  end

  defp write_cert(dir, name, cert, key) do
    cert_pem = :public_key.pem_encode([{:Certificate, cert, :not_encrypted}])
    key_pem = :public_key.pem_encode([{:RSAPrivateKey, key, :not_encrypted}])

    File.write!(Path.join(dir, "#{name}.pem"), cert_pem)
    File.write!(Path.join(dir, "#{name}.key"), key_pem)
  end
end
