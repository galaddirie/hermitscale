defmodule Hermitscale.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Hermitscale.Repo

  alias Hermitscale.Accounts.{
    Organization,
    OrganizationMembership,
    OrganizationProvisioningWorker,
    Scope,
    User,
    UserNotifier,
    UserToken
  }

  alias Hermitscale.WorkOS.Client, as: WorkOSClient

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a non-deleted local user by their WorkOS User ID.
  """
  def get_user_by_workos_id(workos_user_id) when is_binary(workos_user_id) do
    Repo.one(
      from user in User,
        where: user.workos_user_id == ^workos_user_id and is_nil(user.deleted_at)
    )
  end

  @doc """
  Projects a verified WorkOS User onto a stable local user.

  WorkOS User IDs are the only identity join key. If another local row owns
  the email, the operation returns `{:error, :email_conflict}` and never links
  or merges the records.
  """
  def upsert_from_workos(workos_user) when is_map(workos_user) do
    with {:ok, attrs} <- workos_user_attrs(workos_user) do
      case Repo.get_by(User, workos_user_id: attrs.workos_user_id) do
        %User{} = user ->
          case deletion_marker(user) do
            %DateTime{} = marker ->
              handle_projection_after_deletion(user, attrs.workos_updated_at, marker)

            nil ->
              update_from_workos(user, attrs)
          end

        nil ->
          create_from_workos(attrs)
      end
    end
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    Repo.transact(fn ->
      with {:ok, user} <- %User{} |> User.email_changeset(attrs) |> Repo.insert() do
        {:ok, _org, _membership} = create_personal_organization(user)
        {:ok, user}
      end
    end)
  end

  @doc """
  Fetches or registers a user for an externally-verified identity.

  The email has already been proven by an identity provider, so new users
  are confirmed immediately (and get a personal organization via
  `register_user/1`). This is the entry point identity-provider callbacks
  use to provision users.
  """
  def get_or_register_user_by_email(email) when is_binary(email) do
    case get_user_by_email(email) do
      %User{} = user ->
        {:ok, user}

      nil ->
        Repo.transact(fn ->
          with {:ok, user} <- register_user(%{email: email}) do
            user |> User.confirm_changeset() |> Repo.update()
          end
        end)
    end
  end

  ## Organizations

  @doc """
  Creates a local shared organization and durably schedules its WorkOS mirror.

  The organization remains unavailable while its WorkOS Organization and
  creator membership are being provisioned.
  """
  def create_shared_organization(%Scope{user: %User{} = user}, attrs) when is_map(attrs) do
    with true <- is_binary(user.workos_user_id),
         nil <- user.deletion_pending_at,
         nil <- user.deleted_at do
      organization_id = Ecto.UUID.generate()

      Multi.new()
      |> Multi.insert(
        :organization,
        Organization.changeset(%Organization{}, %{
          id: organization_id,
          name: fetch_attr(attrs, :name),
          personal: false,
          provisioning_state: :provisioning
        })
      )
      |> Multi.insert(
        :membership,
        OrganizationMembership.changeset(%OrganizationMembership{}, %{
          org_id: organization_id,
          user_id: user.id,
          role: :owner,
          source: :workos,
          status: :inactive,
          workos_role_slug: "owner"
        })
      )
      |> Oban.insert(:provisioning_job, fn %{organization: organization} ->
        OrganizationProvisioningWorker.new(%{
          "organization_id" => organization.id,
          "owner_user_id" => user.id
        })
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{organization: organization}} -> {:ok, organization}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    else
      false -> {:error, :workos_user_unavailable}
      %DateTime{} -> {:error, :deletion_pending}
    end
  end

  @doc """
  Adds a WorkOS-managed member to the active shared organization.

  WorkOS is updated first and the returned membership is then projected into
  the local authorization read model.
  """
  def create_workos_membership(
        %Scope{} = scope,
        %User{} = user,
        role
      )
      when role in [:owner, :admin, :member] do
    with :ok <- authorize_membership_management(scope, role),
         :ok <- available_workos_user?(user),
         {:ok, remote_membership} <-
           workos_client().create_organization_membership(
             scope.organization.workos_organization_id,
             user.workos_user_id,
             Atom.to_string(role)
           ),
         true <- is_map(remote_membership) do
      sync_workos_membership(remote_membership, :upsert)
    else
      false -> {:error, :invalid_workos_membership_response}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Changes the WorkOS role for a mapped shared-organization membership.
  """
  def update_workos_membership(
        %Scope{} = scope,
        %OrganizationMembership{} = membership,
        role
      )
      when role in [:owner, :admin, :member] do
    with :ok <- authorize_existing_membership(scope, membership, role),
         membership_id when is_binary(membership_id) <- membership.workos_membership_id,
         {:ok, response} <-
           workos_client().update_organization_membership(
             membership_id,
             Atom.to_string(role)
           ) do
      project_membership_command_response(membership, response, %{
        role: role,
        workos_role_slug: Atom.to_string(role),
        status: :active
      })
    else
      nil -> {:error, :unmapped_membership}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Deactivates a WorkOS membership and immediately removes local authority.
  """
  def deactivate_workos_membership(
        %Scope{} = scope,
        %OrganizationMembership{} = membership
      ) do
    with :ok <- authorize_existing_membership(scope, membership, membership.role),
         true <- membership.user_id != scope.user.id,
         membership_id when is_binary(membership_id) <- membership.workos_membership_id,
         {:ok, response} <- workos_client().deactivate_organization_membership(membership_id),
         {:ok, membership} <-
           project_membership_command_response(membership, response, %{status: :inactive}),
         {:ok, _count} <-
           Hermitscale.WorkOS.Session.revoke_for_user_organization(
             membership.user_id,
             membership.org_id
           ) do
      Hermitscale.Integrations.ConnectedAccounts.disable_for_owner_organization(
        membership.user_id,
        membership.org_id
      )

      {:ok, membership}
    else
      false -> {:error, :cannot_deactivate_self}
      nil -> {:error, :unmapped_membership}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Lists the organizations the user belongs to, oldest membership first
  (a user's first organization is their personal one).
  """
  def list_user_organizations(%User{} = user) do
    Repo.all(
      from o in Organization,
        join: m in OrganizationMembership,
        on: m.org_id == o.id,
        where:
          m.user_id == ^user.id and m.status == :active and
            (o.personal == true or o.provisioning_state == :ready),
        order_by: [asc: m.inserted_at, asc: m.id]
    )
  end

  @doc """
  Gets the user's membership in the given organization, with the
  organization preloaded. Returns `nil` if the user is not a member.
  """
  def get_user_membership(%User{} = user, org_id) when is_binary(org_id) do
    Repo.one(
      from m in OrganizationMembership,
        where: m.user_id == ^user.id and m.org_id == ^org_id and m.status == :active,
        preload: [:organization]
    )
  end

  @doc """
  Gets a local shared organization by its WorkOS mapping.
  """
  def get_organization_by_workos_id(workos_organization_id)
      when is_binary(workos_organization_id) do
    Repo.get_by(Organization, workos_organization_id: workos_organization_id)
  end

  @doc false
  def list_workos_users_for_reconciliation do
    Repo.all(
      from user in User,
        where: not is_nil(user.workos_user_id) and is_nil(user.deleted_at)
    )
  end

  @doc false
  def list_workos_organizations_for_reconciliation do
    Repo.all(
      from organization in Organization,
        where:
          organization.personal == false and
            not is_nil(organization.workos_organization_id)
    )
  end

  @doc false
  def list_workos_memberships_for_reconciliation do
    Repo.all(
      from membership in OrganizationMembership,
        where:
          membership.source == :workos and
            not is_nil(membership.workos_membership_id),
        preload: [:user, :organization]
    )
  end

  @doc false
  def mark_workos_organization_missing(workos_organization_id, observed_at)
      when is_binary(workos_organization_id) and is_struct(observed_at, DateTime) do
    case get_organization_by_workos_id(workos_organization_id) do
      %Organization{} = organization ->
        case newer_projection?(observed_at, organization.workos_updated_at) do
          true ->
            organization
            |> Organization.changeset(%{
              provisioning_state: :unavailable,
              workos_updated_at: observed_at
            })
            |> Repo.update()

          false ->
            {:ok, organization}
        end

      nil ->
        {:ok, :already_missing}
    end
  end

  @doc false
  def mark_organization_provisioning_failed(%Organization{} = organization) do
    organization
    |> Organization.changeset(%{provisioning_state: :unavailable})
    |> Repo.update()
  end

  @doc false
  def mark_workos_membership_missing(workos_membership_id, observed_at)
      when is_binary(workos_membership_id) and is_struct(observed_at, DateTime) do
    case Repo.get_by(OrganizationMembership, workos_membership_id: workos_membership_id) do
      %OrganizationMembership{} = membership ->
        case newer_projection?(observed_at, membership.workos_updated_at) do
          true ->
            membership
            |> OrganizationMembership.changeset(%{
              status: :deleted,
              workos_updated_at: observed_at
            })
            |> Repo.update()

          false ->
            {:ok, membership}
        end

      nil ->
        {:ok, :already_missing}
    end
  end

  @doc """
  Applies a WorkOS organization projection to an existing local shared organization.
  """
  def sync_workos_organization(workos_organization, action \\ :upsert)

  def sync_workos_organization(workos_organization, :upsert) when is_map(workos_organization) do
    with {:ok, attrs} <- workos_organization_attrs(workos_organization),
         {:ok, organization} <- find_mapped_organization(attrs),
         true <- newer_projection?(attrs.workos_updated_at, organization.workos_updated_at) do
      organization
      |> Organization.changeset(attrs)
      |> Repo.update()
    else
      false -> existing_organization_result(workos_organization)
      {:error, _reason} = error -> error
    end
  end

  def sync_workos_organization(workos_organization, :delete)
      when is_map(workos_organization) do
    with {:ok, attrs} <- workos_organization_attrs(workos_organization),
         %Organization{} = organization <-
           get_organization_by_workos_id(attrs.workos_organization_id),
         true <- newer_projection?(attrs.workos_updated_at, organization.workos_updated_at) do
      organization
      |> Organization.changeset(%{
        provisioning_state: :unavailable,
        workos_updated_at: attrs.workos_updated_at
      })
      |> Repo.update()
    else
      false -> existing_organization_result(workos_organization)
      nil -> {:error, :unmapped_organization}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Synchronizes a mapped WorkOS organization membership.

  Unknown WorkOS role slugs are stored for diagnosis but projected inactive,
  so they cannot authorize local access.
  """
  def sync_workos_membership(workos_membership, action \\ :upsert)

  def sync_workos_membership(workos_membership, :upsert) when is_map(workos_membership) do
    with {:ok, attrs} <- workos_membership_attrs(workos_membership),
         %User{} = user <- get_user_by_workos_id(attrs.workos_user_id),
         %Organization{} = organization <-
           get_organization_by_workos_id(attrs.workos_organization_id) do
      upsert_membership(user, organization, attrs)
    else
      nil -> {:error, :unmapped_membership}
      {:error, _reason} = error -> error
    end
  end

  def sync_workos_membership(workos_membership, :delete) when is_map(workos_membership) do
    with {:ok, attrs} <- workos_membership_attrs(workos_membership),
         %OrganizationMembership{} = membership <-
           Repo.get_by(OrganizationMembership,
             workos_membership_id: attrs.workos_membership_id
           ),
         true <- newer_projection?(attrs.workos_updated_at, membership.workos_updated_at) do
      membership
      |> OrganizationMembership.changeset(%{
        status: :deleted,
        workos_updated_at: attrs.workos_updated_at
      })
      |> Repo.update()
    else
      false -> existing_membership_result(workos_membership)
      nil -> {:ok, :already_deleted}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Resolves the organization for a user's session.

  A session-stored org id is honored only when the user is actually a
  member; anything else falls back to the user's oldest membership (the
  personal organization today). A user left with no memberships at all —
  possible when their last organization is deleted — gets a fresh personal
  organization instead of crashing every request that builds a scope.
  Returns `{organization, membership}`.
  """
  def resolve_organization(%User{} = user, org_id) do
    membership =
      (is_binary(org_id) && get_user_membership(user, org_id)) ||
        oldest_membership(user) ||
        repair_personal_organization(user)

    {membership.organization, membership}
  end

  defp oldest_membership(%User{} = user) do
    Repo.one(
      from m in OrganizationMembership,
        join: organization in assoc(m, :organization),
        where:
          m.user_id == ^user.id and m.status == :active and
            (organization.personal == true or organization.provisioning_state == :ready),
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: 1,
        preload: [:organization]
    )
  end

  defp repair_personal_organization(%User{} = user) do
    {:ok, org, membership} = create_personal_organization(user)
    %{membership | organization: org}
  end

  defp create_personal_organization(%User{} = user) do
    case Repo.get_by(Organization, personal_owner_user_id: user.id) do
      %Organization{} = organization ->
        ensure_personal_membership(user, organization)

      nil ->
        org_attrs = %{
          id: Ecto.UUID.generate(),
          name: personal_org_name(user.email),
          personal: true,
          personal_owner_user_id: user.id,
          provisioning_state: :ready
        }

        with {:ok, org} <- %Organization{} |> Organization.changeset(org_attrs) |> Repo.insert(),
             {:ok, membership} <- insert_personal_membership(user, org) do
          {:ok, org, membership}
        end
    end
  end

  defp personal_org_name(email) do
    email |> String.split("@") |> hd()
  end

  defp create_from_workos(attrs) do
    case Repo.get_by(User, email: attrs.email) do
      %User{} ->
        {:error, :email_conflict}

      nil ->
        organization_id = Ecto.UUID.generate()

        Multi.new()
        |> Multi.insert(:user, User.workos_changeset(%User{}, attrs))
        |> Multi.insert(:organization, fn %{user: user} ->
          Organization.changeset(%Organization{}, %{
            id: organization_id,
            name: personal_org_name(user.email),
            personal: true,
            personal_owner_user_id: user.id,
            provisioning_state: :ready
          })
        end)
        |> Multi.insert(:membership, fn %{user: user, organization: organization} ->
          OrganizationMembership.changeset(%OrganizationMembership{}, %{
            org_id: organization.id,
            user_id: user.id,
            role: :owner,
            source: :local,
            status: :active
          })
        end)
        |> Repo.transaction()
        |> workos_user_transaction_result()
    end
  end

  defp update_from_workos(%User{} = user, attrs) do
    cond do
      not newer_projection?(attrs.workos_updated_at, user.workos_updated_at) ->
        {:ok, user}

      email_owned_by_another_user?(attrs.email, user.id) ->
        {:error, :email_conflict}

      true ->
        user
        |> User.workos_changeset(Map.put(attrs, :confirmed_at, confirmed_at(user, attrs)))
        |> Repo.update()
    end
  end

  defp deletion_marker(%User{deleted_at: %DateTime{} = deleted_at}), do: deleted_at

  defp deletion_marker(%User{deletion_pending_at: %DateTime{} = deletion_pending_at}),
    do: deletion_pending_at

  defp deletion_marker(%User{}), do: nil

  defp handle_projection_after_deletion(user, workos_updated_at, deletion_marker) do
    remote_second = DateTime.truncate(workos_updated_at, :second)

    case DateTime.compare(remote_second, deletion_marker) do
      ordering when ordering in [:lt, :eq] -> {:ok, user}
      :gt -> {:error, :deletion_pending}
    end
  end

  defp workos_user_transaction_result({:ok, %{user: user}}), do: {:ok, user}

  defp workos_user_transaction_result({:error, :user, changeset, _changes}) do
    case changeset.errors[:email] do
      {_message, [constraint: :unique, constraint_name: _name]} -> {:error, :email_conflict}
      _other -> {:error, changeset}
    end
  end

  defp workos_user_transaction_result({:error, _step, reason, _changes}), do: {:error, reason}

  defp confirmed_at(_user, %{email_verified: false}), do: nil
  defp confirmed_at(%User{confirmed_at: %DateTime{} = confirmed_at}, _attrs), do: confirmed_at
  defp confirmed_at(_user, _attrs), do: DateTime.utc_now(:second)

  defp email_owned_by_another_user?(email, user_id) do
    Repo.exists?(
      from user in User,
        where: user.email == ^email and user.id != ^user_id
    )
  end

  defp ensure_personal_membership(%User{} = user, %Organization{} = organization) do
    case Repo.get_by(OrganizationMembership, user_id: user.id, org_id: organization.id) do
      %OrganizationMembership{} = membership ->
        case membership
             |> OrganizationMembership.changeset(%{
               role: :owner,
               source: :local,
               status: :active
             })
             |> Repo.update() do
          {:ok, membership} -> {:ok, organization, membership}
          {:error, _changeset} = error -> error
        end

      nil ->
        with {:ok, membership} <- insert_personal_membership(user, organization) do
          {:ok, organization, membership}
        end
    end
  end

  defp insert_personal_membership(%User{} = user, %Organization{} = organization) do
    %OrganizationMembership{}
    |> OrganizationMembership.changeset(%{
      org_id: organization.id,
      user_id: user.id,
      role: :owner,
      source: :local,
      status: :active
    })
    |> Repo.insert()
  end

  defp workos_user_attrs(workos_user) do
    with {:ok, workos_user_id} <- required_string(workos_user, "id"),
         {:ok, email} <- required_string(workos_user, "email"),
         {:ok, workos_updated_at} <- remote_timestamp(workos_user) do
      email_verified = fetch_value(workos_user, "email_verified") == true

      {:ok,
       %{
         workos_user_id: workos_user_id,
         email: email,
         email_verified: email_verified,
         first_name: optional_string(workos_user, "first_name"),
         last_name: optional_string(workos_user, "last_name"),
         profile_picture_url: optional_string(workos_user, "profile_picture_url"),
         workos_updated_at: workos_updated_at,
         confirmed_at: if(email_verified, do: DateTime.utc_now(:second), else: nil)
       }}
    end
  end

  defp workos_organization_attrs(workos_organization) do
    with {:ok, workos_organization_id} <- required_string(workos_organization, "id"),
         {:ok, name} <- required_string(workos_organization, "name"),
         {:ok, workos_updated_at} <- remote_timestamp(workos_organization) do
      {:ok,
       %{
         workos_organization_id: workos_organization_id,
         external_ref: optional_string(workos_organization, "external_id"),
         name: name,
         personal: false,
         provisioning_state: :ready,
         workos_updated_at: workos_updated_at
       }}
    end
  end

  defp workos_membership_attrs(workos_membership) do
    with {:ok, workos_membership_id} <- required_string(workos_membership, "id"),
         {:ok, workos_user_id} <- required_string(workos_membership, "user_id"),
         {:ok, workos_organization_id} <-
           required_string(workos_membership, "organization_id"),
         {:ok, workos_updated_at} <- remote_timestamp(workos_membership) do
      workos_role_slug = membership_role_slug(workos_membership)
      {role, known_role?} = local_role(workos_role_slug)
      remote_status = optional_string(workos_membership, "status") || "active"

      {:ok,
       %{
         workos_membership_id: workos_membership_id,
         workos_user_id: workos_user_id,
         workos_organization_id: workos_organization_id,
         workos_role_slug: workos_role_slug,
         workos_updated_at: workos_updated_at,
         role: role,
         source: :workos,
         status: membership_status(remote_status, known_role?)
       }}
    end
  end

  defp find_mapped_organization(attrs) do
    case get_organization_by_workos_id(attrs.workos_organization_id) do
      %Organization{} = organization ->
        {:ok, organization}

      nil ->
        find_organization_by_external_id(attrs.external_ref)
    end
  end

  defp find_organization_by_external_id(external_id) when is_binary(external_id) do
    case Repo.get(Organization, external_id) do
      %Organization{personal: false} = organization -> {:ok, organization}
      _other -> {:error, :unmapped_organization}
    end
  end

  defp find_organization_by_external_id(_external_id), do: {:error, :unmapped_organization}

  defp existing_organization_result(workos_organization) do
    with {:ok, workos_organization_id} <- required_string(workos_organization, "id"),
         %Organization{} = organization <-
           get_organization_by_workos_id(workos_organization_id) do
      {:ok, organization}
    else
      _other -> {:error, :unmapped_organization}
    end
  end

  defp upsert_membership(user, organization, attrs) do
    membership =
      Repo.get_by(OrganizationMembership,
        workos_membership_id: attrs.workos_membership_id
      ) ||
        Repo.get_by(OrganizationMembership, user_id: user.id, org_id: organization.id) ||
        %OrganizationMembership{}

    case newer_projection?(attrs.workos_updated_at, membership.workos_updated_at) do
      true ->
        membership
        |> OrganizationMembership.changeset(
          attrs
          |> Map.take([
            :workos_membership_id,
            :workos_role_slug,
            :workos_updated_at,
            :role,
            :source,
            :status
          ])
          |> Map.put(:user_id, user.id)
          |> Map.put(:org_id, organization.id)
        )
        |> Repo.insert_or_update()

      false ->
        {:ok, membership}
    end
  end

  defp existing_membership_result(workos_membership) do
    with {:ok, workos_membership_id} <- required_string(workos_membership, "id"),
         %OrganizationMembership{} = membership <-
           Repo.get_by(OrganizationMembership, workos_membership_id: workos_membership_id) do
      {:ok, membership}
    else
      _other -> {:ok, :already_deleted}
    end
  end

  defp membership_role_slug(workos_membership) do
    case fetch_value(workos_membership, "role") do
      %{"slug" => slug} when is_binary(slug) -> slug
      %{slug: slug} when is_binary(slug) -> slug
      slug when is_binary(slug) -> slug
      _other -> optional_string(workos_membership, "role_slug")
    end
  end

  defp local_role("owner"), do: {:owner, true}
  defp local_role("admin"), do: {:admin, true}
  defp local_role("member"), do: {:member, true}
  defp local_role(_unknown), do: {:member, false}

  defp membership_status("active", true), do: :active
  defp membership_status(_remote_status, _known_role?), do: :inactive

  defp newer_projection?(%DateTime{}, nil), do: true

  defp newer_projection?(%DateTime{} = remote, %DateTime{} = local) do
    DateTime.after?(remote, local)
  end

  defp remote_timestamp(object) do
    value = fetch_value(object, "updated_at") || fetch_value(object, "created_at")

    case value do
      %DateTime{} = timestamp ->
        {:ok, timestamp}

      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, parsed, _offset} -> {:ok, parsed}
          {:error, _reason} -> {:error, :invalid_workos_timestamp}
        end

      _other ->
        {:error, :invalid_workos_timestamp}
    end
  end

  defp required_string(object, key) do
    case fetch_value(object, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:invalid_workos_object, key}}
    end
  end

  defp optional_string(object, key) do
    case fetch_value(object, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp fetch_value(object, key) when is_binary(key) do
    Map.get(object, key) || Map.get(object, existing_atom_key(key))
  end

  defp fetch_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp existing_atom_key("id"), do: :id
  defp existing_atom_key("email"), do: :email
  defp existing_atom_key("email_verified"), do: :email_verified
  defp existing_atom_key("first_name"), do: :first_name
  defp existing_atom_key("last_name"), do: :last_name
  defp existing_atom_key("profile_picture_url"), do: :profile_picture_url
  defp existing_atom_key("external_id"), do: :external_id
  defp existing_atom_key("name"), do: :name
  defp existing_atom_key("user_id"), do: :user_id
  defp existing_atom_key("organization_id"), do: :organization_id
  defp existing_atom_key("role"), do: :role
  defp existing_atom_key("role_slug"), do: :role_slug
  defp existing_atom_key("status"), do: :status
  defp existing_atom_key("updated_at"), do: :updated_at
  defp existing_atom_key("created_at"), do: :created_at

  defp authorize_membership_management(
         %Scope{
           organization: %Organization{
             personal: false,
             provisioning_state: :ready,
             workos_organization_id: workos_organization_id
           },
           membership: %OrganizationMembership{role: actor_role, status: :active}
         },
         target_role
       )
       when is_binary(workos_organization_id) do
    case {actor_role, target_role} do
      {:owner, role} when role in [:owner, :admin, :member] -> :ok
      {:admin, :member} -> :ok
      _roles -> {:error, :unauthorized}
    end
  end

  defp authorize_membership_management(_scope, _target_role), do: {:error, :unauthorized}

  defp authorize_existing_membership(scope, membership, target_role) do
    with true <- scope.organization.id == membership.org_id,
         :ok <- authorize_membership_management(scope, target_role),
         :ok <- actor_can_manage_membership?(scope.membership.role, membership.role) do
      :ok
    else
      false -> {:error, :unauthorized}
      {:error, _reason} = error -> error
    end
  end

  defp actor_can_manage_membership?(:owner, role) when role in [:owner, :admin, :member],
    do: :ok

  defp actor_can_manage_membership?(:admin, :member), do: :ok
  defp actor_can_manage_membership?(_actor_role, _target_role), do: {:error, :unauthorized}

  defp available_workos_user?(%User{
         workos_user_id: workos_user_id,
         deletion_pending_at: nil,
         deleted_at: nil
       })
       when is_binary(workos_user_id),
       do: :ok

  defp available_workos_user?(_user), do: {:error, :workos_user_unavailable}

  defp project_membership_command_response(_membership, response, _fallback_attrs)
       when is_map(response) and map_size(response) > 0 do
    sync_workos_membership(response, :upsert)
  end

  defp project_membership_command_response(membership, _response, fallback_attrs) do
    membership
    |> OrganizationMembership.changeset(
      Map.put(fallback_attrs, :workos_updated_at, DateTime.utc_now(:microsecond))
    )
    |> Repo.update()
  end

  defp workos_client do
    Application.get_env(:hermitscale, __MODULE__, [])[:workos_client] || WorkOSClient
  end

  @doc """
  Marks a user for durable deletion. New WorkOS sessions are rejected immediately.
  """
  def request_account_deletion(%Scope{} = scope) do
    now = DateTime.utc_now(:second)

    scope.user
    |> User.deletion_changeset(%{deletion_pending_at: now})
    |> Repo.update()
  end

  @doc false
  def request_account_deletion_by_workos_id(
        workos_user_id,
        occurred_at \\ DateTime.utc_now(:second)
      )
      when is_binary(workos_user_id) do
    case Repo.get_by(User, workos_user_id: workos_user_id) do
      nil ->
        {:error, :unmapped_user}

      %User{deleted_at: %DateTime{}} = user ->
        {:ok, user}

      %User{} = user ->
        user
        |> User.deletion_changeset(%{
          deletion_pending_at: user.deletion_pending_at || occurred_at
        })
        |> Repo.update()
    end
  end

  @doc false
  def tombstone_workos_user(workos_user_id, occurred_at \\ DateTime.utc_now(:second))
      when is_binary(workos_user_id) do
    case Repo.get_by(User, workos_user_id: workos_user_id) do
      nil ->
        {:ok, :already_deleted}

      %User{} = user ->
        redacted_email = "deleted+#{user.id}@invalid.local"

        user
        |> User.tombstone_changeset(%{
          deletion_pending_at: user.deletion_pending_at || occurred_at,
          deleted_at: occurred_at,
          email: redacted_email,
          first_name: nil,
          last_name: nil,
          profile_picture_url: nil,
          hashed_password: nil,
          email_verified: false
        })
        |> Repo.update()
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Hermitscale.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Hermitscale.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
