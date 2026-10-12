defimpl Runic.Identity.Projectable, for: Hermitscale.Workflows.Engine.FanOut do
  def identity_document(node), do: %{kind: :collection_fan_out, name: node.name, map: node.map_id}
end
