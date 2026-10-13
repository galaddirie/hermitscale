defmodule Hermitscale.AgentsRuntimeFake do
  @moduledoc false
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  def init(options),
    do:
      {:ok,
       %{
         outcomes: Keyword.get(options, :outcomes, []),
         steps: [],
         publications: [],
         fail_release: Keyword.get(options, :fail_release, false)
       }}

  def step(_scope, session, turn, lease),
    do: GenServer.call(__MODULE__, {:step, session, turn, lease})

  def steps, do: GenServer.call(__MODULE__, :steps)
  def publications, do: GenServer.call(__MODULE__, :publications)
  def publish_branch(_workspace, _lease, attrs), do: GenServer.call(__MODULE__, {:publish, attrs})
  def ensure_allocated(_workspace), do: {:ok, %{compute_state: :sleeping}}

  def verify_termination(workspace, lease, proof),
    do: GenServer.call(__MODULE__, {:verify, workspace, lease, proof})

  def termination_evidence(workspace, lease), do: {:ok, proof(workspace.id, lease)}

  def handle_call(:publications, _from, state),
    do: {:reply, Enum.reverse(state.publications), state}

  def handle_call({:publish, attrs}, _from, state) do
    result = %{
      repository: attrs.repository,
      branch: attrs.branch,
      commit_sha: String.duplicate("b", 40)
    }

    {:reply, {:ok, result},
     %{state | publications: [Map.drop(attrs, [:credential]) | state.publications]}}
  end

  def handle_call(:steps, _from, state), do: {:reply, Enum.reverse(state.steps), state}

  def handle_call({:step, session, turn, lease}, _from, %{outcomes: [outcome | rest]} = state) do
    outcome =
      if outcome.status in [:succeeded, :failed, :interrupted, :cancelled],
        do: Map.put(outcome, :termination_evidence, proof(session.workspace_id, lease)),
        else: outcome

    {:reply, {:ok, Map.put_new(outcome, :events, [])},
     %{state | outcomes: rest, steps: [{turn, lease} | state.steps]}}
  end

  def handle_call({:verify, _workspace, _lease, _proof}, _from, %{fail_release: true} = state),
    do: {:reply, {:error, :termination_unverified}, %{state | fail_release: false}}

  def handle_call({:verify, workspace, lease, evidence}, _from, state) do
    reply =
      if evidence == proof(workspace.id, lease), do: :ok, else: {:error, :termination_unverified}

    {:reply, reply, state}
  end

  defp proof(workspace_id, lease),
    do: %{
      "workspace_id" => workspace_id,
      "lease_id" => lease.id,
      "operation_key" => lease.operation_key,
      "generation" => lease.generation,
      "writer_stopped" => true,
      "receipt" => "actual-fixture-receipt"
    }
end
