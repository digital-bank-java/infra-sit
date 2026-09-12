#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/opensearch" && pwd)"
if [ -n "${RENDERED_FILE:-}" ]; then
  rendered="$RENDERED_FILE"
else
  rendered="$(mktemp)"
  trap 'rm -f "$rendered"' EXIT
  helm lint "$chart_dir" --values "$chart_dir/values-sit.yaml"
  helm template opensearch "$chart_dir" \
    --namespace digital-bank-sit \
    --values "$chart_dir/values-sit.yaml" > "$rendered"
fi

test "$(grep -c 'name: OPENSEARCH_DASHBOARDS_PASSWORD' "$rendered")" -eq 2
grep -q 'opensearch.username: "kibanaserver"' "$rendered"
grep -q 'opensearch.password: ${OPENSEARCH_DASHBOARDS_PASSWORD}' "$rendered"
! grep -q 'name: OPENSEARCH_DASHBOARDS_USERNAME' "$rendered"
grep -q 'kind: Job' "$rendered"
grep -q '"helm.sh/hook": post-install,post-upgrade' "$rendered"
grep -q 'securityadmin.sh' "$rendered"
grep -q -- '-backup' "$rendered"
grep -q 'internal_users.yml' "$rendered"
grep -q -- '-t internalusers' "$rendered"
grep -q 'kibanaserver' "$rendered"
! grep -q 'OPENSEARCH_DASHBOARDS_USERNAME' "$rendered"
! grep -q 'opensearch.password: kibanaserver' "$rendered"
grep -q 'opensearch.requestHeadersAllowlist' "$rendered"
! grep -q 'opensearch.requestHeadersWhitelist' "$rendered"
grep -q 'name: OPENSEARCH_INITIAL_ADMIN_PASSWORD' "$rendered"
grep -q 'key: OPENSEARCH_INITIAL_ADMIN_PASSWORD' "$rendered"
grep -q 'install_demo_configuration.sh' "$rendered"
grep -q 'helm.sh/chart: opensearch-0.1.0' "$rendered"

echo "OpenSearch chart validation passed"
