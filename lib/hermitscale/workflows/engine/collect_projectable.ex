defimpl Runic.Identity.Projectable, for: Hermitscale.Workflows.Engine.Collect do
  def identity_document(node) do
    %{kind: :collection_collect, name: node.name, parent: node.parent, map: node.map_id}
  end
end
