defimpl Runic.Component, for: Hermitscale.Workflows.Engine.Node do
  alias Runic.Workflow

  def connect(node, parents, workflow) do
    workflow
    |> Workflow.add_step(parents, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: node.kind})
    |> Workflow.register_component(node)
  end

  def connectable?(_node, _other), do: true
  def hash(node), do: node.hash
  def source(node), do: Macro.escape(node)
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any]]
end
