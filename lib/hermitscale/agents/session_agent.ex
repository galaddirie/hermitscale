defmodule Hermitscale.Agents.SessionAgent do
  @moduledoc "Disposable Jido projection of committed conversation work; never a source of authority."
  use Jido.Agent,
    name: "hermitscale_session",
    schema: [
      session_id: [type: :string, default: ""],
      turn_id: [type: :string, default: ""],
      status: [type: :string, default: "queued"],
      outcome: [type: :any, default: nil]
    ],
    signal_routes: [{"turn.reconcile", Hermitscale.Agents.Actions.Reconcile}]

  @doc false
  def reconcile(scope, turn) do
    id = "session:" <> turn.session_id

    agent =
      new(
        id: id,
        state: %{
          session_id: turn.session_id,
          turn_id: turn.id,
          status: Atom.to_string(turn.status)
        }
      )

    with {:ok, pid} <- start(agent) do
      try do
        with {:ok, projection} <-
               Jido.AgentServer.call(
                 pid,
                 Jido.Signal.new!("turn.reconcile", %{scope: scope, turn_id: turn.id},
                   source: "/agents"
                 ),
                 min(
                   max(DateTime.diff(turn.deadline, DateTime.utc_now(), :millisecond), 60_000),
                   660_000
                 )
               ) do
          case projection.state.outcome do
            :settled -> {:ok, projection.state}
            {:error, reason} -> {:error, reason}
          end
        end
      after
        # Coordination is disposable even when its bounded step fails. Oban owns
        # durable recovery, so do not leave a second retry owner alive here.
        Jido.stop_agent(Hermitscale.AgentRuntime, id)
      end
    end
  end

  defp start(agent) do
    case Jido.start_agent(Hermitscale.AgentRuntime, agent, agent_module: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end
end
