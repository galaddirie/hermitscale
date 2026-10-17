# ADR-0001: Broker workspace credentials through Hermitscale

| | |
|---|---|
| **Status** | Proposed |
| **Date** | 2026-10-16 |
| **Deciders** | [names of the people who made the call] |
| **Consulted** | [optional] |

---

## Context

Workspaces are Fly Sprites that run user commands and coding agents
([design](../agent-apps-design.md)). Users want those agents to act for them:
clone and push repositories, open Linear issues, read Google Sheets, and, as we
work toward n8n parity, call many more providers. Organizations connect those
providers through WorkOS Pipes (OAuth and API keys). `Hermitscale.Integrations`
already vends Pipes credentials server-side, immediately before each request.

Everything inside a Sprite is readable by whatever runs there. Environment
variables are inherited by every child process (an `npm install` hook sees them),
files persist on disk and in checkpoints, and a prompt-injected agent can print
or send anything it can read. A Pipes OAuth token usually works across the whole
connected account, often with a refresh token behind it, so one leak exposes
the whole account. Sprites run in a single Hermitscale-owned Sprites
organization that serves every customer, so a misconfiguration in Sprites-level
isolation is a cross-tenant leak.

The options were: pass provider tokens to runs as environment variables (the
current non-goal); store user credentials in Sprites Connectors; call WorkOS
Pipes Relay from the Sprite; or put a Hermitscale-owned broker between the
Sprite and every provider.

---

## Decision

> [!DECISION]
> Provider credentials never enter a Sprite. Code in a workspace calls the
> Hermitscale credential broker, which authenticates the workspace, checks a
> per-workspace grant, vends the Pipes credential server-side, and forwards the
> request.

Concretely:

- **Grants.** A grant attaches one organization connected account per provider
  to one workspace, with an allowlist of rules such as `GET /repos/acme/*`,
  `POST /graphql`, `FETCH /acme/web`, or `PUSH /acme/*` (exact paths, or
  prefixes ending in `*`). No grant means no access. Managing grants requires
  `connections:manage`.
- **Workspace identity (phase 1).** A broker token is a random secret bound to
  one workspace and the member acting through it, with a TTL of at most 24
  hours. Only its SHA-256 hash is stored. It can be revoked, and it stops
  working when the workspace is deleted. Callers pass it to runs as
  `HERMITSCALE_BROKER_TOKEN`. If it leaks, it only works against the broker,
  only for that workspace's grants and rules, and only until it expires.
- **Every request is re-checked.** The token, the grant, and the rule are
  checked on every call, and `ConnectedAccounts.vend/1` re-checks the actor's
  membership and permission and the account's state before each upstream
  request. Removing a member, a grant, or a connection takes effect on the next
  request.
- **HTTP APIs** go through `/broker/v1/api/<provider>/<path>` to the provider's
  declared host, reusing `Integrations.Request`: the destination is checked,
  redirects are refused, the credential is replaced on retries, and echoed
  secrets are redacted.
- **Git** goes through `/broker/v1/git/<provider>/<owner>/<repo>.git` as a
  smart-HTTP proxy to the provider's Git host. Git accepts the broker token as
  a Basic password or bearer header, so no provider token is written to
  `.git/config`.
- **Egress.** Workspaces expose the Sprites network policy so an organization
  can restrict a Sprite to the broker and the package registries it needs.

**Phase 2: workspace identity without a secret in the Sprite.** We will
replace the token with one Sprites "Custom API" connector per workspace. It
points at the broker, holds that workspace's broker key, and has an access
policy that matches only that Sprite's name. Sprite names are fixed-length
(`hs-` plus 32 hex characters), so a name prefix matches exactly one Sprite.
Fly authenticates the calling Sprite, and the Sprite holds nothing reusable.
Before adopting this we must confirm with Fly that Custom API connectors can be
created through the API, that streaming and large bodies work within the
gateway's 120-second timeout, and that `/v1/gateway/list` does not show other
workspaces' connectors.

---

## Alternatives considered

### Pass provider tokens to runs as environment variables

This is the simplest option and works with every CLI unmodified. It lost
because the token is readable by every process in the Sprite, survives in logs
and checkpoints, and usually grants account-wide access until it expires. We
could not revoke it for one workspace, scope it to one repository, or audit its
use.

### Store user credentials in Sprites Connectors

Credentials would be held by Fly, and Sprites would never see them. That is the
right model, but the wrong store for user credentials:

- All customers share one Sprites organization, so tenant isolation would
  depend only on access policies we maintain.
- The OAuth consent screen and app belong to Sprites, so users would connect
  every provider twice: once to Pipes and once to Sprites.
- The connector API cannot accept or refresh a token we already hold, so Pipes
  OAuth tokens, which expire, cannot be kept current.
- The catalog is small (GitHub, Slack, LLM providers, and Custom API) and has
  no Linear or Google.

We still use Connectors where they fit: Hermitscale-owned LLM keys for agent
CLIs, and phase 2 workspace identity.

### Call WorkOS Pipes Relay from the Sprite

Relay injects credentials at WorkOS and is designed for untrusted runtimes. It
lost because it authenticates with the environment-wide WorkOS API key, and the
`X-Relay-User` and `X-Relay-Organization` headers are whatever the caller sends.
A key in a Sprite could act as any member of any customer organization. Relay
is safe only when called by our backend. Even there, it cannot select one of
several connected accounts for the same provider, which our organizations use.
We may adopt it as the broker's upstream once it supports account selection.

### Transparent placeholder-substituting egress proxy

A man-in-the-middle HTTPS proxy, with a trusted CA installed in the Sprite,
could swap placeholder tokens for real ones so unmodified SDKs and CLIs work
([varlock](https://varlock.dev/sandboxes/flyio/) does this on Sprites). It lost
for now because of the complexity of running and securing a TLS-intercepting
proxy. It is the natural next step if base-URL configuration proves too limiting.

---

## Consequences

### Positive

- A compromised or prompt-injected agent can misuse only the grants on its own
  workspace, only through the broker, and only until the token expires. It
  cannot take a provider credential with it.
- One place to scope, revoke, rate-limit, audit, and later require approval for
  agent access to providers.
- WorkOS Pipes stays the only credential store; adding a provider for workflows
  also makes it available to workspaces.

### Negative

- Tools must be pointed at the broker. SDKs need a base URL, and Git needs the
  broker remote and credential. Some CLIs (for example `gh`) cannot use an
  arbitrary API URL.
- Every provider call takes an extra hop through Phoenix, plus WorkOS calls to
  vend and to check membership. Brokered request bodies are buffered (10 MB for
  APIs, 100 MB for Git pushes).
- Path rules cannot tell a GraphQL query from a mutation. `POST /graphql` grants
  both, so finer control needs typed actions.

> [!WARNING]
> In phase 1 the broker token is still a secret inside the Sprite. Anything
> running in that workspace can use the workspace's grants until the token
> expires. Keep TTLs short, grant narrow rules, and revoke tokens when runs end.

### Neutral

- The workspace is the trust boundary. All processes in a Sprite share one
  Linux user, so grants attach to workspaces, not runs. Today only
  organization-owned connections exist. If personal connections are added, they
  must be attachable only to workspaces their owner uses alone.
- Brokered requests emit `[:hermitscale, :credential_broker, :request]`
  telemetry. A persistent audit table and approvals for write requests are
  follow-ups.

---

## Notes

- Sprites Connectors: <https://docs.fly.io/sprites/concepts/connectors>
- Sprites network policy: <https://docs.fly.io/sprites/concepts/networking>
- WorkOS Pipes Relay: <https://workos.com/docs/pipes/relay>
- Follow-ups: phase 2 connector identity; a typed-action MCP server built on
  `Integrations.*.Operations`; a persistent audit log; approval gates for write
  rules; GitHub App installation tokens limited to one repository for Git.
