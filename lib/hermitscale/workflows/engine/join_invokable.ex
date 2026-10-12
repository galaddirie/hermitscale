defimpl Runic.Workflow.Invokable, for: Hermitscale.Workflows.Engine.Join do
  alias Hermitscale.Workflows.Engine.Coordination

  def match_or_execute(_node), do: :execute
  defdelegate prepare(node, workflow, fact), to: Coordination
  defdelegate execute(node, runnable), to: Coordination
  defdelegate invoke(node, workflow, fact), to: Coordination
end
