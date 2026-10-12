defimpl Runic.Component, for: Hermitscale.Workflows.Engine.Collect do
  alias Runic.Workflow

  def connect(node, parent, workflow) do
    workflow
    |> Workflow.add_step(parent, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :collect})
    |> Workflow.register_component(node)
  end

  def connectable?(_node, _other), do: true
  def hash(node), do: node.hash
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any]]

  def source(node) do
    quote do
      Hermitscale.Workflows.Engine.Collect.new(
        unquote(node.name),
        unquote(Macro.escape(node.parent)),
        unquote(node.map_id)
      )
    end
  end
end
