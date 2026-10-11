defmodule Hermitscale.WorkOS.TokenCipher do
  @moduledoc """
  Versioned AES-256-GCM protection for server-side WorkOS session material.
  """

  @version 1
  @iv_bytes 12
  @tag_bytes 16
  @aad_prefix "hermitscale:workos-session:v1:"

  @doc """
  Encrypts token material with the configured active key.
  """
  def encrypt(plaintext) when is_binary(plaintext) do
    config = config()
    key_id = Keyword.fetch!(config, :active_key_id)

    with {:ok, key} <- fetch_key(config, key_id) do
      iv = :crypto.strong_rand_bytes(@iv_bytes)
      aad = @aad_prefix <> key_id

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, aad, @tag_bytes, true)

      {:ok, key_id, <<@version, iv::binary, tag::binary, ciphertext::binary>>}
    end
  end

  @doc """
  Decrypts token material using the key recorded on the session row.
  """
  def decrypt(
        <<@version, iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes),
          ciphertext::binary>>,
        key_id
      )
      when is_binary(key_id) do
    with {:ok, key} <- fetch_key(config(), key_id),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             iv,
             ciphertext,
             @aad_prefix <> key_id,
             tag,
             false
           ) do
      {:ok, plaintext}
    else
      :error -> {:error, :invalid_ciphertext}
      {:error, _reason} = error -> error
    end
  rescue
    ArgumentError -> {:error, :invalid_ciphertext}
  end

  def decrypt(_ciphertext, _key_id), do: {:error, :invalid_ciphertext}

  defp fetch_key(config, key_id) do
    case get_in(config, [:keys, key_id]) do
      key when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _other -> {:error, :unknown_encryption_key}
    end
  end

  defp config do
    Application.fetch_env!(:hermitscale, __MODULE__)
  end
end
