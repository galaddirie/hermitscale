defmodule Hermitscale.Integrations.WebhookSignature do
  @moduledoc "HMAC-SHA256 verification of exact provider delivery bytes."
  @doc "Checks a hex digest using constant-time comparison."
  def verify(raw, secret, signature, prefix \\ "") do
    expected = prefix <> (:crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower))

    case is_binary(signature) and byte_size(signature) == byte_size(expected) and
           Plug.Crypto.secure_compare(String.downcase(signature), expected) do
      true -> :ok
      false -> {:error, :unauthorized}
    end
  end

  @doc "Extracts a bounded non-empty provider delivery identifier."
  def delivery_key(headers, name, provider) do
    case Map.fetch(headers, name) do
      {:ok, value} when is_binary(value) and byte_size(value) in 1..200 ->
        {:ok, provider <> ":" <> value}

      _ ->
        {:error, :unauthorized}
    end
  end
end
