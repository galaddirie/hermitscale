# Organization credential refactor implementation plan

Adopt organization-owned WorkOS Pipes connections everywhere. Automatically create an ordinary organization for every user, initially containing only that user. A workflow and all its connections belong to the same organization; every permitted member runs it with the same selected accounts.

Hermitscale is in early development. Replace the old model directly in one implementation effort. Change the schema, replace contracts, update fixtures and delete obsolete code together. Development workflows, runs, events and trigger state can be recreated. Do not build backfills, rollout flags, dual readers, legacy resolvers, ownership-transfer tooling or old-run compatibility. This document is the plan; it does not execute a data reset.

This supersedes the earlier refactor proposal. [Pipes capabilities](2026-10-11-workos-pipes-capabilities.md) contains the supporting WorkOS research.

Frontend controllers, HTML, routes and browser authentication integration are deferred for now. The backend organization provisioning, switching, permissions and connection-management contracts remain in scope.

## Product decisions

- Every workflow belongs to one organization. Cross-org workflow sharing is unsupported.
- Every connection is organization-owned, including personal-workspace connections.
- A personal org is simply the organization automatically created for a user. It uses the same membership, invitation and permission rules as every other org. Its owner can invite collaborators without converting it or creating another org; no personal-org restrictions apply.
- Authors choose accounts once. Runners do not configure, bind or map personal credentials.
- If one compatible connection exists, select it automatically during authoring or activation and persist the choice. If several exist, the author selects. Never silently change an existing selection.
- Missing credentials or expired consent produce an org setup/repair action, not onboarding for every runner.
- Workflow privacy follows organization membership and permissions. An org containing only its owner provides a private workspace; invited members gain access according to their permissions. There is no separate private-workflow flag or user-credential ownership mode.

## Target model

Organization ownership and execution identity are separate. WorkOS shared vending still requires an active acting member. [Connection sharing](https://workos.com/docs/pipes/connection-sharing)

| Concept | Representation |
| --- | --- |
| Tenant | Existing Graph.org_id, checked against verified caller scope |
| Author | Existing Graph.created_by_user_id, for attribution only |
| Selected account | One node-level connection object with provider and account_id |
| Execution identity | Trusted, non-secret context containing organization_id and actor_user_id |
| Credential requirement | Catalog metadata specifying provider and operation scopes |
| Runtime reference | CredentialRef containing validated account selection, execution identity and required scopes; no secret |
| Automation authority | Trigger.execution_actor_user_id, recorded at activation or explicit reassignment |
| Run provenance | initiated_by_user_id, execution_actor_user_id, optional trigger_id, and a snapshot of node account selections |

The sole graph connection format is:

```json
{
  "id": "read_orders",
  "type": "google.sheets.read_rows",
  "version": 1,
  "params": {"spreadsheet_id": "sheet_id"},
  "connection": {
    "provider": "google",
    "account_id": "data_installation_example"
  }
}
```

The provider must match the typed node's requirement and a deployed integration descriptor. Generic HTTP nodes use the same object. The account must belong to that provider and the workflow org. Graph fields select accounts; they never establish trusted ownership or execution authority.

Use auth-neutral provider identifiers such as google, replacing google.oauth in requirements, fixtures and docs. Keep node type names unchanged. OAuth versus API key is connection configuration, not a parallel credential subsystem.

## Implementation order

These are dependent implementation tasks for one replacement, not deployment phases.

### 1 Personal organizations and switching

Add Accounts.ensure_personal_organization/1 using WorkOS organization and membership endpoints through the existing Req adapter. Use a deterministic external ID derived from the WorkOS user ID. Recover an already-created org by lookup and ensure membership separately, making retries and concurrent first logins converge. Keep personal-workspace metadata in WorkOS; do not restore local identity mirrors.

Ensure every user has a personal org, including users invited into teams. Select it when sign-in has no org; preserve a valid team context otherwise. Grant the personal owner the application's administrative permissions.

Add explicit organization switching to WorkOS.Session: refresh for the selected org, verify the returned user and requested org, then reseal the session. Preserve ordinary refresh's same-org invariant. Add a minimal workspace selector. Use the ordinary invitation and membership flows for every org, including automatically created personal orgs; no org-type checks or conversion flow are needed.

Touch: a new accounts.ex context, accounts/scope.ex, work_os/client.ex, work_os/session.ex, auth_controller.ex, user_auth.ex and the authenticated layout.

### 2 Unified org credential vending

Replace WorkOS.Client.fetch_oauth_token/3 with credential vending through /data-integrations/:slug/credentials. Always send connection_owner=organization, trusted organization and actor IDs, and the selected account ID. Implement the documented account-selection contract against the development WorkOS environment. If multiple connections are unavailable, constrain creation to one account per provider; do not build an alternate resolver.

Normalize credential responses by auth_method. OAuth yields an access token with scopes and expiry; API keys yield an opaque secret. Handle missing connection, reauthorization, insufficient scope and selection errors without leaking secrets. API keys may require Bearer auth or a provider-specific header. [Credentials API](https://workos.com/docs/reference/pipes/access-token)

Keep ConnectedAccounts responsible for org connection listing, validation, readiness and vending. Keep WorkOS authoritative for state and secrets. Use one integration descriptor for slug, supported auth methods, request authentication and allowed destinations. Remove the fetch_token callback from Provider; retain useful metadata/discovery. Delete the redundant provider map and Google.OAuth forwarding module.

Touch: work_os/client.ex, integrations/connected_accounts.ex, integrations/credential_ref.ex, integrations/provider.ex, integrations/google.ex, integrations/google/oauth.ex and the Sheets client.

### 3 One graph selection and resolution path

Rewrite Workflows.Credentials around catalog requirements, the canonical connection object and trusted execution context. Retain its small interface for whole-run resolution, trigger-node resolution and requirement collection. Validate selections before execution and build non-secret references per node.

Delete graph-level provider defaults, graph-level node overrides, node-local legacy credential maps, recursive bound?/1, Google-specific resolution and local-account compatibility helpers. Reject old formats through the new validator. Replace all fixtures and examples; do not write conversion code.

Reserve runtime credential keys for the resolver so caller-supplied run_context cannot inject credentials or actors. Keep expression data separate. Actual credential material is retrieved immediately before provider requests, including fresh vending when a request is retried. Remove the split where Google uses references while other providers receive tokens at run start.

Readiness checks catch missing setup before run/activation. Vending still happens before effects because readiness does not freeze connection state.

Touch: workflows/credentials.ex, workflows/validator.ex, workflows/graph.ex, integration clients and fixtures.

### 4 WorkOS roles and organization permissions

Remove Graph.validate_credential_owner and all Credentials.authorize calls. Keep tenant equality checks. Add one small authorization module using verified WorkOS permissions across workflow, trigger, connection and membership contexts. Check permission slugs rather than hardcoding role names. Do not reuse Workflows.Policy, which already represents execution/retry policy.

Use three roles with one role per organization membership:

| Permission | Actions | Admin | Editor | Runner |
| --- | --- | :---: | :---: | :---: |
| workflows:run | Start, manually fire and resume org workflows | Yes | Yes | Yes |
| workflows:edit | Create/edit graphs and choose compatible org accounts | Yes | Yes | No |
| workflows:activate | Activate, deactivate, enable, disable and reassign automation | Yes | Yes | No |
| connections:manage | Establish, rotate and disconnect org connections | Yes | No | No |
| members:manage | Invite/remove members and assign membership roles | Yes | No | No |

All three roles can view their org's workflows, run results and connection status. Running a workflow includes using its selected org credentials without exposing the secrets. The creator of an automatically provisioned personal org receives Admin. Invitations default to Runner, with an explicit administrative choice to grant Editor or Admin. Apply these rules identically to every organization.

WorkOS owns role definitions, permission assignments and membership roles. Configure the intended roles and permissions manually in WorkOS. Hermitscale consumes verified session permissions through Scope and enforces actions server-side; it does not maintain local role or permission tables. WorkOS supports membership roles and session permission claims. [Roles and permissions](https://workos.com/docs/authkit/roles-and-permissions)

Tenant authorization remains an independent check: a permission never grants access to another organization's resources. Refresh session claims after role changes; background execution resolves current membership and permissions rather than persisting the activator's old permissions indefinitely.

If using WorkOS widgets, grant Admin widgets:pipes:manage for Pipes Admin and widgets:users-table:manage for User Management. Widget permissions enable those surfaces; application context methods still enforce connections:manage and members:manage. [Pipes Admin](https://workos.com/docs/widgets/pipes-admin), [User Management](https://workos.com/docs/widgets/user-management)

Do not build custom-role UI, multiple-role assignment, per-workflow ACLs or per-connection grants for this scope.

Run-only users execute saved graphs; they cannot submit replacement node definitions or account selections. Request destination restrictions still apply to editors.

Touch: workflows.ex, workflows/graph.ex, triggers.ex, accounts/scope.ex, the new authorization module, connection/membership contexts and documentation for manual WorkOS configuration.

### 5 Explicit execution identity everywhere

Manual runs use the verified caller. Preserve that identity through Triggers.fire_manual, Dispatcher.fire and Workflows.start_run_from_trigger, where the current flow loses caller scope.

Scheduled, webhook, polling and stream execution use the member recorded at activation. Persist that actor on the activation record and check current authority when admitting unattended work. Poll/reconnect paths use the same execution context. Ordinary disable/enable does not transfer authority; explicit activation/reassignment does.

When the actor is no longer eligible, mark automation errored with a reassignment action. Connection reauthorization produces a repair action. Never pick an arbitrary surviving member. WorkOS can invalidate shared credentials when the establishing member leaves, independently of the execution actor. [Connection sharing](https://workos.com/docs/pipes/connection-sharing)

Persist run provenance and selected accounts at run creation. Resume authorizes its requester separately while preserving the saved actor and selections. Retain the existing graph fingerprint check. Old development histories do not need to survive. Keep Run.owner separate from human identity.

Touch: workflows.ex, workflows/run.ex, triggers.ex, triggers/trigger.ex, triggers/dispatcher.ex and poll/stream runtimes. Generate a normal Ecto migration for the new fields; no data backfill.

### 6 Credentialed provider requests

Update Sheets and generic HTTP to consume references through the common integration path. Trusted integration metadata determines destinations and authentication headers. Graph JSON cannot define arbitrary secret-bearing headers.

Enforce approved hosts and HTTPS before attaching credentials. Disable automatic redirects or validate each destination before forwarding auth. Cover dynamic URL inputs. The existing network_domains declarations are not enforced by HTTP.request/3; implement enforcement in the actual request path.

Keep credentials out of graph JSON, run inputs/outputs, expression bindings, events, job arguments, errors and logs. Do not add a vault, refresh worker or credential cache.

Touch: http.ex, workflows/nodes/builtin/http_request/v2.ex, integration descriptors and clients.

### 7 Minimal connection experience and documentation

Expose org connection status and admin connect/reconnect/rotate/disconnect actions. Configure organization-owned Pipes for personal and team workspaces. Establish fresh development connections; skip transferring old personal credentials.

Expose account selection/readiness through the workflow context for the future editor. An eventual “use this account for all Google steps” action fills canonical node selections without adding another persisted default format. Show which shared account is selected and whether setup is needed. A workflow canvas is outside this refactor.

Workspace-switching and connection-management controller routes belong in the existing scope using [:browser, :require_authenticated_user] because both need verified membership. If these screens use LiveView, add one :require_authenticated_user live session and a WorkOS-backed mount hook; neither currently exists. Pass current_scope to Layouts.app and contexts. Keep public sign-in/callback routes in the browser-only scope so unauthenticated users can complete sign-in.

Rewrite the credential chapter in docs/node-authoring-kit.md around the final contract and update authoring examples.

## Delete checklist

- Recursive credential-bound detection, creator authorization and creator changeset validation.
- Creator-as-default execution identity, user-owned credential resolution and runner-binding concepts.
- All three legacy binding formats and their precedence helpers.
- google.oauth identifiers and Google-specific credential resolution.
- OAuth-only vending, Google.OAuth forwarding and token-provider callback dispatch.
- Token-at-run-start paths and tests expecting secret material in workflow context.
- Creator-only rejection tests, local-account compatibility tests and old fixture formats.
- Stale vault, credential owner and binding descriptions in the authoring guide.

Keep tenant checks, scope validation, references, per-node context, request restrictions and replay fingerprint validation. The earlier projection-removal migration already deletes local connected accounts and identities; do not recreate them.

## Development cutover

Implement the new contract directly. Recreate local development workflow data and execution history as needed, replace seeds/fixtures, configure org-owned Pipes providers and connect fresh accounts. Preserve neither old credential semantics nor old run history. Do not reset unrelated WorkOS users, organizations or external accounts.

The capability research is reference material, not a requirement to implement migration tooling.

## Verification and definition of done

Add focused behavior tests while changing each module:

- Two permitted members run the same workflow against the same selected account without personal credential setup.
- Cross-org IDs and forged actor/owner fields fail. Runners cannot edit graphs, activate automation, manage connections or manage members; Editors cannot manage connections or members.
- Automatically provisioned org creators receive Admin. Invitations default to Runner; only permitted admins can assign another role. Manually configured WorkOS roles and permissions match the role matrix.
- Permission checks enforce the role matrix through application contexts, independently of widget visibility. Background work observes current membership and permission changes.
- Personal-org provisioning converges on retries; org switching verifies the tenant; invited members can collaborate in automatically created orgs under the same permissions as any other org.
- OAuth and API keys share one reference path. Selections stay stable when another account is added. Missing, ambiguous and insufficient-scope states are actionable.
- Manual, resumed, scheduled, webhook, polling and stream execution carry the intended actor. Actor removal or connection invalidation prevents further credentialed work.
- Rotation is picked up on subsequent requests; secrets never appear in persisted events or error output.
- Generic HTTP cannot send credentials to an unapproved host or through a redirect.
- A fresh database starts and passes tests with only the new schema and fixtures.

Run relevant context, integration, auth and trigger tests, then mix precommit and fix failures. The existing OAuth.fetch_token/1 versus /2 mismatch is eliminated with the wrapper; update all callers together.

Done means the old model is deleted, shared runs need no runner binding, automatically created orgs support ordinary collaboration, and every execution path uses the same organization credential contract.
