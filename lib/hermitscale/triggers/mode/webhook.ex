defmodule Hermitscale.Triggers.Mode.Webhook do
  @moduledoc """
  Contract for webhook-mode triggers.

  A webhook trigger has no process of its own; it is invoked on the inbound
  request's process. `handle_request/2` decides whether the request becomes a
  firing, a direct reply (e.g. a provider URL-verification challenge), or is
  ignored.
  """

  @type request :: %{
          required(:method) => String.t(),
          required(:path) => [String.t()],
          required(:headers) => %{String.t() => String.t()},
          required(:query) => map(),
          required(:body) => map(),
          required(:raw_body) => binary()
        }

  @type fire_opt :: {:idempotency_key, String.t()}

  @callback handle_request(request(), params :: map()) ::
              {:fire, payload :: map()}
              | {:fire, payload :: map(), [fire_opt()]}
              | {:reply, status :: pos_integer(), body :: map()}
              | {:ignore, reason :: String.t()}
              | {:error, :unauthorized}
end
