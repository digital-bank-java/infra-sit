#!/usr/bin/env bash
set -euo pipefail

readonly CONTEXT="docker-desktop"
readonly NAMESPACE="digital-bank-sit"
readonly FIXTURE_RELEASE="transfer-acceptance-fixture"
readonly FIXTURE_USERNAME="transfer-orchestrator"
readonly SOURCE_ACCOUNT_ID="26100000-0000-4000-8000-000000000101"
readonly DESTINATION_ACCOUNT_ID="26100000-0000-4000-8000-000000000102"
readonly LEDGER_COMPLETED_TOPIC="ledger.posting.completed.v1"
readonly TRANSACTION_LEDGER_GROUP="transaction-service-ledger"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=false
RUN_DIR=""
EVIDENCE_FILE=""
PORT_FORWARD_PID=""
AUTH_SECRET_NAME=""
AUTH_PATCHED=false
LEDGER_PATCHED=false
TRANSACTION_REPLICAS=""
FIXTURE_PASSWORD=""
ACCESS_TOKEN=""

usage() {
  cat <<'EOF'
Usage: scripts/run-transfer-saga-acceptance.sh [--dry-run] [--help]

Runs the controlled local-SIT transfer-saga acceptance procedure. It only
operates against the docker-desktop context and digital-bank-sit namespace.

  --dry-run  Print the guarded workflow without reading or mutating SIT.
  --help     Show this help text.
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

new_id() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

write_evidence() {
  printf '%s\n' "$*" >> "$EVIDENCE_FILE"
}

cleanup() {
  local exit_code=$?
  set +e
  if [[ -n "$PORT_FORWARD_PID" ]]; then
    kill "$PORT_FORWARD_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$TRANSACTION_REPLICAS" ]]; then
    kubectl -n "$NAMESPACE" scale deployment/transaction-service --replicas="$TRANSACTION_REPLICAS" >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" rollout status deployment/transaction-service --timeout=5m >/dev/null 2>&1 || true
  fi
  if [[ "$LEDGER_PATCHED" == true ]]; then
    kubectl -n "$NAMESPACE" set env deployment/ledger-service \
      LEDGER_POSTING_ACCEPTANCE_FIXTURE_ENABLED- \
      LEDGER_POSTING_ACCEPTANCE_FIXTURE_POSTING_REQUEST_ID- >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" rollout status deployment/ledger-service --timeout=5m >/dev/null 2>&1 || true
  fi
  if [[ "$AUTH_PATCHED" == true && -n "$RUN_DIR" && -f "$RUN_DIR/auth-env-before.json" ]]; then
    kubectl -n "$NAMESPACE" patch deployment/auth-service --type=json \
      --patch "$(cat "$RUN_DIR/auth-env-before.json")" >/dev/null 2>&1 || true
    kubectl -n "$NAMESPACE" rollout status deployment/auth-service --timeout=5m >/dev/null 2>&1 || true
  fi
  if [[ -n "$AUTH_SECRET_NAME" ]]; then
    kubectl -n "$NAMESPACE" delete secret "$AUTH_SECRET_NAME" --ignore-not-found >/dev/null 2>&1 || true
  fi
  if [[ -n "$RUN_DIR" ]]; then
    rm -f "$RUN_DIR/auth-env-before.json" "$RUN_DIR/kafka-records.txt" 2>/dev/null || true
  fi
  unset FIXTURE_PASSWORD ACCESS_TOKEN
  exit "$exit_code"
}

run_sql() {
  local database=$1
  local query=$2
  kubectl -n "$NAMESPACE" exec statefulset/postgres -- sh -ec \
    'psql --username "$POSTGRES_USER" --dbname "$1" --tuples-only --no-align --command "$2"' \
    sh "$database" "$query"
}

wait_for_transfer_status() {
  local transfer_id=$1
  local expected_status=$2
  local attempt response status
  for attempt in $(seq 1 60); do
    response="$(curl --silent --show-error --fail-with-body \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$GATEWAY_URL/internal/v1/transfer-workflows/$transfer_id")" || die "cannot read transfer workflow $transfer_id"
    status="$(jq -er '.status' <<<"$response")" || die "transfer response does not contain status"
    if [[ "$status" == "$expected_status" ]]; then
      write_evidence "transfer_id=$transfer_id status=$status"
      return
    fi
    sleep 2
  done
  die "transfer $transfer_id did not reach $expected_status"
}

wait_for_auth_route() {
  local attempt http_status
  for attempt in $(seq 1 60); do
    http_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data '{"username":"acceptance-route-probe","password":"invalid"}' \
      "$GATEWAY_URL/api/v1/auth/login")" || http_status=000
    case "$http_status" in
      400|401|422) return ;;
    esac
    sleep 2
  done
  die "API Gateway Auth route did not become ready after the Auth rollout"
}

request_transfer() {
  local scenario=$1
  local amount=$2
  local transfer_id=$3
  local correlation_id=$4
  local transfer_request_id=$5
  local reservation_request_id=$6
  local posting_request_id=$7
  local response http_status body
  body="$(jq -nc \
    --arg transferId "$transfer_id" \
    --arg sourceAccountId "$SOURCE_ACCOUNT_ID" \
    --arg destinationAccountId "$DESTINATION_ACCOUNT_ID" \
    --arg amount "$amount" \
    --arg correlationId "$correlation_id" \
    --arg transferRequestId "$transfer_request_id" \
    --arg reservationRequestId "$reservation_request_id" \
    --arg postingRequestId "$posting_request_id" \
    '{transferId:$transferId,sourceAccountId:$sourceAccountId,destinationAccountId:$destinationAccountId,amount:($amount|tonumber),currency:"AED",correlationId:$correlationId,transferRequestId:$transferRequestId,reservationRequestId:$reservationRequestId,postingRequestId:$postingRequestId,channel:"INTERNAL",destinationClass:"INTERNAL"}')"
  response="$(curl --silent --show-error --write-out $'\n%{http_code}' \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$body" \
    "$GATEWAY_URL/internal/v1/transfer-workflows")" || die "gateway request failed for $scenario"
  http_status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  [[ "$http_status" == 201 ]] || die "$scenario transfer was not created (HTTP $http_status)"
  jq -e --arg id "$transfer_id" --arg posting "$posting_request_id" \
    '.transferId == $id and .postingRequestId == $posting' <<<"$body" >/dev/null \
    || die "$scenario transfer response does not match its requested identifiers"
  write_evidence "scenario=$scenario http_status=$http_status transfer_id=$transfer_id correlation_id=$correlation_id posting_request_id=$posting_request_id"
}

capture_ledger_offset() {
  local correlation_id=$1
  local record partition offset
  kubectl -n "$NAMESPACE" exec statefulset/kafka -- \
    /opt/kafka/bin/kafka-console-consumer.sh \
      --bootstrap-server kafka:9092 \
      --topic "$LEDGER_COMPLETED_TOPIC" \
      --from-beginning --timeout-ms 10000 \
      --property print.partition=true --property print.offset=true --property print.value=true \
      > "$RUN_DIR/kafka-records.txt"
  record="$(rg -m1 "\"correlationId\":\"$correlation_id\"" "$RUN_DIR/kafka-records.txt" || true)"
  [[ -n "$record" ]] || die "cannot locate the original ledger completion record for $correlation_id"
  partition="$(sed -n 's/.*Partition:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$record")"
  offset="$(sed -n 's/.*Offset:[[:space:]]*\([0-9][0-9]*\).*/\1/p' <<<"$record")"
  [[ -n "$partition" && -n "$offset" ]] || die "Kafka console output does not expose partition and offset"
  DUPLICATE_PARTITION=$partition
  DUPLICATE_OFFSET=$offset
  write_evidence "duplicate_topic=$LEDGER_COMPLETED_TOPIC duplicate_partition=$partition duplicate_offset=$offset"
  rm -f "$RUN_DIR/kafka-records.txt"
}

patch_auth_fixture() {
  local deployment container_index username_index hash_index patch
  deployment="$(kubectl -n "$NAMESPACE" get deployment/auth-service -o json)"
  container_index="$(jq -er '[.spec.template.spec.containers[].name] | index("auth-service")' <<<"$deployment")" \
    || die "auth-service container contract is missing"
  username_index="$(jq -er --argjson container "$container_index" \
    '.spec.template.spec.containers[$container].env | map(.name) | index("AUTH_FIXTURE_USERNAME")' <<<"$deployment")" \
    || die "AUTH_FIXTURE_USERNAME reference is missing"
  hash_index="$(jq -er --argjson container "$container_index" \
    '.spec.template.spec.containers[$container].env | map(.name) | index("AUTH_FIXTURE_PASSWORD_HASH")' <<<"$deployment")" \
    || die "AUTH_FIXTURE_PASSWORD_HASH reference is missing"
  jq -e --argjson container "$container_index" --argjson username "$username_index" --argjson hash "$hash_index" \
    '.spec.template.spec.containers[$container].env[$username].valueFrom.secretKeyRef and .spec.template.spec.containers[$container].env[$hash].valueFrom.secretKeyRef' \
    <<<"$deployment" >/dev/null || die "auth fixture variables are not Secret references"
  patch="$(jq -nc --argjson container "$container_index" --argjson username "$username_index" --argjson hash "$hash_index" \
    --arg secret "$AUTH_SECRET_NAME" \
    '[
      {op:"replace",path:("/spec/template/spec/containers/" + ($container|tostring) + "/env/" + ($username|tostring)),value:{name:"AUTH_FIXTURE_USERNAME",valueFrom:{secretKeyRef:{name:$secret,key:"fixture-username"}}}},
      {op:"replace",path:("/spec/template/spec/containers/" + ($container|tostring) + "/env/" + ($hash|tostring)),value:{name:"AUTH_FIXTURE_PASSWORD_HASH",valueFrom:{secretKeyRef:{name:$secret,key:"fixture-password-hash"}}}}
    ]')"
  jq -nc --argjson container "$container_index" --argjson username "$username_index" --argjson hash "$hash_index" \
    --argjson deployment "$deployment" \
    '[
      {op:"replace",path:("/spec/template/spec/containers/" + ($container|tostring) + "/env/" + ($username|tostring)),value:$deployment.spec.template.spec.containers[$container].env[$username]},
      {op:"replace",path:("/spec/template/spec/containers/" + ($container|tostring) + "/env/" + ($hash|tostring)),value:$deployment.spec.template.spec.containers[$container].env[$hash]}
    ]' > "$RUN_DIR/auth-env-before.json"
  kubectl -n "$NAMESPACE" patch deployment/auth-service --type=json --patch "$patch" >/dev/null
  AUTH_PATCHED=true
  kubectl -n "$NAMESPACE" rollout status deployment/auth-service --timeout=5m
}

patch_ledger_failure() {
  local posting_request_id=$1 existing
  existing="$(kubectl -n "$NAMESPACE" get deployment/ledger-service -o json)"
  jq -e '.spec.template.spec.containers[] | select(.name == "ledger-service") | .env[]? | select(.name == "LEDGER_POSTING_ACCEPTANCE_FIXTURE_ENABLED" or .name == "LEDGER_POSTING_ACCEPTANCE_FIXTURE_POSTING_REQUEST_ID")' \
    <<<"$existing" >/dev/null && die "ledger acceptance fixture variables are already present"
  jq -e '.spec.template.spec.containers[] | select(.name == "ledger-service") | .env[]? | select(.name == "SPRING_PROFILES_ACTIVE" and .value == "sit")' \
    <<<"$existing" >/dev/null || die "ledger-service is not configured with exactly the sit profile"
  kubectl -n "$NAMESPACE" set env deployment/ledger-service \
    LEDGER_POSTING_ACCEPTANCE_FIXTURE_ENABLED=true \
    LEDGER_POSTING_ACCEPTANCE_FIXTURE_POSTING_REQUEST_ID="$posting_request_id" >/dev/null
  LEDGER_PATCHED=true
  kubectl -n "$NAMESPACE" rollout status deployment/ledger-service --timeout=5m
}

replay_original_ledger_completion() {
  local transfer_id=$1
  TRANSACTION_REPLICAS="$(kubectl -n "$NAMESPACE" get deployment/transaction-service -o jsonpath='{.spec.replicas}')"
  [[ "$TRANSACTION_REPLICAS" =~ ^[1-9][0-9]*$ ]] || die "transaction-service must have active replicas before replay"
  kubectl -n "$NAMESPACE" scale deployment/transaction-service --replicas=0 >/dev/null
  kubectl -n "$NAMESPACE" rollout status deployment/transaction-service --timeout=5m
  kubectl -n "$NAMESPACE" exec statefulset/kafka -- \
    /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server kafka:9092 \
      --group "$TRANSACTION_LEDGER_GROUP" --topic "$LEDGER_COMPLETED_TOPIC:$DUPLICATE_PARTITION" \
      --reset-offsets --to-offset "$DUPLICATE_OFFSET" --execute
  kubectl -n "$NAMESPACE" scale deployment/transaction-service --replicas="$TRANSACTION_REPLICAS" >/dev/null
  kubectl -n "$NAMESPACE" rollout status deployment/transaction-service --timeout=5m
  TRANSACTION_REPLICAS=""
  wait_for_transfer_status "$transfer_id" COMPLETED
  local terminal_count
  terminal_count="$(run_sql transaction_service "SELECT count(*) FROM transfer_terminal_event_outbox WHERE transaction_id = '$transfer_id';")"
  [[ "$terminal_count" == 1 ]] || die "duplicate delivery changed terminal transfer evidence"
  write_evidence "duplicate_terminal_outbox_count=$terminal_count transfer_id=$transfer_id"
}

for argument in "$@"; do
  case "$argument" in
    --help) usage; exit 0 ;;
    --dry-run) DRY_RUN=true ;;
    *) die "unknown argument: $argument" ;;
  esac
done

for required in kubectl helm curl jq openssl htpasswd uuidgen rg; do
  require_command "$required"
done

if [[ "$DRY_RUN" == true ]]; then
  cat <<'EOF'
Dry run: no Kubernetes, Helm, gateway, Kafka, database, Secret, or deployment
operation will be performed. A normal run validates docker-desktop and
digital-bank-sit, installs the opt-in fixture, uses a temporary Auth Secret,
executes three real transfer workflows, resets only the original ledger
completion offset for transaction-service-ledger, records redacted evidence,
and restores every temporary deployment or Secret change through a trap.
EOF
  exit 0
fi

umask 077
RUN_DIR="$ROOT_DIR/tmp/transfer-saga-acceptance/$(date -u +%Y%m%dT%H%M%SZ)-$(new_id)"
mkdir -p "$RUN_DIR"
chmod 700 "$RUN_DIR"
EVIDENCE_FILE="$RUN_DIR/evidence.txt"
trap cleanup EXIT INT TERM

[[ "$(kubectl config current-context)" == "$CONTEXT" ]] || die "Kubernetes context must be $CONTEXT"
kubectl get namespace "$NAMESPACE" >/dev/null || die "namespace $NAMESPACE is unavailable"
for resource in deployment/auth-service deployment/ledger-service deployment/transaction-service service/api-gateway statefulset/postgres statefulset/kafka; do
  kubectl -n "$NAMESPACE" get "$resource" >/dev/null || die "required SIT resource is unavailable: $resource"
done

kubectl -n "$NAMESPACE" port-forward service/api-gateway 18080:8080 > "$RUN_DIR/port-forward.log" 2>&1 &
PORT_FORWARD_PID=$!
for _ in $(seq 1 20); do
  curl --silent --output /dev/null --write-out '%{http_code}' http://127.0.0.1:18080/api/v1/auth/login | rg -q '^(405|415)$' && break
  sleep 1
done
kill -0 "$PORT_FORWARD_PID" >/dev/null 2>&1 || die "API Gateway port-forward exited before becoming ready"
GATEWAY_URL="http://127.0.0.1:18080"
gateway_status="$(curl --silent --output /dev/null --write-out '%{http_code}' "$GATEWAY_URL/internal/v1/transfer-workflows/00000000-0000-0000-0000-000000000000")"
[[ "$gateway_status" == 401 || "$gateway_status" == 403 ]] || die "gateway does not expose the governed transfer workflow route"

helm upgrade --install "$FIXTURE_RELEASE" "$ROOT_DIR/helm/transfer-acceptance-fixture" \
  --namespace "$NAMESPACE" --values "$ROOT_DIR/helm/transfer-acceptance-fixture/values-sit.yaml" \
  --set fixtures.enabled=true --wait --timeout 5m
fixture_source_balance="$(run_sql account_service "SELECT current_balance || ':' || available_balance FROM accounts WHERE id = '$SOURCE_ACCOUNT_ID';" | tr -d '[:space:]')"
fixture_destination_balance="$(run_sql account_service "SELECT current_balance || ':' || available_balance FROM accounts WHERE id = '$DESTINATION_ACCOUNT_ID';" | tr -d '[:space:]')"
fixture_ledger_line_count="$(run_sql ledger_service "SELECT count(*) FROM ledger_entry_lines WHERE entry_id = '26100000-0000-4000-8000-000000000201';" | tr -d '[:space:]')"
fixture_ledger_net="$(run_sql ledger_service "SELECT COALESCE(SUM(CASE WHEN line_type = 'DEBIT' THEN amount ELSE -amount END), 999999) FROM ledger_entry_lines WHERE entry_id = '26100000-0000-4000-8000-000000000201';" | tr -d '[:space:]')"
[[ "$fixture_source_balance" == "1000.0000:1000.0000" ]] || die "SIT source fixture balance does not match the approved seed"
[[ "$fixture_destination_balance" == "0.0000:0.0000" ]] || die "SIT destination fixture balance does not match the approved seed"
[[ "$fixture_ledger_line_count" == 2 && "$fixture_ledger_net" == "0.0000" ]] || die "SIT opening ledger fixture is not a balanced two-line entry"
write_evidence "fixture_source_balance=$fixture_source_balance fixture_destination_balance=$fixture_destination_balance"
write_evidence "fixture_ledger_line_count=$fixture_ledger_line_count fixture_ledger_net=$fixture_ledger_net"

FIXTURE_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
FIXTURE_HASH="$(printf '%s\n' "$FIXTURE_PASSWORD" | htpasswd -niBC 12 "$FIXTURE_USERNAME" | sed 's/^[^:]*://')"
AUTH_SECRET_NAME="transfer-acceptance-auth-$(new_id)"
kubectl -n "$NAMESPACE" create secret generic "$AUTH_SECRET_NAME" \
  --from-literal=fixture-username="$FIXTURE_USERNAME" \
  --from-literal=fixture-password-hash="$FIXTURE_HASH" >/dev/null
unset FIXTURE_HASH
patch_auth_fixture
wait_for_auth_route

login_response="$(curl --silent --show-error --fail-with-body -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg username "$FIXTURE_USERNAME" --arg password "$FIXTURE_PASSWORD" '{username:$username,password:$password}')" \
  "$GATEWAY_URL/api/v1/auth/login")" || die "fixture login failed"
ACCESS_TOKEN="$(jq -er '.accessToken' <<<"$login_response")" || die "login response does not contain accessToken"
unset login_response FIXTURE_PASSWORD

success_transfer_id="$(new_id)"
success_correlation="transfer-acceptance-success-$(new_id)"
request_transfer success 10.0000 "$success_transfer_id" "$success_correlation" "request-$(new_id)" "reservation-$(new_id)" "posting-$(new_id)"
wait_for_transfer_status "$success_transfer_id" COMPLETED
success_source_balance="$(run_sql account_service "SELECT current_balance || ':' || available_balance FROM accounts WHERE id = '$SOURCE_ACCOUNT_ID';" | tr -d '[:space:]')"
success_destination_balance="$(run_sql account_service "SELECT current_balance || ':' || available_balance FROM accounts WHERE id = '$DESTINATION_ACCOUNT_ID';" | tr -d '[:space:]')"
[[ "$success_source_balance" == "990.0000:990.0000" ]] || die "successful transfer did not project the source debit"
[[ "$success_destination_balance" == "10.0000:10.0000" ]] || die "successful transfer did not project the destination credit"
write_evidence "success_source_balance=$success_source_balance success_destination_balance=$success_destination_balance"

insufficient_transfer_id="$(new_id)"
insufficient_reservation_request_id="reservation-$(new_id)"
request_transfer insufficient-funds 1001.0000 "$insufficient_transfer_id" "transfer-acceptance-insufficient-$(new_id)" "request-$(new_id)" "$insufficient_reservation_request_id" "posting-$(new_id)"
wait_for_transfer_status "$insufficient_transfer_id" FAILED
insufficient_reservation_count="$(run_sql account_service "SELECT count(*) FROM account_reservations WHERE reservation_request_id = '$insufficient_reservation_request_id';" | tr -d '[:space:]')"
[[ "$insufficient_reservation_count" == 0 ]] || die "insufficient-funds transfer left a reservation row"
write_evidence "insufficient_reservation_count=$insufficient_reservation_count"

failure_transfer_id="$(new_id)"
failure_posting_request_id="posting-$(new_id)"
failure_reservation_request_id="reservation-$(new_id)"
patch_ledger_failure "$failure_posting_request_id"
request_transfer ledger-compensation 5.0000 "$failure_transfer_id" "transfer-acceptance-ledger-failure-$(new_id)" "request-$(new_id)" "$failure_reservation_request_id" "$failure_posting_request_id"
wait_for_transfer_status "$failure_transfer_id" FAILED
failure_reservation_status="$(run_sql account_service "SELECT status FROM account_reservations WHERE reservation_request_id = '$failure_reservation_request_id';" | tr -d '[:space:]')"
[[ "$failure_reservation_status" == "RELEASED" ]] || die "ledger failure did not release the account reservation"
write_evidence "failure_reservation_status=$failure_reservation_status"
kubectl -n "$NAMESPACE" set env deployment/ledger-service \
  LEDGER_POSTING_ACCEPTANCE_FIXTURE_ENABLED- \
  LEDGER_POSTING_ACCEPTANCE_FIXTURE_POSTING_REQUEST_ID- >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/ledger-service --timeout=5m
LEDGER_PATCHED=false

capture_ledger_offset "$success_correlation"
replay_original_ledger_completion "$success_transfer_id"
write_evidence "result=completed context=$CONTEXT namespace=$NAMESPACE"
log "Acceptance evidence written to $EVIDENCE_FILE"
