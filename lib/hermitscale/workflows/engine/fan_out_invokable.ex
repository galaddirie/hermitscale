defimpl Runic.Workflow.Invokable, for: Hermitscale.Workflows.Engine.FanOut do
  alias Hermitscale.Workflows.Engine.FanOut

  def match_or_execute(_node), do: :execute
  defdelegate prepare(node, workflow, fact), to: FanOut
  defdelegate execute(node, runnable), to: FanOut
  defdelegate invoke(node, workflow, fact), to: FanOut
end
