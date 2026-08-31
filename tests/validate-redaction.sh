#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/fluent-bit" && pwd)"
tmpdir="$(mktemp -d)"
container="fluent-bit-redaction-validation"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

rendered="$tmpdir/rendered.yaml"
helm template fluent-bit "$chart_dir" \
  --namespace digital-bank-sit \
  --values "$chart_dir/values-sit.yaml" > "$rendered"

awk '/^  redact.lua: \|$/{capture=1; next} /^---$/{capture=0} capture{sub(/^    /,""); print}' \
  "$rendered" > "$tmpdir/redact.lua"

printf '%s\n' \
  '[SERVICE]' \
  '    Flush 1' \
  '    Grace 1' \
  '' \
  '[INPUT]' \
  '    Name dummy' \
  '    Tag kube.test' \
  '    Dummy {"log":"2026-08-30 21:00:00.000 INFO app : Spring application started password=password-value-123 token=token-value-456 authorization=authorization-value-789 secret=secret-value-abc api_key=api-key-value-def client_secret=client-secret-value-ghi Bearer bearer-value-jkl"}' \
  '' \
  '[INPUT]' \
  '    Name dummy' \
  '    Tag kube.structured' \
  '    Dummy {"structured":{"apiKey":"camel-api-key-value","clientSecret":"camel-client-secret-value","secret":"structured-secret-value"}}' \
  '' \
  '[FILTER]' \
  '    Name lua' \
  '    Match kube.*' \
  '    script /fluent-bit/scripts/redact.lua' \
  '    call process_record' \
  '' \
  '[OUTPUT]' \
  '    Name stdout' \
  '    Match kube.*' > "$tmpdir/fluent-bit.conf"

docker run -d --name "$container" \
  -v "$tmpdir/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro" \
  -v "$tmpdir/redact.lua:/fluent-bit/scripts/redact.lua:ro" \
  fluent/fluent-bit:3.2.10 \
  --config=/fluent-bit/etc/fluent-bit.conf >/dev/null

sleep 3
docker logs "$container" > "$tmpdir/output" 2>&1

grep -q 'Spring application started' "$tmpdir/output"
grep -q 'logging_parse_status"=>"unstructured"' "$tmpdir/output"
grep -q 'logging_invalid_event"=>false' "$tmpdir/output"
grep -q 'Bearer \[REDACTED\]' "$tmpdir/output"
grep -q 'password=\[REDACTED\]' "$tmpdir/output"
grep -q 'token=\[REDACTED\]' "$tmpdir/output"
grep -q 'authorization=\[REDACTED\]' "$tmpdir/output"
grep -q 'secret=\[REDACTED\]' "$tmpdir/output"
grep -q 'api_key=\[REDACTED\]' "$tmpdir/output"
grep -q 'client_secret=\[REDACTED\]' "$tmpdir/output"
grep -q 'apiKey.*\[REDACTED\]' "$tmpdir/output"
grep -q 'clientSecret.*\[REDACTED\]' "$tmpdir/output"
! grep -Eq 'password-value-123|token-value-456|authorization-value-789|secret-value-abc|api-key-value-def|client-secret-value-ghi|bearer-value-jkl|camel-api-key-value|camel-client-secret-value|structured-secret-value' "$tmpdir/output"

echo "Fluent Bit plain-text redaction validation passed"
