#!/usr/bin/env bash
set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../helm/fluent-bit" && pwd)"
container="fluent-bit-docker-mode-validation"
tmpdir="$(mktemp -d)"
sit_rendered="$(mktemp)"
default_rendered="$(mktemp)"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
  rm -f "$sit_rendered" "$default_rendered"
}
trap cleanup EXIT

helm template fluent-bit "$chart_dir" \
  --namespace digital-bank-sit \
  --values "$chart_dir/values-sit.yaml" > "$sit_rendered"

helm template fluent-bit "$chart_dir" \
  --namespace digital-bank-sit \
  --values "$chart_dir/values.yaml" > "$default_rendered"

grep -q 'Path                  /var/lib/docker/containers/\*/\*-json.log' "$sit_rendered"
grep -q 'Parser                docker' "$sit_rendered"
grep -q 'Tag                   docker.\*' "$sit_rendered"
grep -q 'DB                    /var/lib/fluent-bit/docker-tail.db' "$sit_rendered"
grep -q 'Key_Name              _docker_raw_log' "$sit_rendered"
grep -q 'call                  prepare_docker_record' "$sit_rendered"
grep -q 'call                  process_docker_record' "$sit_rendered"
grep -q 'Name                  parser' "$sit_rendered"
grep -q 'Path: /var/lib/docker/containers' "$sit_rendered"
grep -q 'mountPath: /var/lib/docker/containers' "$sit_rendered"
grep -q 'readOnly: true' "$sit_rendered"
grep -q 'io.kubernetes.pod.name' "$sit_rendered"
grep -q 'io.kubernetes.pod.namespace' "$sit_rendered"
grep -q 'io.kubernetes.container.name' "$sit_rendered"
grep -q 'io.kubernetes.pod.uid' "$sit_rendered"
grep -q 'io.kubernetes.container.logpath' "$sit_rendered"
grep -q 'config.v2.json' "$sit_rendered"
grep -q 'logging_source.*docker-json' "$sit_rendered"
grep -q 'Retry_Limit           False' "$sit_rendered"
grep -q 'storage.total_limit_size' "$sit_rendered"

! grep -q 'Path                  /var/lib/docker/containers/\*/\*-json.log' "$default_rendered"
! grep -q 'mountPath: /var/lib/docker/containers' "$default_rendered"

grep -q 'Path                  /var/log/containers/\*.log' "$sit_rendered"
grep -q 'Kube_Tag_Prefix       kube.var.log.containers.' "$sit_rendered"
grep -q 'Merge_Log_Key         structured' "$sit_rendered"

config_block="$(awk '/^  redact.lua: \|$/{capture=1; next} /^---$/{capture=0} capture{sub(/^    /," "); print}' "$sit_rendered")"
! grep -q 'record\["config"\]' <<<"$config_block"
! grep -q 'record\["Config"\]' <<<"$config_block"
! grep -q 'record\["Env"\]' <<<"$config_block"
grep -q 'record\["kubernetes"\]' <<<"$config_block"

id="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
mkdir -p "$tmpdir/containers/$id"
printf '%s\n' \
  '{"log":"{\"message\":\"accepted\",\"password\":\"app-secret\",\"clientSecret\":\"nested-secret\"}\n","stream":"stdout","time":"2026-09-06T10:00:00.000000000Z"}' \
  '{"log":"plain password=plain-secret token=plain-token\n","stream":"stdout","time":"2026-09-06T10:00:01.000000000Z"}' \
  '{"log":"{\"password\":\"unterminated\n","stream":"stdout","time":"2026-09-06T10:00:02.000000000Z"}' \
  > "$tmpdir/containers/$id/$id-json.log"

printf '%s\n' \
  '{"Config":{"Labels":{"io.kubernetes.pod.name":"orders-7d9f","io.kubernetes.pod.namespace":"digital-bank-sit","io.kubernetes.container.name":"orders","io.kubernetes.pod.uid":"pod-uid-123","io.kubernetes.container.logpath":"/var/log/pods/orders.log","ignored":"not-emitted"}},"Config.Env":["PASSWORD=config-env-secret"]}' \
  > "$tmpdir/containers/$id/config.v2.json"

awk '/^  redact.lua: \|$/{capture=1; next} /^---$/{capture=0} capture{sub(/^    /," "); print}' \
  "$sit_rendered" > "$tmpdir/redact.lua"
awk '/^  parsers.conf: \|$/{capture=1; next} /^  redact.lua: \|$/{capture=0} capture{sub(/^    /,""); print}' \
  "$sit_rendered" > "$tmpdir/parsers.conf"

printf '%s\n' \
  '[SERVICE]' \
  '    Flush 1' \
  '    Grace 1' \
  '    Parsers_File /fluent-bit/etc/parsers.conf' \
  '' \
  '[INPUT]' \
  '    Name tail' \
  '    Path /var/lib/docker/containers/*/*-json.log' \
  '    Parser docker' \
  '    Tag docker.*' \
  '    Read_from_Head On' \
  '    DB /tmp/docker-tail.db' \
  '' \
  '[FILTER]' \
  '    Name lua' \
  '    Match docker.*' \
  '    script /fluent-bit/scripts/redact.lua' \
  '    call prepare_docker_record' \
  '' \
  '[FILTER]' \
  '    Name parser' \
  '    Match docker.*' \
  '    Key_Name _docker_raw_log' \
  '    Parser json' \
  '    Preserve_Key Off' \
  '    Reserve_Data On' \
  '' \
  '[FILTER]' \
  '    Name lua' \
  '    Match docker.*' \
  '    script /fluent-bit/scripts/redact.lua' \
  '    call process_docker_record' \
  '' \
  '[OUTPUT]' \
  '    Name stdout' \
  '    Match docker.*' > "$tmpdir/fluent-bit.conf"

docker run -d --name "$container" \
  -v "$tmpdir/fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf:ro" \
  -v "$tmpdir/parsers.conf:/fluent-bit/etc/parsers.conf:ro" \
  -v "$tmpdir/redact.lua:/fluent-bit/scripts/redact.lua:ro" \
  -v "$tmpdir/containers:/var/lib/docker/containers:ro" \
  fluent/fluent-bit:3.2.10 \
  --config=/fluent-bit/etc/fluent-bit.conf >/dev/null

sleep 3
docker logs "$container" > "$tmpdir/output" 2>&1

grep -q 'orders-7d9f' "$tmpdir/output"
grep -q 'digital-bank-sit' "$tmpdir/output"
grep -q 'container_name"=>"orders"' "$tmpdir/output"
grep -q 'pod_uid"=>"pod-uid-123"' "$tmpdir/output"
grep -q 'log_path"=>"/var/log/pods/orders.log"' "$tmpdir/output"
grep -q 'structured' "$tmpdir/output"
grep -q 'logging_parse_status"=>"valid"' "$tmpdir/output"
grep -q 'logging_parse_status"=>"unstructured"' "$tmpdir/output"
grep -q 'logging_parse_status"=>"invalid"' "$tmpdir/output"
grep -q 'REDACTED_INVALID_STRUCTURED_LOG' "$tmpdir/output"
grep -q 'password"=>"\[REDACTED\]' "$tmpdir/output"
grep -q 'password=\[REDACTED\]' "$tmpdir/output"
grep -q 'token=\[REDACTED\]' "$tmpdir/output"
! grep -Eq 'app-secret|nested-secret|plain-secret|plain-token|config-env-secret|ignored|config.v2.json' "$tmpdir/output"

echo "Fluent Bit Docker Desktop fallback validation passed"
