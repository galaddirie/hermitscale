defmodule Hermitscale.Triggers.Builtin.Webhook.V1 do
  @moduledoc """
  Trigger fired by an inbound HTTP request to the workflow's hook URL.

  Authentication modes:

    * `"none"` — every request fires.
    * `"secret"` — the request must carry the shared secret in the
      `x-hermitscale-secret` header.
    * `"hmac"` — the signature header must contain the hex HMAC-SHA256 of the
      raw request body under the shared secret (an optional `sha256=` prefix,
      as sent by GitHub-style webhooks, is accepted).
  """

  use Hermitscale.Triggers.Behaviour,
    id: "trigger.webhook",
    version: 1,
    mode: :webhook,
    params: [
      auth: [type: {:in, ~w(none secret hmac)}, default: "none"],
      secret: [type: :string],
      signature_header: [type: :string, default: "x-signature"],
      respond: [type: {:in, ~w(immediately when_finished)}, default: "immediately"]
    ]

  @secret_header "x-hermitscale-secret"

  @impl true
  def validate_params(params) do
    case params do
      %{auth: auth} when auth in ["secret", "hmac"] ->
        if is_binary(params[:secret]) and params[:secret] != "" do
          :ok
        else
          {:error, "secret is required when auth is #{inspect(auth)}"}
        end

      _params ->
        :ok
    end
  end

  @impl true
  def handle_request(request, params) do
    with :ok <- authorize(request, params) do
      {:fire, payload(request, params)}
    end
  end

  defp authorize(_request, %{auth: "none"}), do: :ok

  defp authorize(request, %{auth: "secret", secret: secret}) do
    case Map.fetch(request.headers, @secret_header) do
      {:ok, presented} -> compare(presented, secret)
      :error -> {:error, :unauthorized}
    end
  end

  defp authorize(request, %{auth: "hmac", secret: secret} = params) do
    header = String.downcase(params[:signature_header] || "x-signature")

    with {:ok, presented} <- Map.fetch(request.headers, header) do
      presented = String.trim_leading(presented, "sha256=")

      expected =
        :hmac
        |> :crypto.mac(:sha256, secret, request.raw_body)
        |> Base.encode16(case: :lower)

      compare(String.downcase(presented), expected)
    else
      :error -> {:error, :unauthorized}
    end
  end

  defp compare(presented, expected) do
    if Plug.Crypto.secure_compare(presented, expected) do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp payload(request, params) do
    %{
      "method" => request.method,
      "path" => request.path,
      "query" => request.query,
      "headers" => redact_headers(request.headers, params),
      "body" => request.body
    }
  end

  # Credentials presented to authenticate the hook must not leak into run
  # input, where they would be persisted and exposed to expressions.
  defp redact_headers(headers, params) do
    signature_header = String.downcase(params[:signature_header] || "x-signature")

    Map.drop(headers, ["authorization", "cookie", @secret_header, signature_header])
  end
end
