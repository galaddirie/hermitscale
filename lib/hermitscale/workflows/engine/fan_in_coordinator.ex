defimpl Runic.Workflow.Coordinator, for: Hermitscale.Workflows.Engine.FanIn do
  defdelegate finalize(node, workflow, runnable), to: Hermitscale.Workflows.Engine.Coordination
end
