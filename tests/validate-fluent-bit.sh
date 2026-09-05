#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/fluent-bit" && pwd)"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm lint "$chart_dir" --values "$chart_dir/values-sit.yaml"
helm template fluent-bit "$chart_dir" \
  --namespace digital-bank-sit \
  --values "$chart_dir/values-sit.yaml" > "$rendered"

for kind in ServiceAccount ClusterRole ClusterRoleBinding ConfigMap DaemonSet Service; do
  grep -q "^kind: ${kind}$" "$rendered"
done

grep -q 'Name                  kubernetes' "$rendered"
grep -q 'Merge_Parser          json' "$rendered"
grep -q 'Merge_Log_Key         structured' "$rendered"
grep -q 'structured_json_parse_failed' "$rendered"
grep -q 'Retry_Limit           False' "$rendered"
grep -q 'storage.total_limit_size' "$rendered"
grep -q 'OPENSEARCH_HOST' "$rendered"
grep -q 'opensearch-admin' "$rendered"

bash "$(dirname "${BASH_SOURCE[0]}")/validate-redaction.sh"
bash "$(dirname "${BASH_SOURCE[0]}")/validate-fluent-bit-docker.sh"

echo "Fluent Bit chart validation passed"
