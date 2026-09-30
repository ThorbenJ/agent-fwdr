# Agent Forwarder — concept

Developer notes covering how and why the integration works the way it does. This is not end-user
documentation; see [package/agent_fwdr/docs/README.md](package/agent_fwdr/docs/README.md) for that.

## Reason

Not every Elastic Agent can reach Elasticsearch. Agents land in DMZs, air-gapped segments, remote
sites, and networks whose egress policy permits exactly one hop to exactly one host. Those agents
still need to ship data.

The established answer is to deploy Logstash as a relay. That works, but it means running and
operating a second product — a JVM, its own configuration language, its own pipeline files, its own
upgrade cycle — for the sole purpose of moving bytes from one network to another. Nothing about the
data is being transformed. The relay is pure plumbing, and it is disproportionately expensive
plumbing.

## Goal

Let a Fleet-managed Elastic Agent be that relay.

A downstream agent points its existing **Logstash output** at a forwarder agent instead of at a
Logstash instance. The forwarder receives the events and passes them on to Elasticsearch — no JVM,
no second product, no separate config language.

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
  carry no `data_stream.*` (e.g. non-Fleet shippers). These stay in `agent_fwdr.forwarded`.
- Sync `event.dataset` from `data_stream.dataset` if absent.

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

`routing_rules.yml` defines a single rule: if `data_stream.dataset` is set and is not
`agent_fwdr.forwarded`, reroute to `'{{{data_stream.dataset}}}'` / `'{{{data_stream.namespace}}}'`.

Fleet compiles this at policy build time into a `reroute` processor that is **appended to the end
of the default ingest pipeline**. By the time that processor runs, the pipeline has already promoted
the payload and set the correct `data_stream.*` values. The reroute then targets the right index,
including the correct type via the mechanism above.

Documents whose payload carries no dataset (non-Fleet shippers, or payloads that fail to unwrap)
fall through the reroute condition and stay in `agent_fwdr.forwarded`, where dynamic mapping
accepts them.

## Companion data streams: `forwarded_metrics` and `forwarded_traces`

Fleet derives an agent's output API key permissions from the **enabled** data streams in its
policy. Each enabled data stream contributes index grants of the form `{type}-*-*` to the agent's
API key. The `forwarded` data stream contributes `logs-*-*` — but cross-type rerouting also
requires `metrics-*-*` and `traces-*-*`.

`forwarded_metrics` and `forwarded_traces` exist solely to contribute those grants. No downstream
client is intended to connect to them; all lumberjack traffic arrives on the single
`0.0.0.0:5044` listener of the `forwarded` data stream. The companion streams carry no routing
rules and no ingest logic.

### Why not `enabled: false`?

A natural first instinct is to configure the companion streams with `enabled: false` so the agent
skips creating a listener for them. This does not work with **elastic-otel-collector**, the
OpenTelemetry-based agent runner used by Elastic Agent 9.x.

The elastic-otel-collector creates one `filebeatreceiver` component per lumberjack stream in the
policy. A receiver whose input configuration contains only `enabled: false` (and no other valid
input definition) causes Filebeat to error:

```
no modules or inputs enabled and configuration reloading disabled
```

This crashes the entire `lumberjack-default` component — closing the main `0.0.0.0:5044`
listener with it.

The workaround: the companion stream templates configure unique **loopback-only** listen addresses
(`127.0.0.2:5044` and `127.0.0.3:5044`). Each receiver initialises successfully and the agent
starts without error, but the addresses are unreachable from any external client. The single
`0.0.0.0:5044` listener on the `forwarded` stream remains the only externally accessible port.

This is a known limitation of the current agent architecture. When elastic-otel-collector gains
the ability to handle `enabled: false` gracefully on lumberjack streams, the loopback addresses
can be removed from the companion stream templates.

## Boundaries

- **We own only the forwarder's own pipeline.** The sending integration's pipeline is never
  modified, never bypassed, and never needs to know a forwarder was involved.
- **Targets are assumed present.** The forwarder and the integrations it relays for are managed by
  the same Fleet, so a relayed integration's index templates and pipelines are already installed.
  The forwarder does not prepare, declare, or know about its destinations.
- **Multi-hop chaining works.** Each hop's forwarder identity is nested under `fleet.forwarder.upstream`,
  preserving the full chain. The integration does not explicitly limit hop count.

## Testing

The lumberjack input is undocumented and marked Beta. Verifying it still works after stack upgrades
is the main ongoing testing obligation.

### Run order

`elastic-package test` runs test types in alphabetical order: asset → pipeline → policy →
**script** → static → **system**. The script test is self-contained — it installs downstream
integrations and manages its own agent — so all types can run in one go:

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

### `data_stream/forwarded/_dev/test/scripts/reroute.txtar`

A self-contained integration test. Does everything in one run:

1. **Installs downstream integrations** (`system`, `apm`) — via Fleet EPM API, resolving the
   latest version. Necessary so index templates and ingest pipelines exist before rerouted
   documents land. (The script-test primitive `install_package_from_registry` requires a literal
   version; this is an EP gap recorded in the txtar header comment.)

2. **Deploys its own agent** — `install_agent` + `add_package_policy` (lumberjack, port 5044).

3. **Widens the package policy** — `add_package_policy` enables only one data stream; the other two
   (`forwarded_metrics`, `forwarded_traces`) must be enabled via Fleet API PUT so Fleet grants the
   agent `logs-*-*`, `metrics-*-*`, and `traces-*-*` in its output API key. This is an EP gap
   (`packagepolicy.go buildStreamsForInput`).

4. **Confirms the API key** — polls `GET /_security/api_key` until all three grants are present.
   This is both the assertion and the synchronisation barrier — events are not sent until the agent
   has the correct key.

5. **Stamps timestamps** — rewrites `@timestamp` (and the syslog message date) in the `$WORK`
   copy of the fixture to now. Required because:
   - `metrics-system.cpu-default` uses `index.mode=time_series`; the write window is ~now ± 2h.
   - `system.syslog` grok overwrites `@timestamp` from the message date — a past date leaves the
     document invisible in Kibana's default range. (This caused a false "nothing arrived" diagnosis
     before the fix.)
   The source tree is never mutated.

6. **Sends events** — `docker_up` + `docker_signal SIGHUP` + `docker_wait_exit`.

7. **Asserts arrival** — probe via `get_docs`; the three rerouted targets via `exec curl` polling
   ES `_search` with a `term` filter on `fleet.forwarder.agent.id`. Filtering on the agent id
   replaces the old `event.ingested > now − 2h` recency window: each run has a distinct Fleet
   agent id, so documents from previous runs on a reused stack cannot cause a false pass.

8. **Tears down** — docker_down, remove_package_policy, uninstall_agent, remove_package.

### OOTB scope

`elastic-package test pipeline` and `elastic-package test system` run with no preparation.

- **Pipeline**: calls `_ingest/pipeline/_simulate` only; no stack interaction beyond the simulate
  API. Static timestamps are fine.
- **System**: sends the 4-event ndjson over lumberjack and asserts the probe (event 4) lands in
  `logs-agent_fwdr.forwarded-<ns>`. Events 1–3 reroute to shared target data streams; the system
  test makes no assertion on them. The cpu event may be rejected by TSDB (static date outside the
  write window) but that is outside the tested data stream and does not fail the system test.

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
