defmodule Hermitscale.Agents.Actions.Reconcile do
  @moduledoc "One bounded product reconciliation step; no model reasoning or remote retry loop."
  use Jido.Action,
    name: "reconcile_admitted_turn",
    schema: [scope: [type: :any, required: true], turn_id: [type: :string, required: true]]

  @impl true
  def run(%{scope: scope, turn_id: id}, _context) do
    case Hermitscale.Agents.reconcile_turn(scope, id) do
      {:ok, turn} ->
        {:ok, %{turn_id: turn.id, status: Atom.to_string(turn.status), outcome: :settled}}

      {:error, reason} ->
        {:ok, %{outcome: {:error, reason}}}
    end
  end
end
