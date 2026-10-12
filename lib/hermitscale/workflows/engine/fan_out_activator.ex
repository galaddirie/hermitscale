defimpl Runic.Workflow.Activator, for: Hermitscale.Workflows.Engine.FanOut do
  defdelegate activate_downstream(node, workflow, runnable),
    to: Hermitscale.Workflows.Engine.FanOut,
    as: :activate
end
