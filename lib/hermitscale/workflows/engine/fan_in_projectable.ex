defimpl Runic.Identity.Projectable, for: Hermitscale.Workflows.Engine.FanIn do
  def identity_document(node) do
    %{kind: :collection_fan_in, name: node.name, parent: node.parent, map: node.map_id}
  end
end
