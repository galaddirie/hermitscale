# Workflow Expression System — Design Document

| | |
|---|---|
| **Status** | Draft |
| **Authors** | Galad Dirie |
| **Reviewers** | [name(s)] |
| **Last updated** | 2026-06-28 |
| **Related docs** | Runic (https://github.com/zblanco/runic) · Solid (https://solid.hexdocs.pm/readme.html) · `lib/hermitscale/workflows/template.ex` (system being replaced) · **Prior art:** the `fizz` expression system (`Fizz.Workflows.Expressions` + `…/expressions/access_plan.ex`) — a shipped Solid-backed engine that prefigures this design; lessons folded in throughout |

---

## 1. TL;DR

We are replacing `Hermitscale.Workflows.Template` — a regex-based interpolator that only understands `{{ $.path }}` accessors against a single input map — with an **n8n-style expression system** backed by [Solid](https://solid.hexdocs.pm/readme.html) (a Liquid template engine for Elixir). Workflow param fields will accept expressions like `{{ $json.email }}`, `{{ $node["fetch_user"].json.body.id }}`, and `{{ $env.API_BASE }}/users/{{ $json.id }}`, evaluated at runtime against the data flowing through the `Runic` DAG. The expression layer is **sandboxed by construction** — Liquid has no `eval`, no filesystem, no arbitrary code — which is exactly the constraint a low-code workflow tool wants. The plumbing that makes expressions work (context assembly, the cross-node "envelope", type preservation) is generated centrally by the `Nodes.Behaviour` macro, so node authors write only pure `work/3` logic and get expressions for free.

---

## 2. Context & Problem

### 2.1 Background

Hermitscale compiles JSON workflow graphs into `Runic.Workflow` structs (`Workflows.Compiler`). Each graph node names a catalog node module (`Nodes.Behaviour` implementors such as `HttpRequest.V2`), whose `build/2` returns a Runic component (`Runic.step`, `Runic.map`, …). Params are validated against a `NimbleOptions` schema by `Nodes.Params`, and policy/topology are applied by the compiler.

Today, dynamic field values are handled by `Workflows.Template.render/2`:

- Syntax is limited to JSON accessors: `{{ $.sku }}`, `{{ $.items.0.sku }}`.
- It resolves **only against the single input map** handed to the step — there is no way to reference another node's output, run metadata, environment, or the clock.
- Every value is stringified, so an expression can never return an integer, list, or map.
- It is invoked **manually inside each node's `build/2`** (see `HttpRequest.V2` line 30: `Template.render!(^url_template, input)`), so every node re-implements the same plumbing and any node that forgets it silently loses interpolation.

### 2.2 Problem statement

Workflow authors cannot express the dynamic data references that an n8n-style builder requires: "use the id from the HTTP node two steps back", "read the API base from an environment variable", "send this field as a real number, not a quoted string". The current template engine is too narrow (single input, string-only) and the integration is too manual (per-node, easily skipped). We need a richer, type-preserving, **centrally-enforced** expression layer that stays sandboxed.

### 2.3 Why now

The catalog/compiler foundation (durable Runic workflows, the node authoring kit, credential resolution) has just landed. The expression layer is the next dependency for a usable visual builder, and retrofitting it after dozens of catalog nodes exist would mean editing every `build/2`. Doing it now lets the `Behaviour` macro own the plumbing before the node count grows.

---

## 3. Goals & Non-goals

### 3.1 Goals

- **n8n-familiar *interpolation and namespaces*.** Support `{{ … }}` interpolation with the `$json`, `$node["Name"]`, `$vars`, `$env`, `$workflow`, `$execution`, `$now`, `$today` namespaces. **Be explicit about where the familiarity ends:** Liquid has no infix operators, so the *expression body* is not n8n-compatible past simple access. n8n's `{{ $json.total > 100 && $json.active }}` has no direct form — comparisons and boolean logic become filter pipelines (`{{ $json.total | gt: 100 }}`), and there are no ternaries or arithmetic operators (use `plus`/`minus`/`times` filters). This is the largest expectation gap for authors arriving from n8n; the editor/docs must teach the filter-pipeline idiom, not imply JS-expression parity. `fizz` shipped exactly this constraint (e.g. `input.total | gt: 100`) and it held up — but it must be stated, not discovered.
- **Sandboxed evaluation.** No arbitrary code execution; expressions cannot touch the filesystem, network, or other templates. Liquid's restricted object+filter grammar is the entire surface.
- **Type preservation.** A field that is exactly one expression (`{{ $json.count }}`) returns the native value (integer, map, list); a field that mixes literals and expressions returns a string.
- **Centrally enforced plumbing.** Node authors implement a pure `work/3`; the `Behaviour` macro generates the `build/2` that resolves params, assembles context, and threads the cross-node envelope. No node can break the `$node` chain.
- **Compile-time validation.** Expression syntax is parsed once at graph-compile time (errors surface at save/compile, not at run). `$node["X"]` references are statically checked against the graph's nodes by the `Validator`.
- **Drop-in replacement.** `Workflows.Template` is removed; `HttpRequest.V2` and future nodes use the new system with no per-node interpolation code.

### 3.2 Non-goals

- **Arbitrary JavaScript / general computation.** n8n allows raw JS in expressions; we deliberately do not. The sandbox is the point. Authors who need real logic write a catalog node.
- **Backward compatibility with `{{ $.path }}` syntax.** The old single-input JSON-pointer form is replaced, not aliased. Existing graphs (if any) are migrated (§9). The richer `$json` namespace supersedes the bare `$.` root.
- **A visual expression builder / autocomplete UI.** This doc covers the evaluation engine only; the front-end editor is separate work.
- **Per-item streaming semantics beyond what Runic already models.** We map onto Runic's existing `step`/`map`/`reduce`/`join` primitives; we do not introduce a new execution model.

### 3.3 Success criteria

- `HttpRequest.V2` builds a URL from `{{ $env.API_BASE }}/users/{{ $json.id }}` and a downstream node reads `{{ $node["http_request"].json.body.email }}` — both pass through compiler and run.
- A `{{ $json.count | to_number }}` field arrives at the node as an Elixir integer.
- A graph referencing a non-existent `$node["typo"]` fails `Validator.validate/1` at compile time.
- Zero `Template.render` call sites remain; node authors who implement only `work/3` get working expressions.

---

## 4. Overview

### 4.1 Approach

n8n expressions are three things glued together: a **delimiter syntax** (`{{ … }}`), a **variable namespace** (`$json`, `$node`, `$now`, …), and an **evaluator** (V8/JS). We keep the first, re-create the second on top of Runic primitives, and replace the third with Liquid's restricted grammar via Solid. The replacement *is* the value proposition: deterministic, serializable, no `eval`.

The variable namespace splits cleanly across Runic primitives **by lifetime**:

- **Per-item, dynamic** (`$json`, `$binary`, `$itemIndex`) → the input fact the Runic step receives.
- **Per-run, static** (`$vars`, `$env`, `$workflow`, `$execution`) → Runic `context/1` / `put_run_context` (scoped by name, not part of the workflow hash, not serialized).
- **Cross-node** (`$node["X"].json`, `$items(...)`) → an **envelope** threaded through facts, because Runic's dataflow only hands a node its parents' output, not arbitrary ancestors.
- **Clock** (`$now`, `$today`) → computed at render time.

Three modules carry the design: **`Expr`** (compile + render, type preservation, the `$`-rewrite), **`Expr.Filters`** (n8n-flavored Liquid filters), and an extended **`Nodes.Behaviour`** that adds a `work/3` callback and generates `build/2` per node `kind`. `Params` learns to compile expressionable fields; the `Compiler` seeds the envelope and run context; the `Validator` gains a `$node` static-analysis pass.

### 4.2 System diagram

```mermaid
flowchart LR
    Graph[Graph JSON<br/>param values] --> Params[Nodes.Params.cast]
    Params -->|expressionable fields| Expr_c[Expr.compile<br/>literal / interp / expr]
    Params -->|plain fields| NO[NimbleOptions]
    Expr_c --> Spec[Compiled params in<br/>Runic component]
    NO --> Spec
    Spec --> Compiler
    Compiler -->|put_run_context _expr| WF[(Runic.Workflow)]
    WF -->|envelope fact| Step[Generated build/2 step]
    Step --> BC[Expr.build_context]
    BC --> Render[Expr.resolve → Solid.render]
    Render --> Work["work/3 (pure node logic)"]
    Work --> Env[Expr.put_output → envelope]
    Env --> WF
```

### 4.3 Key design decisions

- **Solid/Liquid as the engine, not a custom DSL.** Liquid gives delimiters, dotted/bracket variable access, and a filter pipeline essentially for free, and its lack of `eval` is the sandbox we want. We add ~5 custom filters for n8n-isms (`to_json`, `to_number`, …).
- **Plumbing lives in the `Behaviour` macro, not in `build/2`.** Expression resolution is a cross-cutting concern. The macro knows `kind` and `requires` statically, so it generates a kind-appropriate `build/2` and unrolls `requires` into literal `context/1` calls. Authors implement pure `work/3`. `build/2` remains `defoverridable` as an escape hatch.
- **Two render paths for type preservation.** "Whole field is one expression" → a focused object evaluator that returns native types; "string with expressions" → `Solid.render!` returning a binary. This matches n8n's own behavior and is unavoidable since Liquid always renders to iodata.
- **`$`-prefix rewrite is region-scoped.** Solid does strict Liquid lexing and `$` is not a legal identifier char. We rewrite `$ident → ident` **only inside `{{ }}`/`{% %}` regions**, never in literal text (so an OData `?$top=5` in a URL survives).
- **`$node` via an envelope fact, not global mutable state.** Each generated step emits `%{"json" => result, "node" => %{...prior outputs}}`. This is the only way to give a node access to non-parent ancestors within Runic's parent-only dataflow. **This is the one part of the design with no `fizz` precedent to copy:** `fizz` accumulates step outputs in a central `ExecutionContext.steps` map because it isn't on Runic's parent-only model. The envelope is our forced adaptation — and `fizz`'s central-context approach quietly confirms the §10.2 pruning worry is real (it never hit unbounded growth precisely because nothing was threaded per-fact). Give the envelope the heaviest test coverage; it is the novel part.
- **`$node` references resolve by stable node ID, not display name.** `$node["X"]` keys on the graph's immutable node ID; the editor may *show* a human label, but a label→ID map is resolved at compile time (`fizz` does this for `steps["Fetch Orders"]` via a `step_name_to_id` map, `expressions.ex:230-240`). This makes node renames a no-op for expressions — only the editor's label map changes, never the stored expression. `fizz` chose ID-keyed referencing and *still* logged automatic rename-rewriting as a painful deferred item; keying on ID from day one avoids that debt entirely.
- **Validation is split by what's knowable when.** Syntax + `$node` reference existence are checked at compile time; value types of expression fields are deferred to run time (the value doesn't exist at compile time). Expressionable fields are marked in the spec, not in the `NimbleOptions` schema (which rejects unknown keys).

---

## 5. Detailed Design

### 5.1 Components

#### 5.1.1 `Hermitscale.Workflows.Expr`

**Responsibility.** Compile a raw param value into a tagged, pre-parsed form at graph-compile time, render it against a runtime context at run time, **and preview it against sample context at edit time.** `preview/2` (compile one expression string + render against the current upstream outputs, returning `{:ok, value} | {:error, located_message}`) is engine surface even though the visual builder UI is out of scope (§3.2) — the *evaluation* half of preview belongs here, only the rendering UI is separate. `fizz` exposes exactly this as `Expressions.preview/2` and the editor LiveView calls it.

**Owns.** The compiled-value representation, the `$`-rewrite, the type-preserving object evaluator, context assembly, and the envelope protocol.

**Depends on.** `Solid`, `Expr.Filters`, `Jason` (for `to_json` round-trips).

**Notes.** Compiled values are tagged:

```elixir
@type compiled ::
        {:literal, term()}                          # no expression — passed through untouched
        | {:interp, Solid.Template.t()}              # mixed literal/expression — renders to a string
        | {:expr, path :: [String.t()] | nil, Solid.Template.t()}  # lone expression — native value
        | {:predicate, Solid.Template.t()}           # boolean field — resolves to a real boolean
```

`compile/1`: non-binary → `{:literal, v}`; binary without `{{`/`{%` → `{:literal, v}`; a single whole-string `{{ … }}` → `{:expr, …}` (or `{:predicate, …}` for fields a node declares boolean — see below); anything else → `{:interp, Solid.parse!(normalized, tags: safe_tags)}`. `normalize/1` applies the region-scoped `$`-rewrite. `render/2` dispatches on the tag. `build_context/2` produces the Solid context map from the envelope (`$json`, `$item`, `$node`) and the per-run runtime map (`$vars`, `$env`, `$workflow`, `$execution`, `$now`, `$today`). `put_output/3` re-wraps a node result into the envelope under the node name.

**Type preservation — do not hand-roll a Liquid subset.** An earlier sketch had the lone-expression path reimplement dotted/bracket access plus a filter pipeline so it could return native types. The `fizz` engine demonstrates a strictly better approach that we adopt: **reuse Solid's own evaluator on the single extracted object.** For a lone `{{ … }}`, pull the one `%Solid.Object{argument: arg, filters: fs}` out of the parsed template and call `Solid.Argument.get(arg, %Solid.Context{vars: bindings}, fs, custom_filters: Filters)`. That runs the access path **and the filter pipeline** and returns the raw Elixir term — so `{{ $json.count | to_number }}` yields an integer with zero reimplemented grammar (`fizz`: `Expressions.render_object_value/2`, `expressions.ex:270-277`).

On top of that, a **compile-time fast path**: when the lone expression is a pure literal access with no filters, store its path (`["json","email"]`) and resolve at run time with a direct map walk, skipping Solid entirely (`fizz`: `resolve/2` clause at `expressions.ex:127-133`, falling back to the object evaluator otherwise). Hence `{:expr, path, parsed}` carries both — `path` when extractable for the fast walk, `parsed` always for the `Argument.get` fallback.

Full Liquid semantics (`for`, `if`, default chains) remain only in the `{:interp, …}` path, which always yields a string. The `{:predicate, …}` path evaluates the same single-object way and coerces the result through a `truthy?/1` — it exists because boolean fields (branch/conditional nodes) need a real boolean, and Liquid's lack of infix operators means predicates are written as filter pipelines (`{{ $json.total | gt: 100 }}`).

> **The seam we couple to (and the one we don't).** `Argument.get/4` and the `%Solid.Object{}`/`%Solid.Context{}` shapes are a semi-internal Solid API. We accept that coupling because it is *small and stable* — and far cheaper than reimplementing and maintaining Liquid's object+filter semantics ourselves (which would also drift from the string path's behavior). **Rejected alternative:** walking `%Solid.Template{}`'s full parsed `parts` list to detect a lone object — that couples us to the *structure* of the AST (version-dependent, currently v1.3.2), a broader and more fragile surface than calling the evaluation functions. Pin the Solid version; cover the `Argument.get` path with tests that assert native-type return across each custom filter.

#### 5.1.2 `Hermitscale.Workflows.Expr.Filters`

**Responsibility.** Expose n8n-style helpers as Liquid filters, called by Solid as `Module.fun(value, args...)`.

**Owns.** `to_json/1`, `from_json/1`, `to_number/1`, `is_empty/1`, `uuid/1`, the predicate comparators (`eq`, `ne`, `gt`, `gte`, `lt`, `lte` — these are how `{:predicate,_}` fields express comparisons, since Liquid has no `>`), plus any future additions. Liquid's built-ins (`upcase`, `downcase`, `default`, `date`, `plus`/`minus`, `size`, `join`, `split`, `first`/`last`, `replace`, `truncate`) cover most of n8n's string/number/array surface.

**The catalog is an explicit allowlist, not "whatever Solid ships."** `fizz` curates the set of permitted built-ins *and* custom filters and rejects anything outside it at publish time (`expressions.ex:13-49`, the `@allowed_filters` union; `expression-filter-catalog.md` decision record). We do the same: the allowlist is the public, documentable surface; an unknown filter is a compile-time error (see §5.1.6), not a silent run-time no-op. This keeps the sandbox auditable and the author-facing vocabulary bounded.

**Depends on.** `Jason`; a UUID source (`Ecto.UUID` or `:crypto`).

#### 5.1.3 `Hermitscale.Workflows.Nodes.Behaviour` (extended)

**Responsibility.** Generate compile-time-validated specs **and** a kind-appropriate `build/2` from a pure `work/3` callback.

**Owns.** A new `expr: [atoms]` option (stored in the spec as `expr_fields`), a new `@callback work(params, item, deps) :: term()`, and the `__gen_build__/1` AST generator. `build/2` becomes `defoverridable`.

**Depends on.** `Runic`, `Expr`, `NimbleOptions`, `Policy`.

**Notes.** Two constraints force the plumbing into the macro rather than a generic compiler wrapper:

1. **`context/1` is a compile-time AST rewrite.** Runic's `context(:_expr)` only works when it appears *literally* inside the `fn` handed to `Runic.step` — it cannot hide behind a helper. So whoever fetches run context must emit that call inside the generated step.
2. **Context differs by `kind`.** For `:step`, `$json` is the input fact. For `:map`, `$json` should be the *current element*. For `:reduce`, element vs. accumulator. For `:join`, multiple parents. A single dumb wrapper can't be correct; the generator branches on `kind` (which the spec already carries).

`requires` keys are unrolled at macro-expansion time into a literal map of `context/1` calls — you cannot loop over keys at runtime and call a macro.

#### 5.1.4 `Hermitscale.Workflows.Nodes.Params` (extended)

**Responsibility.** Split a node's raw params into expressionable and plain fields; compile the former via `Expr.compile`, validate the latter via `NimbleOptions` exactly as today.

**Owns.** The `cast/3` arity that takes `expr_fields`. Output is an atom-keyed map mixing validated literals and tagged compiled values.

**Notes.** Expressionable fields accept **either** a literal or an expression and defer their type check to run time. Plain fields are unchanged.

**Open design tension — per-field vs per-leaf expressionability.** The `expr: [:url]` whitelist treats expressionability as a property of a *top-level field*. `fizz` instead walks the **entire nested config tree** and evaluates any string leaf containing tags (`config_resolver.ex:29-37`, recursing through maps and lists), passing literal strings through untouched. Its TODO (TODO.md:169-171) records *why*: the per-field "fixed vs expression" distinction turned out leaky — a map/table editor is nominally a "fixed" input yet still needs to evaluate expressions inside individual cells, and the team openly questioned whether the distinction should exist at all. Our flat `expr: [:url]` cannot express "this param is a map whose cells may contain expressions." Decide deliberately (§10.2) whether expressionability is a top-level-field flag or a property of any string leaf in a possibly-nested param; `fizz`'s experience pushes toward the latter.

#### 5.1.5 `Hermitscale.Workflows.Compiler` (extended)

**Responsibility.** Pass `spec.expr_fields` into `Params.cast!/3`, seed the per-run `_expr` context, and start runs with a wrapped envelope fact.

**Notes.** The envelope contract: facts are `%{"json" => …, "node" => …}` and `_expr` lives under the global run context key. Single change at `Params.cast!` call site; the rest is run-start wiring (`put_run_context` + `react_until_satisfied(%{"json" => input, "node" => %{}})`).

#### 5.1.6 `Hermitscale.Workflows.Validator` (extended)

**Responsibility.** Three static passes over each compiled expression, folded into the existing topo/connection checks:

1. **`$node` reference existence** — extract `$node["X"]` references and check them against the graph's node set (and optionally connectivity). Makes "references a node that doesn't exist / isn't upstream" a compile-time error.
2. **Filter allowlist + arity** — walk the parsed template collecting every filter name, reject any outside the §5.1.2 allowlist, and check argument arity against the exported function. `fizz` does exactly this at publish (`expressions.ex:313-373`); an unknown or misused filter is a located compile error, same channel as a bad `$node` ref.
3. **Dependency extraction (not just checking).** The same walk that finds `$node["X"]` also *yields* the set of referenced nodes and runtime namespaces. `fizz`'s `dependencies/1` (`expressions.ex:206-228`) returns `%{step_ids, runtime_keys}` from a parsed template. We use this two ways: to drive the connectivity check ("`$node["X"]` ⇒ X must be upstream"), and as a potential source of implicit DAG edges — an expression reference is a real data dependency, so the graph need not redundantly declare the edge. (Whether we *auto-add* edges or merely *validate* declared ones is an open question — §10.2.)

**Two-tier strictness — lenient draft, strict publish.** `fizz` accepts incomplete/partial expressions on draft save and runs full validation (filter strictness + known-node set) only at publish. We adopt the same split: parse-lenient while editing (so autosave doesn't hard-fail mid-keystroke), fully strict at publish/compile. The `Validator` takes a `strict?`/`known_nodes` flag that the draft path leaves off.

### 5.2 Data model

No new persistent state. The only new in-memory structures are the **compiled param** tagged tuple (`{:literal | :interp | :expr | :predicate, …}`, embedded in the compiled `Runic.Workflow`) and the **envelope** fact (`%{"json" => term, "node" => %{name => %{"json" => term}}}`) that flows between nodes at run time. Run-scoped `_expr` data lives in Runic's `context`, which is intentionally *not* part of the serialized workflow hash.

### 5.3 Interfaces / APIs

Node-author contract — implement `work/3`, get expressions for free:

```elixir
defmodule Hermitscale.Workflows.Nodes.HttpRequest.V2 do
  use Hermitscale.Workflows.Nodes.Behaviour,
    id: "http_request", version: 2, kind: :step,
    requires: [credentials: []],
    expr: [:url],                       # which params accept expressions
    params: [
      method: [type: {:in, ~w(GET POST PUT PATCH DELETE)}, required: true],
      url:    [type: :string, required: true]
    ]

  @impl true
  def work(%{method: method, url: url}, _item, %{credentials: creds}) do
    # params arrive RESOLVED; requires arrive FETCHED; result is auto-wrapped.
    Hermitscale.HTTP.request(method, url, auth: creds) |> handle()
  end
end
```

Expression surface available in any expressionable field:

```
{{ $json.email }}                                   # current item
{{ $node["http_request"].json.body.id }}            # cross-node
{{ $env.API_BASE }}/users/{{ $json.id }}            # mixed → string
{{ $json.count | to_number }}                       # lone expr → integer
{{ $json.items | size }}   {{ $now }}   {{ $vars.region | upcase }}
```

### 5.4 Key flows

#### 5.4.1 Compile a graph node with an expression

```mermaid
sequenceDiagram
    participant C as Compiler
    participant P as Params
    participant E as Expr
    participant V as Validator

    C->>P: cast!(raw_params, schema, spec.expr_fields)
    P->>E: compile("{{ $env.API_BASE }}/users/{{ $json.id }}")
    E->>E: normalize ($-rewrite, region-scoped) + Solid.parse!
    E-->>P: {:interp, %Solid.Template{}}
    P-->>C: %{method: "GET", url: {:interp, ...}}
    C->>V: validate $node refs vs graph nodes
    V-->>C: :ok | {:error, issues}
    C-->>C: build/2 (generated) embeds compiled params in Runic step
```

#### 5.4.2 Run a step: resolve, work, re-wrap

```mermaid
sequenceDiagram
    participant WF as Runic.Workflow
    participant S as Generated step
    participant E as Expr
    participant W as work/3

    WF->>S: envelope = %{"json"=>item, "node"=>prior}
    S->>S: runtime = context(:_expr)
    S->>E: build_context(envelope, runtime)
    E-->>S: %{"json"=>item, "node"=>prior, "env"=>..., "now"=>...}
    S->>E: resolve(params, ctx)
    E-->>S: %{method: "GET", url: "https://api/users/42"}
    S->>W: work(resolved, item, deps)
    W-->>S: result
    S->>E: put_output(envelope, name, result)
    E-->>WF: %{"json"=>result, "node"=> prior ⊕ {name=>result}}
```

The `:map`/`:reduce` generated clauses differ only in **what `build_context` points `$json` at** (the current element / the accumulator), which is exactly the part that cannot be made generic.

### 5.5 Dependencies

| Dependency | Type | Hard / soft | Notes |
|---|---|---|---|
| `Solid` (Liquid engine) | Hex library (**new dep**) | Hard | Parsing + rendering. Pin a version; `{:expr,_}` path avoids its internal AST. |
| `Runic` `~> 0.1.0-alpha.8` | Hex library (existing) | Hard | `step`/`map`/`reduce`/`join`, `context/1`, `put_run_context`. Alpha — API may shift. |
| `NimbleOptions` | via existing params system | Hard | Plain-field validation (unchanged). |
| `Jason` `~> 1.2` | existing | Hard | `to_json`/`from_json` filters. |

---

## 6. Alternatives Considered

### 6.1 Alternative: Extend the existing regex `Template`

**What it is.** Grow `Workflows.Template` to support `$node`, `$env`, filters, and type preservation with more regexes and a hand-rolled accessor walker.

**Why it was tempting.** No new dependency; the code already exists and is small.

**Why rejected.** We'd be reimplementing a template language one regex at a time — filters, escaping, nested access, error reporting. Solid already solves all of it, is sandboxed, and is battle-tested. Extending the regex engine trades a one-line dep for an open-ended maintenance burden and a worse author experience.

### 6.2 Alternative: Embed a real scripting language (Lua / JS via a port)

**What it is.** Match n8n literally — let authors write arbitrary expressions in an embedded interpreter.

**Why it was tempting.** Maximum expressive power; exact n8n parity.

**Why rejected.** It reintroduces the sandbox problem we're explicitly trying to avoid (resource limits, injection, non-determinism, serialization). For a low-code catalog tool, arbitrary computation belongs in a catalog node, not an inline field. Liquid's restricted grammar is a feature, not a limitation.

### 6.3 Alternative: Resolve expressions inside each node's `build/2` (the v1 sketch)

**What it is.** Keep `build/2` as the integration point and call `Expr.resolve`/`put_output`/`build_context` by hand in every node, as `HttpRequest.V2` does with `Template.render!` today.

**Why it was tempting.** No macro magic; each node is fully explicit and self-contained.

**Why rejected.** It's per-node boilerplate for a cross-cutting concern. A node that forgets `put_output` silently breaks the `$node` chain for everything downstream — a failure mode that's invisible until a later node reads a `nil`. Centralizing in the `Behaviour` macro makes the envelope protocol unforgeable and lets policy/telemetry/error handling live in one generated path. The macro is justified precisely because the per-kind context logic is hard to get right; we don't want it copied into 40 modules.

### 6.4 Alternative: do nothing / keep `Template`

**What it is.** Ship the visual builder on the current single-input, string-only interpolator.

**Why rejected.** Authors cannot reference other nodes, env, or the clock, and cannot emit non-string values — table stakes for an n8n-style tool. The status quo blocks the builder.

---

## 7. Cross-cutting Concerns

### 7.1 Security

The headline security property is **the sandbox**: Liquid has no `eval`, no I/O, no network. We further drop filesystem/template-include tags (`render`, `include`) from the default tag set so an expression cannot pull in other templates. The existing `Nodes.Params` discipline (only schema-declared keys become atoms) is preserved, so user input never creates arbitrary atoms.

**Credentials never enter the expression namespace.** `$env`/`$vars` carry *non-secret* run config only, populated by the compiler/run-starter from trusted sources — never from user-controlled graph JSON. Secrets do **not** flow through `$env`/`$vars`: they reach a node through the separate `requires: [credentials: …]` path, resolved at run time. This mirrors `fizz`, which keeps credentials out of its Liquid bindings entirely (`solid_bindings/4` exposes only `input/json/steps/workflow/env`) and resolves them through a distinct `CredentialRef` + injected 4-arity resolver (`access_plan.ex:44-61`, `expressions.ex:150-178`). The property we get: **an expression can never print a secret**, because no secret is ever bound into the expression context. *(This corrects an earlier draft that routed secrets through `$env`/`$vars`.)* **Threat to watch:** the run-starter must still scope `$env`/`$vars` to what the workflow is authorized to see.

### 7.2 Privacy & data handling

The engine adds no new storage or PII categories, but it does *move* item data through the envelope (`$node` outputs accumulate across the run). In-memory flow is by design and bounded to the run.

**The real exposure is persistence/serialization, not the in-memory envelope.** `fizz`'s TODO records a concrete, lived leak: *evaluated* config gets written into step execution metadata, and that metadata is encoded to the client — so resolved values (and anything they incorporated) can surface in client logs/UI. The lesson for us: the danger isn't the fact flowing between nodes, it's any path that **persists or transmits resolved expression values**. Two mitigations, made requirements: (1) since credentials never enter the expression namespace (§7.1), resolved expression values cannot *contain* a secret by construction — the most important safeguard; (2) when we persist run state for durability/replay or ship step I/O to the editor, resolved values that derived from `$env`/`$vars` must be redactable, and we should default to not serializing the fully-resolved param map to the client. Treat "evaluated config → execution metadata → client" as an exfiltration path to design against, not an afterthought.

### 7.3 Observability

**Logs.** Render failures (missing var under `strict_variables: true`, filter errors) logged with the node name, field, and (truncated) source. Compile-time parse/validation errors surface through the existing compiler/validator error channel.

**Metrics.** Expression render count and error rate per node type; compile-time parse failures per graph. Useful for spotting authors fighting the syntax.

**Traces.** Per-step render is cheap and need not be its own span; piggyback on the existing Runic step instrumentation.

### 7.4 Reliability & failure modes

| Failure | Detection | Behavior | Recovery |
|---|---|---|---|
| Bad expression syntax | `Solid.parse!` at compile time | Graph fails to compile with a located error | Author fixes source; never reaches run |
| `$node["typo"]` reference | Validator static pass | `validate/1` returns `{:error, …}` | Author fixes; compile-time |
| Missing var at run time | `strict_variables` flag | Default `false` → renders empty (n8n-permissive); per-field `true` → raise | Tune per field |
| Node forgets `put_output` | **Cannot happen** — macro-generated | N/A | N/A by construction |
| Type mismatch after resolve | Run-time (deferred check) | `work/3` receives resolved value; node validates as needed | Author guards or adds a filter |

### 7.5 Performance & scale

Templates are parsed **once** at graph-compile time and embedded in the `Runic.Workflow`; run-time cost is just `Solid.render` over a small context. Literal fields compile to `{:literal, v}` and `resolve` is effectively free for them, so static-heavy nodes pay almost nothing. `Solid.Caching` is unnecessary given one-time compilation (we also drop `{% render %}`, the main caching beneficiary). The envelope grows with node count per run — acceptable for typical workflow sizes; if very large fan-out workflows appear, we can prune `$node` entries to those statically referenced downstream.

### 7.6 Cost

N/A — no new infrastructure; one Hex dependency. CPU cost is negligible relative to the I/O the nodes themselves perform.

---

## 8. Operations

### 8.1 Deployment

Ships as a code change within the existing app release. Adds the `solid` dependency to `mix.exs`.

### 8.2 Rollout plan

The engine is only active for nodes that opt in via `expr: [...]` and is exercised the moment `Template` is removed and `HttpRequest.V2` is migrated. Because validation is compile-time, a bad rollout surfaces at graph compile, not in production traffic. Migrate node-by-node (§9); there is no traffic-percentage gating needed for a pure compile/run-time library change.

### 8.3 Testing strategy

- **Unit:** `Expr.compile/1` tag selection (literal vs interp vs expr); region-scoped `$`-rewrite (must preserve OData `?$top=5`); type preservation (`{{ $json.n }}` → integer); each custom filter.
- **Integration:** compile a multi-node graph using `$json`, `$node`, `$env`; run it through the compiler + Runic and assert resolved values and the envelope chain.
- **Validator:** `$node` reference checks (existing node, missing node, non-upstream node).
- **Regression:** the `HttpRequest.V2` URL-building scenario end to end.

### 8.4 Ownership & on-call

Owning team: workflows. No new on-call surface; failures are compile-time or contained to a single workflow run.

---

## 9. Migration / Rollback

### 9.1 Migration plan

```mermaid
flowchart LR
    P1[Phase 1<br/>add Solid dep + Expr/Filters modules] --> P2[Phase 2<br/>extend Behaviour: work/3 + gen build/2]
    P2 --> P3[Phase 3<br/>extend Params/Compiler/Validator]
    P3 --> P4[Phase 4<br/>migrate HttpRequest.V2 to work/3 + expr]
    P4 --> P5[Phase 5<br/>migrate remaining catalog nodes; delete Template]
```

- **Phase 1–3** are additive — nothing uses the new path yet; existing nodes keep working through `defoverridable build/2`.
- **Phase 4** migrates the one current `Template.render` call site (`HttpRequest.V2`).
- **Phase 5** converts remaining nodes (currently `:step` ×4, `:join` ×1) and deletes `Workflows.Template`. Any persisted graph JSON using the old `{{ $.path }}` form must be rewritten to `{{ $json.path }}` — a mechanical transform (only the root token changes). If no such graphs exist yet, this is a no-op.

### 9.2 Rollback

Phases 1–3 are reversible (pure additions). Phase 5's `Template` deletion is the only irreversible step; until it lands, reverting is just `git revert` since nodes still have working `build/2`. Hold the `Template` deletion in its own commit so it can be reverted independently if a migrated graph misbehaves.

---

## 10. Risks & Open Questions

### 10.1 Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Solid evaluation API (`Argument.get/4`, `%Object{}`/`%Context{}`) shifts across versions | L | M | We deliberately reuse this *small* API for native-type return (§5.1.1, proven by `fizz`) instead of reimplementing Liquid or introspecting the parsed-AST structure; pin the version, test native-type return per filter |
| Runic alpha API (`context/1`, `put_run_context`, fact shape) changes | M | M | Envelope + context wiring isolated to `Expr`/macro/compiler; pin Runic; small blast radius |
| `$`-rewrite mangles literal text (e.g. OData `$top`) | M | M | Region-scoped rewrite (only inside `{{ }}`/`{% %}`); explicit test |
| ~~Hand-rolled object evaluator diverges from Liquid semantics~~ — **eliminated** | — | — | Resolved: the `{:expr,_}` path calls Solid's own `Argument.get/4` (per `fizz`), so there is no hand-rolled grammar to diverge. Native types and the filter pipeline come from the same engine as the string path |
| Macro-generated `build/2` per kind has a subtle context bug (esp. `:map`/`:reduce`) | M | M | Centralized + heavily tested; escape hatch `build/2` for unusual topologies |
| Accumulating envelope leaks sensitive node output downstream | L | M | By-design and run-scoped; prune to referenced nodes if needed; scope `$env`/`$vars` |

### 10.2 Open questions

- **Default `strict_variables`?** Permissive (`false`, n8n-like, empty on missing) vs strict (raise) — and is it per-field configurable via the spec? Owner: [TBD].
- **`:map`/`:reduce` context shape.** Exact `build_context` mapping for element vs. accumulator, and what `$json` means inside a reduce. Needs the concrete generated clauses written out. Owner: [TBD].
- **`$node` pruning.** Do we keep the full envelope or prune to statically-referenced nodes? Defer until a large workflow forces it. Owner: [TBD].
- **`$items` / multi-item access.** n8n exposes whole-input-list helpers; do we model these now or after single-item works? Owner: [TBD].
- **UUID source for the `uuid` filter** (`Ecto.UUID` vs `:crypto`) and whether non-deterministic filters are even desirable in a re-runnable workflow. Owner: [TBD].
- **Per-field vs per-leaf expressionability** (§5.1.4). Is `expr` a top-level-field whitelist, or do we evaluate any string leaf in a (nested) param like `fizz` does? Forced by the first structured/table field that needs per-cell expressions. Owner: [TBD].
- **Implicit DAG edges from expression dependencies** (§5.1.6). Do `$node["X"]` references *create* graph edges, or merely get *validated* against declared ones? `fizz`'s `dependencies/1` makes the former cheap. Owner: [TBD].
- **How a node declares a field is a predicate** (§5.1.1's `{:predicate,_}`). Likely a `predicate: [atoms]` spec option parallel to `expr:`; confirm and define the truthiness rule. Owner: [TBD].

---

## 11. Appendices

### Appendix A — Glossary

| Term | Meaning |
|---|---|
| **Expression** | A `{{ … }}` fragment in a param field, evaluated at run time against the workflow context. |
| **Envelope** | The fact shape threaded between nodes: `%{"json" => result, "node" => %{name => %{"json" => …}}}`. Enables `$node` references. |
| **Expressionable field** | A param listed in a node's `expr: [...]` option; accepts a literal or an expression and defers its type check to run time. |
| **Compiled value** | The tagged result of `Expr.compile/1`: `{:literal, v}`, `{:interp, template}`, `{:expr, path, template}`, or `{:predicate, template}`. |
| **Per-run context (`_expr`)** | Static, *non-secret* run data (`$vars`, `$env`, `$workflow`, `$execution`) placed in Runic `context`, not in the serialized workflow. Credentials are not here — they resolve via the `requires` path (§7.1). |
| **Pure expression** | A field that is exactly one `{{ … }}`; resolves to a native value rather than a string, via Solid's `Argument.get/4` on the single object (with a literal-path fast walk when there are no filters). |
| **Predicate expression** | A boolean field that is one `{{ … }}` using comparator filters (`{{ $json.total | gt: 100 }}`), coerced to a real boolean. Exists because Liquid has no infix operators. |
| **Filter allowlist** | The curated, validated set of permitted built-in + custom filters; an unknown filter is a compile-time error. |

### Appendix B — References

- Runic — DAG workflow composition for Elixir: https://github.com/zblanco/runic
- Solid — Liquid template engine for Elixir (v1.3.2): https://solid.hexdocs.pm/readme.html
- System being replaced: `lib/hermitscale/workflows/template.ex`
- Current sole call site: `lib/hermitscale/workflows/nodes/http_request/v2.ex`
- Related: node authoring kit, durable Runic workflow system, integration credential resolution (recent commits)
- **Prior art — the `fizz` expression system** (sibling project, shipped). Most lessons in this doc are drawn from it:
  - `lib/fizz/workflows/expressions.ex` — facade, `classify/1`, `resolve/2`, `to_access_plan/2`, `dependencies/1`, `validate/2`, `preview/2`, the single-object native-type evaluator (`render_object_value/2`)
  - `lib/fizz/workflows/expressions/access_plan.ex` — the `Literal | ValueExpression | TemplateExpression | PredicateExpression | CredentialRef` representation
  - `lib/fizz/workflows/expressions/filters.ex` — the custom filter catalog (incl. predicate comparators)
  - `lib/fizz/workflows/compiler/expression_compiler.ex` — compile-time pass; `lib/fizz/workflows/runtime/config_resolver.ex` — deep recursive resolution
  - `docs/plans/expression-design.md`, `docs/spec/decisions/expression-filter-catalog.md` — fizz's own design + filter-allowlist decision
  - Scars worth reading: `TODO.md:169-171` (fixed-vs-expression leakiness) and the deferred rename-rewrite / evaluated-config-in-client-metadata notes
