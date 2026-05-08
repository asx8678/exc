defmodule CodePuppyControl.Credentials do
  @moduledoc """
  Encrypted credential store for API keys and tokens.

  Provides persistent, encrypted storage for sensitive values like API keys,
  OAuth tokens, and other secrets. Credentials are encrypted at rest using
  AES-256-GCM with a key derived from the machine identity.

  ## Storage Location

  Credentials are stored in `~/.code_puppy_ex/credentials/store.json`
  (or the equivalent under `PUP_EX_HOME`). The file contains a single
  encrypted blob — individual key names and values are not visible without
  decryption.

  ## API

      # Store a credential
      :ok = CodePuppyControl.Credentials.set("OPENAI_API_KEY", "sk-abc123")

      # Retrieve a credential
      {:ok, "sk-abc123"} = CodePuppyControl.Credentials.get("OPENAI_API_KEY")

      # List stored key names (values are NOT returned)
      ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"] = CodePuppyControl.Credentials.list_keys()

      # Delete a credential
      :ok = CodePuppyControl.Credentials.delete("OPENAI_API_KEY")

      # Key not found
      {:error, :not_found} = CodePuppyControl.Credentials.get("NONEXISTENT")

  ## Migration from Python

      # Import API keys from the Python puppy.cfg
      {:ok, count} = CodePuppyControl.Credentials.import_from_python()

  ## Security Model

  - **At-rest encryption**: AES-256-GCM provides authenticated encryption
  - **Machine-bound key**: Encryption key is derived from hostname + username
    via HMAC-SHA256. Credentials are not portable across machines.
  - **File permissions**: The store file is created with 0o600 permissions.
  - **No OS keychain**: This is a simple encrypted file store. For OS-level
    keychain integration, see future work.

  ## Isolation

  This module writes ONLY to `~/.code_puppy_ex/` (or `PUP_EX_HOME`).
  It never writes to the legacy Python home (`~/.code_puppy/`).
  """

  alias CodePuppyControl.Credentials.Crypto
  require Logger

  @store_filename "store.json"

  # API key names that Python stores in puppy.cfg
  @python_api_key_names [
    "OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "ANTHROPIC_API_KEY",
    "CEREBRAS_API_KEY",
    "SYN_API_KEY",
    "AZURE_OPENAI_API_KEY",
    "AZURE_OPENAI_ENDPOINT",
    "OPENROUTER_API_KEY",
    "ZAI_API_KEY",
    "FIREWORKS_API_KEY",
    "GROQ_API_KEY",
    "MISTRAL_API_KEY",
    "MOONSHOT_API_KEY",
    "GITHUB_TOKEN"
  ]

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  Retrieve a credential by key name.

  Returns `{:ok, value}` if found, `{:error, :not_found}` if the key
  does not exist, or `{:error, reason}` on decryption / I/O failure.

  ## Examples

      iex> CodePuppyControl.Credentials.set("TEST_KEY", "test-value", store_dir: "/tmp/cred_test")
      :ok
      iex> CodePuppyControl.Credentials.get("TEST_KEY", store_dir: "/tmp/cred_test")
      {:ok, "test-value"}
  """
  @spec get(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get(key, opts \\ []) when is_binary(key) do
    with {:ok, entries} <- read_store(opts) do
      case Map.fetch(entries, key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end
  end

  @doc """
  Store a credential value under the given key name.

  If the key already exists, its value is updated. Returns `:ok` on success
  or `{:error, reason}` on failure.

  ## Options

  - `:store_dir` — override the directory for the credential store (for testing)

  ## Examples

      iex> CodePuppyControl.Credentials.set("MY_KEY", "secret", store_dir: "/tmp/cred_test")
      :ok
  """
  @spec set(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def set(key, value, opts \\ []) when is_binary(key) and is_binary(value) do
    with {:ok, entries} <- read_store(opts) do
      entries = Map.put(entries, key, value)
      write_store(entries, opts)
    end
  end

  @doc """
  Delete a credential by key name.

  Returns `:ok` even if the key did not exist (idempotent).
  Returns `{:error, reason}` on I/O or decryption failure.

  ## Examples

      iex> CodePuppyControl.Credentials.delete("MY_KEY", store_dir: "/tmp/cred_test")
      :ok
  """
  @spec delete(String.t(), keyword()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) when is_binary(key) do
    with {:ok, entries} <- read_store(opts) do
      entries = Map.delete(entries, key)
      write_store(entries, opts)
    end
  end

  @doc """
  List all stored credential key names.

  Returns a sorted list of key names. The actual values are NOT included
  to minimize exposure.

  ## Examples

      iex> CodePuppyControl.Credentials.set("KEY_A", "a", store_dir: "/tmp/cred_test")
      :ok
      iex> CodePuppyControl.Credentials.list_keys(store_dir: "/tmp/cred_test")
      ["KEY_A"]
  """
  @spec list_keys(keyword()) :: [String.t()] | {:error, term()}
  def list_keys(opts \\ []) do
    case read_store(opts) do
      {:ok, entries} -> entries |> Map.keys() |> Enum.sort()
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a credential key exists in the store.

  ## Examples

      iex> CodePuppyControl.Credentials.set("MY_KEY", "val", store_dir: "/tmp/cred_test")
      :ok
      iex> CodePuppyControl.Credentials.exists?("MY_KEY", store_dir: "/tmp/cred_test")
      true
      iex> CodePuppyControl.Credentials.exists?("NO_KEY", store_dir: "/tmp/cred_test")
      false
  """
  @spec exists?(String.t(), keyword()) :: boolean()
  def exists?(key, opts \\ []) when is_binary(key) do
    case get(key, opts) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Import API keys from the Python puppy.cfg into the credential store.

  Reads the legacy Python configuration file and imports any API keys
  that are present. This is a one-time migration helper.

  Returns `{:ok, count}` with the number of keys imported, or
  `{:error, reason}` on failure.

  ## Options

  - `:python_cfg_path` — override the path to the Python puppy.cfg

  ## Examples

      {:ok, 3} = CodePuppyControl.Credentials.import_from_python()
  """
  @spec import_from_python(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import_from_python(opts \\ []) do
    python_cfg_path =
      Keyword.get(opts, :python_cfg_path) || default_python_cfg_path()

    if not File.exists?(python_cfg_path) do
      {:ok, 0}
    else
      with {:ok, contents} <- File.read(python_cfg_path),
           {:ok, entries} <- read_store(opts) do
        imported =
          @python_api_key_names
          |> Enum.reduce({entries, 0}, fn key_name, {acc, count} ->
            case parse_ini_value(contents, key_name) do
              nil ->
                {acc, count}

              value when byte_size(value) > 0 ->
                {Map.put(acc, key_name, value), count + 1}

              _ ->
                {acc, count}
            end
          end)

        {new_entries, imported_count} = imported

        if imported_count > 0 do
          case write_store(new_entries, opts) do
            :ok -> {:ok, imported_count}
            error -> error
          end
        else
          {:ok, 0}
        end
      end
    end
  end

  # ── Store Path ──────────────────────────────────────────────────────────

  @doc """
  Get the directory path for the credential store.

  Defaults to `~/.code_puppy_ex/credentials/`. Override with the
  `:store_dir` option for testing.

  ## Examples

      iex> dir = CodePuppyControl.Credentials.store_dir([])
      iex> String.ends_with?(dir, "/credentials")
      true
  """
  @spec store_dir(keyword()) :: String.t()
  def store_dir(opts) do
    dir = Keyword.get(opts, :store_dir) || default_store_dir()
    validate_isolation!(dir)
    dir
  end

  @doc """
  Get the full file path for the credential store.

  ## Examples

      iex> path = CodePuppyControl.Credentials.store_path([])
      iex> String.ends_with?(path, "credentials/store.json")
      true
  """
  @spec store_path(keyword()) :: String.t()
  def store_path(opts) do
    Path.join(store_dir(opts), @store_filename)
  end

  # ── Private ─────────────────────────────────────────────────────────────

  defp default_store_dir do
    CodePuppyControl.Config.Paths.credentials_dir()
  end

  defp validate_isolation!(dir) do
    legacy_home = CodePuppyControl.Config.Paths.legacy_home_dir()
    expanded = Path.expand(dir)

    if String.starts_with?(expanded, legacy_home <> "/") or expanded == legacy_home do
      raise ArgumentError,
            "Credentials must not be stored in the legacy Python home " <>
              "(#{legacy_home}). Use ~/.code_puppy_ex/ instead."
    end

    :ok
  end

  defp default_python_cfg_path do
    Path.join([CodePuppyControl.Config.Paths.legacy_home_dir(), "puppy.cfg"])
  end

  defp encryption_key do
    Crypto.derive_key()
  end

  defp read_store(opts) do
    path = store_path(opts)

    cond do
      not File.exists?(path) ->
        {:ok, %{}}

      true ->
        with {:ok, raw} <- File.read(path),
             {:ok, json} <- Jason.decode(raw),
             {:ok, plaintext} <- Crypto.decrypt_from_json(json, encryption_key()) do
          case Jason.decode(plaintext) do
            {:ok, entries} when is_map(entries) -> {:ok, entries}
            _ -> {:error, :invalid_entries}
          end
        else
          {:error, :decryption_failed} ->
            Logger.error("Credentials: failed to decrypt store — key mismatch or corrupted data")
            {:error, :decryption_failed}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp write_store(entries, opts) when is_map(entries) do
    dir = store_dir(opts)
    path = store_path(opts)

    with :ok <- File.mkdir_p(dir),
         # Best-effort permission set (no-op on some platforms)
         :ok <- File.chmod(dir, 0o700) do
      plaintext = Jason.encode!(entries)
      encrypted = Crypto.encrypt_to_json(plaintext, encryption_key())
      json = Jason.encode!(encrypted)

      # Write atomically: write to temp file then rename
      tmp_path = path <> ".tmp.#{:erlang.unique_integer([:positive])}"

      try do
        with :ok <- File.write(tmp_path, json),
             :ok <- File.chmod(tmp_path, 0o600),
             :ok <- File.rename(tmp_path, path) do
          :ok
        else
          {:error, reason} ->
            # Clean up temp file on failure
            File.rm(tmp_path)
            {:error, reason}
        end
      rescue
        e ->
          File.rm(tmp_path)
          {:error, e}
      end
    end
  end

  # Parse a simple INI-style value from the Python puppy.cfg.
  # Format: KEY=value (one per line, no section headers for API keys)
  defp parse_ini_value(contents, key_name) do
    case Regex.run(~r/^#{Regex.escape(key_name)}=(.*)$/m, contents) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end
end
