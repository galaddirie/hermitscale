# WorkOS Pipes capabilities for the credential refactor

Researched October 11, 2026 against current WorkOS documentation, Context7's WorkOS documentation index, and official SDK source. These are provider capabilities, not confirmation that this application's WorkOS environment has every feature enabled.

## Verified capabilities

- **True organization ownership exists.** User ownership remains the default; merely adding `organization_id` still selects that user's connection within the organization. Shared credential vending requires `connection_owner: "organization"`, `organization_id`, and an acting `user_id` with active membership. A provider can have separate user-owned and organization-owned integrations. Shared connections support OAuth, API keys, and client credentials. [Connection sharing](https://workos.com/docs/pipes/connection-sharing)
- **Departure affects shared credentials.** When the member who established a shared connection leaves, is deactivated, or is deleted, WorkOS clears credential material and marks it `needs_reauthorization`; another admin must reconnect. Provenance includes `established_by_user_id` and `state_reason`. Organization ownership does not imply independence from all user lifecycle events. [Connection sharing](https://workos.com/docs/pipes/connection-sharing)
- **Admin versus member UI is explicit.** Pipes Admin requires `widgets:pipes:manage`. Both widgets need the opt-in `enableSharedConnections` prop. Members see shared connections without management controls; administrators connect, rotate, and disconnect them. Application workflow/edit/run permissions still need enforcement. [Pipes Admin](https://workos.com/docs/widgets/pipes-admin)
- **API keys share the credential-vending path.** `POST /data-integrations/:slug/credentials` returns `credential.auth_method` and `credential.value`: an OAuth access token or stored API key, with applicable metadata. OAuth refresh is handled by WorkOS. The existing `/token` endpoint is OAuth-specific. [Credentials API](https://workos.com/docs/reference/pipes/access-token)
- **API-key configuration has limits.** A configured provider chooses OAuth or API-key authentication; switching requires removing and recreating that integration. API-key support represents one opaque secret, including custom providers. Do not assume arbitrary compound credentials are supported. [API-key providers](https://workos.com/docs/pipes/api-keys), [Custom providers](https://workos.com/docs/pipes/custom-providers)
- **Connection identity remains necessary.** The plural credential contract accepts `connected_account_id` and `supports_multiple_connections: true`; multiple matches without a selector yield `account_selection_required`. Omitting the plural flag selects the compatibility connection. Account selection is therefore distinct from mapping each runner's credential. [Vend credentials](https://workos.com/docs/reference/pipes/access-token/vend-credentials)

## Migration and availability caveats

- The connected-account API supports organization OAuth imports, explicit connection IDs, and API-key upserts. OAuth import requires supplied tokens; no documented operation transferring an existing user connection into organization ownership was found. Reauthorization is the safe migration baseline because ordinary credential vending does not export refresh tokens. [Connected-account API](https://workos.com/docs/reference/pipes/connected-account)
- Multi-connection creation documents `multiple_connections_unavailable` while that feature is unavailable; the organization disconnect endpoint is marked feature flagged. Confirm feature access and provider behavior in the actual environment before scheduling a cutoff. [Connected-account API](https://workos.com/docs/reference/pipes/connected-account)
- Disconnecting deletes WorkOS's stored credentials but does **not** revoke provider-side authorization. Do not describe WorkOS deletion as revoking already-issued credentials at the provider. [Connected-account API](https://workos.com/docs/reference/pipes/connected-account)
- No userless/service-account guarantee for shared vending was verified. Scheduled runs still need a deliberately chosen active execution principal. Do not silently substitute the workflow author, connection-establishing admin, or an arbitrary surviving member.

## Personal organizations

WorkOS imposes no organization-count limit and exposes creation plus lookup by external ID. External IDs are unique per environment and limited to 64 characters. These primitives support a deterministic identifier such as `personal:<workos-user-id>` and recovery by lookup after uncertain creation. Membership provisioning is a separate step; no atomic create-organization-and-membership API or personal-organization auto-provisioning guarantee was verified. [Organization API](https://workos.com/docs/reference/organization), [External IDs](https://workos.com/docs/authkit/metadata)

The documented onboarding pattern is create an organization, create membership, then refresh authentication with the new organization ID. A personal organization for *every* user, including invited users, is an application policy requiring an idempotent provisioning/reconciliation flow. [Membership management](https://workos.com/docs/authkit/users-organizations/organizations/membership-management)

## Elixir integration

Official `workos-elixir` main includes API-key upsert and credential vending with request maps. This proves source support, not compatibility of any particular published version or complete organization/multiple-account coverage. The application can continue using its existing Req boundary with the documented REST request shapes; this refactor does not inherently require an SDK migration. [Official Pipes module](https://raw.githubusercontent.com/workos/workos-elixir/main/lib/workos/pipes.ex)

## Design implications (recommendations)

Prefer organization-owned credentials if the product deliberately makes the organization the sharing boundary. Retain stable connection references and author/admin selection; remove runner-specific remapping. Keep active actor validation, workflow authorization, provider/account compatibility checks, credential redaction, and actionable reconnect states. Moving personal credentials into a team organization expands who can cause actions with those credentials, so migration must require an explicit authorized choice rather than automatically promoting the author's existing connection.
