defimpl Runic.Workflow.Activator, for: Hermitscale.Workflows.Engine.FanIn do
  def activate_downstream(_node, workflow, _runnable), do: {workflow, []}
end
