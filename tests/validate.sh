#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/opensearch" && pwd)"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT

helm lint "$chart_dir" --values "$chart_dir/values-sit.yaml"
helm template opensearch "$chart_dir" \
  --namespace digital-bank-sit \
  --values "$chart_dir/values-sit.yaml" > "$rendered"

kubectl create --dry-run=client --validate=false -f "$rendered" >/dev/null

test "$(grep -c 'name: Authorization' "$rendered")" -eq 3
grep -q 'value: Basic a2liYW5hc2VydmVyOmtpYmFuYXNlcnZlcg==' "$rendered"
grep -q 'opensearch.requestHeadersAllowlist' "$rendered"
! grep -q 'opensearch.requestHeadersWhitelist' "$rendered"

echo "OpenSearch chart validation passed"
