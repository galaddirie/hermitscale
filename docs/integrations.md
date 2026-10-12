# Backend integrations

Integration modules declare trusted authentication methods and API destinations.
Clients use `Hermitscale.Integrations.Request`, which checks the destination,
checks the execution actor's current authority, and vends the selected account's
credential immediately before each request. Tokens and keys stay out of graph
definitions, expression data, and workflow outputs. No frontend routes are needed
to use these APIs.

| Provider ID | Authentication | Allowed API hosts | Operations |
| --- | --- | --- | --- |
| `google` | OAuth | `sheets.googleapis.com`, `www.googleapis.com` | Read Sheets values; append rows |
| `linear` | OAuth or personal API key | `api.linear.app` | Seven issue/comment actions and signed resource triggers |
| `github` | OAuth or personal access token stored as an API key | `api.github.com` | 47 file, issue, PR, review, release, repository, organization, user, and workflow actions; signed repository triggers |
| `openai` | API key | `api.openai.com` | Create a synchronous Responses API response |

WorkOS Pipes is the credential service independently of `Hermitscale.Auth`.
`WORKOS_API_KEY` is loaded for Pipes in development and production even when an
alternate authentication provider is selected. The actor and organization IDs
used with Pipes must identify active WorkOS records; changing the authentication
provider does not migrate or map those records automatically.

## Manual WorkOS setup

In the target WorkOS environment, add each provider with **Organization** access.
This is a shared account established by an organization administrator. Configure
OAuth with your application's credentials, then authorize an organization account
through `ConnectedAccounts.connect/4`. Configure OpenAI as an API-key provider and
install an organization's key through `ConnectedAccounts.rotate/4`.

| Provider | WorkOS catalog choice | Method | Required OAuth scopes |
| --- | --- | --- | --- |
| `google` | Google | OAuth | `https://www.googleapis.com/auth/spreadsheets.readonly`, `https://www.googleapis.com/auth/spreadsheets` |
| `linear` | Linear | OAuth | `read`, `write`, `issues:create`, `comments:create`; `admin` for webhooks |
| `github` | GitHub | OAuth | `repo`; `read:org` for organization reads; `admin:org` for invitations; `admin:repo_hook` for hook-only connections; `workflow` for workflow file edits |
| `openai` | OpenAI | API key | None |

Enable the Google Sheets API in the OAuth application's Google Cloud project.
Use the callback URI displayed by WorkOS in each provider's OAuth application;
recreating a pipe changes this URI. OAuth client IDs and secrets must be available
before the Google, Linear, and GitHub setup can be completed.

Request only the scopes needed by the selected nodes. GitHub normalizes consent:
`repo` includes repository webhook access, and `admin:org` includes `read:org`.
Readiness and immediate vending recognize these trusted scope implications.
Dispatching, enabling, and disabling Actions workflows use `repo`; editing
workflow files through file actions can also require `workflow`.

A GitHub API-key connection can hold a personal access token with the fine-grained
permissions needed by the selected endpoints (for example Issues, Contents,
Pull requests, Actions, or repository Administration). Provider permission errors
become workflow failures. Linear also supports personal API-key
connections; its key uses `Authorization: <key>`, while OAuth uses
`Authorization: Bearer <token>`. Choose one authentication method for each
WorkOS pipe; Pipes does not allow changing it in place. The deployed clients
support either method without changing saved graph selections.

OpenAI uses an API project key and the Responses API. It does not implement a
ChatGPT sign-in flow. Keys are stored by Pipes rather than in graph parameters
or application-wide OpenAI configuration. Choose a model available to that key's
project; the node has no default model.

Sources: [WorkOS connection sharing](https://workos.com/docs/pipes/connection-sharing),
[WorkOS API-key providers](https://workos.com/docs/pipes/api-keys),
[Google Sheets scopes](https://developers.google.com/workspace/sheets/api/scopes),
[Linear OAuth scopes](https://linear.app/developers/oauth-2-0-authentication),
[Linear authentication and GraphQL](https://linear.app/developers/graphql),
[GitHub issue endpoints](https://docs.github.com/en/rest/issues/issues),
[GitHub OAuth scopes](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps),
[OpenAI authentication](https://developers.openai.com/api/reference/overview), and
[OpenAI Responses quickstart](https://developers.openai.com/api/docs/quickstart).

## Connecting an organization account

The scope must contain verified organization membership and `connections:manage`.
OAuth returns a WorkOS authorization URL for the admin to complete. Reauthorization
uses the existing account ID; omit it to add an account.

```elixir
alias Hermitscale.Integrations.ConnectedAccounts

{:ok, %{"url" => url}} =
  ConnectedAccounts.connect(scope, "linear", approved_return_url)

# secret is supplied by the admin; never log it or put it in a graph.
{:ok, :connected} = ConnectedAccounts.rotate(scope, "openai", nil, secret)
{:ok, accounts} = ConnectedAccounts.list(scope)
```

Use `list/1` to get the new account's non-secret ID. For later rotations, pass
that ID instead of `nil`. `select/3` chooses the only ready account, or returns
`{:error, :account_selection_required}` when several match. Multiple saved accounts
require an explicit choice. OAuth scopes are checked against current account
consent; API-key permissions are enforced by the external provider.

## Workflow nodes

All nodes below have version `1` and use canonical organization account selections.
Parameters support expressions, including nested JSON field/filter maps. OpenAI
input can be text or a Responses API input item list. Output is the provider's
decoded JSON object or an ordered list for collection actions.
The OpenAI node also adds `output_text` by collecting text from message output
items, while retaining `output`, `usage`, and other response fields.

| Node type | Parameters | Default workflow retries |
| --- | --- | --- |
| `google.sheets.read_rows` | `spreadsheet_id`; `range` defaults to `Sheet1!A:Z` | 3 |
| `google.sheets.append_row` | `spreadsheet_id`; `range`; incoming value supplies rows | 3 (existing behavior) |
| `linear.issues.get` | `issue_id` (UUID or identifier such as `ENG-7`) | 3 |
| `linear.issues.create` | `team_id`, `title`; `description` defaults to empty | 0 |
| `github.issues.get` | `owner`, `repo`, positive `issue_number` | 3 |
| `github.issues.create` | `owner`, `repo`, `title`; `body` defaults to empty | 0 |
| `openai.responses.create` | `model`, `input`; optional `instructions`, `max_output_tokens` (4096) | 0 |

New write nodes default to zero retries because retries can create duplicate
issues or charge for another model request. Graph policy can explicitly override
this. The shared HTTP client retries safe transient reads and vends credentials
afresh for each attempt. GitHub and Linear mutations disable HTTP retries,
including PUT and DELETE requests. Linear GraphQL reads use POST and retain the
shared POST retry behavior (no automatic retry).
The existing Google append node retains its earlier retry policy; use
`"policy": {"max_retries": 0}` when duplicate appends are unacceptable.

```json
{
  "schema_version": 1,
  "id": "wf_generate_response",
  "name": "generate_response",
  "nodes": [{
    "id": "generate",
    "type": "openai.responses.create",
    "version": 1,
    "params": {
      "model": "YOUR_MODEL_ID",
      "input": "{{ $json.prompt }}",
      "instructions": "Answer concisely.",
      "max_output_tokens": 1000
    },
    "connection": {"provider": "openai", "account_id": "YOUR_CONNECTED_ACCOUNT_ID"}
  }],
  "connections": []
}
```

Linear rejects GraphQL partial errors even on HTTP 200. OpenAI disables streaming
and background responses, defaults `store` to false, and rejects failed,
incomplete, queued, and in-progress responses. Provider errors become workflow
failures, with status codes or stable error reasons instead of provider error
content. Credential failures retain the existing actionable setup, consent,
scope, and execution-authority reasons.

Tests use Req stubs and the credential boundary fixtures; no paid model requests
or live provider mutations are required. Live OAuth and API-key validation must
be completed after credentials are configured.

## GitHub and Linear action catalog

See [the complete action and trigger reference](integrations/actions-and-triggers.md)
for all node IDs, parameters, webhook lifecycle behavior, and setup requirements.
