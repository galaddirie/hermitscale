defmodule Hermitscale.WorkOS.WebhookSignature do
  @moduledoc """
  Constant-time verification for the WorkOS `WorkOS-Signature` header.
  """

  @default_tolerance_seconds 300

  @doc """
  Verifies timestamp tolerance and any `v1` HMAC in a signature header.
  """
  def verify(raw_body, signature_header, secrets, opts \\ [])

  def verify(raw_body, signature_header, secrets, opts)
      when is_binary(raw_body) and is_binary(signature_header) and is_list(secrets) do
    tolerance = Keyword.get(opts, :tolerance_seconds, @default_tolerance_seconds)
    now = Keyword.get(opts, :now, System.system_time(:second))

    with {:ok, timestamp, timestamp_text, signatures} <- parse_header(signature_header),
         :ok <- validate_timestamp(timestamp, now, tolerance),
         true <- Enum.any?(secrets, &valid_signature?(&1, timestamp_text, raw_body, signatures)) do
      :ok
    else
      false -> {:error, :invalid_signature}
      {:error, _reason} = error -> error
    end
  end

  def verify(_raw_body, _signature_header, _secrets, _opts),
    do: {:error, :invalid_signature}

  defp parse_header(header) do
    entries =
      header
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&String.split(&1, "=", parts: 2))

    timestamp_text =
      Enum.find_value(entries, fn
        ["t", value] -> value
        _entry -> nil
      end)

    signatures =
      Enum.flat_map(entries, fn
        ["v1", value] -> [String.downcase(value)]
        _entry -> []
      end)

    with value when is_binary(value) <- timestamp_text,
         {timestamp, ""} <- Integer.parse(value),
         true <- signatures != [] do
      {:ok, normalize_timestamp(timestamp), value, signatures}
    else
      _invalid -> {:error, :invalid_signature_header}
    end
  end

  defp normalize_timestamp(timestamp) when timestamp > 10_000_000_000,
    do: div(timestamp, 1_000)

  defp normalize_timestamp(timestamp), do: timestamp

  defp validate_timestamp(timestamp, now, tolerance)
       when is_integer(timestamp) and is_integer(now) and is_integer(tolerance) do
    case abs(now - timestamp) <= tolerance do
      true -> :ok
      false -> {:error, :stale_signature}
    end
  end

  defp valid_signature?(secret, timestamp_text, raw_body, signatures)
       when is_binary(secret) and byte_size(secret) > 0 do
    expected =
      :crypto.mac(:hmac, :sha256, secret, timestamp_text <> "." <> raw_body)
      |> Base.encode16(case: :lower)

    Enum.any?(signatures, &secure_equal?(expected, &1))
  end

  defp valid_signature?(_secret, _timestamp_text, _raw_body, _signatures), do: false

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_equal?(_left, _right), do: false
end
