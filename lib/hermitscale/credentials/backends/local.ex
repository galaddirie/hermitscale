defmodule Hermitscale.Credentials.Backends.Local do
  @moduledoc """
  Self-hosted credential backend: secret material lives in the
  `credential_secrets` table, encrypted at rest by
  `Hermitscale.Credentials.LocalVault`.

  Pure storage — it does not declare `:managed_oauth`, so OAuth flows and
  refresh run in the shared `Hermitscale.Credentials` layer. Each
  `put_secret/2` writes a new version; `get_secret/2` reads the latest. The
  `external_ref` is the credential id itself.
  """

  @behaviour Hermitscale.Credentials.Backend

  import Ecto.Query

  alias Hermitscale.Credentials.Backends.Local.Secret
  alias Hermitscale.Credentials.SecretPayload
  alias Hermitscale.Repo

  @impl true
  def id, do: "local"

  @impl true
  def capabilities, do: [:secret_versions]

  @impl true
  def put_secret(payload, %{credential_id: credential_id}) do
    map = SecretPayload.to_map(payload)

    Repo.transaction(fn ->
      changeset =
        Secret.changeset(%Secret{}, %{
          credential_id: credential_id,
          payload: map,
          version: next_version(credential_id)
        })

      case Repo.insert(changeset) do
        {:ok, _secret} -> credential_id
        {:error, changeset} -> Repo.rollback({:invalid_secret, changeset})
      end
    end)
  end

  @impl true
  def get_secret(external_ref, _ctx) do
    Secret
    |> where([s], s.credential_id == ^external_ref)
    |> order_by([s], desc: s.version)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      secret -> SecretPayload.from_map(secret.payload)
    end
  end

  @impl true
  def delete_secret(external_ref, _ctx) do
    Secret
    |> where([s], s.credential_id == ^external_ref)
    |> Repo.delete_all()

    :ok
  end

  defp next_version(credential_id) do
    Secret
    |> where([s], s.credential_id == ^credential_id)
    |> select([s], max(s.version))
    |> Repo.one()
    |> case do
      nil -> 1
      version -> version + 1
    end
  end
end
