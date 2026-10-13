defmodule Hermitscale.Agents.Protocol do
  @moduledoc "The versioned, shared boundary for private workspace worker messages."

  defdelegate validate_command(command, options \\ []), to: Hermitscale.WorkspaceProtocol.V1
  defdelegate validate_event(event), to: Hermitscale.WorkspaceProtocol.V1
  defdelegate payload_digest(payload), to: Hermitscale.WorkspaceProtocol.V1
  defdelegate redact_payload(payload, secrets \\ []), to: Hermitscale.WorkspaceProtocol.V1
end
