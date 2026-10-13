defmodule Hermitscale.Agents.SourceBundle do
  @moduledoc "Private, immutable app source references resolved before workspace setup."
  alias Hermitscale.Artifacts
  def validate(_scope, bundle) when bundle == %{}, do: :ok

  def validate(scope, bundle) do
    with {:ok, _resolved} <- resolve(scope, bundle), do: :ok
  end

  def resolve(_scope, bundle) when bundle == %{}, do: {:ok, nil}

  def resolve(
        scope,
        %{
          "artifact_id" => id,
          "artifact_digest" => digest,
          "deployed_revision" => revision,
          "app_id" => app_id
        } = bundle
      )
      when is_binary(revision) do
    with true <-
           Enum.sort(Map.keys(bundle)) == ~w(app_id artifact_digest artifact_id deployed_revision),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, revision),
         {:ok, artifact} <- Artifacts.get(scope, id),
         true <-
           artifact.owner_type == "app" and artifact.owner_id == app_id and
             artifact.kind == "source_bundle" and artifact.digest == digest do
      {:ok,
       %{
         content: artifact.content,
         artifact_digest: artifact.digest,
         deployed_revision: revision,
         artifact_id: artifact.id,
         app_id: app_id
       }}
    else
      false -> {:error, :invalid_source_bundle}
      {:error, _reason} = error -> error
    end
  end

  def resolve(_scope, _invalid), do: {:error, :invalid_source_bundle}
end
