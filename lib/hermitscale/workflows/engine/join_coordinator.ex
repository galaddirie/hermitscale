defimpl Runic.Workflow.Coordinator, for: Hermitscale.Workflows.Engine.Join do
  defdelegate finalize(node, workflow, runnable), to: Hermitscale.Workflows.Engine.Coordination
end
