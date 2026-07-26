# Elasticsearch 9.4.4 — secured 7-node cluster (homework)

A fault-tolerant, TLS-secured Elasticsearch cluster with hot/warm data tiers and
**self-monitoring**: the stack's own component logs (Elasticsearch, Kibana,
Filebeat) are shipped by Filebeat back into the cluster, into the `self-monitoring`
index, which is itself managed by a hot→warm→delete ILM policy.

- **7 nodes:** 3 dedicated masters + 2 hot + 2 warm.
- **Security:** TLS (transport + HTTP) with `elasticsearch-certutil` certs; built-in users.
- **Log shipper:** standalone Filebeat 9.4.4 (autodiscover → `self-monitoring`).

## Requirements

- Docker (Colima or Docker Desktop), ~12–16 GB RAM.
- Linux hosts: `sudo sysctl -w vm.max_map_count=262144` (Docker Desktop / Colima already provision a high value).

## Run

```bash
# 1. (optional) adjust credentials
cp .env.example .env        # .env ships with demo creds; skip if you keep them

# 2. start Docker, then generate TLS certs
./setup/generate-certs.sh

# 3. bring everything up — the `setup` container auto-bootstraps secrets, ILM, and the index
docker compose up -d
```

The `setup` service runs once (sets the `kibana_system` password, creates the ILM
policy + index template, bootstraps the first `self-monitoring` rollover index),
then exits. Kibana and Filebeat start after it completes.

Wait ~90s, then:

- **Kibana UI:** http://localhost:5601 — log in as `elastic` with `$ELASTIC_PASSWORD`.
- **Cluster health:**

```bash
source .env
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  https://localhost:9201/_cluster/health?pretty
```

> **Note on ports:** Elasticsearch is exposed on host port **9201** (`es-hot-1` maps
> `9201:9200`) because port 9200 was already in use on the author's machine. If your
> port 9200 is free, change `"9201:9200"` to `"9200:9200"` in `docker-compose.yml`.

## What to screenshot (for the assignment)

1. **Logs arriving in the cluster** — Kibana → Discover, data view `self-monitoring*`.
   Or via API:
   ```bash
   source .env
   curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
     https://localhost:9201/self-monitoring/_count
   ```
2. **ILM policy (Hot + Warm)** — Kibana → Stack Management → Index Lifecycle Policies →
   `self-monitoring-policy`. Exported JSON is committed at `policies/self-monitoring-policy.json`.
3. **Hot → Warm transition** — see "Demonstrate the lifecycle" below, then
   Kibana → Index Management (a backing index shows the `warm` tier).

Save screenshots under `docs/screenshots/`.

## Demonstrate the lifecycle (force a tier transition for the screenshot)

```bash
source .env
AUTH="elastic:${ELASTIC_PASSWORD}"; CACERT=certs/ca/ca.crt; ES=https://localhost:9201

# roll over: creates self-monitoring-000002; the old index is no longer the write index
curl -fsS --cacert "$CACERT" -u "$AUTH" -X POST "$ES/self-monitoring/_rollover"

# move self-monitoring-000001 from hot into the warm phase immediately
curl -fsS --cacert "$CACERT" -u "$AUTH" -X POST "$ES/_ilm/move/self-monitoring-000001" \
  -H 'Content-Type: application/json' \
  -d '{"current_step":{"phase":"hot","action":"rollover","name":"check-rollover-ready"},"next_step":{"phase":"warm"}}'

# observe: 000001 now lives on a data_warm node, 000002 on a hot node
curl -fsS --cacert "$CACERT" -u "$AUTH" "$ES/_cat/shards/self-monitoring*?v&h=index,prirep,store,node"
```

> If `_ilm/move` rejects the `current_step` (it must match the index's actual current
> step), first run `curl -fsS --cacert "$CACERT" -u "$AUTH" "$ES/self-monitoring-000001/_ilm/explain"`
> and copy the real `phase`/`action`/`name` (the step `name`, not the action) into
> `current_step`. Note the ES 9 endpoint is `/_ilm/move/<index>` (path-style) and the
> target is the `next_step` object — `{"phase": "warm"}` moves to the first step of the
> warm phase.

## Export the ILM policy (deliverable JSON)

```bash
source .env
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  https://localhost:9201/_ilm/policy/self-monitoring-policy?pretty > ilm-export.json
```
(The canonical copy is already committed at `policies/self-monitoring-policy.json`.)

## Tear down

```bash
docker compose down -v   # -v also removes the Elasticsearch data volumes
```

## Layout

See `docs/architecture.md` and the design spec at
`docs/superpowers/specs/2026-07-26-es-cluster-design.md`.
