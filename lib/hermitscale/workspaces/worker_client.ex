defmodule Hermitscale.Workspaces.WorkerClient do
  @moduledoc "Private authenticated Sprite exec bridge to the worker's local Unix socket."
  alias Hermitscale.Workspaces.{SpriteAccess, SpriteSDK, SpritesManagement}
  alias Hermitscale.WorkspaceProtocol.V1, as: Protocol

  @bridge """
  import sys, socket, json, struct
  message = json.load(sys.stdin)
  payload = json.dumps(message).encode()
  s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
  s.settimeout(50)
  s.connect('/run/hermitscale/worker.sock')
  s.sendall(struct.pack('>I', len(payload)) + payload)
  def read(n):
      b = b''
      while len(b) < n:
          part = s.recv(n-len(b))
          if not part: raise EOFError()
          b += part
      return b
  size = struct.unpack('>I', read(4))[0]
  if size > 1700000: raise ValueError('frame too large')
  sys.stdout.buffer.write(read(size))
  s.close()
  """

  def command(workspace, lease, envelope) do
    with {:ok, envelope} <- Protocol.validate_command(envelope),
         :ok <- identity(workspace, lease, envelope),
         {:ok, token} <- control_token(workspace),
         {:ok, sprite} <- SpriteAccess.sprite(workspace),
         {:ok, %{exit_code: 0, output: output}} <-
           SpriteSDK.capture(sprite, "sudo", ["-n", "python3", "-I", "-c", @bridge],
             stdin: Jason.encode!(%{token: token, command: envelope}),
             timeout: 55_000,
             output_limit: 1_700_000
           ),
         {:ok, response} <- Jason.decode(output) do
      decode_response(response)
    else
      {:ok, %{exit_code: _code}} -> {:error, :worker_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def control_token(workspace) do
    with {:ok, token} <- SpritesManagement.token() do
      {:ok,
       :crypto.mac(:hmac, :sha256, token, "hermitscale-worker-v1:" <> workspace.id)
       |> Base.url_encode64(padding: false)}
    end
  end

  defp identity(workspace, lease, envelope) do
    if envelope["workspace_id"] == workspace.id and lease.workspace_id == workspace.id and
         envelope["generation"] == lease.generation,
       do: :ok,
       else: {:error, :worker_identity_mismatch}
  end

  defp decode_response(%{"ok" => true, "result" => result}) when is_map(result), do: {:ok, result}

  defp decode_response(%{"ok" => false, "error" => error}) do
    reasons = %{
      "operation_not_found" => :operation_not_found,
      "stale_generation" => :stale_generation,
      "generation_mismatch" => :generation_mismatch,
      "writer_active" => :writer_active,
      "command_conflict" => :command_conflict,
      "history_gap" => :history_gap,
      "deadline_expired" => :deadline_expired,
      "requires_reconciliation" => :requires_reconciliation,
      "cancellation_unconfirmed" => :cancellation_unconfirmed,
      "runtime_unavailable" => :runtime_unavailable
    }

    {:error, Map.get(reasons, error, :worker_command_rejected)}
  end

  defp decode_response(_response), do: {:error, :invalid_worker_response}
end
