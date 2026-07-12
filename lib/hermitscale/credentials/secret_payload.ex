defmodule Hermitscale.Credentials.SecretPayload do
  @moduledoc """
  Typed secret material stored by credential backends.

  Payloads round-trip through `to_map/1` / `from_map/1` so backends can store
  them as JSON-able maps. Every payload struct redacts its secret fields from
  `inspect/1` so tokens can't leak through logs, crash reports, or run events.
  """

  defmodule ApiKey do
    @moduledoc "A single API key or personal access token."
    @enforce_keys [:key]
    defstruct [:key]

    @type t :: %__MODULE__{key: String.t()}

    defimpl Inspect do
      def inspect(_payload, _opts), do: "#SecretPayload.ApiKey<redacted>"
    end
  end

  defmodule OAuthToken do
    @moduledoc "An OAuth access/refresh token pair."
    @enforce_keys [:access_token]
    defstruct [:access_token, :refresh_token, :expires_at, scopes: []]

    @type t :: %__MODULE__{
            access_token: String.t(),
            refresh_token: String.t() | nil,
            expires_at: DateTime.t() | nil,
            scopes: [String.t()]
          }

    defimpl Inspect do
      def inspect(payload, _opts) do
        "#SecretPayload.OAuthToken<expires_at: #{inspect(payload.expires_at)}, redacted>"
      end
    end
  end

  defmodule Custom do
    @moduledoc "Arbitrary named secret fields (basic auth pairs, multi-part credentials)."
    defstruct fields: %{}

    @type t :: %__MODULE__{fields: %{String.t() => String.t()}}

    defimpl Inspect do
      def inspect(payload, _opts) do
        keys = payload.fields |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        "#SecretPayload.Custom<fields: [#{keys}], redacted>"
      end
    end
  end

  @type t :: ApiKey.t() | OAuthToken.t() | Custom.t()

  @doc "Returns the credential kind atom for a payload."
  def kind(%ApiKey{}), do: :api_key
  def kind(%OAuthToken{}), do: :oauth
  def kind(%Custom{}), do: :custom

  @doc "Serializes a payload to a JSON-able map for backend storage."
  def to_map(%ApiKey{key: key}) do
    %{"kind" => "api_key", "key" => key}
  end

  def to_map(%OAuthToken{} = token) do
    %{
      "kind" => "oauth_token",
      "access_token" => token.access_token,
      "refresh_token" => token.refresh_token,
      "expires_at" => encode_datetime(token.expires_at),
      "scopes" => token.scopes
    }
  end

  def to_map(%Custom{fields: fields}) do
    %{"kind" => "custom", "fields" => fields}
  end

  @doc "Deserializes a stored map back into a payload struct."
  def from_map(%{"kind" => "api_key", "key" => key}) when is_binary(key) do
    {:ok, %ApiKey{key: key}}
  end

  def from_map(%{"kind" => "oauth_token", "access_token" => access_token} = map)
      when is_binary(access_token) do
    with {:ok, expires_at} <- decode_datetime(map["expires_at"]) do
      {:ok,
       %OAuthToken{
         access_token: access_token,
         refresh_token: map["refresh_token"],
         expires_at: expires_at,
         scopes: map["scopes"] || []
       }}
    end
  end

  def from_map(%{"kind" => "custom", "fields" => fields}) when is_map(fields) do
    {:ok, %Custom{fields: fields}}
  end

  def from_map(_map), do: {:error, :invalid_secret_payload}

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp decode_datetime(nil), do: {:ok, nil}

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_secret_payload}
    end
  end

  defp decode_datetime(_value), do: {:error, :invalid_secret_payload}
end
