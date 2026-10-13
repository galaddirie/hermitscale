defmodule Hermitscale.ProductFixtures do
  @moduledoc false
  alias Hermitscale.{Auth, AuthTest.Provider, Reviews, Workflows}
  alias Hermitscale.Integrations.ExecutionAccess

  def authenticated_product_fixture do
    configure_product_fixture(Auth, provider: Provider)
    ExUnit.Callbacks.start_supervised!({Provider, %{}})
    {:ok, authentication} = Auth.sign_in("team-code")
    authentication
  end

  def configure_product_fixture(module, options) do
    previous = Application.get_env(:hermitscale, module)
    Application.put_env(:hermitscale, module, options)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:hermitscale, module)
        previous -> Application.put_env(:hermitscale, module, previous)
      end
    end)
  end

  def product_graph_fixture(scope, attrs \\ %{}) do
    definition =
      Hermitscale.WorkflowsFixtures.valid_join_graph(%{
        "nodes" => [
          %{
            "id" => "sum",
            "type" => "math",
            "version" => 1,
            "params" => %{"operation" => "add", "left" => 1, "right" => 2}
          }
        ],
        "connections" => []
      })

    id = "wf_product_#{System.unique_integer([:positive])}"

    attrs =
      Hermitscale.WorkflowsFixtures.graph_attrs(
        Map.merge(%{id: id, definition: definition}, Map.new(attrs))
      )

    {:ok, graph} = Workflows.create_graph(scope, attrs)
    graph
  end

  def review_attrs_fixture(attrs \\ %{}) do
    Map.merge(
      %{
        operation_key: Ecto.UUID.generate(),
        action: "reviews.test",
        target: %{"branch" => "fix/ENG-7", "manifest" => ["lib/fix.ex"]},
        target_digest:
          Hermitscale.Agents.Protocol.payload_digest(%{
            "branch" => "fix/ENG-7",
            "manifest" => ["lib/fix.ex"]
          }),
        policy_revision: 1
      },
      Map.new(attrs)
    )
  end

  def review_fixture(scope, attrs \\ %{}) do
    {:ok, review} = Reviews.request(scope, review_attrs_fixture(attrs))
    review
  end

  def product_capability_fixture(scope, resources, actions, options \\ []) do
    {:ok, issued} = ExecutionAccess.issue_product(scope, resources, actions, options)
    issued
  end

  def inference_capability_fixture(scope, turn, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          kind: "inference",
          resource_ids: [turn.id],
          actions: ["responses"],
          operation_id: turn.id,
          connection: %{"provider" => "openai", "account_id" => "data_openai"},
          models: ["test-model"],
          remaining_calls: 5,
          remaining_cost_micros: 100_000,
          ttl_seconds: 60
        },
        Map.new(attrs)
      )

    {:ok, issued} = ExecutionAccess.issue(scope, attrs)
    issued
  end

  def expire_fixture(record) do
    record
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second))
    |> Hermitscale.Repo.update!()
  end
end
