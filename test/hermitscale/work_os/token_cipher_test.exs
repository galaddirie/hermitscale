defmodule Hermitscale.WorkOS.TokenCipherTest do
  use ExUnit.Case, async: false

  alias Hermitscale.WorkOS.TokenCipher

  setup do
    previous = Application.fetch_env!(:hermitscale, TokenCipher)
    key_one = :crypto.strong_rand_bytes(32)
    key_two = :crypto.strong_rand_bytes(32)

    Application.put_env(
      :hermitscale,
      TokenCipher,
      active_key_id: "key-one",
      keys: %{"key-one" => key_one, "key-two" => key_two}
    )

    on_exit(fn -> Application.put_env(:hermitscale, TokenCipher, previous) end)
  end

  test "authenticates ciphertext and keeps older key IDs decryptable during rotation" do
    assert {:ok, "key-one", ciphertext} = TokenCipher.encrypt("refresh-secret")
    refute ciphertext =~ "refresh-secret"

    config = Application.fetch_env!(:hermitscale, TokenCipher)
    Application.put_env(:hermitscale, TokenCipher, Keyword.put(config, :active_key_id, "key-two"))

    assert {:ok, "refresh-secret"} = TokenCipher.decrypt(ciphertext, "key-one")
    assert {:ok, "key-two", _rotated} = TokenCipher.encrypt("new-secret")
  end

  test "rejects tampering and unknown key IDs" do
    assert {:ok, "key-one", ciphertext} = TokenCipher.encrypt("access-secret")
    last = binary_part(ciphertext, byte_size(ciphertext) - 1, 1)
    tampered_last = :binary.first(last) |> Bitwise.bxor(1)
    prefix = binary_part(ciphertext, 0, byte_size(ciphertext) - 1)
    tampered = prefix <> <<tampered_last>>

    assert {:error, :invalid_ciphertext} = TokenCipher.decrypt(tampered, "key-one")
    assert {:error, :unknown_encryption_key} = TokenCipher.decrypt(ciphertext, "missing")
  end
end
