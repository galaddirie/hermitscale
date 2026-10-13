defmodule Hermitscale.Artifacts do
  @moduledoc "Private stored exports; historical reads never wake a workspace."
  alias Hermitscale.{Repo, Authorization}
  alias Hermitscale.Accounts.Scope
  alias Hermitscale.Artifacts.Artifact

  def record(scope, attrs) do
    content = Map.get(attrs, :content, Map.get(attrs, "content"))

    if is_binary(content) and byte_size(content) <= 8_388_608 do
      with :ok <- write_permission(scope) do
        digest = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

        base = %Artifact{
          org_id: Scope.organization_id!(scope),
          created_by_user_id: scope.user.id,
          content: content,
          digest: digest,
          size_bytes: byte_size(content)
        }

        cs = Artifact.changeset(base, attrs)

        with {:ok, _} <-
               Repo.insert(cs,
                 on_conflict: :nothing,
                 conflict_target: [:org_id, :owner_type, :owner_id, :kind, :digest]
               ) do
          candidate = Ecto.Changeset.apply_changes(cs)

          {:ok,
           Repo.get_by!(Artifact,
             org_id: candidate.org_id,
             owner_type: candidate.owner_type,
             owner_id: candidate.owner_id,
             kind: candidate.kind,
             digest: digest
           )}
        end
      end
    else
      {:error, :artifact_too_large_or_invalid}
    end
  end

  def get(scope, id) do
    with :ok <- permission(scope), {:ok, id} <- Ecto.UUID.cast(id) do
      case Repo.get_by(Artifact, id: id, org_id: Scope.organization_id!(scope)) do
        %Artifact{created_by_user_id: actor} = artifact when actor == scope.user.id ->
          if creator_read?(scope, artifact),
            do: {:ok, artifact},
            else: {:error, :not_found}

        %Artifact{owner_type: type} = artifact
        when type in ["app", "environment", "deployment", "backup"] ->
          if(Authorization.authorize(scope, "apps:read") == :ok,
            do: {:ok, artifact},
            else: {:error, :not_found}
          )

        %Artifact{} ->
          {:error, :not_found}

        nil ->
          {:error, :not_found}
      end
    else
      :error -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def read(scope, id) do
    with {:ok, artifact} <- get(scope, id), do: {:ok, artifact.content}
  end

  def find(scope, %{owner_type: type, owner_id: owner, kind: kind, digest: digest}) do
    with :ok <- permission(scope) do
      case Repo.get_by(Artifact,
             org_id: Scope.organization_id!(scope),
             owner_type: type,
             owner_id: owner,
             kind: kind,
             digest: digest
           ) do
        nil -> {:error, :not_found}
        artifact -> get(scope, artifact.id)
      end
    end
  end

  defp permission(scope),
    do:
      if(
        Enum.any?(
          ~w(agents:read agents:run apps:read apps:write apps:deploy),
          &(Authorization.authorize(scope, &1) == :ok)
        ),
        do: :ok,
        else: {:error, :forbidden}
      )

  defp write_permission(scope) do
    if Enum.any?(
         ~w(agents:run apps:write apps:deploy),
         &(Authorization.authorize(scope, &1) == :ok)
       ),
       do: :ok,
       else: {:error, :forbidden}
  end

  defp creator_read?(scope, %{owner_type: type}) when type in ["session", "turn"],
    do: Authorization.authorize(scope, "agents:read") == :ok

  defp creator_read?(scope, _artifact), do: Authorization.authorize(scope, "apps:read") == :ok
end
