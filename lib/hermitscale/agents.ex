defmodule Hermitscale.Agents do
  @moduledoc """
  Durable private conversations, admitted turns, cancellation, and stored history.

  All user operations require a verified scope. Browser closure never cancels work.
  A runtime restart reconciles committed intent; it never replays an accepted effect.
  The retained worker executes bounded turns and reconciles accepted operations.
  """
  import Ecto.Query
  alias Ecto.Changeset
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.{Authorization, Repo, Workspaces}

  alias Hermitscale.Agents.{
    Event,
    Protocol,
    ReconcileWorker,
    Runtime,
    Session,
    Turn,
    RemoteRuntime
  }

  @doc "Publishes the current workspace branch under current actor authority and one fenced lease."
  def publish_branch(scope, session_id, attrs) when is_map(attrs) do
    with :ok <- Authorization.authorize(scope, "agents:publish"),
         {:ok, scope} <-
           Authorization.execution_scope(
             Scope.execution_context(scope, ["agents:read", "agents:publish"])
           ),
         {:ok, session} <- get_session(scope, session_id),
         {:ok, request} <- publication_request(attrs),
         {:ok, recorded} <- record_publication_request(session, request) do
      case Repo.get_by(Event,
             session_id: session.id,
             source_key: publication_key(request, "published")
           ) do
        nil -> publish_requested_branch(scope, session, recorded)
        completed -> finish_publication(scope, completed)
      end
    end
  end

  def publish_branch(_scope, _session_id, _attrs), do: {:error, :invalid_publication}

  defp publication_request(attrs) do
    request = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    request = Map.take(request, ~w(branch message operation_key))

    case request do
      %{"branch" => branch, "message" => message, "operation_key" => key}
      when is_binary(branch) and byte_size(branch) in 1..255 and is_binary(message) and
             byte_size(message) in 1..4096 and is_binary(key) and byte_size(key) in 8..128 ->
        {:ok, request}

      _invalid ->
        {:error, :invalid_publication}
    end
  end

  defp record_publication_request(session, request) do
    transaction_and_broadcast(session.id, fn ->
      current = lock_session!(session.id)
      key = publication_key(request, "requested")

      case Repo.get_by(Event, session_id: session.id, source_key: key) do
        %Event{payload: payload} = event ->
          if Map.take(payload, ~w(branch message operation_key)) != request,
            do: Repo.rollback(:publication_key_conflict)

          event

        nil ->
          payload =
            Map.put(
              request,
              "deadline",
              DateTime.to_iso8601(DateTime.add(DateTime.utc_now(:second), 300))
            )

          append_event!(current, %{id: nil}, "branch.requested", payload, key)
          Repo.get_by!(Event, session_id: session.id, source_key: key)
      end
    end)
  end

  defp publish_requested_branch(scope, session, event) do
    request = event.payload
    {:ok, deadline, 0} = DateTime.from_iso8601(request["deadline"])

    with {:ok, credential} <-
           Hermitscale.Integrations.ExecutionAccess.credential(
             scope,
             session,
             "github",
             ["repo"],
             ["agents:publish"]
           ),
         {:ok, lease} <-
           Workspaces.admit_lease(
             scope,
             session.workspace_id,
             "publish:" <> request["operation_key"],
             deadline
           ),
         {:ok, result} <-
           Workspaces.publish_branch(scope, session.workspace_id, lease.id, %{
             repository: session.repository,
             branch: request["branch"],
             message: request["message"],
             operation_key: request["operation_key"],
             credential: credential
           }),
         {:ok, completed} <-
           transaction_and_broadcast(session.id, fn ->
             current = lock_session!(session.id)
             payload = %{"result" => Jason.decode!(Jason.encode!(result)), "lease_id" => lease.id}
             key = publication_key(request, "published")
             append_event!(current, %{id: nil}, "branch.published", payload, key)
             Repo.get_by!(Event, session_id: session.id, source_key: key)
           end) do
      finish_publication(scope, completed)
    end
  end

  defp finish_publication(scope, event) do
    with {:ok, _lease} <- Workspaces.release_activity(scope, event.payload["lease_id"]),
         do: {:ok, event.payload["result"]}
  end

  defp publication_key(request, suffix),
    do: "publish:" <> request["operation_key"] <> ":" <> suffix

  def list_sessions(%Scope{} = scope) do
    with :ok <- Authorization.authorize(scope, "agents:read") do
      scope
      |> sessions()
      |> order_by([s], desc: s.updated_at, desc: s.id)
      |> limit(100)
      |> Repo.all()
    end
  end

  def get_session(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, "agents:read"),
         {:ok, id} <- uuid(id) do
      case Repo.get(sessions(scope), id) do
        nil -> {:error, :not_found}
        session -> {:ok, session}
      end
    end
  end

  def change_session(%Scope{} = scope, attrs \\ %{}) do
    %Session{
      org_id: Scope.organization_id!(scope),
      initiator_user_id: scope.user.id,
      workspace_id: Ecto.UUID.generate()
    }
    |> Session.changeset(attrs)
  end

  def change_turn(%Scope{} = scope, session_id, attrs \\ %{}) do
    %Turn{
      org_id: Scope.organization_id!(scope),
      execution_actor_user_id: scope.user.id,
      session_id: session_id
    }
    |> Turn.changeset(attrs)
  end

  @doc "Creates a conversation and retained workspace identity atomically, without waking compute."
  def start_session(%Scope{} = scope, attrs) when is_map(attrs) do
    with {:ok, scope} <- execution_scope(scope) do
      Repo.transaction(fn ->
        id = Ecto.UUID.generate()
        changeset = change_session(scope, attrs)
        if not changeset.valid?, do: Repo.rollback(changeset)

        candidate = Changeset.apply_changes(changeset)

        if candidate.operation_key do
          identity =
            Protocol.payload_digest(%{
              "resource" => "agent_session",
              "organization" => candidate.org_id,
              "actor" => candidate.initiator_user_id,
              "key" => candidate.operation_key
            })

          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [identity])
        end

        existing =
          if candidate.operation_key,
            do:
              Repo.get_by(Session,
                org_id: candidate.org_id,
                initiator_user_id: candidate.initiator_user_id,
                operation_key: candidate.operation_key
              ),
            else: nil

        if existing do
          fields = [:title, :repository, :base_sha, :connection_set]

          if Map.take(existing, fields) != Map.take(candidate, fields),
            do: Repo.rollback(:session_key_conflict)

          existing
        else
          workspace_attrs =
            Map.take(Changeset.apply_changes(changeset), [:repository, :base_sha])
            |> Map.update!(:repository, fn
              nil -> nil
              repository -> "github:" <> repository
            end)

          workspace = unwrap!(Workspaces.ensure_workspace(scope, id, workspace_attrs))

          %Session{
            id: id,
            org_id: Scope.organization_id!(scope),
            initiator_user_id: scope.user.id,
            workspace_id: workspace.id
          }
          |> Session.changeset(attrs)
          |> Repo.insert()
          |> unwrap!()
        end
      end)
    end
  end

  def start_session(%Scope{}, _attrs), do: {:error, :invalid_session_attributes}

  @doc "Admits immutable input and its dispatch job in the same transaction. Retries reuse a key."
  def submit_turn(%Scope{} = scope, session_id, attrs) when is_map(attrs) do
    with {:ok, scope} <- execution_scope(scope),
         {:ok, session} <- get_session(scope, session_id) do
      transaction_and_broadcast(session.id, fn ->
        session = lock_session!(session.id)
        changeset = change_turn(scope, session.id, attrs)
        if not changeset.valid?, do: Repo.rollback(changeset)
        candidate = Changeset.apply_changes(changeset)
        digest = input_digest(candidate)

        case Repo.get_by(Turn, session_id: session.id, operation_key: candidate.operation_key) do
          %Turn{input_digest: ^digest, execution_actor_user_id: actor} = existing
          when actor == scope.user.id ->
            existing

          %Turn{} ->
            Repo.rollback(:operation_key_conflict)

          nil ->
            if session.status != :open, do: Repo.rollback(:session_not_open)
            deadline = DateTime.add(DateTime.utc_now(:second), candidate.timeout_seconds, :second)

            turn =
              changeset
              |> Changeset.put_change(:input_digest, digest)
              |> Changeset.put_change(:admission_sequence, session.last_event_sequence + 1)
              |> Changeset.put_change(:deadline, deadline)
              |> Repo.insert()
              |> unwrap!()

            append_event!(
              session,
              turn,
              "turn.queued",
              %{"instructions" => turn.instructions},
              "queued:" <> turn.id
            )

            enqueue!(turn.id)
            turn
        end
      end)
    end
  end

  def submit_turn(%Scope{}, _session_id, _attrs), do: {:error, :invalid_turn_attributes}

  def list_turns(%Scope{} = scope, session_id, opts \\ []) do
    with {:ok, session} <- get_session(scope, session_id) do
      before = Keyword.get(opts, :before_admission_sequence, session.last_event_sequence + 1)
      batch_size = Keyword.get(opts, :limit, 100) |> min(200) |> max(1)

      Turn
      |> where([t], t.session_id == ^session.id and t.admission_sequence < ^before)
      |> order_by([t], desc: t.admission_sequence)
      |> limit(^batch_size)
      |> Repo.all()
    end
  end

  @doc "Reads monotonic persisted history after a sequence; no connection to the worker or Sprite."
  def list_events(%Scope{} = scope, session_id, opts \\ []) do
    with {:ok, session} <- get_session(scope, session_id) do
      after_sequence = Keyword.get(opts, :after_sequence, Keyword.get(opts, :after, 0))
      batch_size = Keyword.get(opts, :limit, 100) |> min(200) |> max(1)
      before = Keyword.get(opts, :before_sequence, session.last_event_sequence + 1)

      query =
        Event
        |> where(
          [e],
          e.session_id == ^session.id and e.sequence > ^after_sequence and e.sequence < ^before
        )

      if Keyword.has_key?(opts, :before_sequence) do
        query
        |> order_by([e], desc: e.sequence)
        |> limit(^batch_size)
        |> Repo.all()
        |> Enum.reverse()
      else
        query |> order_by([e], asc: e.sequence) |> limit(^batch_size) |> Repo.all()
      end
    end
  end

  def subscribe(%Scope{} = scope, session_id) do
    with {:ok, session} <- get_session(scope, session_id) do
      Phoenix.PubSub.subscribe(Hermitscale.PubSub, topic(session.id))
    end
  end

  @doc "Archives or closes visibility/admission while retaining the workspace and pending turn."
  def update_session(%Scope{} = scope, id, status) when status in [:open, :archived, :closed] do
    with {:ok, scope} <- execution_scope(scope),
         {:ok, session} <- get_session(scope, id) do
      transaction_and_broadcast(session.id, fn ->
        current = lock_session!(session.id)
        if current.status == :closed and status != :closed, do: Repo.rollback(:session_closed)
        current |> Changeset.change(status: status) |> Repo.update() |> unwrap!()
      end)
    end
  end

  def update_session(%Scope{}, _id, _status), do: {:error, :invalid_status}

  @doc "Records stop intent. Only undispatched work can be confirmed cancelled locally."
  def cancel_turn(%Scope{} = scope, turn_id) do
    with {:ok, scope} <- execution_scope(scope),
         {:ok, turn} <- get_turn(scope, turn_id) do
      transaction_and_broadcast(turn.session_id, fn ->
        session = lock_session!(turn.session_id)
        turn = Repo.get!(Turn, turn.id)

        cond do
          Turn.terminal?(turn) ->
            turn

          turn.cancellation_requested_at != nil ->
            turn

          true ->
            now = DateTime.utc_now(:second)
            cancelled? = turn.status == :queued and is_nil(turn.dispatched_at)
            attrs = %{cancellation_requested_at: now}

            attrs =
              if cancelled?,
                do: Map.merge(attrs, %{status: :cancelled, completed_at: now}),
                else: attrs

            updated = turn |> Changeset.change(attrs) |> Repo.update() |> unwrap!()
            type = if cancelled?, do: "turn.cancelled", else: "turn.cancellation_requested"

            append_event!(
              session,
              updated,
              type,
              %{"status" => Atom.to_string(updated.status)},
              "cancel:" <> turn.id
            )

            if not cancelled?, do: enqueue!(turn.id)
            updated
        end
      end)
    end
  end

  def get_turn(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, "agents:read"),
         {:ok, id} <- uuid(id) do
      org_id = Scope.organization_id!(scope)
      user_id = scope.user.id

      query =
        from t in Turn,
          join: s in Session,
          on: t.session_id == s.id,
          where: s.org_id == ^org_id and s.initiator_user_id == ^user_id

      case Repo.get(query, id) do
        nil -> {:error, :not_found}
        turn -> {:ok, turn}
      end
    end
  end

  @doc "Waits on committed turn updates, reattaching to the retained turn through its deadline."
  def await_turn(%Scope{} = scope, id) do
    with {:ok, turn} <- get_turn(scope, id),
         :ok <- subscribe(scope, turn.session_id) do
      try do
        await_turn_update(scope, turn.id, turn.session_id)
      after
        Phoenix.PubSub.unsubscribe(Hermitscale.PubSub, topic(turn.session_id))
      end
    end
  end

  defp await_turn_update(scope, id, session_id) do
    with {:ok, turn} <- get_turn(scope, id) do
      case Turn.terminal?(turn) do
        true ->
          {:ok, turn}

        false ->
          receive do
            {:agent_turn_updated, ^session_id, ^id} -> await_turn_update(scope, id, session_id)
          after
            max(DateTime.diff(turn.deadline, DateTime.utc_now(), :millisecond), 0) ->
              {:error, :turn_deadline_exceeded}
          end
      end
    end
  end

  def get_turn_by_operation(%Scope{} = scope, session_id, operation_key) do
    with {:ok, session} <- get_session(scope, session_id) do
      case Repo.get_by(Turn,
             session_id: session.id,
             org_id: session.org_id,
             operation_key: operation_key
           ) do
        nil -> {:error, :not_found}
        turn -> {:ok, turn}
      end
    end
  end

  @doc false
  def execution_identity(turn_id) do
    with {:ok, id} <- uuid(turn_id) do
      case Repo.get(Turn, id) do
        nil ->
          {:error, :not_found}

        turn ->
          {:ok,
           %Hermitscale.Integrations.ExecutionContext{
             organization_id: turn.org_id,
             actor_user_id: turn.execution_actor_user_id,
             required_permissions: ["agents:read", "agents:run"]
           }}
      end
    end
  end

  @doc false
  def reconcile_turn(%Scope{} = scope, id) do
    with :ok <- Authorization.authorize(scope, "agents:run"),
         {:ok, turn} <- get_turn(scope, id) do
      admitted =
        transaction_and_broadcast(turn.session_id, fn ->
          session = lock_session!(turn.session_id)
          turn = Repo.get!(Turn, turn.id)

          cond do
            Turn.terminal?(turn) ->
              turn

            earlier_pending?(turn) ->
              Repo.rollback(:waiting_for_previous_turn)

            DateTime.compare(turn.deadline, DateTime.utc_now(:second)) != :gt and
                is_nil(turn.lease_id) ->
              interrupt!(session, turn, "deadline_exceeded")

            turn.status == :queued ->
              turn
              |> Changeset.change(
                status: :provisioning,
                worker_command_id: Ecto.UUID.generate(),
                cancel_command_id: Ecto.UUID.generate()
              )
              |> Repo.update()
              |> unwrap!()

            true ->
              turn
          end
        end)

      with {:ok, turn} <- admitted do
        if Turn.terminal?(turn),
          do: settle_terminal(scope, turn),
          else: reconcile_admitted(scope, turn)
      end
    end
  end

  defp reconcile_admitted(scope, turn) do
    with {:ok, session} <- get_session(scope, turn.session_id),
         {:ok, lease} <- turn_lease(scope, session, turn) do
      case Runtime.step(scope, session, turn, lease) do
        {:ok, outcome} ->
          accept_runtime_outcome(scope, session, turn, lease, outcome)

        {:error, reason}
        when reason in [
               :sprites_token_missing,
               :connection_setup_required
             ] ->
          interrupt_after_termination(turn, Atom.to_string(reason))

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason}
      when reason in [
             :sprites_token_missing,
             :connection_setup_required
           ] ->
        interrupt_after_termination(turn, Atom.to_string(reason))

      {:error, _reason} = error ->
        error
    end
  end

  defp settle_terminal(_scope, %Turn{lease_id: nil} = turn), do: {:ok, turn}

  defp settle_terminal(scope, turn) do
    with {:ok, lease} <- Workspaces.get_lease(scope, turn.lease_id) do
      if lease.status == :released do
        with {:ok, _released} <- Workspaces.release_activity(scope, lease.id), do: {:ok, turn}
      else
        evidence =
          case turn.runtime_state["termination_evidence"] do
            nil -> Workspaces.termination_evidence(scope, lease.workspace_id, lease.id)
            proof -> {:ok, proof}
          end

        with {:ok, proof} <- evidence,
             {:ok, _released} <- Workspaces.release_lease(scope, lease.id, proof) do
          with {:ok, _released} <- Workspaces.release_activity(scope, lease.id), do: {:ok, turn}
        end
      end
    end
  end

  defp interrupt_after_termination(%Turn{lease_id: nil} = turn, reason),
    do: interrupt_undispatched_turn(turn.id, reason)

  defp interrupt_after_termination(turn, reason) do
    with %Session{} = session <- Repo.get(Session, turn.session_id),
         {:ok, _released} <- Workspaces.terminate_admitted(session.workspace_id, turn.lease_id) do
      transaction_and_broadcast(session.id, fn ->
        interrupt!(lock_session!(session.id), Repo.get!(Turn, turn.id), reason)
      end)
    end
  end

  @doc false
  def terminate_turn(id, reason) do
    with {:ok, id} <- uuid(id), %Turn{} = turn <- Repo.get(Turn, id) do
      interrupt_after_termination(turn, reason)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp turn_lease(scope, session, %Turn{lease_id: nil} = turn) do
    with {:ok, lease} <-
           Workspaces.admit_lease(scope, session.workspace_id, turn.operation_key, turn.deadline),
         {:ok, _} <-
           transaction_and_broadcast(session.id, fn ->
             _session = lock_session!(session.id)

             Repo.get!(Turn, turn.id)
             |> Changeset.change(lease_id: lease.id)
             |> Repo.update()
             |> unwrap!()
           end),
         do: {:ok, lease}
  end

  defp turn_lease(scope, _session, turn), do: Workspaces.get_lease(scope, turn.lease_id)

  defp accept_runtime_outcome(scope, session, turn, lease, outcome) do
    events = Map.get(outcome, :events, [])

    with {:ok, _} <- record_worker_events(scope, turn.id, lease.id, events),
         {:ok, outcome} <- validate_outcome(scope, session, turn, outcome),
         {:ok, updated} <-
           transaction_and_broadcast(session.id, fn ->
             current = Repo.get!(Turn, turn.id)
             _session = lock_session!(session.id)
             worker = Map.get(outcome, :worker_state, %{})

             worker =
               if Map.has_key?(outcome, :termination_evidence),
                 do: Map.put(worker, "termination_evidence", outcome.termination_evidence),
                 else: worker

             last = List.last(events)

             attrs = %{
               status: outcome.status,
               runtime_state: worker,
               worker_epoch: if(last, do: last["epoch"], else: current.worker_epoch),
               worker_cursor: if(last, do: last["cursor"], else: current.worker_cursor),
               approval_id: Map.get(outcome, :approval_id, current.approval_id),
               provider_conversation_id: worker["provider_session_id"],
               result: Map.get(outcome, :result, current.result),
               error:
                 if(Map.has_key?(outcome, :error),
                   do: %{"reason" => outcome.error},
                   else: current.error
                 ),
               dispatched_at: current.dispatched_at || DateTime.utc_now(:second)
             }

             attrs =
               if outcome.status in [:succeeded, :failed, :interrupted, :cancelled],
                 do: Map.put(attrs, :completed_at, DateTime.utc_now(:second)),
                 else: attrs

             updated = current |> Changeset.change(attrs) |> Repo.update() |> unwrap!()
             provider_id = updated.provider_conversation_id

             if provider_id,
               do:
                 lock_session!(session.id)
                 |> Changeset.change(provider_conversation_id: provider_id)
                 |> Repo.update()
                 |> unwrap!()

             append_event!(
               lock_session!(session.id),
               updated,
               "turn." <> Atom.to_string(updated.status),
               %{"status" => Atom.to_string(updated.status)},
               "state:" <>
                 turn.id <>
                 ":" <>
                 Atom.to_string(updated.status) <> ":" <> Integer.to_string(updated.worker_cursor)
             )

             updated
           end) do
      if Turn.terminal?(updated) and Map.has_key?(outcome, :termination_evidence) do
        with {:ok, _} <- Workspaces.release_lease(scope, lease.id, outcome.termination_evidence) do
          with {:ok, _released} <- Workspaces.release_activity(scope, lease.id),
               do: {:ok, updated}
        end
      else
        {:ok, updated}
      end
    end
  end

  defp validate_outcome(_scope, session, turn, %{status: :succeeded} = outcome) do
    result = Map.get(outcome, :result, %{})

    case Hermitscale.Agents.Result.validate(result, turn.result_schema) do
      :ok ->
        {:ok, Map.put(outcome, :result, conversation_result(session, result))}

      {:error, reason} ->
        {:ok,
         outcome
         |> Map.put(:status, :failed)
         |> Map.put(:result, %{"outcome" => "invalid_result", "reason" => inspect(reason)})}
    end
  end

  defp validate_outcome(_scope, session, _turn, %{result: result} = outcome) when is_map(result),
    do: {:ok, %{outcome | result: conversation_result(session, result)}}

  defp validate_outcome(_scope, _session, _turn, outcome), do: {:ok, outcome}

  defp conversation_result(session, result) when is_map(result),
    do: Map.merge(result, %{"session_id" => session.id, "workspace_id" => session.workspace_id})

  defp conversation_result(session, _result),
    do: %{"session_id" => session.id, "workspace_id" => session.workspace_id}

  def answer_approval(scope, turn_id, decision) do
    with {:ok, scope} <- execution_scope(scope),
         {:ok, turn} <- get_turn(scope, turn_id),
         true <- turn.status == :waiting_for_approval,
         {:ok, approval} <-
           Hermitscale.Agents.Approvals.decide(scope, turn.approval_id, decision),
         {:ok, session} <- get_session(scope, turn.session_id),
         {:ok, lease} <- Workspaces.get_lease(scope, turn.lease_id),
         request = turn.runtime_state["approval_request"],
         true <- is_map(request),
         :ok <-
           if(decision == :approved,
             do:
               Hermitscale.Agents.Approvals.authorize_decision(
                 scope,
                 approval.id,
                 "agents.approve",
                 Protocol.payload_digest(request),
                 1
               ),
             else: :ok
           ),
         {:ok, _} <-
           Workspaces.worker_command(
             scope,
             session.workspace_id,
             lease.id,
             RemoteRuntime.envelope(
               turn,
               lease,
               "approve",
               %{
                 "request_id" => request["request_id"],
                 "response" => if(decision == :approved, do: "approved", else: "denied")
               },
               approval.id
             )
           ) do
      transaction_and_broadcast(session.id, fn ->
        _s = lock_session!(session.id)

        updated =
          Repo.get!(Turn, turn.id)
          |> Changeset.change(status: :running)
          |> Repo.update()
          |> unwrap!()

        enqueue!(turn.id)
        updated
      end)
    else
      false -> {:error, :stale_approval}
      {:error, _} = error -> error
    end
  end

  defp interrupt!(_session, %Turn{status: status} = turn, _reason)
       when status in [:succeeded, :failed, :interrupted, :cancelled],
       do: turn

  defp interrupt!(session, turn, reason) do
    updated =
      turn
      |> Changeset.change(
        status: :interrupted,
        completed_at: DateTime.utc_now(:second),
        error: %{"reason" => reason}
      )
      |> Repo.update()
      |> unwrap!()

    append_event!(
      session,
      updated,
      "turn.interrupted",
      %{"reason" => reason},
      "interrupted:" <> turn.id
    )

    updated
  end

  defp earlier_pending?(turn) do
    Repo.exists?(
      from t in Turn,
        where:
          t.session_id == ^turn.session_id and t.id != ^turn.id and
            t.status in [
              :queued,
              :provisioning,
              :running,
              :waiting_for_input,
              :waiting_for_approval
            ] and
            t.admission_sequence < ^turn.admission_sequence
    )
  end

  defp append_event!(session, turn, type, payload, source_key) do
    case Repo.get_by(Event, session_id: session.id, source_key: source_key) do
      %Event{turn_id: turn_id, type: ^type, payload: ^payload} when turn_id == turn.id -> session
      %Event{} -> Repo.rollback(:event_source_conflict)
      nil -> insert_event!(session, turn, type, payload, source_key)
    end
  end

  defp insert_event!(session, turn, type, payload, source_key) do
    sequence = session.last_event_sequence + 1

    %Event{org_id: session.org_id, session_id: session.id, turn_id: turn.id}
    |> Event.changeset(%{
      sequence: sequence,
      source_key: source_key,
      source_digest: Protocol.payload_digest(payload),
      type: type,
      payload: payload
    })
    |> Repo.insert()
    |> unwrap!()

    session |> Changeset.change(last_event_sequence: sequence) |> Repo.update() |> unwrap!()
  end

  @doc """
  Commits a bounded worker batch under its admitted lease.
  Worker events are evidence only and cannot approve actions or settle a turn.
  """
  def record_worker_events(scope, turn_id, lease_id, events)
      when is_list(events) and length(events) <= 100 do
    with {:ok, scope} <- execution_scope(scope),
         {:ok, turn} <- get_turn(scope, turn_id),
         {:ok, session} <- get_session(scope, turn.session_id) do
      transaction_and_broadcast(session.id, fn ->
        session = lock_session!(session.id)

        lease =
          Workspaces.validate_lease(scope, lease_id, lock: true, purpose: :evidence) |> unwrap!()

        if lease.workspace_id != session.workspace_id or
             lease.operation_key != turn.operation_key,
           do: Repo.rollback(:event_identity_mismatch)

        {records, _session} =
          Enum.map_reduce(events, session, fn raw, current ->
            event = Protocol.validate_event(raw) |> unwrap!()

            if event["workspace_id"] != session.workspace_id or event["operation_id"] != turn.id,
              do: Repo.rollback(:event_identity_mismatch)

            source_key = Enum.join([event["workspace_id"], event["epoch"], event["cursor"]], ":")
            digest = Protocol.payload_digest(event)

            case Repo.get_by(Event, session_id: session.id, source_key: source_key) do
              %Event{source_digest: ^digest} = record ->
                {record, current}

              %Event{} ->
                Repo.rollback(:event_source_conflict)

              nil ->
                payload = Protocol.redact_payload(event["payload"])

                record =
                  %Event{org_id: session.org_id, session_id: session.id, turn_id: turn.id}
                  |> Event.changeset(%{
                    sequence: current.last_event_sequence + 1,
                    source_key: source_key,
                    source_digest: digest,
                    type: "worker." <> event["type"],
                    payload: payload
                  })
                  |> Repo.insert()
                  |> unwrap!()

                updated =
                  current
                  |> Changeset.change(last_event_sequence: record.sequence)
                  |> Repo.update()
                  |> unwrap!()

                {record, updated}
            end
          end)

        records
      end)
    end
  end

  def record_worker_events(_scope, _turn_id, _lease_id, _events),
    do: {:error, :invalid_event_batch}

  @doc false
  def interrupt_undispatched_turn(id, reason) do
    with {:ok, id} <- uuid(id) do
      case Repo.get(Turn, id) do
        nil ->
          {:error, :not_found}

        turn ->
          transaction_and_broadcast(turn.session_id, fn ->
            session = lock_session!(turn.session_id)
            current = Repo.get!(Turn, id)

            cond do
              Turn.terminal?(current) ->
                current

              current.status in [:queued, :provisioning] and is_nil(current.dispatched_at) ->
                interrupt!(session, current, reason)

              true ->
                Repo.rollback(:termination_unconfirmed)
            end
          end)
      end
    end
  end

  defp sessions(scope) do
    org_id = Scope.organization_id!(scope)
    user_id = scope.user.id
    from s in Session, where: s.org_id == ^org_id and s.initiator_user_id == ^user_id
  end

  defp execution_scope(scope) do
    with :ok <- Authorization.authorize(scope, "agents:run") do
      scope
      |> Scope.execution_context(["agents:read", "agents:run"])
      |> Authorization.execution_scope()
    end
  end

  defp lock_session!(id), do: Repo.one!(from s in Session, where: s.id == ^id, lock: "FOR UPDATE")

  defp input_digest(turn) do
    :crypto.hash(
      :sha256,
      Jason.encode!([
        turn.instructions,
        turn.timeout_seconds,
        turn.result_schema,
        turn.verification_commands
      ])
    )
    |> Base.encode16(case: :lower)
  end

  defp enqueue!(id) do
    %{turn_id: id} |> ReconcileWorker.new() |> Oban.insert() |> unwrap!()
  end

  defp unwrap!({:ok, value}), do: value
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)

  defp uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp topic(id), do: "agent_sessions:" <> id

  defp transaction_and_broadcast(id, fun) do
    case Repo.transaction(fun) do
      {:ok, value} ->
        :ok =
          Phoenix.PubSub.broadcast(Hermitscale.PubSub, topic(id), {:agent_session_updated, id})

        case value do
          %Turn{} = turn ->
            Phoenix.PubSub.broadcast(
              Hermitscale.PubSub,
              topic(id),
              {:agent_turn_updated, id, turn.id}
            )

          _other_resource ->
            :ok
        end

        {:ok, value}

      {:error, _reason} = error ->
        error
    end
  end
end
