# Agent Forwarder

Relay events from Elastic Agents that cannot reach Elasticsearch directly, without deploying
Logstash.

A downstream agent points its existing **Logstash output** at a forwarder agent running this
integration, and the forwarder passes the events on to Elasticsearch — preserving the original data
stream, ingest pipeline, and field structure.

## Documentation

Full setup and reference documentation is in
[package/agent_fwdr/docs/README.md](package/agent_fwdr/docs/README.md).

Developer notes — design rationale, pipeline internals, and implementation details — are in
[CONCEPT.md](CONCEPT.md).

## Repository layout

```
package/agent_fwdr/   Elastic integration package
tests/data/           Master fixture files (one NDJSON per downstream integration)
tests/update_data.sh  Generator: derives committed artefacts from the master files
CONCEPT.md            Developer notes: design rationale, pipeline internals, implementation tricks
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
