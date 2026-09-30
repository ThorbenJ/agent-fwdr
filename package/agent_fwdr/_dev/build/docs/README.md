# Agent Forwarder

Relay events from Elastic Agents that cannot reach Elasticsearch directly, without deploying
Logstash.

## Overview

Not every Elastic Agent can reach Elasticsearch. Agents land in DMZs, air-gapped segments, remote
sites, and networks whose egress policy permits exactly one hop to exactly one host. Those agents
still need to ship data.

Agent Forwarder turns a Fleet-managed Elastic Agent into that relay. A downstream agent points its
existing **Logstash output** at a forwarder agent, and the forwarder passes the events on to
Elasticsearch. No JVM, no second product, no separate configuration language.

A forwarded document is intended to be indistinguishable from one the downstream agent would have
sent directly: same data stream, same ingest pipeline, same field structure, same event timestamp.
The only addition is a `fleet.forwarder.*` breadcrumb recording which forwarder handled the event.

### Where this fits

If restricted agents can reach Fleet Server and Elasticsearch through an HTTP(S) proxy, use that
instead — it needs no extra component. This integration is for when a proxy is not enough: either a
local Fleet Server must be deployed inside the segment, or there is a diode requirement (a proxy
that forwards the Elasticsearch API is not a diode; lumberjack is, because the segment never touches
the API). In both cases, this integration can run on the same agent that hosts the local Fleet
Server, so one agent handles both configuration and data. If you already run Logstash for other
inputs (SNMP, JDBC, …), use it as the relay. Full comparison:
[https://github.com/ThorbenJ/agent-fwdr#where-this-fits](https://github.com/ThorbenJ/agent-fwdr#where-this-fits)

### Compatibility

Requires Kibana 9.0.0 or later.

## What data does this integration collect?

Whatever the downstream agents send. Agent Forwarder is content-agnostic: it does not parse, enrich,
or interpret the events it relays.

The `agent_fwdr.forwarded` data stream is a transit point rather than a destination: under normal
operation documents pass straight through to their real home and little accumulates in it.

### Supported use cases

- Co-located with a local Fleet Server on the segment's egress host, so one agent handles both
  configuration and data traffic.
- Segments with a diode requirement: downstream agents speak only the one-way lumberjack protocol
  and never access the Elasticsearch API.
- Replacing a Logstash instance that exists only to relay Elastic Agent traffic.

## What do I need to use this integration?

- One Elastic Agent that can reach Elasticsearch, to act as the forwarder. This is where you install
  this integration.
- One or more downstream Elastic Agents that can reach the forwarder on a TCP port.
- The integrations you are relaying must be installed in the same Fleet, so their index templates and
  ingest pipelines exist. Agent Forwarder does not create or prepare them.
- TLS certificates, if you want the hop authenticated and encrypted. Strongly recommended.

## How do I deploy this integration?

### 1. Install on the forwarder agent

Add this integration to the agent policy of the agent that will act as the relay. A single listener
receives all event types.

Set **Listen address** to `0.0.0.0` to accept remote connections. The default binds to loopback
only.

Enabling this integration grants the forwarder agent write access to `logs-*-*`. To also forward
metrics or traces events you must add the additional index permissions in the next step.

### 2. Add write permissions for forwarded types

**Important: skip this step only if you are forwarding logs exclusively.** If any downstream agent
sends metrics or traces, the forwarder's API key must include the corresponding index grants.
Omitting a type means those events are rejected with a `security_exception` on reroute and are
**lost** — there is no fallback.

On the integration policy page, expand **Advanced options** and add each required pattern to
**Add a reroute processor permission**:

![Add reroute processor permissions](../img/reroute-permissions.png)

```
metrics-*-*
traces-*-*
synthetics-*-*
```

Add only the types your downstream agents actually send. `logs-*-*` is already granted and does not
need to be listed. **Privileges are granted per agent policy**, not scoped to what downstream agents
actually send, so one forwarder policy covers all downstream agents assigned to it.

### 3. Configure TLS

Mutual TLS is strongly recommended — without it, anything that can reach the port can inject
documents into any data stream the forwarder has access to.

**TLS requires both a server certificate and a key.** The server certificate and key fields must be
filled in for the `ssl:` block to be rendered at all; configuring only **Trusted client certificate
authorities** without the server certificate and key leaves the listener running **plaintext,
silently**.

Set the **Server SSL certificate** and **Server SSL certificate key** fields to the paths of the
forwarder's certificate and private key. Add each trusted client certificate authority to **Trusted
client certificate authorities**. To enforce client certificate authentication, expand **Advanced
SSL options** and add:

```
  client_authentication: required
```

The client certificate's common name is recorded on every event as
`fleet.forwarder.tls.client.subject`. This is the only trustworthy per-sender discriminator, since
everything else in the payload is supplied by the sender.

### 4. Point downstream agents at the forwarder

In **Fleet → Settings → Outputs**, add a **Logstash** output whose host is the forwarder's address
and port, for example `10.0.0.5:5044`. Configure the downstream agent's client certificate and key
— Fleet requires the key in **PKCS#8** format — and the CA that signed the forwarder's server
certificate.

Then assign that output to the downstream agent policy, or to individual integration policies.

### 5. Map the forwarder breadcrumb (one-time, per cluster)

Rerouted documents land in other integrations' data streams, which have no mapping for
`fleet.forwarder.*`. Left alone these are mapped dynamically per index, which risks conflicting
inferred types across indices. Map the whole namespace once as a `flattened` field in the stack-wide
custom component templates, which Fleet applies to every data stream of a type:

```console
PUT _component_template/logs@custom
{
  "template": {
    "mappings": {
      "properties": {
        "fleet": { "properties": { "forwarder": { "type": "flattened" } } }
      }
    }
  }
}
```

Repeat for `metrics@custom` and `traces@custom` as needed. If those component templates already
exist, merge this into them rather than overwriting.

### Validation

Confirm documents are arriving at their real destinations rather than piling up in
`agent_fwdr.forwarded`:

```console
GET logs-*/_search
{
  "query": { "exists": { "field": "fleet.forwarder.agent.id" } },
  "aggs": { "destinations": { "terms": { "field": "data_stream.dataset" } } }
}
```

You should see the downstream integrations' datasets, not `agent_fwdr.forwarded`.

## Limitations

**Document IDs are not preserved.** The upstream `_id` is kept as
`fleet.forwarder.metadata._id` for correlation, but is not reapplied as the document ID.
Integrations that rely on it for deduplication lose that property across the hop.

**Targets must be installed.** If an integration being relayed is not installed in the same Fleet,
its index template and pipeline do not exist and the rerouted document falls back to dynamic mapping.

## Troubleshooting

**Documents accumulating in `agent_fwdr.forwarded`.** They are not being rerouted. Check
`event.kind` — a value of `pipeline_error` means the ingest pipeline could not unwrap the payload
(see `error.message` for the specific processor that failed). For documents that did unwrap,
`fleet.forwarder.*` contains the relay hop breadcrumb; `fleet.forwarder.data_stream.*` records the
forwarder's own data stream at the time the document was received.

**`security_exception` in the agent logs.** The most common cause is a missing index grant for
the type being forwarded. On the integration policy page, expand **Advanced options** and verify
that the required patterns are present in **Add a reroute processor permission** (see step 2).
Events for types without a grant are rejected and lost — they do not fall back to the forwarded
data stream.

To confirm what the API key actually grants:

```console
GET /_security/api_key?id=<api_key_id>
```

`logs-*-*` is always present. `metrics-*-*`, `traces-*-*`, and `synthetics-*-*` appear only if
you added them in step 2.

**Nothing arrives at all.** Check that **Listen address** is `0.0.0.0` rather than the loopback
default, that the port is reachable, and — if TLS is enabled — that both the server certificate
and key fields are filled in (the SSL block is only rendered when the server certificate is set),
and that the downstream agent's key is in PKCS#8 format.

**Events have the wrong timestamp.** Agent Forwarder restores `@timestamp` from the forwarded
payload; the receipt time is kept separately as `fleet.forwarder.received_at`. If `@timestamp`
matches receipt time, the payload carried no timestamp of its own.

## Reference

### Forwarded events

This integration relays events from downstream integrations without modifying their fields. Refer
to the documentation of the originating integration for field definitions.

Agent Forwarder adds one namespace to every event: `fleet.forwarder.*`, a breadcrumb identifying
the relay hop. These fields are listed below.

{{fields "forwarded"}}
