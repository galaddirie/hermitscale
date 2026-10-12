defmodule Hermitscale.Workflows.Nodes.CollectionEffect.V1 do
  @moduledoc false

  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "test.collection_effect",
    version: 1,
    kind: :step,
    requires: [observer: []]

  @impl true
  def work(_params, item, %{observer: observer}) do
    send(observer, {:collection_effect, item})
    item
  end
end
