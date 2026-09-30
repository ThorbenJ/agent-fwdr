# Agent Forwarder

An Elastic integration that turns a Fleet-managed agent into a log/metrics/traces relay, without
deploying Logstash.

## Where this fits

**First, consider whether a proxy is enough.** If the restricted segment's agents can reach Fleet
Server and Elasticsearch through an HTTP(S) proxy, use that — it needs no extra component and
nothing to operate. Proxy the connection; do not intercept the data path.

**If a proxy is not enough, the reason matters.** Two scenarios rule it out:

- A *local Fleet Server* requirement: agents in the segment must receive configuration without
  reaching the main Elasticsearch cluster at all, so a Fleet Server is deployed inside the segment,
  with the same host acting as the segment's one egress point.
- A *diode requirement*: the segment must have no access to the Elasticsearch or Fleet Server API.
  A proxy forwarding those APIs is a conduit, not a diode — it gives restricted agents API access.
  What provides the diode property is the **lumberjack protocol**: restricted agents send a
  one-way event stream, and the forwarder re-originates the data on the far side. Those agents
  never touch the Elasticsearch API. Note that the egress host itself — the one running Fleet
  Server and the forwarder — does have API access; the diode applies to every other agent in the
  segment.

**If you need Logstash for other reasons, use it as the relay too.** Logstash as a relay has the
same diode property as this integration. If you already run Logstash for SNMP, JDBC, or other
inputs, it is the obvious relay. This integration exists for the case where the relay would be
*Logstash's only job* — a JVM, a second product, and a separate upgrade cycle for pure plumbing.

**This integration** replaces that relay with a forwarder running on the *same agent* that hosts
the local Fleet Server. One agent, one egress host, both planes: configuration traffic via Fleet
Server, data traffic via the lumberjack listener. No second product.

## What it does

A downstream agent points its existing **Logstash output** at the forwarder agent, and the
forwarder passes the events on to Elasticsearch — preserving the original data stream, ingest
pipeline, and field structure.

A forwarded document is intended to be indistinguishable from one the downstream agent would have
sent directly. The only addition is a `fleet.forwarder.*` breadcrumb recording which forwarder
handled the event.

## Documentation

Full setup and reference documentation is in
[package/agent_fwdr/docs/README.md](package/agent_fwdr/docs/README.md).

Developer notes — design rationale, pipeline internals, test harness reference, and implementation
details — are in [CONCEPT.md](CONCEPT.md).

## Repository layout

```
package/agent_fwdr/        Elastic integration package
package/agent_fwdr/img/    Icons and screenshots used in the integration UI and docs
.github/workflows/         GitHub Actions (release workflow, currently workflow_dispatch only)
tests/data/                Master fixture files (one NDJSON per downstream integration)
tests/update_data.sh       Generator: derives committed artefacts from the master files
CONCEPT.md                 Developer notes: design rationale, pipeline internals, implementation tricks
```

## Testing

See [CONCEPT.md § Testing](CONCEPT.md#testing) for the full runbook. Quick start:

```bash
elastic-package stack up -d           # start the stack (once per dev session)
cd package/agent_fwdr
elastic-package test -v               # all test types, including the self-contained script test
```

The script test (`reroute.txtar`) installs downstream integrations, manages its own agent, and
asserts all four canonical events arrive at their correct data streams. No preparation step is
needed beyond `elastic-package stack up -d`.

### Keeping fixtures up to date

The files in `tests/data/` are the master fixtures. After editing them:

```bash
./tests/update_data.sh                # regenerate derived artefacts
cd package/agent_fwdr
elastic-package test pipeline -g      # update the pipeline golden file
# review the diff, then commit everything
```
