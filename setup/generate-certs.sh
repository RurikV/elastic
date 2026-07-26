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
