defmodule Hermitscale.Integrations.Request do
  @moduledoc "Immediate vending and destination enforcement for every credentialed provider request."
  alias Hermitscale.Integrations.{ConnectedAccounts, CredentialRef, Provider, RequestError}

  @doc "Validates the resolved URL before attaching secrets. Each safe retry vends afresh."
  def request(method, url, credential, opts \\ [])

  def request(method, url, %CredentialRef{} = ref, opts) do
    with {:ok, descriptor} <- Provider.descriptor(ref.provider_id),
         :ok <- validate_destination(url, descriptor.destinations) do
      method
      |> build_request(url, opts)
      |> Req.Request.append_request_steps(
        credential_adapter: &attach_credential_adapter(&1, ref, descriptor)
      )
      |> Req.run()
      |> normalize_result()
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

  defp build_request(method, url, opts) do
    opts
    |> Keyword.take([:json, :body, :params, :plug, :receive_timeout, :retry_delay])
    |> Keyword.merge(
      method: method,
      url: url,
      redirect: false,
      retry: :safe_transient,
      max_retries: 2,
      retry_log_level: false
    )
    |> Req.new()
  end

  # Req retries the adapter after its request steps have run. Wrapping the
  # prepared adapter keeps credential vending immediately before every effect,
  # including retries, while Req owns the retry budget and backoff.
  defp attach_credential_adapter(request, ref, descriptor) do
    adapter = request.adapter
    %{request | adapter: &vend_and_send(&1, ref, descriptor, adapter)}
  end

  defp vend_and_send(request, ref, descriptor, adapter) do
    with {:ok, credential} <- ConnectedAccounts.vend(ref),
         {:ok, headers} <- auth_headers(descriptor, credential) do
      request
      |> clear_auth_headers(descriptor.authentication)
      |> Req.Request.put_headers(headers)
      |> Req.Request.put_private(:provider_secret, credential.value)
      |> adapter.()
    else
      {:error, reason} -> Req.Request.halt(request, %RequestError{reason: reason})
    end
  end

  defp clear_auth_headers(request, authentication) do
    Enum.reduce(authentication, request, fn
      {_method, :bearer}, request -> Req.Request.delete_header(request, "authorization")
      {_method, {:header, name}}, request -> Req.Request.delete_header(request, name)
    end)
  end

  defp normalize_result({_request, %Req.Response{status: status}}) when status in 300..399,
    do: {:error, :redirect_not_allowed}

  defp normalize_result({request, %Req.Response{} = response}) do
    secret = Map.fetch!(request.private, :provider_secret)

    {:ok,
     %{response | body: redact(response.body, secret), headers: redact(response.headers, secret)}}
  end

  defp normalize_result({_request, %RequestError{reason: reason}}), do: {:error, reason}

  defp normalize_result({_request, %{__exception__: true}}),
    do: {:error, :provider_unavailable}

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
