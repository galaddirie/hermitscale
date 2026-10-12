defimpl Runic.Workflow.Coordinator, for: Hermitscale.Workflows.Engine.Collect do
  defdelegate finalize(node, workflow, runnable), to: Hermitscale.Workflows.Engine.Coordination
end
