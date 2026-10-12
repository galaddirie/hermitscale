defimpl Runic.Identity.Projectable, for: Hermitscale.Workflows.Engine.Node do
  def identity_document(node) do
    %{
      module: node.module,
      code_digest: node.code_digest,
      requires: node.requires,
      params: node.params,
      context: node.build_context,
      kind: node.kind
    }
  end
end
