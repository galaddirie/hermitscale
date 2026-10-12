# GitHub and Linear actions and triggers

The backend implements n8n's documented GitHub and Linear resource/action
families as individual version-1 nodes. GitHub also includes the upstream
organization-member and user-issue reads. The catalog contains 47 GitHub actions,
seven Linear actions, and two provider trigger types. Their definitions are
deployed code; graphs cannot supply arbitrary GraphQL queries, HTTP destinations,
authentication headers, or provider modules.

This covers resource/action selection and webhook event selection. It does not
implement n8n's credential UI, GitHub App installation-token issuance, binary
attachment plumbing, or dispatch-and-wait orchestration. `workflows.get_usage`
retains GitHub's deprecated workflow `/timing` endpoint and can return a provider
failure. Some legacy/App/organization event names in the upstream GitHub menu
cannot be registered on repository hooks; GitHub rejects those subscriptions.
There is no polling fallback.

Sources: [n8n GitHub actions](https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.github/),
[n8n Linear actions](https://docs.n8n.io/integrations/builtin/app-nodes/n8n-nodes-base.linear/),
[upstream GitHub node](https://github.com/n8n-io/n8n/blob/master/packages/nodes-base/nodes/Github/Github.node.ts),
[GitHub workflow API](https://docs.github.com/en/rest/actions/workflows), and
[Linear GraphQL](https://linear.app/developers/graphql).

## Action parameters and results

The tables below list required parameters first. Optional `fields`, `inputs`,
`filters`, and `filter` are string-keyed JSON maps using provider input names.
For example, Linear update fields can contain `priority`, `assigneeId`,
`stateId`, and `labelIds`; GitHub issue fields can contain `labels`, `assignees`,
and `milestone`. Expressions work inside these maps. Required primary fields
take precedence over additional fields.

Read nodes default to three workflow retries; write nodes default to zero and
disable HTTP retries. An explicit graph retry override may repeat a mutation.
Provider 4xx/5xx responses produce stable errors containing the status rather
than the provider's response body. Linear GraphQL partial errors fail the action.

List actions default to `return_all: false`, `limit: 50`. `return_all: true`
collects pages up to 100 requests / 10,000 records; exceeding that bound fails
instead of silently truncating a requested complete result. A numeric limit is
capped at 10,000. Collections are one ordered list output; use a map node to
process their items separately. Pagination never follows a provider URL to a
different host. GitHub filters use REST query names; Linear `filter` uses
`IssueFilter` JSON. File-directory listing follows GitHub's Contents endpoint
limits rather than the paginated list interface.

File writes accept `encoding: "text"` (default, encoded once) or `"base64"`.
Edit/delete fetch the current SHA from the branch in `fields.branch` unless
`fields.sha` was explicitly supplied. File get returns Contents API metadata
with base64 content; it does not follow `download_url`. File list requires a
directory and accepts an empty path for the root. Paths preserve nested segments
and reject leading slashes and dot traversal. PR create/edit comment actions
manage issue-style conversation comments; review actions are separate. Diff and
patch return `{"diff": "..."}` / `{"patch": "..."}`. Empty successful responses
return `{"success": true}`. Workflow IDs are strings containing an ID or file
name, such as `"ci.yml"`.

## Provider triggers

| Type | Required configuration | Optional configuration | OAuth scope |
| --- | --- | --- | --- |
| `github.events` | `owner`, `repo` | `events` (default `["push"]`), `actions` (default `[]`) | `admin:repo_hook`, or implied by `repo` |
| `linear.events` | Exactly one of `team_id` or `all_public_teams: true` | `resources` (default `["Issue"]`), `actions` (default `[]`) | `admin` |

GitHub's deployed event list is available from
`Hermitscale.Triggers.GitHub.Events.V1.events/0`. Select events such as `issues`,
`issue_comment`, `pull_request`, `push`, `release`, and `workflow_run`, or select
only `"*"`. Optional `actions` restricts payload actions such as `opened` or
`closed`. Repository identity is verified in received event bodies. Signed
GitHub pings are acknowledged without firing a workflow.

Linear supports `Reaction` (comment reaction), `Cycle`, `Issue`, `Comment`,
`IssueLabel`, and `Project`. Optional actions are `create`, `update`, and `remove`.
The team selection is applied when registering the provider hook. The callback
checks the registered webhook ID and requires `webhookTimestamp` to be within
60 seconds of the server clock. Keep nodes' clocks synchronized.

Both providers require the exact raw-body HMAC signature and a bounded provider
delivery ID. Accepted payloads retain the original event body in the trigger's
standard runtime envelope; downstream expressions use `$json.data` for the
original body (`$json.data.data` for Linear's nested resource). Callback
tokens identify subscriptions; they are not a substitute for signatures.

## Registration, delivery, and cleanup

Apply migrations with `mix ecto.migrate`. Set `INTEGRATION_WEBHOOK_BASE_URL` to a
public HTTPS origin serving this Phoenix endpoint. The callback is
`<base>/hooks/<random-token>`. Keep `INTEGRATION_WEBHOOK_SIGNING_SECRET` (at least
32 bytes) stable and identical across application nodes. When unset, the
endpoint's `SECRET_KEY_BASE` is used. These settings are separate from WorkOS's
OAuth callback. There are no setup scripts.

The endpoint plug handles only provider ingress before `Plug.Parsers`, preserves
the exact bytes for signature verification, and limits JSON requests to 1 MiB.
It uses no browser pipeline, login controller, HTML template, or LiveView session:
external providers authenticate requests through their signing secrets.

Graph activation records desired subscription state and an Oban registration job
in the same transaction. The `:triggers` queue must run both lifecycle and
delivery workers. Callbacks become usable after registration reaches `:active`;
`Webhooks.get_subscription!(scope, trigger)` exposes non-secret status and
`Webhooks.url(subscription)` returns the recorded URL. Signing secrets derive
from server configuration and the random token; they are absent from graphs,
subscription records, jobs, and workflow outputs.

Reactivation reuses an unchanged registration. Editing a trigger creates a new
registration generation and removes the retired provider hook before creating
its replacement. Deactivation and trigger removal queue cleanup. Retired desired
configurations remain durable so cleanup still works after a provider create
commits but its acknowledgement is lost. Reconciliation only adopts/removes the
recorded unpredictable callback URL (GitHub) or planned UUID/URL (Linear).
Unrelated provider hooks are left alone. Startup and periodic reconciliation
enqueue pending work and orphaned active subscriptions.

Every provider effect rechecks the recorded execution actor's current membership,
permissions, account readiness, and consent before vending credentials. Terminal
setup errors mark the trigger as errored; restore permissions or consent and
reactivate to repair it. Explicit actor reassignment synchronizes the desired
subscription authority. If authority is revoked, ingress stops, while remote
cleanup can remain errored until an eligible credential is available.

A verified event is inserted with a delivery job before returning HTTP 202.
Duplicate provider delivery IDs share a retained record and the existing trigger
firing idempotency key, producing one workflow run. Dispatch retries use that
same key. Deliveries queued before deactivation or a registration change are
ignored instead of starting a later run. HTTP 200 acknowledges selected-out events
and pings; 401 rejects bad signatures, 404 rejects inactive/unknown subscriptions,
and 503 leaves an unretained event available for provider retry. Payload retention
has no automatic expiration in this implementation.

Sources: [n8n GitHub trigger](https://docs.n8n.io/integrations/builtin/trigger-nodes/n8n-nodes-base.githubtrigger/),
[n8n Linear trigger](https://docs.n8n.io/integrations/builtin/trigger-nodes/n8n-nodes-base.lineartrigger/),
[GitHub repository hooks](https://docs.github.com/en/rest/repos/webhooks),
[GitHub signature verification](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries),
and [Linear webhooks](https://linear.app/developers/webhooks).

## Example: Linear issues to GitHub issues

Save the organization account selections returned by `ConnectedAccounts.select/3`.
The execution actor must have `workflows:run` and `workflows:activate`, and the
selected Linear connection must have webhook admin access.

```json
{
  "schema_version": 1,
  "id": "wf_linear_to_github",
  "name": "linear_to_github",
  "nodes": [
    {
      "id": "linear_event",
      "type": "linear.events",
      "version": 1,
      "params": {"team_id": "LINEAR_TEAM_UUID", "resources": ["Issue"], "actions": ["create"]},
      "connection": {"provider": "linear", "account_id": "LINEAR_ACCOUNT_ID"}
    },
    {
      "id": "github_issue",
      "type": "github.issues.create",
      "version": 1,
      "params": {"owner": "YOUR_OWNER", "repo": "YOUR_REPO", "title": "{{ $json.data.data.title }}", "body": "Created from a Linear issue webhook."},
      "connection": {"provider": "github", "account_id": "GITHUB_ACCOUNT_ID"}
    }
  ],
  "connections": [{"from": "linear_event", "to": "github_issue"}]
}
```

## Complete action catalog

All IDs below have version `1`. Parameters marked `*` are required. The tables
reflect the deployed operation schemas; `Catalog.fetch(type, 1)` exposes the
full schema and policy through `module.spec()`.

### GitHub

| Node ID | Parameters | OAuth scopes |
| --- | --- | --- |
| `github.files.create` | `owner`*, `repo`*, `path`*, `message`*, `content`*, `encoding`, `fields` | `repo` |
| `github.files.delete` | `owner`*, `repo`*, `path`*, `message`*, `fields` | `repo` |
| `github.files.edit` | `owner`*, `repo`*, `path`*, `message`*, `content`*, `encoding`, `fields` | `repo` |
| `github.files.get` | `owner`*, `repo`*, `path`*, `ref` | `repo` |
| `github.files.list` | `owner`*, `repo`*, `path`, `ref` | `repo` |
| `github.issues.create` | `owner`*, `repo`*, `title`*, `body`, `fields` | `repo` |
| `github.issues.create_comment` | `owner`*, `repo`*, `issue_number`*, `body`* | `repo` |
| `github.issues.edit` | `owner`*, `repo`*, `issue_number`*, `fields`* | `repo` |
| `github.issues.get` | `owner`*, `repo`*, `issue_number`* | `repo` |
| `github.issues.lock` | `owner`*, `repo`*, `issue_number`*, `lock_reason` | `repo` |
| `github.organizations.get_members` | `organization`*, `return_all`, `limit`, `filters` | `read:org` |
| `github.organizations.get_repositories` | `organization`*, `return_all`, `limit`, `filters` | `read:org` |
| `github.pull_requests.close` | `owner`*, `repo`*, `pull_number`* | `repo` |
| `github.pull_requests.create` | `owner`*, `repo`*, `title`*, `head`*, `base`*, `body`, `fields` | `repo` |
| `github.pull_requests.create_comment` | `owner`*, `repo`*, `pull_number`*, `body`* | `repo` |
| `github.pull_requests.edit_comment` | `owner`*, `repo`*, `comment_id`*, `body`* | `repo` |
| `github.pull_requests.get` | `owner`*, `repo`*, `pull_number`* | `repo` |
| `github.pull_requests.get_diff` | `owner`*, `repo`*, `pull_number`* | `repo` |
| `github.pull_requests.get_patch` | `owner`*, `repo`*, `pull_number`* | `repo` |
| `github.pull_requests.merge` | `owner`*, `repo`*, `pull_number`*, `merge_method`, `fields` | `repo` |
| `github.pull_requests.reopen` | `owner`*, `repo`*, `pull_number`* | `repo` |
| `github.pull_requests.update` | `owner`*, `repo`*, `pull_number`*, `fields`* | `repo` |
| `github.releases.create` | `owner`*, `repo`*, `tag_name`*, `fields` | `repo` |
| `github.releases.delete` | `owner`*, `repo`*, `release_id`* | `repo` |
| `github.releases.get` | `owner`*, `repo`*, `release_id`* | `repo` |
| `github.releases.list` | `owner`*, `repo`*, `return_all`, `limit`, `filters` | `repo` |
| `github.releases.update` | `owner`*, `repo`*, `release_id`*, `fields`* | `repo` |
| `github.repositories.get` | `owner`*, `repo`* | `repo` |
| `github.repositories.get_issues` | `owner`*, `repo`*, `return_all`, `limit`, `filters` | `repo` |
| `github.repositories.get_license` | `owner`*, `repo`* | `repo` |
| `github.repositories.get_profile` | `owner`*, `repo`* | `repo` |
| `github.repositories.get_pull_requests` | `owner`*, `repo`*, `return_all`, `limit`, `filters` | `repo` |
| `github.repositories.list_popular_paths` | `owner`*, `repo`* | `repo` |
| `github.repositories.list_referrers` | `owner`*, `repo`* | `repo` |
| `github.reviews.create` | `owner`*, `repo`*, `pull_number`*, `event`*, `body`, `fields` | `repo` |
| `github.reviews.get` | `owner`*, `repo`*, `pull_number`*, `review_id`* | `repo` |
| `github.reviews.list` | `owner`*, `repo`*, `pull_number`*, `return_all`, `limit`, `filters` | `repo` |
| `github.reviews.update` | `owner`*, `repo`*, `pull_number`*, `review_id`*, `body`* | `repo` |
| `github.users.get_issues` | `return_all`, `limit`, `filters` | `repo` |
| `github.users.get_repositories` | `username`*, `return_all`, `limit`, `filters` | `repo` |
| `github.users.invite` | `organization`*, `email`*, `fields` | `admin:org` |
| `github.workflows.disable` | `owner`*, `repo`*, `workflow_id`* | `repo` |
| `github.workflows.dispatch` | `owner`*, `repo`*, `workflow_id`*, `ref`*, `inputs` | `repo` |
| `github.workflows.enable` | `owner`*, `repo`*, `workflow_id`* | `repo` |
| `github.workflows.get` | `owner`*, `repo`*, `workflow_id`* | `repo` |
| `github.workflows.get_usage` | `owner`*, `repo`*, `workflow_id`* | `repo` |
| `github.workflows.list` | `owner`*, `repo`*, `return_all`, `limit`, `filters` | `repo` |

### Linear

| Node ID | Parameters | OAuth scopes |
| --- | --- | --- |
| `linear.comments.create` | `issue_id`*, `body`* | `comments:create` |
| `linear.issues.add_link` | `issue_id`*, `title`*, `url`* | `write` |
| `linear.issues.create` | `team_id`*, `title`*, `description`, `fields` | `issues:create` |
| `linear.issues.delete` | `issue_id`* | `write` |
| `linear.issues.get` | `issue_id`* | `read` |
| `linear.issues.list` | `return_all`, `limit`, `filter`, `include_archived` | `read` |
| `linear.issues.update` | `issue_id`*, `fields`* | `write` |
