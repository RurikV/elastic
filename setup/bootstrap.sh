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

echo "Bootstrapping first self-monitoring index (skipped if it already exists) ..."
if curl -fsS --cacert "$CACERT" -u "$AUTH" "${ES}/self-monitoring-000001" >/dev/null 2>&1; then
  echo "  self-monitoring-000001 already exists, skipping."
else
  curl -fsS --cacert "$CACERT" -u "$AUTH" -X PUT \
    "${ES}/self-monitoring-000001" \
    -H 'Content-Type: application/json' \
    -d '{"aliases":{"self-monitoring":{"is_write_index":true}}}'
fi
echo

echo "Bootstrap complete."
