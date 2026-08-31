#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/opensearch" && pwd)"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm lint "$chart_dir" --values "$chart_dir/values-sit.yaml"
helm template opensearch "$chart_dir" \
  --namespace digital-bank-sit \
  --values "$chart_dir/values-sit.yaml" > "$rendered"

test "$(grep -c 'name: OPENSEARCH_DASHBOARDS_' "$rendered")" -eq 2
grep -q 'opensearch.username: ${OPENSEARCH_DASHBOARDS_USERNAME}' "$rendered"
grep -q 'opensearch.password: ${OPENSEARCH_DASHBOARDS_PASSWORD}' "$rendered"
! grep -q 'kibanaserver' "$rendered"
grep -q 'opensearch.requestHeadersAllowlist' "$rendered"
! grep -q 'opensearch.requestHeadersWhitelist' "$rendered"

echo "OpenSearch chart validation passed"
