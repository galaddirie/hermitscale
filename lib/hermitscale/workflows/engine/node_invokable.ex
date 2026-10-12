defimpl Runic.Workflow.Invokable, for: Hermitscale.Workflows.Engine.Node do
  alias Hermitscale.Workflows.Engine.Metadata
  alias Runic.Workflow.SingleOutput

  def match_or_execute(_node), do: :execute

  def prepare(node, workflow, fact) do
    fact = %{fact | meta: Metadata.initialize(fact)}
    {:ok, runnable} = SingleOutput.prepare(node, workflow, fact)

    context = %{
      runnable.context
      | meta_context: Map.put(runnable.context.meta_context, :_hermitscale_input_id, fact.hash)
    }

    {:ok, %{runnable | context: context}}
  end

  defdelegate execute(node, runnable), to: Hermitscale.Workflows.Engine.Node

  def invoke(node, workflow, fact) do
    {:ok, runnable} = prepare(node, workflow, fact)
    Runic.Workflow.apply_runnable(workflow, execute(node, runnable))
  end
end
