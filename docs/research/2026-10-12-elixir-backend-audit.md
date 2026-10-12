# Hermitscale backend Elixir audit

The backend now validates external data before using internal assertions, preserves actionable dependency failures, and records workflow outcomes from the runner's actual state. Workflow topology and map-region rules have focused modules, while authentication, credential effects, and trigger delivery retain explicit contracts.

The audit covers `lib/hermitscale/` and its callers, tests, configuration, migrations, and installed Runic, Req, and JOSE implementations. It leaves two delivery architecture problems open: crash-safe firing/run linkage and atomic concurrent-run admission. The refactor makes incomplete delivery visible without attempting unsafe reclamation.

## Review coverage

Three independent first passes used the installed Elixir skills, including `let-it-crash`, Elixir essentials, code quality, and relevant Ecto, OTP, Oban, security, and testing guidance.

| Area | Modules and responsibilities |
| --- | --- |
| Workflow domain | Compiler, Validator, Graph, Catalog, Policy, Credentials, Replay, Expr, Matcher, Filters, node DSL, parameter binding, builtins, and Sheets nodes |
| Trigger runtime | Trigger context and schemas, dispatcher, scheduler, Oban worker, reconciler, supervisor, manual/webhook/schedule/poll/stream contracts, runtimes, and Sheets polling |
| External boundaries | Accounts, Scope, Authorization, WorkOS Client/JWT/Session, HTTP, connected accounts, provider registry, credential references, provider requests, Google Sheets client, Repo, and Mailer |
| Workflow control plane | Graph preparation, run creation/resume, completion, notifications, event storage, and checkpoint ordering |

Separate subsequent passes applied the linked resources to those areas:

- [J3RN on let it crash](https://j3rn.com/posts/let-it-crash/) informed boundary handling and source quarantine.
- [Elixir code anti-patterns](https://elixir.hexdocs.pm/main/code-anti-patterns.html) informed required versus optional access and explicit error contracts.
- [Elixir design anti-patterns](https://elixir.hexdocs.pm/main/design-anti-patterns.html) informed focused validation and removal of exception-driven tuple lookup.
- [Elixir process anti-patterns](https://elixir.hexdocs.pm/main/process-anti-patterns.html) informed process ownership, startup continuations, and failure containment.
- [Elixir macro anti-patterns](https://elixir.hexdocs.pm/main/macro-anti-patterns.html) informed compile-time declaration validation while retaining the essential Runic DSL.

The project runs Elixir 1.18.4. The linked `/main/` documentation tracks development; no newer Elixir API was introduced. Independent final reviewers examined the implementation, exercised 108 malformed graph variants, and checked Runic completion and mixed-executor behavior with controlled probes.

## Workflow domain changes

| Finding | Result |
| --- | --- |
| Malformed node type/version/params and graph metadata could pass validation or crash a later validation pass | Structural validation rejects those values before catalog, parameter, topology, or compiler work. Explicit null policies and malformed namespaces return structured issues. |
| Literal expression fields bypassed their declared schemas | Literal values are validated. Actual expressions remain deferred to the existing runtime expression contract. |
| Dynamic expression access leaked `:error` into a compiled expression | Unsupported fast paths use the Solid evaluator. Dynamic access resolves normally. |
| Valid reordered join edges were rejected | Slot validation compares sorted slots; compilation preserves the declared input order. |
| Tuple lookup rescued bounds errors across recursive work | Guards handle expected bounds misses without swallowing deeper defects. |
| Topology construction and traversal were duplicated | `Workflows.Topology` owns parent/child maps, ancestor traversal, and deterministic ordering. Validator's public ordering boundary still reports issues. |
| Map-region rules dominated the general validator | `Validator.MapRegions` owns its cohesive rule set through `issues/3`. |
| Issue and exception modules were nested | Separate files preserve the existing module names and serialized event compatibility. |
| Node declarations silently accepted invalid expression fields and policy defaults | Compile-time checks reject unknown/duplicate options, invalid ports, undeclared expression fields, invalid predicate declarations, and invalid integer policies. |
| Validation metadata was authorable | Graph changesets leave validation timestamps and issues under server control. |
| Credential collections repeatedly appended lists | Prepend/reverse accumulation preserves order with linear collection work. |

Shared graph preparation now handles create and update through the same validation and account-selection sequence. Ecto remains responsible for field casting and required-field errors. Omitted definitions retain the saved definition; explicit null definitions are rejected.

Runic builder closures, node identities, and replay fingerprints retain their established semantics. The essential macros remain because they generate the node contract and Runic context expressions. Documented scalar map inputs and merge behavior remain supported.

## External boundary changes

WorkOS successful responses now validate the fields their callers consume, including organization and membership identities, role permissions, provider/account lists, connection URLs, credentials, and pagination. Pagination rejects malformed or repeated cursors. Credential expiration accepts absence or a valid timestamp and rejects malformed supplied values. Malformed Google Sheets read responses return `:invalid_google_sheets_response`; an omitted values array remains a valid empty sheet.

Session and authorization preserve dependency errors such as `:unavailable`, `:rate_limited`, `:invalid_response`, and `:invalid_jwks`. An outage or malformed dependency response no longer implies that a session is invalid or an actor has been revoked.

JWT verification validates the selected public RSA key before JOSE conversion and permits unrelated advertised algorithms. JOSE already reports malformed tokens and signatures as values. Removing the whole-function rescue makes client-adapter and internal defects visible without turning malformed tokens into uncaught exceptions.

Personal membership provisioning performs one re-read after a creation conflict. It succeeds if the concurrent membership is visible and otherwise returns the conflict; it never recursively repeats creation forever.

Provider requests use Req's bounded safe-transient retry policy and backoff, including `Retry-After`. A prepared adapter wrapper rechecks authorization and vends credentials immediately before every attempt. Authentication-method rotation removes the previous method's headers. Writes and permanent transport failures are not retried. Destination enforcement, disabled redirects, secret redaction, and secret-free error normalization remain in place. Req's required exception-shaped adapter errors are represented by an unraised `RequestError` value and converted back to the domain error tuple at the request boundary.

## Trigger delivery and supervision changes

Polling explicitly accepts dispatched runs, completed duplicates, and deliberate admission rejections. Other failures retain the previous cursor and consume the bounded retry budget. Partial batches replay with their successful prefix deduplicated.

An unresolved `:dispatched` firing without a linked run returns `:firing_in_progress`. It cannot claim successful delivery and cannot be reclaimed while another dispatcher may still be working. Retry exhaustion reports that delivery needs review.

FireWorker validates persisted arguments and dates. Deleted, disabled, ineligible, and repair-required cases cancel explicitly; dependency failures retry through Oban. Scheduler insertion uses the error-returning API and rolls back rather than advancing an occurrence after failed enqueueing.

Source loading runs in `handle_continue`, keeping database and catalog work out of supervisor startup. Deleted or disabled sources stop normally. Public execution identity and graph deactivation reload authoritative records rather than trusting stale or forged structs. Reconciler fingerprints compare exact configuration tuples.

Expected callback error tuples retain their retry contract. Exceptions and invalid callback results quarantine the source immediately and stop normally. This prevents a deterministic callback bug from consuming the shared supervisor's restart budget. The only callback rescue is scoped to the extension invocation. Logs retain the exception class and stack locations while omitting exception messages and argument values. Internal dispatcher exceptions remain visible.

Stream reconnects preserve consecutive failure counts until successful delivery. Sheets cursor epochs and generations distinguish real repeated changes and reactivation from replay of the same failed poll. Older cursors receive a stable legacy epoch until reinitialization.

## Workflow outcomes and persistence

Runic invokes completion callbacks when stopped admission drains, including failed work, and after failed checkpoint writes. Completion therefore uses the state-aware `on_idle` hook. Only saved state with no admission failure becomes `:complete`. Execution failures and failed durable outcomes become `:failed` with sanitized error codes; exception messages and dependency details are not persisted in error JSON.

Successful and failed outcomes publish distinct `:run_complete` and `:run_failed` notifications. Inline admission reloads the recorded result after synchronization. Pending work from asynchronous component overrides remains a successfully admitted running run.

The completion hook captures the admitted terminal node IDs. Editing a stored graph during execution cannot replace the original run's output selection. Successful completion clears a prior failure code.

The Postgres store locks a newly created run even when another writer wins creation, then serializes sequence allocation. Ordered append, checkpoint replacement, empty logs, and deletion retain the store contract.

## Remaining architecture work

1. **Durable firing and run linkage.** A process can still die between reserving a firing, creating a run, starting runner work, and linking the records. `:firing_in_progress` exposes this uncertainty and prevents false deduplication, but does not recover it. A complete design should transactionally record admission and run linkage, retain startup intent, and reconcile startup independently. Wrapping the current start call in a transaction is insufficient because it starts separate processes and effects before commit. Never reclaim an unresolved reservation solely because its `run_id` is nil or old.
2. **Atomic concurrent-run admission.** The dispatcher still counts running runs and admits outside a shared graph transaction. Concurrent firings can exceed `max_concurrent_runs`. Serialize admission and run insertion on the graph row, including different triggers belonging to the same graph, as part of the durable admission design.
3. **Recovery after failed outcome recording.** A successful Runic checkpoint retry does not call the idle hook again. Failed durable outcomes remain failed until an explicit recovery/resume path handles them. If the shared database is unavailable, even recording the failure can fail; durable reconciliation must cover that control-plane state too.
4. **Provider stream replay.** Generic stream processes cannot promise replay without a provider-specific acknowledgment and event-identity contract. Keep that requirement explicit when adding production stream providers.
5. **Boot and deployment contracts.** Required production WorkOS environment variables currently check presence but not blank values or URL validity. Catalog modules removed by a deployment can invalidate stored source configuration. Validate required operator configuration at boot and define a catalog-removal policy before relying on automatic restart to recover these cases.

## Verification

The baseline suite passed 222 tests. Final `mix precommit` passed 290 tests with no failures, including compilation with warnings treated as errors, formatting, and the full suite. `git diff --check` also passed. Regression coverage includes malformed authoring data and provider bodies, authorization freshness, bounded provisioning, key validation, credential rotation, retries, cursor retention, source quarantine, stream failure budgets, repeated Sheets transitions and reactivation, stale graph deactivation, failed run outcomes, pending component overrides, admitted output selection, and store ordering.

The installed code-quality analysis scripts were unavailable. A local AST pass checked the skill's ABC metric against the baseline and refactored backend: neither had a function at or above 30. Compiler checks cover unused private functions; review removed duplicated topology and graph preparation. Hex reported no retired dependencies. No dependencies, routes, or migrations were added.
