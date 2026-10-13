defmodule Hermitscale.Agents.RemoteRuntime do
  @moduledoc "Bounded reconciliation of one remote journal operation; never an independent retry loop."
  alias Hermitscale.Workspaces
  alias Hermitscale.Agents.Approvals
  alias Hermitscale.Integrations.ExecutionAccess
  alias Hermitscale.Agents.Protocol

  def preflight(scope, session, _turn) do
    with {:ok, _token} <- Hermitscale.Workspaces.SpritesManagement.token(),
         :ok <- ExecutionAccess.provider_ready(scope, session) do
      :ok
    end
  end

  def step(scope, session, turn, lease) do
    with {:ok, workspace} <- Workspaces.provision_workspace(scope, session.workspace_id),
         {:ok, operation} <- inspect_or_start(scope, session, turn, lease, workspace),
         {:ok, events} <- events(scope, workspace, turn, lease, operation) do
      status = operation["status"]

      cond do
        status in ["completed", "failed", "interrupted"] and
            operation["termination_confirmed"] == true ->
          terminal_outcome(scope, session, turn, lease, workspace, operation, events)

        turn.cancellation_requested_at != nil or
            DateTime.compare(turn.deadline, DateTime.utc_now(:second)) != :gt ->
          with {:ok, _} <-
                 Workspaces.worker_command(
                   scope,
                   workspace.id,
                   lease.id,
                   envelope(turn, lease, "cancel", %{}, turn.cancel_command_id)
                 ),
               {:ok, current} <-
                 Workspaces.worker_command(
                   scope,
                   workspace.id,
                   lease.id,
                   envelope(turn, lease, "inspect", %{})
                 ) do
            if current["termination_confirmed"] == true do
              terminal_outcome(
                scope,
                session,
                turn,
                lease,
                workspace,
                Map.put(current, "status", "interrupted"),
                events
              )
            else
              {:ok, %{status: :running, events: events, worker_state: current}}
            end
          end

        status == "uncertain" ->
          {:ok,
           %{
             status: :running,
             events: events,
             worker_state: operation,
             error: "worker_interrupted"
           }}

        operation["approval_request"] != nil ->
          approval = operation["approval_request"]

          with {:ok, permission} <-
                 Approvals.request(scope, turn.id, %{
                   action: "agents.approve",
                   target_digest: Protocol.payload_digest(approval),
                   policy_revision: 1
                 }) do
            case permission.status do
              :pending ->
                {:ok,
                 %{
                   status: :waiting_for_approval,
                   events: events,
                   worker_state: operation,
                   approval_id: permission.id
                 }}

              decision when decision in [:approved, :rejected] ->
                with :ok <-
                       if(decision == :approved,
                         do:
                           Approvals.authorize_decision(
                             scope,
                             permission.id,
                             "agents.approve",
                             Protocol.payload_digest(approval),
                             1
                           ),
                         else: :ok
                       ),
                     {:ok, current} <-
                       Workspaces.worker_command(
                         scope,
                         workspace.id,
                         lease.id,
                         envelope(
                           turn,
                           lease,
                           "approve",
                           %{
                             "request_id" => approval["request_id"],
                             "response" =>
                               if(decision == :approved, do: "approved", else: "denied")
                           },
                           permission.id
                         )
                       ) do
                  {:ok,
                   %{
                     status: :running,
                     events: events,
                     worker_state: current,
                     approval_id: permission.id
                   }}
                end
            end
          end

        true ->
          {:ok, %{status: :running, events: events, worker_state: operation}}
      end
    end
  end

  defp terminal_outcome(scope, session, turn, lease, workspace, operation, events) do
    with {:ok, evidence} <- Workspaces.termination_evidence(scope, workspace.id, lease.id) do
      outcome =
        case operation["status"] do
          "completed" ->
            :succeeded

          "failed" ->
            :failed

          "interrupted" ->
            if(turn.cancellation_requested_at != nil, do: :cancelled, else: :interrupted)
        end

      result =
        with {:ok, base} <- Hermitscale.Agents.Publications.current_base_sha(scope, session.id) do
          Workspaces.collect_evidence(scope, workspace.id, lease.id, base,
            verification_commands:
              if(outcome == :succeeded, do: turn.verification_commands, else: [])
          )
        end

      with {:ok, result} <- result do
        {:ok,
         %{
           status: outcome,
           events: events,
           worker_state: operation,
           result: result,
           termination_evidence: evidence
         }}
      end
    end
  end

  defp inspect_or_start(scope, session, turn, lease, workspace) do
    case Workspaces.worker_command(
           scope,
           workspace.id,
           lease.id,
           envelope(turn, lease, "inspect", %{})
         ) do
      {:ok, operation} ->
        {:ok, operation}

      {:error, reason}
      when reason in [:operation_not_found, :worker_unavailable, :worker_not_started] ->
        with {:ok, env} <- ExecutionAccess.provider_env(scope, session, turn),
             {:ok, source} <- source_credential(scope, session),
             {:ok, _} <-
               Workspaces.prepare_turn(scope, workspace.id, lease, turn, env,
                 source_credential: source
               ),
             {:ok, state} <-
               Workspaces.worker_command(
                 scope,
                 workspace.id,
                 lease.id,
                 envelope(
                   turn,
                   lease,
                   "start",
                   start_payload(session, turn),
                   turn.worker_command_id
                 )
               ),
             do: {:ok, state}

      {:error, _} = error ->
        error
    end
  end

  defp source_credential(scope, %{repository: repository} = session) when is_binary(repository) do
    case ExecutionAccess.credential(scope, session, "github", ["repo"]) do
      {:error, :connection_setup_required} -> {:ok, nil}
      result -> result
    end
  end

  defp source_credential(_scope, _session), do: {:ok, nil}

  defp start_payload(session, turn) do
    %{
      "prompt" => turn.instructions <> result_instruction(turn.result_schema)
    }
    |> then(fn payload ->
      if session.provider_conversation_id,
        do: Map.put(payload, "provider_conversation_id", session.provider_conversation_id),
        else: payload
    end)
  end

  defp result_instruction(schema) when schema == %{}, do: ""

  defp result_instruction(schema) do
    "\nWrite the final structured result to .hermitscale/result.json matching this JSON schema: " <>
      Jason.encode!(schema)
  end

  defp events(scope, workspace, turn, lease, operation) do
    epoch = operation["epoch"]

    if epoch do
      cursor = if turn.worker_epoch == epoch, do: turn.worker_cursor, else: 0

      with {:ok, %{"events" => events}} <-
             Workspaces.worker_command(
               scope,
               workspace.id,
               lease.id,
               envelope(turn, lease, "read_events", %{
                 "epoch" => epoch,
                 "cursor" => cursor,
                 "limit" => 100
               })
             ),
           do: {:ok, events}
    else
      {:ok, []}
    end
  end

  def envelope(turn, lease, type, payload, command_id \\ Ecto.UUID.generate()) do
    %{
      "version" => 1,
      "workspace_id" => lease.workspace_id,
      "operation_id" => turn.id,
      "command_id" => command_id,
      "generation" => lease.generation,
      "payload_digest" => Protocol.payload_digest(payload),
      "deadline" =>
        DateTime.to_iso8601(
          if(type in ["inspect", "read_events", "ack_events"],
            do: DateTime.add(DateTime.utc_now(:second), 60),
            else: turn.deadline
          )
        ),
      "type" => type,
      "payload" => payload
    }
  end
end
