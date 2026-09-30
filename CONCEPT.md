# Agent Forwarder — concept

Developer notes covering how and why the integration works the way it does. This is not end-user
documentation; see [package/agent_fwdr/docs/README.md](package/agent_fwdr/docs/README.md) for that.

## Reason

Not every Elastic Agent can reach Elasticsearch. Agents land in DMZs, air-gapped segments, remote
sites, and networks whose egress policy permits exactly one hop to exactly one host. Those agents
still need to ship data.

**First option: proxy.** If restricted agents can reach Fleet Server and Elasticsearch through an
HTTP(S) proxy, use that — it needs no extra component. Forwarding the Fleet and Elasticsearch API
through a proxy is a *conduit*, not a diode: the restricted agents have full API access through the
proxy. That is acceptable in many environments, but not in all.

**What rules the proxy out.** Two scenarios:

- A *local Fleet Server* requirement: agents must receive configuration without touching the main
  cluster at all. A Fleet Server is deployed inside the segment with the same host acting as the
  segment's single egress point.
- A *diode requirement*: the segment must have no access to the Elasticsearch or Fleet Server API.
  A proxy forwarding those APIs cannot satisfy this, because forwarding the API *is* access to the
  API. The diode property comes from the **protocol break**: restricted agents speak only the
  one-way lumberjack shipping protocol and never initiate an API connection. The forwarder re-
  originates the data on the far side. Note that the egress host itself — running Fleet Server and
  the forwarder — does have API access; the diode applies to every other agent in the segment.

**If you already run Logstash for other inputs** (SNMP, JDBC, …), using it as the relay is the
obvious choice. Logstash provides the same diode property. This integration exists for the case
where the relay would be Logstash's *only* job — a JVM, a second product, and its own upgrade
cycle for pure plumbing.

## Goal

Let a Fleet-managed Elastic Agent be that relay.

A downstream agent points its existing **Logstash output** at a forwarder agent instead of at a
Logstash instance. The forwarder receives the events and passes them on to Elasticsearch — no JVM,
no second product, no separate config language. It runs on the *same agent* that hosts the local
Fleet Server: one agent, one egress host, both planes.

The bar for success is **transparency**: a forwarded document should be indistinguishable from one
the downstream agent would have sent directly. Same data stream, same ingest pipeline, same field
structure, same event timestamp. The only difference is an added breadcrumb recording that the hop
happened, so an operator can tell which forwarder handled a given event.

## The lumberjack input

An Elastic Agent's Logstash output emits the **Lumberjack** protocol. Agentbeat (the Beats
executable embedded in Elastic Agent) ships a **`lumberjack` input** that receives it. The
forwarder wraps that input — the wire protocol needs no translation.

This input is **undocumented and marked Beta**. It does not appear in Fleet's published list of
supported inputs and has no documentation page. The integration deliberately depends on it, which is
a tested and re-testable risk — verify it still functions after stack upgrades.

## Why the field inversion must happen in Elasticsearch

A natural first instinct is to rewrite the document in the agent, using processors, before it is
indexed. This cannot work:

- Fleet bakes a fixed destination index into the agent's API key and configuration before any
  processor runs. Rewriting `data_stream.*` in a processor does not change where the document lands.
- `data_stream.*` fields are `constant_keyword`, so writing a foreign dataset value into the
  forwarder's own data stream gets the document rejected outright.

Changing where a document lands is something only Elasticsearch can do, via the `reroute` ingest
processor. All meaningful transformation therefore happens in the ingest pipeline, not the agent.

## Ingest pipeline: field inversion

The `lumberjack` input does not hand back the original document — it nests the entire received
event under a `lumberjack` key, and the receiving agent stamps its own identity at the document
root. What lands in Elasticsearch looks like this:

```
agent.*          ← forwarder's own identity
elastic_agent.*  ← forwarder's own identity
host.*           ← forwarder's own host
event.*          ← forwarder's own input event
data_stream.*    ← forwarder's own data stream
@timestamp       ← receipt time at the forwarder
source.address   ← connecting client IP
tls.client.subject ← client cert CN (if mTLS)
lumberjack.@timestamp       ← original event timestamp
lumberjack.agent.id         ← original agent id
lumberjack.data_stream.*    ← original data stream target
lumberjack.<anything>       ← rest of the original event
```

The pipeline inverts this in two Painless scripts:

**`park_forwarder_fields`** — iterates every key at the document root. Anything that is not `_*`
or `lumberjack` is moved to `fleet.forwarder.*`. `@timestamp` (receipt time) is moved to
`fleet.forwarder.received_at`. The `lumberjack` key is left untouched.

**`promote_lumberjack`** — promotes every key inside `lumberjack.*` to the document root, removing
the `lumberjack` key entirely. `@metadata` from Lumberjack goes to `fleet.forwarder.metadata` (not
the root, since `_meta` is not an indexable field). If the document already has a `fleet.forwarder`
from a prior hop, it is nested under `fleet.forwarder.upstream` before the current forwarder's
breadcrumb is attached — so multi-hop chains are preserved.

After promotion the document looks exactly as the downstream agent would have sent it directly, plus
`fleet.forwarder.*`.

The remaining processors in the pipeline:

- Fall back `@timestamp` to receipt time if the payload carried none.
- Re-parse `@timestamp` to normalise ISO8601 strings coming out of Painless.
- Set `event.ingested` to ingest time.
- Default `data_stream.type`, `data_stream.dataset`, and `data_stream.namespace` for payloads that
  carry no `data_stream.*` (e.g. non-Fleet shippers). These stay in `agent_fwdr.forwarded`. The
  namespace default is **two stages**: `default_ds_namespace` first copies from
  `fleet.forwarder.data_stream.namespace` (inheriting the forwarder's own namespace), then
  `fallback_ds_namespace` sets the literal `default` if the copy left the field still null. This
  is what determines where a non-Fleet shipper's events actually land.
- Sync `event.dataset` from `data_stream.dataset` if absent.

Every processor carries a `tag`, so the `on_failure` handler can name the culprit in
`error.message`. The handler also sets `event.kind: pipeline_error`. A document that fails to
unwrap ends up in `agent_fwdr.forwarded` with these two fields set — searching for
`event.kind: pipeline_error` is the first step for debugging an unwrap failure.

**Note on `tags` and `fleet.forwarder.tags`.** The `park_forwarder_fields` script moves the
`tags` field added by the lumberjack input (defaulting to `["forwarded"]`) to
`fleet.forwarder.tags`, preventing it from colliding with the forwarded event's own tags, which are
promoted out of `lumberjack` at the same time.

## Cross-type routing: the key trick

The standard `reroute` processor can change a document's `dataset` and `namespace` but has **no
`type` configuration option**. Naively this would mean a metrics event arriving on a logs-type data
stream could never be rerouted to `metrics-*-*`.

The trick: **the `reroute` processor computes its target index as
`{data_stream.type}-{data_stream.dataset}-{data_stream.namespace}` using the document's own
`data_stream.type` field**. This is undocumented behaviour that was tested and confirmed to work.

Because the `promote_lumberjack` script lifts `lumberjack.data_stream.type` to `data_stream.type`
before any routing processor runs, a metrics event arrives with `data_stream.type: metrics` already
set at the root. When the reroute processor fires, it uses that value and targets
`metrics-{dataset}-{namespace}` — the correct destination.

The pipeline's `default_ds_type` processor only fires when `data_stream.type` is null (payloads
from non-Fleet shippers), so it never overwrites a legitimate type from the payload.

## Routing rules and Fleet compilation

`routing_rules.yml` defines a single rule keyed by `source_dataset: agent_fwdr.forwarded` (which
must match the data stream's `dataset:` field in `manifest.yml` exactly). It targets:

```yaml
    - target_dataset: '{{{data_stream.dataset}}}'
      namespace:
        - '{{{data_stream.namespace}}}'
        - default
```

The `namespace` value is an ordered fallback list: the mustache expression is tried first; if it
resolves empty, `default` is used.

Fleet compiles this at policy build time into a `reroute` processor that is **appended to the end
of the default ingest pipeline**. By the time that processor runs, the pipeline has already promoted
the payload and set the correct `data_stream.*` values. The reroute then targets the right index,
including the correct type via the mechanism above.

Documents whose payload carries no dataset (non-Fleet shippers, or payloads that fail to unwrap)
fall through the reroute condition and stay in `agent_fwdr.forwarded`, where dynamic mapping
accepts them.

## Cross-type write permissions

Fleet derives an agent's output API key permissions from the **enabled** data streams in its
policy. The `forwarded` data stream (type `logs`) contributes `logs-*-*` automatically via
`dynamic_dataset: true` + `dynamic_namespace: true`. Cross-type rerouting — metrics or traces
events arriving on the lumberjack listener — also requires `metrics-*-*` and `traces-*-*` in the
API key, but a single `logs`-type data stream does not grant them. `synthetics-*-*` follows the
same pattern (it is listed in the user doc and in Fleet's validation regex) but is not covered by
any current test.

The mechanism: Fleet's `additional_datastreams_permissions` field on a package policy appends
arbitrary index patterns to the API key role descriptor. In the Fleet UI this appears as the
**"Add a reroute processor permission"** combobox under *Advanced options* on the integration
policy page. Users type in e.g. `metrics-*-*` and `traces-*-*` and those grants are included in
the next key re-issue. Fleet validates entries against `/^(logs|metrics|traces|synthetics|profiles)-(.+)$/`.

This is a required manual step documented in the integration README. The failure mode if omitted is
silent: the reroute processor sets `_index` to the target data stream, the bulk request returns 403
for that document, and the agent drops it after retries. The event does not fall back to
`agent_fwdr.forwarded`. **This 403 happens post-pipeline, after the reroute processor fires, so
no ingest `on_failure` handler can catch it.** The troubleshooting section covers this.

**On `fleet.forwarder.*` mapping.** `fields/fields.yml` notes that `fleet.forwarder.*` dynamic-maps
consistently across indices, because all sub-field values have the same types everywhere. That is
true, but dynamic mapping produces per-index inferred types, which risks conflicting mappings across
thousands of target indices and consumes more field-mapping budget. The user doc recommends mapping
`fleet.forwarder` as `flattened` in the `logs@custom`, `metrics@custom`, and `traces@custom`
component templates — that is the recommended hardening. It costs 1 field-mapping slot instead of
~25 and eliminates the conflicting-types risk.

### Why not companion data streams?

An earlier design (v0.5.0) included two companion data streams — `forwarded_metrics` (type
`metrics`) and `forwarded_traces` (type `traces`) — whose sole purpose was to contribute those
grants automatically, without any user action. Each was a valid lumberjack stream that listened on
a loopback-only address (`127.0.0.2:5044`, `127.0.0.3:5044`) so it could not receive external
connections while still producing a non-empty input config.

The loopback trick was necessary because **elastic-otel-collector**, the OpenTelemetry-based agent
runner used by Elastic Agent 9.x, creates one `filebeatreceiver` component per lumberjack stream
in the policy. A receiver whose rendered config is empty or contains only `enabled: false` (and no
valid input definition) causes Filebeat to error:

```
no modules or inputs enabled and configuration reloading disabled
```

This crashes the entire `lumberjack-default` component — taking the real `0.0.0.0:5044` listener
with it. `enabled: false` is therefore not a safe option with the current agent architecture.

v0.6.0 removes the companion data streams and documents the manual permission step instead. Two
upstream changes would eliminate the manual step: (1) Fleet / package-spec support for declaring
`additional_datastreams_permissions` defaults in a package manifest so they are pre-populated when
a policy is created; (2) elastic-otel-collector handling `enabled: false` on lumberjack streams
gracefully (skipping the receiver rather than crashing). Until then, the manual step remains.

## Boundaries

- **We own only the forwarder's own pipeline.** The sending integration's pipeline is never
  modified, never bypassed, and never needs to know a forwarder was involved.
- **Targets are assumed present.** The forwarder and the integrations it relays for are managed by
  the same Fleet, so a relayed integration's index templates and pipelines are already installed.
  The forwarder does not prepare, declare, or know about its destinations.
- **Multi-hop chaining works.** Each hop's forwarder identity is nested under `fleet.forwarder.upstream`,
  preserving the full chain. The integration does not explicitly limit hop count.
- **Document IDs are not preserved.** The upstream `_id` is kept as `fleet.forwarder.metadata._id`
  for correlation, but is not reapplied as the document ID. Integrations that rely on it for
  deduplication lose that property across the hop.

## Build and repository mechanics

### Generated documentation

`package/agent_fwdr/_dev/build/docs/README.md` is the **template**; `package/agent_fwdr/docs/README.md`
is the **generated output**. The template ends with `{{fields "forwarded"}}`, which `elastic-package build`
expands into the exported-fields table and writes back to the source tree.

**Edit only the template.** `elastic-package lint` re-renders the template and diffs the result
against the committed output file; a mismatch fails lint. `elastic-package build` writes the output
file; do both and commit both files.

Trap: **any change to `fields/*.yml`** — adding a field, changing a description — re-renders the
field table, silently invalidating the committed `docs/README.md`. If only the field file is
committed and `docs/README.md` is not rebuilt, lint breaks on the next run.

### `.gitignore` anchoring

`.gitignore` contains `/build/` with a leading slash. The slash anchors the pattern to the repo
root, so it only ignores the top-level `build/` directory that `elastic-package build` creates for
its output zip.

**Do not change it to `build/` (unanchored).** An unanchored pattern matches at any depth, which
would also ignore `package/agent_fwdr/_dev/build/`. That directory holds two files that the package
cannot be built or linted without:

- `_dev/build/build.yml` — ECS dependency pin
- `_dev/build/docs/README.md` — the only copy of the user doc template

The failure is delayed and silent: `git` keeps tracking already-tracked files even when they match a
newly-added ignore rule. The breakage surfaces on a fresh clone, where those files are absent. At
that point `elastic-package lint` sees no `_dev/build/docs/` directory, treats the README as static,
and **passes without rendering it** — so the docs are simply no longer generated, with no error.

### Build directory resolution

`elastic-package` resolves its output directory by walking **up from cwd** for the first ancestor
directory named `build`. If none exists, it falls back to `<repoRoot>/build` (where `<repoRoot>` is
found via the `.git` directory). Two developers with different filesystem layouts get different output
paths for the same command.

Consequence for the release workflow: `release.yml` globs both `${GITHUB_WORKSPACE}/build/packages`
and `$HOME/build/packages` to handle both cases. On a runner with no `~/build`, elastic-package
uses the repo-root fallback and the zip lands at `${GITHUB_WORKSPACE}/build/packages`.

`elastic-package build` also requires being run inside a git repository and produces the zip by
default (`--zip` defaults to true, so no flag is needed).

### ECS pin (`_dev/build/build.yml`)

```yaml
dependencies:
  ecs:
    reference: "git@v8.17.0"
```

This pin is what makes `external: ecs` in `data_stream/forwarded/fields/ecs.yml` resolve. It
causes elastic-package to clone/cache the ECS repo at that tag (needs network on first use, cached
under `~/.elastic-package`). Air-gapped or first-run-offline builds fail here.

The pin is mirrored by hand as `"ecs": {"version": "8.17.0"}` in every event in `tests/data/` and
in the forwarder identity generated by `tests/update_data.sh`. Bump the pin without bumping the
fixtures and they drift silently.

Bumping the pin also changes the ECS field descriptions injected into the generated field table,
producing a `docs/README.md` diff. Rebuild after any ECS bump.

### Changelog discipline

`elastic-package lint` requires the top entry in `changelog.yml` to have the same `version:` as
`manifest.yml`, and entries must be in newest-first order. `type` is a closed enum:
`enhancement`, `bugfix`, `breaking-change`.

### LICENSE.txt

The package carries its own `LICENSE.txt` (Elastic-2.0). This is required because the package lives
outside the integrations monorepo; `elastic-package build` looks for a repository license
(`findRepositoryLicensePath`).

## Package configuration decisions

These decisions currently live only as in-file comments; collected here so they are discoverable.

**`dynamic: true` on the index template** (`data_stream/forwarded/manifest.yml`). A relay cannot
declare the fields of the payloads it carries. Documents normally pass straight through to their
real data stream, but any that cannot be rerouted are parked here and must be indexable whatever
they contain. Dynamic mapping is the only safe default.

**`event.dataset` is plain `keyword`, not `constant_keyword`** (`fields/base-fields.yml`). Pass-
through documents carry the *destination* dataset, not the forwarder's own dataset. Overriding the
base field to plain keyword is intentional and unusual.

**`publisher_pipeline.disable_host: true`** (`lumberjack.yml.hbs`). Libbeat re-adds `host.name` to
every document after processors run. Setting this flag suppresses it at the source, so the
forwarded event's own `host.*` fields are not overwritten.

**The `ssl_certificate` field gates the entire `ssl:` block.** `lumberjack.yml.hbs` wraps the
whole `ssl:` section in `{{#if ssl_certificate}}`. An admin who fills in only **Trusted client
certificate authorities** — perhaps intending to verify connecting clients — gets a plaintext
listener, silently. The server certificate and key must be set for TLS to be enabled at all.

**`{{ssl_advanced}}` is injected raw inside the `ssl:` mapping.** The manifest tells users to
indent each option by two spaces, so the raw YAML aligns under the `ssl:` key. Correctness depends
on user-supplied indentation — a YAML footgun to be aware of.

**`{{custom}}` is appended last.** It can override any setting above it. Stated in the manifest
var description; noted here for completeness.

**`keepalive` doubles as the connection read/write timeout** in current Filebeat builds. The
separate `timeout` option is inoperative; that is why it is not exposed as a manifest variable.

**`secret: true` on `ssl_key`** requires Fleet Server 8.12.0 or later.

## Testing

The lumberjack input is undocumented and marked Beta. Verifying it still works after stack upgrades
is the main ongoing testing obligation.

### Run order

`elastic-package test` runs test types in alphabetical order: asset → pipeline → policy →
**script** → static → **system**. The repo has no `_dev/test/policy/` directory, so policy tests
contribute nothing; asset and static tests run with no fixtures. The two meaningful suites are
`pipeline` and `system` (both OOTB) and `script` (requires a running stack).

```bash
elastic-package stack up -d           # start the stack (once per dev session)
cd package/agent_fwdr
elastic-package test -v               # all test types
```

### The 4 canonical events

One set of 4 events drives the pipeline test, the system test, and the script test.
The master fixtures live in `tests/data/` at the repository root; `tests/update_data.sh` derives
the per-suite artefacts from them.

| # | event | target data stream | proves |
|---|---|---|---|
| 1 | syslog line | `logs-system.syslog-default` | same-type reroute; `system.syslog` pipeline ran (grok) |
| 2 | `system.cpu` metric | `metrics-system.cpu-default` | **cross-type** logs→metrics reroute |
| 3 | APM transaction | `traces-apm-default` | **cross-type** logs→traces reroute |
| 4 | probe | stays in `logs-agent_fwdr.forwarded-<ns>` | reroute correctly declines |

The probe (event 4) is what `elastic-package test system` asserts against via `assert.hit_count: 1`.
Events 1–3 are rerouted out of the forwarder's own data stream and verified by the script test.

**Two fixture representations exist because the two suites consume different shapes:**

- `_dev/deploy/docker/sample_logs/forwarded-logs.ndjson` — the *raw downstream-agent* events, as
  the `stream` container sends them over lumberjack. Consumed by the system test and by the script
  test (which stamps `@timestamp` at runtime before sending — see below).

- `data_stream/forwarded/_dev/test/pipeline/test-forwarded.json` — the *lumberjack-wrapped* form:
  forwarder identity at the root, original event nested under `lumberjack`. This is what the
  forwarder's input produces and what the ingest pipeline processes. Static timestamps are fine
  here — `_ingest/pipeline/_simulate` is not subject to TSDB write-window constraints.

Easy confusion: `test-forwarded.json` is fed to `_ingest/pipeline/_simulate` and never reaches the
agent or any index. `forwarded-logs.ndjson` is what the agent actually receives. They are not the
same shape and not the same file.

### Master fixtures and `tests/update_data.sh`

`tests/data/` holds one NDJSON file per downstream integration, hand-maintained:

```
tests/data/system.ndjson      # system.syslog event + system.cpu event
tests/data/apm.ndjson         # apm transaction event
tests/data/agent_fwdr.ndjson  # probe event (not rerouted)
```

These are clean raw events — fields that fail `agent_fwdr` field validation
(`system.cpu.*`, `metricset`, `transaction.type`, `transaction.duration`) are absent at rest;
no per-run stripping is needed.

`tests/update_data.sh` reads the masters and writes two committed artefacts:

1. `_dev/deploy/docker/sample_logs/forwarded-logs.ndjson` — raw concatenation in canonical order
2. `data_stream/forwarded/_dev/test/pipeline/test-forwarded.json` — lumberjack-wrapped, plus the
   multi-hop `fleet.forwarder.upstream` edge case

Both outputs are committed and self-contained. No test suite depends on the generator having
been run recently. Run it after editing `tests/data/*.ndjson`:

```bash
./tests/update_data.sh
cd package/agent_fwdr && elastic-package test pipeline -g
# Review the diff before committing
```

**The multi-hop edge case is a hand-written literal inside `update_data.sh`**, not derived from
`tests/data/`. "Edit the masters and regenerate" does not cover it; edit the generator script
directly.

### `data_stream/forwarded/_dev/test/scripts/reroute.txtar`

A self-contained integration test. Does everything in one run:

1. **Installs downstream integrations** (`system`, `apm`) — via Fleet EPM API, resolving the
   latest version. Necessary so index templates and ingest pipelines exist before rerouted
   documents land. (The script-test primitive `install_package_from_registry` requires a literal
   version; this is EP gap (a) recorded in the txtar header comment.)

2. **Deploys its own agent** — `install_agent` + `add_package_policy` (lumberjack, port 5044).

3. **Sets extra permissions** — `elastic-package` has no support for `additional_datastreams_permissions`
   (absent from the `PackagePolicy` struct in `internal/kibana/policies.go`, from `add_package_policy`'s
   config schema, and from the system test config — EP gap (d)). A raw Fleet API PUT is the only
   route; the txtar sets `additional_datastreams_permissions: ["metrics-*-*", "traces-*-*"]` on the
   package policy so Fleet grants those index patterns in the output API key alongside the automatic
   `logs-*-*`.

4. **Confirms the API key** — there are **two** synchronisation barriers in `assert-api-key.sh`,
   not one:
   - **Policy revision barrier**: `set-extra-permissions.sh` records the post-PUT agent policy
     revision into `expected-policy-revision.txt`. `assert-api-key.sh` polls until the agent has
     applied that revision. Policy revision match means the agent has finished reloading its inputs
     and the lumberjack listener is ready.
   - **API key grant barrier**: polls `GET /_security/api_key` until all three grants (`logs-*-*`,
     `metrics-*-*`, `traces-*-*`) appear in the role descriptor. Only then are events sent.

5. **Stamps timestamps** — rewrites `@timestamp` (and the syslog message date) in the `$WORK`
   copy of the fixture to now. Required because:
   - `metrics-system.cpu-default` uses `index.mode=time_series`; the write window is ~now ± 2h.
   - `system.syslog` grok overwrites `@timestamp` from the message date — a past date leaves the
     document invisible in Kibana's default range. (This caused a false "nothing arrived" diagnosis
     before the fix.)
   The source tree is never mutated.

   The stamp also **rewrites the probe's `data_stream.namespace`** from the master fixture value
   (`default`) to the test-run namespace extracted from `$FWD_DS`. `data_stream.namespace` is a
   `constant_keyword` in the backing index, set at creation to the run's namespace. A mismatch is
   rejected **silently** — no error message, just the document disappearing. See the fixture
   contract section below.

6. **Sends events** — `docker_up` + `docker_signal SIGHUP` + `docker_wait_exit`.

7. **Asserts arrival** — probe via `get_docs`; the three rerouted targets via `exec curl` polling
   ES `_search` with a `term` filter on `fleet.forwarder.agent.id`. Filtering on the agent id
   replaces the old `event.ingested > now − 2h` recency window: each run has a distinct Fleet
   agent id, so documents from previous runs on a reused stack cannot cause a false pass.

8. **Tears down** — `docker_down`, `remove_package_policy`, `uninstall_agent`. The package and
   the downstream integrations (`system`, `apm`) are **deliberately left installed**, and the
   rerouted events are deliberately left in their target indices (`logs-system.syslog-default`,
   `metrics-system.cpu-default`, `traces-apm-default`). This is so you can inspect the results in
   Kibana after the run. Consequence: repeated runs accumulate documents in those shared indices,
   which is exactly why assertions filter on `fleet.forwarder.agent.id` rather than by recency.

### Test harness reference

#### txtar guards and environment

The script test file begins with guards:

```
[!external_stack] skip 'requires an external stack: elastic-package stack up -d'
[!exec:jq] skip 'requires jq'
[!exec:curl] skip 'requires curl'
```

`[!external_stack]` is a built-in txtar condition (`internal/testrunner/script/script.go`). Without
the `skip` directives, a missing prerequisite causes a hard failure rather than a clean skip.

`elastic-package` injects these environment variables into every shell member:

```
PROFILE                   current stack profile name
CONFIG_ROOT               ~/.elastic-package (or override)
CONFIG_PROFILES           $CONFIG_ROOT/profiles
PACKAGE_NAME              agent_fwdr
PACKAGE_BASE              package/agent_fwdr (relative to repo root)
PACKAGE_ROOT              absolute path to package/agent_fwdr
CURRENT_VERSION           current package version (from manifest.yml)
STACK_VERSION             running stack version
LATEST_EPR_VERSION        …
ECS_BASE_SCHEMA_URL       …
PACKAGE_REGISTRY_BASE_URL …
```

#### `use_stack` and credential preambles

`use_stack` writes a JSON object (Kibana host, Elasticsearch host, credentials) to **stdout** and
sets no environment variables. Hence the idiom:

```sh
use_stack -profile ${CONFIG_PROFILES}/${PROFILE}
cp stdout stack-config.json
```

Every embedded shell member reads credentials from that file with `jq`. This is why every member
has a near-identical four-line preamble extracting `KB_URL`, `ES_URL`, `ES_USER`, `ES_PASS`.

#### Capture-variable convention

`add_package_policy`, `install_agent`, and similar primitives can write their output into named
variables. The variable *name* is passed as a trailing argument:

```
install_agent -profile ${CONFIG_PROFILES}/${PROFILE} AGENT_CONTAINER AGENT_NETWORK
```

`AGENT_CONTAINER` and `AGENT_NETWORK` are the names of variables to be filled in (accessible as
`${AGENT_CONTAINER}` and `${AGENT_NETWORK}` in subsequent lines), not literal values. This is the
single most confusing line in the file for a newcomer. Note that `AGENT_CONTAINER` is captured but
never used in this script.

#### `$WORK` staging

`docker_up` reads from `$WORK/<service-dir>/docker-compose.yml`. The committed deploy assets must
be copied into `$WORK` first:

```sh
mkdir agent-fwdr-logs
exec cp -R ${PACKAGE_ROOT}/_dev/deploy/docker/. agent-fwdr-logs/
```

The directory name (`agent-fwdr-logs`) must equal the compose **service** name, because
`docker_signal`, `docker_wait_exit`, and `docker_down` use it as the target identifier.

#### The `stream` container contract

The system test and the script test both use the `stream` container
(`docker.elastic.co/observability/stream`). Three env vars form a three-way contract across the
compose file, the system test config, and the txtar:

- **`STREAM_LUMBERJACK_PARSE_JSON=true`** — load-bearing. Without it, each NDJSON line is shipped
  as a raw `message` string rather than as a structured event, so no document has `data_stream.*`
  to promote and everything parks in `agent_fwdr.forwarded`.
- **`STREAM_ADDR=tcp://elastic-agent:5044`** — the hostname `elastic-agent` is an elastic-package
  internal constant (`dockerTestAgentServiceName = "elastic-agent"` in `internal/agentdeployer/agent.go`).
  If that constant is ever renamed, both tests break with "connection refused" and no hint about
  the cause.
- **`STREAM_START_SIGNAL=SIGHUP`** — must match `service_notify_signal: SIGHUP` in
  `_dev/test/system/test-lumberjack-config.yml` and `docker_signal agent-fwdr-logs SIGHUP` in the
  txtar. Change one of the three, and the sender waits forever.

#### System test config

`_dev/test/system/test-lumberjack-config.yml`:

- **Filename convention**: `test-<name>-config.yml`. The `<name>` becomes the test case name in
  elastic-package output.
- **`service:`** must equal the compose service name in `_dev/deploy/docker/`.
- **`data_stream.vars`** overrides the manifest defaults. `listen_address: '0.0.0.0'` is required;
  the lumberjack input's own default is `localhost`, which accepts no remote connections.
- **`fields_present` assertions**: `fleet.forwarder.agent.id` proves `park_forwarder_fields` ran
  (the forwarder's identity moved to the breadcrumb); `tags` proves the probe's own tags survived
  promotion.
- **The runner generates a random namespace** per run — the `<ns>` in
  `logs-agent_fwdr.forwarded-<ns>`. This is the origin of the constant_keyword namespace issue
  described in the fixture contract below.

#### Pipeline test

`elastic-package test pipeline` calls `_ingest/pipeline/_simulate` only. No stack interaction
beyond the simulate API; static timestamps are fine.

`test-forwarded.json-config.yml` contains:

```yaml
dynamic_fields:
  event.ingested: ".*"
```

This wildcard is **mandatory**. The pipeline sets `event.ingested` from `{{{_ingest.timestamp}}}`,
which differs on every run. Without the wildcard, the golden file could never match and the test
fails permanently. Any future processor that produces a run-time-varying field must add an entry
here.

**Critical limitation: the pipeline test cannot exercise routing at all.** Fleet compiles
`routing_rules.yml` into a `reroute` processor that is appended to the end of the ingest pipeline
at *policy install time*. `_simulate` runs against `default.yml` only and never sees that processor.
The central trick of the design — cross-type reroute via `data_stream.type` — has **zero**
pipeline-test coverage. `reroute.txtar` is its only guard.

#### Fleet API workarounds in the script test

`set-extra-permissions.sh` must use a raw Fleet API PUT because elastic-package does not support
`additional_datastreams_permissions` anywhere. Several gotchas apply:

- **GET-mutate-PUT with no partial update.** There is no PATCH endpoint; the full policy body must
  be sent. Fleet **rejects** the read-only fields it returned in the GET (`id`, `revision`,
  `created_at`, …), so they must be deleted with `jq`'s `del(…)`.
- `--data-binary @policy-update.json`, not `-d`. Large JSON with embedded YAML can be garbled by
  `-d`.
- `kbn-xsrf: true` on every Kibana API call (Kibana's CSRF protection).
- `-k` because the stack uses a self-signed certificate.
- **Version compat shim**: `(.policy_ids // [.policy_id])[0]` — Fleet changed the field name
  between stack versions.
- The Fleet agents API returns `.items` (not `.list`) — a trap if copying from older examples.
- `install-downstream.sh` posts `{"force":true}` and checks `._meta` in the response to detect
  registry rejection.

The four elastic-package gaps recorded in the txtar header (gaps (a)–(d)) are referenced by letter
from inside the shell members. If CONCEPT.md is the authoritative account, the gaps are:

- **(a)**: `install_package_from_registry` requires a literal version string, not a "latest" alias
  — no built-in way to resolve current version before calling it.
- **(b)**: (recorded in the txtar; consult the header for the current text)
- **(c)**: `exec curl` for ES search assertions — no built-in equivalent with polling.
- **(d)**: `additional_datastreams_permissions` is absent from the `PackagePolicy` struct
  (`internal/kibana/policies.go`), from `add_package_policy`'s config schema
  (`internal/testrunner/script/data_stream.go`), and from the system test config
  (`internal/testrunner/runners/system/test_config.go`). A raw Fleet API PUT is the only route.

### OOTB scope

`elastic-package test pipeline` and `elastic-package test system` run with no preparation.

- **Pipeline**: calls `_ingest/pipeline/_simulate` only; no stack interaction beyond the simulate
  API. Static timestamps are fine.
- **System**: sends the 4-event ndjson over lumberjack and asserts the probe (event 4) lands in
  `logs-agent_fwdr.forwarded-<ns>`. Events 1–3 reroute to shared target data streams; the system
  test makes no assertion on them. `elastic-package test system` cannot set
  `additional_datastreams_permissions`, so the system-test agent holds only `logs-*-*`. The cpu
  (metrics) and APM (traces) events will be rejected on reroute with 403 — this is expected and
  does not fail the test. `reroute.txtar` is the only test that exercises cross-type routing end
  to end.

### Debugging

```bash
# Iterate on the script test, keeping $WORK for inspection:
cd package/agent_fwdr
elastic-package test script --work --verbose-scripts

# Keep the system-test agent alive for post-mortem:
elastic-package test system --defer-cleanup 30m

# Inspect all forwarded documents in Kibana (ES|QL):
FROM logs-*, metrics-*, traces-*
| WHERE `data_stream.dataset` != "elastic_agent*"
  AND `data_stream.dataset` != "fleet_server*"
  AND `fleet.forwarder.agent.id` IS NOT NULL
```

## Fixture contract

The master fixtures in `tests/data/` and the artefacts derived from them carry hidden invariants
that other files depend on silently. Changing a fixture without understanding these will cause subtle
failures, often with no error message.

| Invariant | Depended on by | Failure mode if broken |
|---|---|---|
| Syslog `message` contains literal `"Sep 24 10:15:01"` | `stamp-fixture.sh` `gsub` | Stamp silently no-ops; document lands with a past timestamp, invisible in Kibana's default range |
| Probe `tags: ["system-test-probe"]` | `reroute.txtar` jq assertion; `fields_present: tags` in system test config | Assertion fails or `tags` field not found |
| Probe `data_stream.dataset == "agent_fwdr.forwarded"` | routing-rule `if`; namespace rewrite in `stamp-fixture.sh`; `hit_count: 1` | Probe rerouted away; system test never finds it |
| Syslog message contains `sshd[4321]`, `myserver`, `10.42.0.9` | `reroute.txtar` asserts grok-derived `process.name`, `process.pid`, `host.hostname` | Assertion fails, even though the document arrived |
| `ecs.version: "8.17.0"` in all events | Mirrors `_dev/build/build.yml` ECS pin | Field table mismatch; lint fails after next `elastic-package build` |
| File order: `system.ndjson`, `apm.ndjson`, `agent_fwdr.ndjson`; exactly 2+1+1 lines | `update_data.sh` uses `--slurpfile` with index 0 and 1 into `system.ndjson` | Wrong events get the lumberjack-wrap treatment |
| `system.ndjson` has syslog first, cpu second | Same | `$syslog[0]` / `$syslog[1]` references break silently |
| Absence of `system.cpu.*`, `metricset`, `transaction.type`, `transaction.duration` | `agent_fwdr` field validation in the pipeline test | Pipeline test fails: unknown field |

**Probe namespace rewrite.** The probe's master fixture carries `data_stream.namespace: default`, but the test-run backing index has a random namespace. `data_stream.namespace` is a `constant_keyword` whose value is fixed at index creation. A mismatch is rejected **silently** — the document disappears with no error. `stamp-fixture.sh` extracts `TEST_NS` from `$FWD_DS` with `sed 's/.*-//'` and rewrites the probe's namespace. A namespace containing `-` would confuse this extraction.

**The multi-hop edge case is not in `tests/data/`.** It is a hand-written literal inside `update_data.sh` (~lines 122–151): an `nginx.access` event carrying a `hop1` `fleet.forwarder` breadcrumb. Editing the masters does not regenerate it; edit the generator directly.

## Failure-mode catalogue

Silent failures that are hard to diagnose without this list:

**403 on a missing type grant.** The reroute processor fires and sets `_index`; the ES bulk API
returns 403 for that document; the agent retries and eventually drops it. The event does not fall
back to `agent_fwdr.forwarded`. No `on_failure` handler can catch this — the 403 happens
post-pipeline, after ingest is complete. Check the agent logs for `security_exception` and verify
the grant in the API key (`GET /_security/api_key?id=<id>`).

**`constant_keyword` namespace mismatch.** A document whose `data_stream.namespace` mismatches the
backing index's `constant_keyword` value is silently rejected. Manifests as: event never arrives,
no error logged. Most likely to occur in the script test when the probe's namespace is not stamped.

**TSDB write window.** `metrics-system.cpu-default` uses `index.mode: time_series`. Documents with
`@timestamp` older than ~2 hours are rejected. The script test stamps timestamps at runtime to
avoid this; the system test's static timestamps can silently lose the cpu event.

**Plaintext listener when only the CA is set.** `lumberjack.yml.hbs` wraps the entire `ssl:` block
in `{{#if ssl_certificate}}`. Configuring only **Trusted client certificate authorities** renders no
`ssl:` block and the listener runs plaintext. No warning.

**Grok-overwritten timestamp outside Kibana's default range.** The `system.syslog` pipeline rewrites
`@timestamp` from the syslog message date. A fixture with a past date lands invisibly in Kibana's
default time range, producing a false "nothing arrived" diagnosis. The script test stamps the
syslog message date at runtime.

## Release and CI

`.github/workflows/release.yml` builds the package and attaches the zip to a GitHub release.
Currently it is **disabled**: `on:` is set to `workflow_dispatch` only, with the tag trigger
commented out. Enable by uncommenting the `on.push.tags` block and commenting out the
`workflow_dispatch` block.

**No lint or test CI exists.** Nothing runs `elastic-package lint`, `elastic-package test`, or any
check on push or pull request. A stale `docs/README.md`, a stale pipeline golden file, or a
`changelog.yml`/`manifest.yml` version mismatch surfaces only when someone runs those commands
locally — or when the release job's `elastic-package build` fails at release time.

**elastic-package is installed unpinned** (latest release at workflow run time). A breaking
elastic-package change breaks releases with no repo change.

**Tag vs manifest version are not enforced.** The zip is named from `manifest.yml`'s `version:`,
not from the git tag. Tagging `v0.7.0` with `manifest.yml` at `0.6.1` ships
`agent_fwdr-0.6.1.zip`. Always bump the manifest version and changelog before tagging.

**Build directory on the runner.** The workflow globs both `${GITHUB_WORKSPACE}/build/packages`
and `$HOME/build/packages` because elastic-package's output directory depends on whether any
ancestor named `build` exists (see Build and repository mechanics above).

**`generate_release_notes: true`** pulls notes from merged PRs since the previous tag. PR titles
become the de-facto release notes alongside the hand-maintained `changelog.yml` — two sources of
truth.
