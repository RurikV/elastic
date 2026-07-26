# Architecture

```
                 ┌─────────────────────────────────────────────────┐
                 │            Docker network: elastic              │
   :9201 ──────► es-hot-1, es-hot-2          (data_hot, ingest)    │
                 │ es-master-1/2/3            (master, quorum)      │
                 │ es-warm-1, es-warm-2       (data_warm)          │
                 │                                                 │
                 │   setup ──► bootstraps secrets + ILM + index    │
   :5601 ──────► kibana  (kibana_system ── HTTPS ──► ES)           │
                 │   filebeat ── autodiscover ──► self-monitoring  │
                 └─────────────────────────────────────────────────┘
```

## Topology — 7 nodes

- **3 dedicated master-eligible nodes** (`es-master-1/2/3`, `node.roles: [master]`) — form a quorum of 3.
- **2 hot data nodes** (`es-hot-1/2`, `node.roles: [data_hot, data_content, ingest]`).
- **2 warm data nodes** (`es-warm-1/2`, `node.roles: [data_warm]`).

## Fault tolerance

- 3 masters → the cluster keeps quorum after losing **1 master**.
- Each data tier has 2 nodes with `number_of_replicas: 1` → the cluster keeps all shards available after losing **any single data node**, hot **or** warm. This satisfies the assignment's "maximum tolerable failure: one data node".

## Data lifecycle (ILM)

Component logs land in the `self-monitoring` rollover alias and are themselves managed by the `self-monitoring-policy` ILM policy:

- **hot** — rollover at 1 day or 5 GB primary shard size; priority 100.
- **warm** — at `min_age 1d`: allocate 1 replica, force-merge to 1 segment, priority 50. Elasticsearch automatically sets `_tier_preference` so the shard relocates to the `data_warm` nodes.
- **delete** — at `min_age 7d`.

## Self-monitoring

Filebeat autodiscovers containers whose image name contains `elastic` (Elasticsearch, Kibana, Filebeat) and writes them over HTTPS into the `self-monitoring` alias — i.e. the stack logs its own components into itself.
