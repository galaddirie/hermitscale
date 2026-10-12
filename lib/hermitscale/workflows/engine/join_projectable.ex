defimpl Runic.Identity.Projectable, for: Hermitscale.Workflows.Engine.Join do
  def identity_document(node) do
    %{kind: :item_join, name: node.name, parents: node.parents}
  end
end
