defmodule Hermitscale.Integrations.Request do
  @moduledoc "Immediate vending and destination enforcement for every credentialed provider request."
  alias Hermitscale.Integrations.{ConnectedAccounts, CredentialRef, Provider}

  @doc "Validates the resolved URL before attaching secrets. Each safe retry vends afresh."
  def request(method, url, credential, opts \\ [])

  def request(method, url, %CredentialRef{} = ref, opts) do
    with {:ok, descriptor} <- Provider.descriptor(ref.provider_id),
         :ok <- validate_destination(url, descriptor.destinations) do
      attempt(method, url, ref, descriptor, opts, 2)
    end
  end

  def request(_method, _url, _credential, _opts), do: {:error, :missing_credentials}

  def validate_destination(url, hosts) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, port: 443} when is_binary(host) ->
        case String.downcase(host) in hosts do
          true -> :ok
          false -> {:error, :unapproved_destination}
        end

      _ ->
        {:error, :unapproved_destination}
    end
  end

  def validate_destination(_url, _hosts), do: {:error, :unapproved_destination}

  defp attempt(method, url, ref, descriptor, opts, remaining) do
    with {:ok, credential} <- ConnectedAccounts.vend(ref),
         {:ok, headers} <- auth_headers(descriptor, credential) do
      result =
        Req.request(
          Keyword.take(opts, [:json, :body, :params, :plug, :receive_timeout]) ++
            [method: method, url: url, headers: headers, redirect: false, retry: false]
        )

      case {result, method, remaining} do
        {{:ok, %Req.Response{status: status}}, method, n}
        when status in [429, 502, 503, 504] and method in [:get, :head] and n > 0 ->
          attempt(method, url, ref, descriptor, opts, n - 1)

        {{:error, _reason}, method, n} when method in [:get, :head] and n > 0 ->
          attempt(method, url, ref, descriptor, opts, n - 1)

        {{:ok, %Req.Response{status: status}}, _, _} when status in 300..399 ->
          {:error, :redirect_not_allowed}

        {{:ok, response}, _, _} ->
          {:ok,
           %{
             response
             | body: redact(response.body, credential.value),
               headers: redact(response.headers, credential.value)
           }}

        {{:error, _reason}, _, _} ->
          {:error, :provider_unavailable}
      end
    end
  end

  defp auth_headers(descriptor, %{auth_method: method, value: value}) do
    case Map.fetch(descriptor.authentication, method) do
      {:ok, :bearer} -> {:ok, [{"authorization", "Bearer " <> value}]}
      {:ok, {:header, name}} -> {:ok, [{name, value}]}
      :error -> {:error, :unsupported_auth_method}
    end
  end

  defp redact(value, secret) when is_binary(value),
    do: String.replace(value, secret, "[REDACTED]")

  defp redact(value, secret) when is_map(value),
    do: Map.new(value, fn {k, v} -> {redact(k, secret), redact(v, secret)} end)

  defp redact(value, secret) when is_list(value), do: Enum.map(value, &redact(&1, secret))
  defp redact(value, _secret), do: value
end
