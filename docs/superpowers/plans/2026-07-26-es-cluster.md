# Elasticsearch 9.4.4 Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a secured, fault-tolerant 5-node Elasticsearch 9.4.4 cluster in Docker Compose with hot/warm ILM, Kibana UI, and Filebeat shipping the stack's own logs into a `self-monitoring` index.

**Architecture:** 3 dedicated master nodes + 2 hot + 2 warm data nodes, secured with `elasticsearch-certutil`-generated TLS certs and built-in-user auth. A one-shot `setup` container bootstraps secrets, the ILM policy, the index template, and the rollover alias before Kibana and Filebeat start — so a single `docker compose up -d` produces a working cluster.

**Tech Stack:** Elasticsearch / Kibana / Filebeat 9.4.4, Docker Compose, Bash, curl. Host: macOS + Colima (or Docker Desktop). ~12–16 GB RAM.

**Spec:** `docs/superpowers/specs/2026-07-26-es-cluster-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `.env` / `.env.example` | Demo credentials + stack version (committed `.env` for friction-free grading) |
| `.gitignore` | Ignore `certs/`, runtime `data/`, `.claude/` local settings |
| `config/es-master.yml` | Full config for dedicated-master nodes (security + discovery + `node.roles: [master]`) |
| `config/es-hot.yml` | Full config for hot nodes (`node.roles: [data_hot, data_content, ingest]`) |
| `config/es-warm.yml` | Full config for warm nodes (`node.roles: [data_warm]`) |
| `config/kibana.yml` | Kibana → secured ES over HTTPS as `kibana_system` |
| `setup/instances.yml` | Node hostnames/SANs for `elasticsearch-certutil` |
| `setup/generate-certs.sh` | Generate CA + node cert (PEM) into `certs/` |
| `setup/bootstrap.sh` | Set `kibana_system` pw, create ILM policy + template + bootstrap index |
| `policies/self-monitoring-policy.json` | hot→warm→delete ILM policy (the exported JSON deliverable) |
| `policies/self-monitoring-template.json` | Index template attaching the policy to `self-monitoring-*` |
| `filebeat/filebeat.yml` | Autodiscover stack logs → `self-monitoring` over HTTPS |
| `docker-compose.yml` | 7 ES nodes + setup + kibana + filebeat |
| `README.md` | Run steps, architecture, screenshot guide, troubleshooting |
| `docs/architecture.md` | Diagram + topology explanation |

**Note on config layout vs. spec:** Elasticsearch reads a single `elasticsearch.yml` and does not merge config files, so `node.roles` lives inside each per-role config (3 self-contained files) rather than in a separate shared file. The shared security/discovery settings are intentionally duplicated across the three for clarity and correctness.

---

## Task 1: Foundation — secrets, .gitignore, per-role ES configs

**Files:**
- Create: `.env`, `.env.example`
- Modify: `.gitignore`
- Create: `config/es-master.yml`, `config/es-hot.yml`, `config/es-warm.yml`

- [ ] **Step 1: Update `.gitignore` to allow committing `.env`**

Replace the `- .env`-style block so the file reads (keep `certs/`, ignore runtime data, do NOT ignore `.env`):

```gitignore
# --- Generated material (created by setup/generate-certs.sh) ---
certs/

# --- Runtime bind-mount data (if ever used; named volumes live in Docker) ---
data/
kibana-data/

# --- OS / editor ---
.DS_Store
*.swp
.idea/
.vscode/

# --- Claude local ---
.claude/settings.local.json
```

- [ ] **Step 2: Create `.env`**

```env
# DEMO credentials for the Elasticsearch homework cluster.
# Safe to commit for this throwaway cluster; CHANGE for any real use.
STACK_VERSION=9.4.4
CLUSTER_NAME=elastic-homework
ELASTIC_PASSWORD=Elastic-9.4.4-Demo
KIBANA_SYSTEM_PASSWORD=Kibana-9.4.4-Demo
```

- [ ] **Step 3: Create `.env.example` (same keys, placeholder values)**

```env
STACK_VERSION=9.4.4
CLUSTER_NAME=elastic-homework
ELASTIC_PASSWORD=change-me
KIBANA_SYSTEM_PASSWORD=change-me
```

- [ ] **Step 4: Create `config/es-master.yml`**

```yaml
cluster.name: elastic-homework
network.host: 0.0.0.0

# --- Cluster formation (seed = the 3 masters) ---
discovery.seed_hosts: ["es-master-1", "es-master-2", "es-master-3"]
cluster.initial_master_nodes: ["es-master-1", "es-master-2", "es-master-3"]

# --- Node role: dedicated master-eligible ---
node.roles: [ master ]

# --- Security: TLS (PEM form) ---
xpack.security.enabled: true
xpack.security.enrollment.enabled: true

xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.certificate_authorities: [ "certs/ca/ca.crt" ]
xpack.security.transport.ssl.certificate: certs/instance/node.crt
xpack.security.transport.ssl.key: certs/instance/node.key

xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.certificate_authorities: [ "certs/ca/ca.crt" ]
xpack.security.http.ssl.certificate: certs/instance/node.crt
xpack.security.http.ssl.key: certs/instance/node.key
```

- [ ] **Step 5: Create `config/es-hot.yml`** (identical to master except `node.roles`)

```yaml
cluster.name: elastic-homework
network.host: 0.0.0.0

discovery.seed_hosts: ["es-master-1", "es-master-2", "es-master-3"]
cluster.initial_master_nodes: ["es-master-1", "es-master-2", "es-master-3"]

node.roles: [ data_hot, data_content, ingest ]

xpack.security.enabled: true
xpack.security.enrollment.enabled: true

xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.certificate_authorities: [ "certs/ca/ca.crt" ]
xpack.security.transport.ssl.certificate: certs/instance/node.crt
xpack.security.transport.ssl.key: certs/instance/node.key

xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.certificate_authorities: [ "certs/ca/ca.crt" ]
xpack.security.http.ssl.certificate: certs/instance/node.crt
xpack.security.http.ssl.key: certs/instance/node.key
```

- [ ] **Step 6: Create `config/es-warm.yml`** (identical to hot except `node.roles`)

```yaml
cluster.name: elastic-homework
network.host: 0.0.0.0

discovery.seed_hosts: ["es-master-1", "es-master-2", "es-master-3"]
cluster.initial_master_nodes: ["es-master-1", "es-master-2", "es-master-3"]

node.roles: [ data_warm ]

xpack.security.enabled: true
xpack.security.enrollment.enabled: true

xpack.security.transport.ssl.enabled: true
xpack.security.transport.ssl.verification_mode: certificate
xpack.security.transport.ssl.certificate_authorities: [ "certs/ca/ca.crt" ]
xpack.security.transport.ssl.certificate: certs/instance/node.crt
xpack.security.transport.ssl.key: certs/instance/node.key

xpack.security.http.ssl.enabled: true
xpack.security.http.ssl.certificate_authorities: [ "certs/ca/ca.crt" ]
xpack.security.http.ssl.certificate: certs/instance/node.crt
xpack.security.http.ssl.key: certs/instance/node.key
```

- [ ] **Step 7: Verify YAML parses**

Run: `python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('config/*.yml')]; print('YAML OK')"`
Expected: `YAML OK`

- [ ] **Step 8: Commit**

```bash
git add .env .env.example .gitignore config/
git commit -m "feat: add env config and per-role elasticsearch configs"
```

---

## Task 2: Certificate generation

**Files:**
- Create: `setup/instances.yml`, `setup/generate-certs.sh`

- [ ] **Step 1: Create `setup/instances.yml`**

A single node cert with SANs covering every container hostname + localhost, so any client/host can verify it.

```yaml
instances:
  - name: node
    ip:
      - 127.0.0.1
    dns:
      - localhost
      - es-master-1
      - es-master-2
      - es-master-3
      - es-hot-1
      - es-hot-2
      - es-warm-1
      - es-warm-2
      - kibana
      - filebeat
      - setup
```

- [ ] **Step 2: Create `setup/generate-certs.sh`**

```bash
#!/usr/bin/env bash
# Generates a CA (PEM) and a single node certificate valid for all cluster
# hostnames, into ./certs/. Run once before `docker compose up`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ES_IMAGE="docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION:-9.4.4}"

echo "Using image: $ES_IMAGE"
echo "Cleaning ./certs ..."
rm -rf certs && mkdir -p certs

echo "Generating CA ..."
docker run --rm \
  -v "$PWD/certs:/usr/share/elasticsearch/config/certs" \
  "$ES_IMAGE" \
  bash -c "elasticsearch-certutil ca --pem --out config/certs/ca.zip > /dev/null"

# Unpack the CA now: the certutil cert step below needs ca/ca.crt and ca/ca.key.
( cd certs && unzip -o -q ca.zip )

echo "Generating node certificate ..."
docker run --rm \
  -v "$PWD/certs:/usr/share/elasticsearch/config/certs" \
  -v "$PWD/setup/instances.yml:/usr/share/elasticsearch/config/instances.yml:ro" \
  "$ES_IMAGE" \
  bash -c "elasticsearch-certutil cert --pem \
    --in config/instances.yml \
    --ca-cert config/certs/ca/ca.crt \
    --ca-key config/certs/ca/ca.key \
    --out config/certs/certs.zip > /dev/null"

echo "Unpacking ..."
( cd certs && unzip -o -q ca.zip && unzip -o -q certs.zip )

# certutil writes the single instance as certs/node/node.{crt,key}; normalize it.
mkdir -p certs/instance
mv certs/node/node.crt certs/instance/node.crt
mv certs/node/node.key certs/instance/node.key
rmdir certs/node 2>/dev/null || true
rm -f certs/ca.zip certs/certs.zip

chmod 644 certs/ca/ca.crt certs/instance/node.crt
chmod 600 certs/ca/ca.key certs/instance/node.key

echo "Done. Files:"
find certs -type f | sort
```

- [ ] **Step 3: Make it executable**

Run: `chmod +x setup/generate-certs.sh`

- [ ] **Step 4: Run it** (requires Docker/Colima running)

Run: `./setup/generate-certs.sh`
Expected: ends with a listing containing `certs/ca/ca.crt`, `certs/ca/ca.key`, `certs/instance/node.crt`, `certs/instance/node.key`.

- [ ] **Step 5: Commit** (only the scripts; `certs/` is gitignored)

```bash
git add setup/instances.yml setup/generate-certs.sh
git commit -m "feat: add certificate generation for the secured cluster"
```

---

## Task 3: Elasticsearch nodes in docker-compose

**Files:**
- Create: `docker-compose.yml` (7 ES nodes + volumes + network only, for now)

- [ ] **Step 1: Create `docker-compose.yml`**

```yaml
name: elastic-homework

services:
  es-master-1:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: es-master-1
    environment:
      - node.name=es-master-1
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    volumes:
      - ./config/es-master.yml:/usr/share/elasticsearch/config/elasticsearch.yml:ro
      - ./certs/ca:/usr/share/elasticsearch/config/certs/ca:ro
      - ./certs/instance:/usr/share/elasticsearch/config/certs/instance:ro
      - es-data-master-1:/usr/share/elasticsearch/data
    mem_limit: 1g
    ulimits:
      memlock: { soft: -1, hard: -1 }
    networks: [elastic]

  es-master-2:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: es-master-2
    environment:
      - node.name=es-master-2
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    volumes:
      - ./config/es-master.yml:/usr/share/elasticsearch/config/elasticsearch.yml:ro
      - ./certs/ca:/usr/share/elasticsearch/config/certs/ca:ro
      - ./certs/instance:/usr/share/elasticsearch/config/certs/instance:ro
      - es-data-master-2:/usr/share/elasticsearch/data
    mem_limit: 1g
    ulimits:
      memlock: { soft: -1, hard: -1 }
    networks: [elastic]

  es-master-3:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: es-master-3
    environment:
      - node.name=es-master-3
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms512m -Xmx512m
    volumes:
      - ./config/es-master.yml:/usr/share/elasticsearch/config/elasticsearch.yml:ro
      - ./certs/ca:/usr/share/elasticsearch/config/certs/ca:ro
      - ./certs/instance:/usr/share/elasticsearch/config/certs/instance:ro
      - es-data-master-3:/usr/share/elasticsearch/data
    mem_limit: 1g
    ulimits:
      memlock: { soft: -1, hard: -1 }
    networks: [elastic]

  es-hot-1:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: es-hot-1
    environment:
      - node.name=es-hot-1
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    volumes:
      - ./config/es-hot.yml:/usr/share/elasticsearch/config/elasticsearch.yml:ro
      - ./certs/ca:/usr/share/elasticsearch/config/certs/ca:ro
      - ./certs/instance:/usr/share/elasticsearch/config/certs/instance:ro
      - es-data-hot-1:/usr/share/elasticsearch/data
    ports:
      - "9200:9200"
    mem_limit: 2g
    ulimits:
      memlock: { soft: -1, hard: -1 }
    networks: [elastic]

  es-hot-2:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: es-hot-2
    environment:
      - node.name=es-hot-2
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    volumes:
      - ./config/es-hot.yml:/usr/share/elasticsearch/config/elasticsearch.yml:ro
      - ./certs/ca:/usr/share/elasticsearch/config/certs/ca:ro
      - ./certs/instance:/usr/share/elasticsearch/config/certs/instance:ro
      - es-data-hot-2:/usr/share/elasticsearch/data
    mem_limit: 2g
    ulimits:
      memlock: { soft: -1, hard: -1 }
    networks: [elastic]

  es-warm-1:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: es-warm-1
    environment:
      - node.name=es-warm-1
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    volumes:
      - ./config/es-warm.yml:/usr/share/elasticsearch/config/elasticsearch.yml:ro
      - ./certs/ca:/usr/share/elasticsearch/config/certs/ca:ro
      - ./certs/instance:/usr/share/elasticsearch/config/certs/instance:ro
      - es-data-warm-1:/usr/share/elasticsearch/data
    mem_limit: 2g
    ulimits:
      memlock: { soft: -1, hard: -1 }
    networks: [elastic]

  es-warm-2:
    image: docker.elastic.co/elasticsearch/elasticsearch:${STACK_VERSION}
    container_name: es-warm-2
    environment:
      - node.name=es-warm-2
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - ES_JAVA_OPTS=-Xms1g -Xmx1g
    volumes:
      - ./config/es-warm.yml:/usr/share/elasticsearch/config/elasticsearch.yml:ro
      - ./certs/ca:/usr/share/elasticsearch/config/certs/ca:ro
      - ./certs/instance:/usr/share/elasticsearch/config/certs/instance:ro
      - es-data-warm-2:/usr/share/elasticsearch/data
    mem_limit: 2g
    ulimits:
      memlock: { soft: -1, hard: -1 }
    networks: [elastic]

volumes:
  es-data-master-1:
  es-data-master-2:
  es-data-master-3:
  es-data-hot-1:
  es-data-hot-2:
  es-data-warm-1:
  es-data-warm-2:

networks:
  elastic:
    driver: bridge
```

- [ ] **Step 2: Validate compose**

Run: `docker compose config --quiet`
Expected: no output, exit 0.

- [ ] **Step 3: Start the cluster** (Docker/Colima must be running; Linux hosts: `sudo sysctl -w vm.max_map_count=262144`)

Run: `docker compose up -d es-master-1 es-master-2 es-master-3 es-hot-1 es-hot-2 es-warm-1 es-warm-2`

- [ ] **Step 4: Wait for green/yellow and verify cluster health**

Run:
```bash
source .env
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  https://localhost:9200/_cluster/health?pretty
```
Expected: JSON with `"number_of_nodes": 7` and `"status": "green"` or `"yellow"`.

- [ ] **Step 5: Verify node roles**

Run:
```bash
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  https://localhost:9200/_cat/nodes?v\&h=name,node.role
```
Expected: 3 nodes with role `m` (master), 2 with `dih`/`d` containing hot markers, 2 warm. Concretely: masters show `m`, hot nodes show roles including `h`, warm nodes include `w`.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: add 5-node elasticsearch topology to compose"
```

---

## Task 4: ILM policy, index template, and bootstrap

**Files:**
- Create: `policies/self-monitoring-policy.json`, `policies/self-monitoring-template.json`
- Create: `setup/bootstrap.sh`
- Modify: `docker-compose.yml` (append `setup` service)

- [ ] **Step 1: Create `policies/self-monitoring-policy.json`**

```json
{
  "policy": {
    "phases": {
      "hot": {
        "actions": {
          "rollover": {
            "max_age": "1d",
            "max_primary_shard_size": "5gb"
          },
          "set_priority": { "priority": 100 }
        }
      },
      "warm": {
        "min_age": "1d",
        "actions": {
          "set_priority": { "priority": 50 },
          "allocate": { "number_of_replicas": 1 },
          "forcemerge": { "max_num_segments": 1 }
        }
      },
      "delete": {
        "min_age": "7d",
        "actions": {
          "delete": {}
        }
      }
    }
  }
}
```

- [ ] **Step 2: Create `policies/self-monitoring-template.json`**

```json
{
  "index_patterns": ["self-monitoring-*"],
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1,
      "index.lifecycle.name": "self-monitoring-policy",
      "index.lifecycle.rollover_alias": "self-monitoring"
    }
  }
}
```

- [ ] **Step 3: Create `setup/bootstrap.sh`**

```sh
#!/bin/sh
# Waits for Elasticsearch, sets the kibana_system password, creates the ILM
# policy + index template, and bootstraps the first self-monitoring rollover
# index. Exits 0 so Kibana/Filebeat (depends_on) can start.
set -eu

ES="${ES_HOST:-https://es-hot-1:9200}"
AUTH="elastic:${ELASTIC_PASSWORD}"
CACERT="${CACERT:-/certs/ca/ca.crt}"

echo "Waiting for Elasticsearch at ${ES} ..."
until curl -fsS --cacert "$CACERT" -u "$AUTH" \
  "${ES}/_cluster/health?wait_for_status=yellow&timeout=2s" >/dev/null 2>&1; do
  echo "  not ready, retrying in 3s ..."
  sleep 3
done
echo "Elasticsearch is up."

echo "Setting kibana_system password ..."
curl -fsS --cacert "$CACERT" -u "$AUTH" -X POST \
  "${ES}/_security/user/kibana_system/_password" \
  -H 'Content-Type: application/json' \
  -d "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}"
echo

echo "Creating ILM policy self-monitoring-policy ..."
curl -fsS --cacert "$CACERT" -u "$AUTH" -X PUT \
  "${ES}/_ilm/policy/self-monitoring-policy" \
  -H 'Content-Type: application/json' \
  -d @/policies/self-monitoring-policy.json
echo

echo "Creating index template self-monitoring ..."
curl -fsS --cacert "$CACERT" -u "$AUTH" -X PUT \
  "${ES}/_index_template/self-monitoring" \
  -H 'Content-Type: application/json' \
  -d @/policies/self-monitoring-template.json
echo

echo "Bootstrapping first self-monitoring index ..."
curl -fsS --cacert "$CACERT" -u "$AUTH" -X PUT \
  "${ES}/self-monitoring-000001" \
  -H 'Content-Type: application/json' \
  -d '{"aliases":{"self-monitoring":{"is_write_index":true}}}'
echo

echo "Bootstrap complete."
```

- [ ] **Step 4: Make it executable**

Run: `chmod +x setup/bootstrap.sh`

- [ ] **Step 5: Append the `setup` service to `docker-compose.yml`**

Add inside `services:` (after `es-warm-2`):

```yaml
  setup:
    image: alpine:3.20
    container_name: setup
    depends_on:
      [es-master-1, es-master-2, es-master-3, es-hot-1, es-hot-2, es-warm-1, es-warm-2]
    environment:
      - ES_HOST=https://es-hot-1:9200
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - KIBANA_SYSTEM_PASSWORD=${KIBANA_SYSTEM_PASSWORD}
      - CACERT=/certs/ca/ca.crt
    volumes:
      - ./setup/bootstrap.sh:/setup/bootstrap.sh:ro
      - ./policies:/policies:ro
      - ./certs/ca:/certs/ca:ro
    command: >
      sh -c "apk add --no-cache curl >/dev/null 2>&1 && sh /setup/bootstrap.sh"
    restart: "no"
    networks: [elastic]
```

- [ ] **Step 6: Run setup**

Run: `docker compose up setup`
Expected: logs ending with `Bootstrap complete.`, container exits 0.

- [ ] **Step 7: Verify policy, template, and bootstrap index exist**

Run:
```bash
source .env
AUTH="elastic:${ELASTIC_PASSWORD}"
CACERT=certs/ca/ca.crt
curl -fsS --cacert "$CACERT" -u "$AUTH" https://localhost:9200/_ilm/policy/self-monitoring-policy?filter_path=**.phases | head -c 200
echo
curl -fsS --cacert "$CACERT" -u "$AUTH" https://localhost:9200/_alias/self-monitoring?pretty
```
Expected: first call returns JSON containing `"hot"`, `"warm"`, `"delete"` phases; second returns `self-monitoring-000001` with `"is_write_index": true`.

- [ ] **Step 8: Commit**

```bash
git add policies/ setup/bootstrap.sh docker-compose.yml
git commit -m "feat: add ILM policy, index template, and bootstrap setup service"
```

---

## Task 5: Kibana

**Files:**
- Create: `config/kibana.yml`
- Modify: `docker-compose.yml` (append `kibana` service)

- [ ] **Step 1: Create `config/kibana.yml`**

```yaml
server.name: kibana
server.host: "0.0.0.0"
server.publicBaseUrl: "http://localhost:5601"

elasticsearch.hosts: ["https://es-hot-1:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${KIBANA_SYSTEM_PASSWORD}"
elasticsearch.ssl.certificateAuthorities: ["/usr/share/kibana/config/certs/ca/ca.crt"]
```

- [ ] **Step 2: Append the `kibana` service to `docker-compose.yml`**

Add inside `services:` (after `setup`):

```yaml
  kibana:
    image: docker.elastic.co/kibana/kibana:${STACK_VERSION}
    container_name: kibana
    depends_on:
      setup:
        condition: service_completed_successfully
    environment:
      - ELASTICSEARCH_HOSTS=https://es-hot-1:9200
      - ELASTICSEARCH_USERNAME=kibana_system
      - ELASTICSEARCH_PASSWORD=${KIBANA_SYSTEM_PASSWORD}
      - ELASTICSEARCH_SSL_CERTIFICATEAUTHORITIES=config/certs/ca/ca.crt
    volumes:
      - ./config/kibana.yml:/usr/share/kibana/config/kibana.yml:ro
      - ./certs/ca:/usr/share/kibana/config/certs/ca:ro
    ports:
      - "5601:5601"
    networks: [elastic]
```

- [ ] **Step 3: Start Kibana**

Run: `docker compose up -d kibana`

- [ ] **Step 4: Verify Kibana responds**

Run: `curl -fsS http://localhost:5601/api/status | python3 -c 'import sys,json; print(json.load(sys.stdin)["status"]["overall"]["state"])'`
Expected: `green` (may take ~60s; retry until green/yellow).

- [ ] **Step 5: Commit**

```bash
git add config/kibana.yml docker-compose.yml
git commit -m "feat: add Kibana connected to the secured cluster"
```

---

## Task 6: Filebeat log shipper

**Files:**
- Create: `filebeat/filebeat.yml`
- Modify: `docker-compose.yml` (append `filebeat` service)

- [ ] **Step 1: Create `filebeat/filebeat.yml`**

```yaml
filebeat.autodiscover:
  providers:
    - type: docker
      hints.enabled: true
      templates:
        - condition.contains:
            docker.container.image: elastic
          config:
            - type: container
              paths:
                - /var/lib/docker/containers/${data.docker.container.id}/*.log

processors:
  - add_docker_metadata:
      host: "unix:///var/run/docker.sock"
  - add_host_metadata: ~

output.elasticsearch:
  hosts: ["https://es-hot-1:9200"]
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"
  ssl.certificate_authority: "/usr/share/filebeat/certs/ca/ca.crt"
  ssl.verification_mode: "full"
  index: "self-monitoring"

setup.ilm.enabled: false
setup.template.enabled: false
```

- [ ] **Step 2: Append the `filebeat` service to `docker-compose.yml`**

Add inside `services:` (after `kibana`):

```yaml
  filebeat:
    image: docker.elastic.co/beats/filebeat:${STACK_VERSION}
    container_name: filebeat
    user: root
    depends_on:
      setup:
        condition: service_completed_successfully
    environment:
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
    volumes:
      - ./filebeat/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro
      - ./certs/ca:/usr/share/filebeat/certs/ca:ro
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock
    command: filebeat -e -strict.perms=false
    networks: [elastic]
```

- [ ] **Step 3: Start Filebeat**

Run: `docker compose up -d filebeat`

- [ ] **Step 4: Wait ~30s, then verify logs arrived in `self-monitoring`**

Run:
```bash
source .env
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  'https://localhost:9200/self-monitoring/_count?pretty'
```
Expected: JSON with `"count"` greater than 0.

- [ ] **Step 5: Verify the events are stack-component logs**

Run:
```bash
source .env
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  'https://localhost:9200/self-monitoring/_search?size=1&pretty' \
  | python3 -c 'import sys,json; h=json.load(sys.stdin)["hits"]["hits"][0]["_source"]; print(h.get("container",{}).get("image",{}).get("name"), "|", h.get("message","")[:80])'
```
Expected: a line showing an `elasticsearch` or `kibana` image name and a log message.

- [ ] **Step 6: Commit**

```bash
git add filebeat/ docker-compose.yml
git commit -m "feat: add Filebeat shipping stack logs to self-monitoring"
```

---

## Task 7: Docs, screenshots dir, and ILM tier demo

**Files:**
- Create: `README.md`, `docs/architecture.md`, `docs/screenshots/.gitkeep`

- [ ] **Step 1: Create `docs/screenshots/.gitkeep`**

Empty file (so the dir is tracked). Content: a single newline is fine — create the file with no content.

- [ ] **Step 2: Create `docs/architecture.md`**

````markdown
# Architecture

```
                 ┌─────────────────────────────────────────────┐
                 │            Docker network: elastic          │
   :9200 ──────► es-hot-1, es-hot-2          (data_hot, ingest)
                 │ es-master-1/2/3            (master, quorum)  │
                 │ es-warm-1, es-warm-2       (data_warm)       │
                 │                                             │
                 │   setup ──► bootstraps secrets + ILM + idx  │
   :5601 ──────► kibana  (kibana_system ── HTTPS ──► ES)       │
                 │   filebeat ── autodiscover ──► self-monitoring │
                 └─────────────────────────────────────────────┘
```

## Fault tolerance

- 3 dedicated master nodes → quorum survives the loss of 1 master.
- Each data tier has 2 nodes with `number_of_replicas: 1` → the cluster keeps all shards available after losing any single data node, hot **or** warm.

## Data lifecycle

Component logs land in the `self-monitoring` rollover alias and are themselves managed by the `self-monitoring-policy` ILM policy: **hot** (rollover 1d / 5GB) → **warm** (allocate 1 replica, force-merge) → **delete** (7d). Shards move to `data_warm` nodes automatically via `_tier_preference`.
````

- [ ] **Step 3: Create `README.md`**

````markdown
# Elasticsearch 9.4.4 — secured 5-node cluster (homework)

Fault-tolerant Elasticsearch cluster with hot/warm ILM and self-monitoring.
The stack's own component logs (Elasticsearch + Kibana) are shipped by Filebeat
back into the cluster, into the `self-monitoring` index.

## Requirements

- Docker (Colima or Docker Desktop), ~12–16 GB RAM.
- Linux hosts only: `sudo sysctl -w vm.max_map_count=262144` (Docker Desktop sets this for you).

## Run

```bash
# 1. (optional) edit credentials
cp .env.example .env        # .env ships with demo creds; skip if you keep them

# 2. start the Docker daemon first, then generate certs
./setup/generate-certs.sh

# 3. bring everything up (setup auto-bootstraps secrets, ILM, and the index)
docker compose up -d
```

Wait ~90s, then:

- Kibana: <http://localhost:5601> — log in as `elastic` with `$ELASTIC_PASSWORD`.
- Cluster health:

```bash
source .env
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  https://localhost:9200/_cluster/health?pretty
```

## What to screenshot (for the assignment)

1. **Logs arriving in the cluster** — Kibana → Discover, data view `self-monitoring*`; or:
   `curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" https://localhost:9200/self-monitoring/_count`
2. **ILM policy** — Kibana → Stack Management → Data → Index Lifecycle Policies → `self-monitoring-policy`. Exported JSON is committed at `policies/self-monitoring-policy.json`.
3. **Hot → Warm transition** — see "Demonstrate the lifecycle" below, then Kibana → Index Management (a backing index shows `warm` tier).

Save screenshots under `docs/screenshots/`.

## Demonstrate the lifecycle (force a tier transition for the screenshot)

```bash
source .env
AUTH="elastic:${ELASTIC_PASSWORD}"; CACERT=certs/ca/ca.crt; ES=https://localhost:9200

# roll over: creates self-monitoring-000002, the old index is no longer the write index
curl -fsS --cacert "$CACERT" -u "$AUTH" -X POST "$ES/self-monitoring/_rollover"

# move self-monitoring-000001 into the warm phase immediately
curl -fsS --cacert "$CACERT" -u "$AUTH" -X POST "$ES/self-monitoring-000001/_ilm/move" \
  -H 'Content-Type: application/json' -d '{"current_step":{"phase":"hot"},"next_step_name":"warm"}'

# observe the shard now lives on a data_warm node
curl -fsS --cacert "$CACERT" -u "$AUTH" "$ES/_cat/indices/self-monitoring*?v&h=index,prirep,store,node"
```

## Export the ILM policy (deliverable JSON)

```bash
source .env
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  https://localhost:9200/_ilm/policy/self-monitoring-policy?pretty > ilm-export.json
```
(The canonical copy is already committed at `policies/self-monitoring-policy.json`.)

## Tear down

```bash
docker compose down -v   # -v also removes the ES data volumes
```

## Layout

See `docs/architecture.md` and the design spec at
`docs/superpowers/specs/2026-07-26-es-cluster-design.md`.
````

- [ ] **Step 4: Verify the rollover + warm move works** (live cluster from Tasks 3–6)

Run the three commands from the README "Demonstrate the lifecycle" block.
Expected: `_cat/indices/self-monitoring*` shows `self-monitoring-000001` allocated to a warm node (e.g. `es-warm-1`) and `self-monitoring-000002` on a hot node.

- [ ] **Step 5: Verify the ILM JSON export**

Run:
```bash
source .env
curl -fsS --cacert certs/ca/ca.crt -u "elastic:${ELASTIC_PASSWORD}" \
  https://localhost:9200/_ilm/policy/self-monitoring-policy?pretty | grep -E '"(hot|warm|delete)"'
```
Expected: lines containing `"hot"`, `"warm"`, `"delete"`.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/
git commit -m "docs: add README, architecture, and screenshots directory"
```

---

## Self-Review

**Spec coverage:**
- Topology (3 masters + 2 hot + 2 warm) → Task 3.
- Fault tolerance (1 data-node loss) → Task 3 (roles + `replicas` in Task 4 template).
- Security ON, certutil certs → Tasks 1–2.
- ILM hot+warm, exported JSON → Task 4 (`self-monitoring-policy.json`), verified Task 7.
- self-monitoring index + Filebeat → Tasks 4 + 6.
- Config files committed → Tasks 1–6.
- Screenshots dir + guide → Task 7.
- All gaps closed.

**Placeholder scan:** none. Every code step contains full content; every verify step has an exact command + expected output.

**Type/name consistency:** `self-monitoring-policy`, `self-monitoring-template`, `self-monitoring` alias, `self-monitoring-000001` used consistently across Tasks 4, 6, 7. `ELASTIC_PASSWORD` / `KIBANA_SYSTEM_PASSWORD` consistent in `.env`, configs, compose, scripts. Cert paths `certs/ca/ca.crt` + `certs/instance/node.{crt,key}` consistent in configs, generate-certs.sh, and mounts.
