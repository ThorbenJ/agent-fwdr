#!/usr/bin/env bash
# tests/update_data.sh — keep derived test artefacts consistent with tests/data/.
#
# tests/data/ is the MASTER:
#   system.ndjson     — raw downstream events: system.syslog and system.cpu
#   apm.ndjson        — raw downstream event:  apm transaction
#   agent_fwdr.ndjson — raw downstream event:  the system-test probe (not rerouted)
#
# This script produces two committed artefacts from those masters:
#
#   1. package/agent_fwdr/_dev/deploy/docker/sample_logs/forwarded-logs.ndjson
#      Consumed by: system test (via docker compose), script test (via $WORK copy).
#      Shape: concatenation of masters, one raw JSON event per line.
#      Event order: system.syslog, system.cpu, apm, probe.
#
#   2. package/agent_fwdr/data_stream/forwarded/_dev/test/pipeline/test-forwarded.json
#      Consumed by: pipeline test (via _ingest/pipeline/_simulate).
#      Shape: {"events": [...]}, each master event lumberjack-wrapped (forwarder identity
#      at root, original event nested under "lumberjack"), plus a hand-written multi-hop
#      edge case appended.
#
# Both outputs are committed and self-contained. No suite needs this script to have
# run recently — it only needs to be run after editing tests/data/*.ndjson.
#
# After regenerating, update the pipeline golden file:
#   cd package/agent_fwdr && elastic-package test pipeline -g
#   # Review the diff before committing.
#
# Requirements: jq, bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="$REPO_ROOT/tests/data"
SAMPLE_LOGS="$REPO_ROOT/package/agent_fwdr/_dev/deploy/docker/sample_logs"
FORWARDED_NDJSON="$SAMPLE_LOGS/forwarded-logs.ndjson"
PIPELINE_JSON="$REPO_ROOT/package/agent_fwdr/data_stream/forwarded/_dev/test/pipeline/test-forwarded.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}  OK${NC}  $*"; }
info() { echo -e "${YELLOW}INFO${NC}  $*"; }
die()  { echo -e "${RED}ERROR${NC} $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required but not found on PATH"

# ---------------------------------------------------------------------------
# 1. forwarded-logs.ndjson — raw concatenation in canonical order
# ---------------------------------------------------------------------------
# Order matters: the system test's assert.hit_count: 1 counts documents that
# land in agent_fwdr.forwarded; the probe must be present.
# Event order: syslog, cpu, apm, probe.
cat \
    "$DATA_DIR/system.ndjson" \
    "$DATA_DIR/apm.ndjson" \
    "$DATA_DIR/agent_fwdr.ndjson" \
    > "$FORWARDED_NDJSON"

# Ensure no trailing blank lines (cat may produce them from trailing newlines)
# Each master file has exactly one event per line; the output should be 4 lines.
LINE_COUNT=$(wc -l < "$FORWARDED_NDJSON" | tr -d ' ')
ok "Wrote $FORWARDED_NDJSON ($LINE_COUNT lines)"

# ---------------------------------------------------------------------------
# 2. test-forwarded.json — lumberjack-wrapped pipeline-test input
# ---------------------------------------------------------------------------
# Each downstream event arrives at the forwarder wrapped in a lumberjack envelope.
# The pipeline test must exercise this exact shape: forwarder identity at root,
# original event nested under "lumberjack".
#
# The forwarder identity used here is a stable fixture identity, not a live agent.
# Envelope @timestamp values are static — the pipeline test calls
# _ingest/pipeline/_simulate, which is not subject to TSDB write-window
# constraints.
#
# Fields stripped in the pipeline test pipeline (system.cpu.*, metricset,
# transaction.type, transaction.duration) are NOT present in tests/data/ — they
# were removed at rest so no per-run stripping is needed.

WRAPPED=$(jq -cn \
  --slurpfile syslog "$DATA_DIR/system.ndjson" \
  --slurpfile apm    "$DATA_DIR/apm.ndjson" \
  --slurpfile probe  "$DATA_DIR/agent_fwdr.ndjson" \
  '
  # system.ndjson has 2 events; apm.ndjson and agent_fwdr.ndjson have 1 each.
  def wrap(ts; src_addr; event):
    {
      "@timestamp": ts,
      "source": {"address": src_addr},
      "agent": {
        "id": "f0000000-0000-0000-0000-00000000fwdr",
        "name": "forwarder-01",
        "type": "filebeat",
        "version": "9.1.0",
        "ephemeral_id": "aaaaaaaa-0000-0000-0000-00000000fwdr"
      },
      "elastic_agent": {
        "id": "f0000000-0000-0000-0000-00000000fwdr",
        "version": "9.1.0",
        "snapshot": false
      },
      "data_stream": {"type": "logs", "dataset": "agent_fwdr.forwarded", "namespace": "default"},
      "event": {"dataset": "agent_fwdr.forwarded"},
      "input": {"type": "lumberjack"},
      "ecs": {"version": "8.17.0"},
      "tags": ["forwarded"],
      "lumberjack": event
    };

  # --slurpfile wraps all objects from the file into an array:
  # $syslog[0] = syslog event, $syslog[1] = cpu event
  # $apm[0]   = apm event,    $probe[0] = probe event
  [
    wrap("2026-09-24T10:15:04.001Z"; "10.0.0.7:51234"; $syslog[0]),
    wrap("2026-09-24T10:15:04.002Z"; "10.0.0.8:51240"; $syslog[1]),
    wrap("2026-09-24T10:15:04.003Z"; "10.0.0.9:55001"; $apm[0]),
    wrap("2026-09-24T10:15:04.004Z"; "10.0.0.7:51235"; $probe[0])
  ]
')

# Edge case: chained-hop event to test fleet.forwarder.upstream nesting.
# Hand-written — not derived from tests/data/ — so it lives here as a literal.
EDGE_CASE='[
  {
    "@timestamp": "2026-09-24T10:15:08.100Z",
    "source": {"address": "10.0.0.11:55100"},
    "agent": {
      "id": "f0000000-0000-0000-0000-00000000fwdr",
      "name": "forwarder-01",
      "type": "filebeat",
      "version": "9.1.0"
    },
    "data_stream": {"type": "logs", "dataset": "agent_fwdr.forwarded", "namespace": "default"},
    "event": {"dataset": "agent_fwdr.forwarded"},
    "input": {"type": "lumberjack"},
    "lumberjack": {
      "@timestamp": "2026-09-24T10:15:07.800Z",
      "data_stream": {"type": "logs", "dataset": "nginx.access", "namespace": "default"},
      "event": {"dataset": "nginx.access"},
      "message": "chained from hop1",
      "fleet": {
        "forwarder": {
          "agent": {"id": "hop1-agent-id", "name": "hop1-forwarder"},
          "data_stream": {"type": "logs", "dataset": "agent_fwdr.forwarded", "namespace": "default"},
          "input": {"type": "lumberjack"},
          "received_at": "2026-09-24T10:15:07.600Z",
          "source": {"address": "192.168.1.10:44000"}
        }
      }
    }
  }
]'

jq -n \
    --argjson wrapped "$WRAPPED" \
    --argjson extras "$EDGE_CASE" \
    '{"events": ($wrapped + $extras)}' \
    > "$PIPELINE_JSON"

ok "Wrote $PIPELINE_JSON ($(jq '.events | length' "$PIPELINE_JSON") events)"

echo ""
echo -e "${YELLOW}Next step: regenerate the pipeline golden file${NC}"
echo "  cd package/agent_fwdr"
echo "  elastic-package test pipeline -g"
echo "  # Review the diff before committing"
