defmodule Hermitscale.Integrations.RequestError do
  @moduledoc false

  # Req adapters report failures as exceptions. This value is never raised;
  # the request boundary unwraps it back into the credential error contract.
  defexception [:reason, message: "provider request authorization failed"]
end
