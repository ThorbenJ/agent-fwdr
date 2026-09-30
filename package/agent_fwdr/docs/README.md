# Agent Forwarder

Relay events from Elastic Agents that cannot reach Elasticsearch directly, without deploying
Logstash.

## Overview

Not every Elastic Agent can reach Elasticsearch. Agents land in DMZs, air-gapped segments, remote
sites, and networks whose egress policy permits exactly one hop to exactly one host. The established
answer is to deploy Logstash purely as a relay — a second product, a JVM, and its own configuration
and upgrade cycle, for the sole purpose of moving bytes between networks.

Agent Forwarder turns a Fleet-managed Elastic Agent into that relay instead. A downstream agent
points its existing **Logstash output** at a forwarder agent, and the forwarder passes the events on
to Elasticsearch. No JVM, no second product, no separate configuration language.

A forwarded document is intended to be indistinguishable from one the downstream agent would have
sent directly: same data stream, same ingest pipeline, same field structure, same event timestamp.
The only addition is a `fleet.forwarder.*` breadcrumb recording which forwarder handled the event.

### Compatibility

Requires Kibana 9.0.0 or later.

## What data does this integration collect?

Whatever the downstream agents send. Agent Forwarder is content-agnostic: it does not parse, enrich,
or interpret the events it relays.

The `agent_fwdr.forwarded` data stream is a transit point rather than a destination: under normal
operation documents pass straight through to their real home and little accumulates in it.

### Supported use cases

- Agents in a DMZ or other restricted segment permitted a single hop to one internal host.
- Remote sites shipping through one egress point.
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

Enabling this integration grants the forwarder agent write access to `logs-*-*`, `metrics-*-*`, and
`traces-*-*`, which it needs to reroute documents to the correct data streams. **Privileges are
granted per agent policy**, not scoped to what downstream agents actually send.

### 2. Configure TLS

Mutual TLS is strongly recommended — without it, anything that can reach the port can inject
documents into any data stream the forwarder has access to.

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

### 3. Point downstream agents at the forwarder

In **Fleet → Settings → Outputs**, add a **Logstash** output whose host is the forwarder's address
and port, for example `10.0.0.5:5044`. Configure the downstream agent's client certificate and key
— Fleet requires the key in **PKCS#8** format — and the CA that signed the forwarder's server
certificate.

Then assign that output to the downstream agent policy, or to individual integration policies.

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

**Two additional ports are bound on the loopback interface.** The integration binds three lumberjack
listeners in total: the main `0.0.0.0:5044` listener and two loopback-only listeners at
`127.0.0.2:5044` and `127.0.0.3:5044`. The loopback listeners are owned by the `forwarded_metrics`
and `forwarded_traces` companion streams, which exist solely to include `metrics-*-*` and
`traces-*-*` in the agent's output API key. No external client should connect to them — all
downstream agents should point at port 5044 on the forwarder's externally reachable address.

## Troubleshooting

**Documents accumulating in `agent_fwdr.forwarded`.** They are not being rerouted. Check
`fleet.forwarder.intended_data_stream.*` to see where each document was destined.

**`security_exception` in the agent logs.** The forwarder's API key lacks write access to the
destination. Check the key:

```console
GET /_security/api_key?id=<api_key_id>
```

The role descriptor should include `logs-*-*`, `metrics-*-*`, and `traces-*-*`.

**Nothing arrives at all.** Check that **Listen address** is `0.0.0.0` rather than the loopback
default, that the port is reachable, and — if TLS is enabled — that the downstream agent's key is
in PKCS#8 format.

**Events have the wrong timestamp.** Agent Forwarder restores `@timestamp` from the forwarded
payload; the receipt time is kept separately as `fleet.forwarder.received_at`. If `@timestamp`
matches receipt time, the payload carried no timestamp of its own.

## Reference

### Forwarded events

This integration relays events from downstream integrations without modifying their fields. Refer
to the documentation of the originating integration for field definitions.

Agent Forwarder adds one namespace to every event: `fleet.forwarder.*`, a breadcrumb identifying
the relay hop. These fields are listed below.

**Exported fields**

| Field | Description | Type |
|---|---|---|
| @timestamp | Event timestamp. | date |
| data_stream.dataset | Data stream dataset. | constant_keyword |
| data_stream.namespace | Data stream namespace. | constant_keyword |
| data_stream.type | Data stream type. | constant_keyword |
| ecs.version | ECS version this event conforms to. `ecs.version` is a required field and must exist in all events. When querying across multiple indices -- which may conform to slightly different ECS versions -- this field lets integrations adjust to the schema version of the events. | keyword |
| event.dataset | Event dataset. | keyword |
| fleet.forwarder.agent.ephemeral_id | Ephemeral identifier of the forwarding Elastic Agent process. | keyword |
| fleet.forwarder.agent.id | Unique identifier of the forwarding Elastic Agent. | keyword |
| fleet.forwarder.agent.name | Name of the forwarding Elastic Agent, typically its hostname. | keyword |
| fleet.forwarder.agent.type | Beat type underlying the forwarding Elastic Agent. | keyword |
| fleet.forwarder.agent.version | Version of the forwarding Elastic Agent. | keyword |
| fleet.forwarder.data_stream.dataset | Data stream dataset the forwarder itself was writing to. | keyword |
| fleet.forwarder.data_stream.namespace | Data stream namespace the forwarder itself was writing to. | keyword |
| fleet.forwarder.data_stream.type | Data stream type the forwarder itself was writing to. | keyword |
| fleet.forwarder.ecs.version | ECS version the forwarder itself was stamping on events. | keyword |
| fleet.forwarder.elastic_agent.id | Unique identifier of the forwarding Elastic Agent. | keyword |
| fleet.forwarder.elastic_agent.snapshot | Whether the forwarding Elastic Agent is a snapshot build. | boolean |
| fleet.forwarder.elastic_agent.version | Version of the forwarding Elastic Agent. | keyword |
| fleet.forwarder.event.dataset | Event dataset the forwarder itself was writing to. | keyword |
| fleet.forwarder.host.name | Hostname of the machine running the forwarder. Normally absent, because the input sets publisher_pipeline.disable_host to stop libbeat adding it. | keyword |
| fleet.forwarder.input.type | Input type on the forwarder. Always 'lumberjack'. | keyword |
| fleet.forwarder.upstream | When an event passes through more than one forwarder, the previous hop's `fleet.forwarder` breadcrumb is preserved here. Flattened because the structure mirrors `fleet.forwarder` and can chain to arbitrary depth. | flattened |
| fleet.forwarder.metadata | The upstream beat's '@metadata', carrying its input_id, stream_id and intended document _id. Preserved for correlation. Note that _id is not reapplied as this document's ID, so integrations relying on it for deduplication lose that property across the hop. Flattened because its contents vary by sender and beat version. | flattened |
| fleet.forwarder.received_at | Time at which the forwarder received the event. Useful for measuring relay lag. | date |
| fleet.forwarder.source.address | Address and port the forwarded connection originated from. | keyword |
| fleet.forwarder.tags | Tags configured on the forwarder's listener, kept apart from the forwarded event's own tags. | keyword |
| fleet.forwarder.tls.client.subject | Common name of the client certificate presented by the downstream agent, when mutual TLS is enabled. This is the only trustworthy per-sender discriminator. | keyword |
| input.type | Type of Filebeat input. | keyword |
| log.file.path | Full path to the log file this event came from, including the file name. It should include the drive letter, when appropriate. If the event wasn't read from a log file, do not populate this field. | keyword |
| message | Log contents. | match_only_text |
| service.environment | Identifies the environment where the service is running. If the same service runs in different environments (production, staging, QA, development, etc.), the environment can identify other instances of the same service. Can also group services and applications from the same environment. | keyword |
| service.name | Name of the service data is collected from. The name of the service is normally user given. This allows for distributed services that run on multiple hosts to correlate the related instances based on the name. In the case of Elasticsearch the `service.name` could contain the cluster name. For Beats the `service.name` is by default a copy of the `service.type` field if no name is specified. | keyword |
| tags | User defined tags. | keyword |
| trace.id | Unique identifier of the trace. A trace groups multiple events like transactions that belong together. For example, a user request handled by multiple inter-connected services. | keyword |
| transaction.id | Unique identifier of the transaction within the scope of its trace. A transaction is the highest level of work measured within a service, such as a request to a server. | keyword |

