defmodule Hermitscale.WorkflowEditorFixtures do
  @moduledoc false
  alias Hermitscale.Workflows

  def workflow_fixture(scope) do
    id = "wf_" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, graph} =
      Workflows.create_graph(scope, %{
        id: id,
        name: "A saved workflow",
        status: :draft,
        definition: %{
          "schema_version" => 1,
          "id" => id,
          "name" => "A saved workflow",
          "nodes" => [%{"id" => "start", "type" => "debug", "version" => 1, "params" => %{}}],
          "connections" => []
        }
      })

    graph
  end
end
