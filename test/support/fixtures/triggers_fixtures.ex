defmodule Hermitscale.TriggersFixtures do
  @moduledoc """
  Test fixtures for trigger-bearing workflow graphs.
  """

  alias Hermitscale.{Triggers, Workflows}

  def trigger_graph(trigger_node, attrs \\ %{}) do
    attrs = Map.new(attrs)
    trigger_id = trigger_node["id"]

    Map.merge(
      %{
        "schema_version" => 1,
        "id" => "wf_#{trigger_id}_probe",
        "name" => "#{trigger_id}_probe",
        "nodes" => [
          trigger_node,
          %{"id" => "echo", "type" => "test.identity_probe", "version" => 1, "params" => %{}}
        ],
        "connections" => [%{"from" => trigger_id, "to" => "echo"}]
      },
      attrs
    )
  end

  def manual_trigger_node(params \\ %{}) do
    %{"id" => "start", "type" => "trigger.manual", "version" => 1, "params" => params}
  end

  def webhook_trigger_node(params \\ %{}) do
    %{"id" => "hook", "type" => "trigger.webhook", "version" => 1, "params" => params}
  end

  def schedule_trigger_node(params \\ %{"cron" => "*/5 * * * *"}) do
    %{"id" => "cron", "type" => "trigger.schedule", "version" => 1, "params" => params}
  end

  def polling_trigger_node(params \\ %{}) do
    %{"id" => "poll", "type" => "test.counter_poll_probe", "version" => 1, "params" => params}
  end

  def stream_trigger_node(params \\ %{}) do
    %{"id" => "stream", "type" => "test.relay_stream_probe", "version" => 1, "params" => params}
  end

  @doc """
  Inserts a graph for the given definition map.
  """
  def create_graph!(definition) do
    {:ok, graph} =
      Workflows.create_graph(%{
        id: definition["id"],
        name: definition["name"],
        schema_version: definition["schema_version"],
        definition: definition,
        status: :draft
      })

    graph
  end

  @doc """
  Inserts and activates a graph built around the given trigger node; returns
  `{graph, trigger}` for the single trigger.
  """
  def activate_trigger_graph!(trigger_node, attrs \\ %{}) do
    graph = create_graph!(trigger_graph(trigger_node, attrs))
    {:ok, %{graph: graph, triggers: [trigger]}} = Triggers.activate_graph(graph)
    {graph, trigger}
  end
end
