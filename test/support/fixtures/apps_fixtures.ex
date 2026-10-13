defmodule Hermitscale.AppsFixtures do
  @moduledoc false
  alias Hermitscale.{Apps, AccountsFixtures, Reviews}

  def app_scope_fixture do
    scope = AccountsFixtures.organization_scope_fixture()

    %{
      scope
      | membership: %{
          scope.membership
          | permissions: AccountsFixtures.role_permissions_fixture("admin")
        }
    }
  end

  def app_fixture(scope, attrs \\ %{}) do
    {:ok, app} =
      Apps.create_app(
        scope,
        Map.merge(
          %{
            name: "Team notes",
            slug: "notes-" <> Integer.to_string(System.unique_integer([:positive]))
          },
          attrs
        )
      )

    app
  end

  def app_build_fixture(scope, app) do
    {:ok, session} = Apps.start_build(scope, app.id, %{operation_key: Ecto.UUID.generate()})
    session
  end

  def deployment_attrs_fixture(scope, app, session, source_commit \\ String.duplicate("a", 40)) do
    {:ok, built} =
      Apps.build_artifact(scope, app.id, session.id, source_commit, Ecto.UUID.generate())

    [environment] = Apps.list_environments(scope, app.id)

    %{
      session_id: session.id,
      source_commit: source_commit,
      artifact_id: built.artifact.id,
      artifact_digest: built.artifact.digest,
      configuration_digest: environment.configuration_digest,
      environment_id: environment.id,
      expected_active_deployment: environment.active_deployment_id,
      operation_key: Ecto.UUID.generate()
    }
  end

  def approve_deployment_fixture(scope, app, attrs) do
    {:ok, target} = Apps.deployment_target_digest(scope, app.id, attrs)
    approve_fixture(scope, "apps.deploy", target, "review:" <> attrs.operation_key)
  end

  def approve_fixture(scope, action, target, key \\ Ecto.UUID.generate()) do
    {:ok, review} =
      Reviews.request(scope, %{action: action, target_digest: target, operation_key: key})

    {:ok, review} = Reviews.decide(scope, review.id, :approved)
    review
  end

  def deployment_fixture(scope, app, session, commit \\ String.duplicate("a", 40)) do
    attrs = deployment_attrs_fixture(scope, app, session, commit)
    review = approve_deployment_fixture(scope, app, attrs)

    {:ok, deployment} =
      Apps.request_deployment(scope, app.id, Map.put(attrs, :review_id, review.id))

    {:ok, deployment} = Apps.reconcile_deployment(deployment.id)
    deployment
  end
end
