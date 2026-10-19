defmodule OhMyJido.Auth.FileStore do
  @moduledoc """
  AES-256-GCM reference vault with atomic, mode-0600 account records.

  The host supplies a random 32-byte encryption key from its own secret service;
  prefer `key: fn -> secret_service_key() end` so supervisor child specifications
  do not contain raw key bytes. A directly supplied 32-byte key is also accepted.
  This module never discovers, derives from a password, or persists that key.
  Keep the same key to recover accounts after a broker restart. The private
  directory contains only encrypted records named by opaque account references.
  A wrong key, altered ciphertext or renamed account record fails closed.
  """
  @behaviour OhMyJido.Auth.Vault

  @derive {Inspect, only: [:path]}
  @enforce_keys [:path, :key]
  defstruct [:path, :key]

  @magic "OMJVAULT1"
  @max_record_bytes 1_048_576
  @reference ~r/\Aomj_acct_[A-Za-z0-9_-]{32}\z/

  @impl true
  def init(opts) do
    with {:ok, key} <- resolve_key(Keyword.get(opts, :key)),
         path when is_binary(path) <- Keyword.get(opts, :path),
         path = Path.expand(path),
         :ok <- directory(path) do
      {:ok, %__MODULE__{path: path, key: key}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_vault_key}
    end
  end

  defp resolve_key(provider) when is_function(provider, 0) do
    case provider.() do
      key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _invalid -> {:error, :invalid_vault_key}
    end
  rescue
    _error -> {:error, :invalid_vault_key}
  catch
    _kind, _reason -> {:error, :invalid_vault_key}
  end

  defp resolve_key(key) when is_binary(key) and byte_size(key) == 32, do: {:ok, key}
  defp resolve_key(_key), do: {:error, :invalid_vault_key}

  @impl true
  def list(%__MODULE__{path: path}) do
    case File.ls(path) do
      {:ok, names} ->
        references =
          names
          |> Enum.filter(&String.ends_with?(&1, ".vault"))
          |> Enum.map(&String.trim_trailing(&1, ".vault"))
          |> Enum.filter(&valid_reference?/1)
          |> Enum.sort()

        {:ok, references}

      {:error, _reason} ->
        {:error, :vault_unavailable}
    end
  end

  @impl true
  def load(%__MODULE__{} = store, reference) do
    with {:ok, path} <- record_path(store, reference),
         :ok <- regular_private_file(path),
         {:ok, bytes} <- File.read(path),
         {:ok, record} <- decrypt(store, reference, bytes) do
      {:ok, record}
    else
      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason}
      when reason in [:invalid_account_ref, :vault_corrupt, :vault_permissions] ->
        {:error, reason}

      {:error, _reason} ->
        {:error, :vault_unavailable}
    end
  end

  @impl true
  def put(%__MODULE__{} = store, reference, record) when is_map(record) do
    with {:ok, path} <- record_path(store, reference),
         {:ok, bytes} <- encrypt(store, reference, record) do
      atomic_write(path, bytes)
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, reference) do
    with {:ok, path} <- record_path(store, reference) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _reason} -> {:error, :vault_unavailable}
      end
    end
  end

  defp directory(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         :ok <- File.chmod(path, 0o700) do
      :ok
    else
      _error -> {:error, :vault_directory_unavailable}
    end
  end

  defp regular_private_file(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size, mode: mode}} when size <= @max_record_bytes ->
        if Bitwise.band(mode, 0o077) == 0, do: :ok, else: {:error, :vault_permissions}

      {:ok, _stat} ->
        {:error, :vault_corrupt}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_reference?(reference) when is_binary(reference),
    do: Regex.match?(@reference, reference)

  defp valid_reference?(_reference), do: false

  defp record_path(%__MODULE__{path: path}, reference) do
    if valid_reference?(reference),
      do: {:ok, Path.join(path, reference <> ".vault")},
      else: {:error, :invalid_account_ref}
  end

  defp encrypt(store, reference, record) do
    plaintext = :erlang.term_to_binary(record)

    if byte_size(plaintext) <= @max_record_bytes - 64 do
      nonce = :crypto.strong_rand_bytes(12)

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, store.key, nonce, plaintext, reference, true)

      {:ok, <<@magic, nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>}
    else
      {:error, :vault_record_too_large}
    end
  end

  defp decrypt(
         store,
         reference,
         <<@magic, nonce::binary-size(12), tag::binary-size(16), ciphertext::binary>>
       ) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           store.key,
           nonce,
           ciphertext,
           reference,
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) ->
        case :erlang.binary_to_term(plaintext, [:safe]) do
          record when is_map(record) -> {:ok, record}
          _other -> {:error, :vault_corrupt}
        end

      :error ->
        {:error, :vault_corrupt}
    end
  rescue
    _error -> {:error, :vault_corrupt}
  end

  defp decrypt(_store, _reference, _bytes), do: {:error, :vault_corrupt}

  defp atomic_write(path, bytes) do
    temporary =
      path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    result =
      with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]),
           :ok <- write_private(file, temporary, bytes),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        _error -> {:error, :vault_unavailable}
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp write_private(file, path, bytes) do
    with :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(file, bytes) do
      :file.sync(file)
    end
  after
    File.close(file)
  end
end
