defimpl Runic.Component, for: Hermitscale.Workflows.Engine.Join do
  alias Runic.Workflow

  def connect(node, parents, workflow) do
    workflow
    |> Workflow.add_step(parents, node)
    |> Workflow.draw_connection(node, node, :component_of, properties: %{kind: :join})
    |> Workflow.register_component(node)
  end

  def connectable?(_node, _other), do: true
  def hash(node), do: node.hash
  def inputs(_node), do: [in: [type: :any]]
  def outputs(_node), do: [out: [type: :any]]

  def source(node) do
    quote do
      Hermitscale.Workflows.Engine.Join.new(
        unquote(node.name),
        unquote(Macro.escape(node.parents))
      )
    end
  end
end
