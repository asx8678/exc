defmodule CodePuppyControl.Credentials.Crypto do
  @moduledoc """
  Low-level AES-256-GCM encryption helpers for the credential store.

  Uses the Erlang `:crypto` module directly — no external dependencies needed.

  ## Key Derivation

  The encryption key is derived from a persistent machine-specific secret
  stored at `~/.code_puppy_ex/.machine_secret`. This provides at-rest
  encryption that is:

  - Tied to the machine (key isn't portable across hosts)
  - Persisted across restarts (key is stable, not derived from
    predictable values like `:erlang.node()`)
  - Sufficient to protect against casual file-reading attacks
  - NOT a replacement for OS keychain integration (future work)

  ## Wire Format

  Encrypted blobs are stored as Base64-encoded JSON with three fields:

  ```json
  {
    "iv":   "<base64 12-byte IV>",
    "tag":  "<base64 16-byte GCM auth tag>",
    "data": "<base64 ciphertext>"
  }
  ```

  AES-256-GCM provides authenticated encryption (confidentiality + integrity).
  The AAD (Additional Authenticated Data) is set to `"code_puppy_credentials"`
  to bind the ciphertext to this application context.
  """

  @cipher :aes_256_gcm
  @tag_length 16
  @iv_length 12
  @key_length 32
  @aad "code_puppy_credentials"

  # ── Key Derivation ──────────────────────────────────────────────────────

  @doc """
  Derive a 32-byte AES-256 key from a persistent machine secret.

  On first call, generates a random 32-byte secret and persists it to
  `~/.code_puppy_ex/.machine_secret` (or `PUP_MACHINE_SECRET_PATH`
  if set). Subsequent calls read the same secret, producing a stable
  key across restarts.

  The secret file is created with 0o600 permissions.

  ## Examples

      iex> key = CodePuppyControl.Credentials.Crypto.derive_key()
      iex> byte_size(key)
      32
  """
  @spec derive_key() :: <<_::256>>
  def derive_key do
    key_file = machine_secret_path()

    case File.read(key_file) do
      {:ok, secret} ->
        :crypto.hash(:sha256, secret)

      {:error, _} ->
        secret = :crypto.strong_rand_bytes(32)
        File.mkdir_p!(Path.dirname(key_file))
        File.write!(key_file, secret)
        File.chmod!(key_file, 0o600)
        :crypto.hash(:sha256, secret)
    end
  end

  @doc false
  @spec machine_secret_path() :: String.t()
  def machine_secret_path do
    System.get_env("PUP_MACHINE_SECRET_PATH") ||
      Path.join([System.get_env("HOME") || "/tmp", ".code_puppy_ex", ".machine_secret"])
  end

  @doc """
  Derive a 32-byte AES-256 key from an explicit secret.

  Use this when you want to provide your own key material
  (e.g. for testing or custom key management).

  ## Examples

      iex> key = CodePuppyControl.Credentials.Crypto.derive_key("my-secret")
      iex> byte_size(key)
      32
  """
  @spec derive_key(String.t()) :: <<_::256>>
  def derive_key(secret) when is_binary(secret) do
    :crypto.mac(:hmac, :sha256, "code_puppy_credential_key", secret)
  end

  # ── Encrypt / Decrypt ──────────────────────────────────────────────────

  @doc """
  Encrypt a binary plaintext using AES-256-GCM with the given key.

  Returns a map with Base64-encoded `:iv`, `:tag`, and `:data` fields,
  suitable for JSON serialization.

  ## Examples

      iex> key = CodePuppyControl.Credentials.Crypto.derive_key("test")
      iex> encrypted = CodePuppyControl.Credentials.Crypto.encrypt("secret-value", key)
      iex> Map.keys(encrypted) |> Enum.sort()
      [:data, :iv, :tag]
  """
  @spec encrypt(binary(), <<_::256>>) :: %{iv: String.t(), tag: String.t(), data: String.t()}
  def encrypt(plaintext, key) when is_binary(plaintext) and byte_size(key) == @key_length do
    iv = :crypto.strong_rand_bytes(@iv_length)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(@cipher, key, iv, plaintext, @aad, @tag_length, true)

    %{
      iv: Base.encode64(iv),
      tag: Base.encode64(tag),
      data: Base.encode64(ciphertext)
    }
  end

  @doc """
  Decrypt a previously encrypted blob using AES-256-GCM.

  Takes a map with Base64-encoded `:iv`, `:tag`, and `:data` fields
  (as returned by `encrypt/2`) and the encryption key.

  Returns `{:ok, plaintext}` on success or `{:error, reason}` on failure.

  ## Examples

      iex> key = CodePuppyControl.Credentials.Crypto.derive_key("test")
      iex> encrypted = CodePuppyControl.Credentials.Crypto.encrypt("secret-value", key)
      iex> {:ok, decrypted} = CodePuppyControl.Credentials.Crypto.decrypt(encrypted, key)
      iex> decrypted
      "secret-value"
  """
  @spec decrypt(%{iv: String.t(), tag: String.t(), data: String.t()}, <<_::256>>) ::
          {:ok, binary()} | {:error, term()}
  def decrypt(%{iv: iv_b64, tag: tag_b64, data: data_b64}, key)
      when is_binary(iv_b64) and is_binary(tag_b64) and is_binary(data_b64) and
             byte_size(key) == @key_length do
    with {:ok, iv} <- Base.decode64(iv_b64),
         {:ok, tag} <- Base.decode64(tag_b64),
         {:ok, ciphertext} <- Base.decode64(data_b64),
         true <- byte_size(iv) == @iv_length,
         true <- byte_size(tag) == @tag_length do
      case :crypto.crypto_one_time_aead(@cipher, key, iv, ciphertext, @aad, tag, false) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :decryption_failed}
      end
    else
      :error -> {:error, :invalid_base64}
      false -> {:error, :invalid_field_length}
    end
  end

  def decrypt(_, _), do: {:error, :invalid_input}

  # ── Convenience ─────────────────────────────────────────────────────────

  @doc """
  Encrypt a binary, returning a JSON-serializable string map.

  Same as `encrypt/2` but with string keys instead of atom keys,
  for direct JSON encoding with Jason.

  ## Examples

      iex> key = CodePuppyControl.Credentials.Crypto.derive_key("test")
      iex> encrypted = CodePuppyControl.Credentials.Crypto.encrypt_to_json("secret", key)
      iex> Map.keys(encrypted) |> Enum.sort()
      ["data", "iv", "tag"]
  """
  @spec encrypt_to_json(binary(), <<_::256>>) :: %{String.t() => String.t()}
  def encrypt_to_json(plaintext, key) do
    %{iv: iv, tag: tag, data: data} = encrypt(plaintext, key)
    %{"iv" => iv, "tag" => tag, "data" => data}
  end

  @doc """
  Decrypt from a JSON-decoded string-keyed map.

  Same as `decrypt/2` but accepts string keys (as produced by Jason.decode).

  ## Examples

      iex> key = CodePuppyControl.Credentials.Crypto.derive_key("test")
      iex> json_map = CodePuppyControl.Credentials.Crypto.encrypt_to_json("secret", key)
      iex> {:ok, decrypted} = CodePuppyControl.Credentials.Crypto.decrypt_from_json(json_map, key)
      iex> decrypted
      "secret"
  """
  @spec decrypt_from_json(%{String.t() => String.t()}, <<_::256>>) ::
          {:ok, binary()} | {:error, term()}
  def decrypt_from_json(%{"iv" => iv, "tag" => tag, "data" => data}, key) do
    decrypt(%{iv: iv, tag: tag, data: data}, key)
  end

  def decrypt_from_json(_, _), do: {:error, :invalid_input}
end
