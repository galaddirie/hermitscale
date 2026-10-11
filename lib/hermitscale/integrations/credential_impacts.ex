defmodule Hermitscale.Integrations.CredentialImpacts do
  @moduledoc """
  Locates graph JSON references to a connected account and disables dependent triggers.

  This is the explicit impact lookup while credential bindings remain embedded
  in graph definitions rather than normalized in their own table.
  """

  # TODO: Suspect
  import Ecto.Query

  alias Hermitscale.Integrations.ConnectedAccount
  alias Hermitscale.Repo
  alias Hermitscale.Triggers.Trigger
  alias Hermitscale.Workflows.Graph

  @doc """
  Disables triggers belonging to graphs that reference the connected account.
  """
  def disable_triggers(%ConnectedAccount{} = account) do
    graph_ids =
      Graph
      |> where([graph], graph.org_id == ^account.org_id)
      |> select([graph], {graph.id, graph.definition})
      |> Repo.all()
      |> Enum.filter(fn {_id, definition} -> contains_reference?(definition, account.id) end)
      |> Enum.map(&elem(&1, 0))

    case graph_ids do
      [] ->
        0

      ids ->
        {count, _rows} =
          from(trigger in Trigger, where: trigger.workflow_graph_id in ^ids)
          |> Repo.update_all(
            set: [
              status: :disabled,
              error: %{
                "reason" => "connected_account_unavailable",
                "connected_account_id" => account.id
              },
              updated_at: DateTime.utc_now(:second)
            ]
          )

        count
    end
  end

  defp contains_reference?(value, id) when is_map(value) do
    Enum.any?(value, fn
      {key, ^id} when key in ["connected_account_id", :connected_account_id] -> true
      {_key, nested} -> contains_reference?(nested, id)
    end)
  end

  defp contains_reference?(value, id) when is_list(value) do
    Enum.any?(value, &contains_reference?(&1, id))
  end

  defp contains_reference?(_value, _id), do: false
end
