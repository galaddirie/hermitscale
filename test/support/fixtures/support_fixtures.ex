defmodule Hermitscale.SupportFixtures do
  @moduledoc false
  import Hermitscale.AppsFixtures
  alias Hermitscale.{Agents, Apps, Reviews, Support}

  def support_subscription_fixture(scope, app_attrs \\ %{}) do
    app = app_fixture(scope, Map.merge(%{repository: "acme/support-app"}, app_attrs))

    {:ok, build} =
      Apps.start_build(scope, app.id, %{
        operation_key: Ecto.UUID.generate(),
        base_sha: String.duplicate("a", 40)
      })

    deployment = deployment_fixture(scope, app, build)
    {:ok, environment} = Apps.get_environment(scope, deployment.environment_id)

    {:ok, subscription} =
      Support.register_subscription(scope, app.id, environment.id, %{
        connection: %{"provider" => "linear", "account_id" => "data_linear"},
        connection_set: %{"openai" => %{"provider" => "openai", "account_id" => "data_openai"}},
        ticket_prefix: "ENG-"
      })

    %{
      app: app,
      build: build,
      deployment: deployment,
      environment: environment,
      subscription: subscription
    }
  end

  def support_case_fixture(scope, subscription, operation_key \\ Ecto.UUID.generate()) do
    {:ok, investigation} = Support.investigate(scope, subscription.id, "ENG-7", operation_key)

    {:ok, turn} =
      Agents.get_turn_by_operation(
        scope,
        investigation.session_id,
        "support-turn:" <> operation_key
      )

    %{investigation: investigation, turn: turn, operation_key: operation_key}
  end

  def support_reply_fixture(scope, investigation, attrs \\ %{}) do
    target =
      Map.merge(
        %{
          "case_id" => investigation.id,
          "body" =>
            "The current release has this limitation. Use the documented workaround while we prepare a fix.",
          "outcome" => "workaround"
        },
        attrs
      )

    {:ok, review} =
      Reviews.request(scope, %{
        action: "support.reply",
        operation_key: Ecto.UUID.generate(),
        policy_revision: 1,
        target: target,
        target_digest:
          Support.reply_digest(
            target["case_id"],
            target["body"],
            target["outcome"],
            target["deployment_id"]
          )
      })

    {:ok, review} = Reviews.decide(scope, review.id, :approved)
    target |> Map.put("review_id", review.id) |> Map.put("operation_key", Ecto.UUID.generate())
  end
end
