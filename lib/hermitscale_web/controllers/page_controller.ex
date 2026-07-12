defmodule HermitscaleWeb.PageController do
  use HermitscaleWeb, :controller

  alias Hermitscale.Workflows

  def home(conn, _params) do
    graphs = Workflows.list_graphs(conn.assigns.current_scope)

    render(conn, :home,
      graphs: graphs,
      workflow_counts: %{
        total: length(graphs),
        active: Enum.count(graphs, &(&1.status == :active)),
        draft: Enum.count(graphs, &(&1.status == :draft))
      }
    )
  end
end
