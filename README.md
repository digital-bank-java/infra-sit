# Infra SIT

Local Kubernetes infrastructure for the Digital Bank Java platform.

This repository owns shared infrastructure used to run the integrated local SIT environment on Docker Desktop Kubernetes. It does not contain application service code.

## Responsibilities

- Provision shared local infrastructure dependencies for `digital-bank-sit`.
- Keep local SIT infrastructure repeatable through Helm.
- Document how services connect to local infrastructure.
- Keep local infrastructure separate from service repositories and runtime configuration repositories.

## Non-Responsibilities

- Application source code.
- Spring Cloud Config files served by Config Server.
- AWS UAT or production infrastructure.
- Production secrets.

## Current Components

| Component | Chart | Purpose |
| --- | --- | --- |
| PostgreSQL | `helm/postgres` | Shared local SIT PostgreSQL instance with separate logical databases per service. |
| Kafka | `helm/kafka` | Shared local SIT event broker for service integration and future saga/event flows. |
| AKHQ | `helm/akhq` | Local SIT Kafka dashboard for inspecting topics, messages, and consumer groups. |
| Zipkin | `helm/zipkin` | Internal local SIT distributed tracing backend with in-memory storage. |
| Fluent Bit | `helm/fluent-bit` | Local SIT Kubernetes log collector that enriches, redacts, buffers, and forwards logs to OpenSearch. |
| OpenSearch and OpenSearch Dashboards | `helm/opensearch` | Local SIT search and dashboard workloads for future centralized logging. |
| Redis | `helm/redis` | Shared local SIT state store for API Gateway rate limiting and resilience coordination. |
| Transfer acceptance fixture | `helm/transfer-acceptance-fixture` | Disabled-by-default, synthetic local SIT opening position for the transfer acceptance run. |

## Repository Model

```text
config-repo
  Runtime configuration served by Config Server.

infra-sit
  Local Kubernetes infrastructure for Docker Desktop SIT.

platform-infra-aws
  Future AWS infrastructure for UAT and production.
```

## Prerequisites

- Docker Desktop with Kubernetes enabled.
- `kubectl` configured for the `docker-desktop` context.
- Helm 3 or 4.

OpenSearch also requires the Kubernetes node's Linux `vm.max_map_count` to be at least `262144`. Verify the node setting before installing the OpenSearch chart; OpenSearch exits its bootstrap checks when the value is lower. On Linux, set `vm.max_map_count=262144` in the host sysctl configuration and reload it. On Docker Desktop, apply the equivalent setting in the Linux VM used by Docker Desktop.

Verify:

```bash
kubectl config current-context
kubectl get nodes
helm version --short
```

## Install Shared PostgreSQL

Create the local SIT namespace:

```bash
kubectl create namespace digital-bank-sit --dry-run=client -o yaml | kubectl apply -f -
```

Create the PostgreSQL Secret without putting the password into shell history:

```bash
read -r -s -p "Local SIT PostgreSQL password: " POSTGRES_PASSWORD && printf '\n'

printf '%s' "$POSTGRES_PASSWORD" | kubectl create secret generic postgres \
  --namespace digital-bank-sit \
  --from-literal=POSTGRES_DB=postgres \
  --from-literal=POSTGRES_USER=postgres \
  --from-file=POSTGRES_PASSWORD=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -

unset POSTGRES_PASSWORD
```

This reads the password interactively, sends it to `kubectl` through standard input, applies the Secret declaratively, and removes the shell variable afterward. No password literal is written into shell history.

Install PostgreSQL into the local SIT namespace:

```bash
helm upgrade --install postgres helm/postgres \
  --namespace digital-bank-sit \
  --create-namespace \
  --values helm/postgres/values-sit.yaml \
  --wait \
  --timeout 5m
```

Verify:

```bash
kubectl get pods,svc,pvc,secrets -n digital-bank-sit
```

The in-cluster PostgreSQL service name is:

```text
postgres.digital-bank-sit.svc.cluster.local
```

Services in the same namespace can use:

```text
postgres
```

## Logical Databases

The SIT PostgreSQL instance creates separate logical databases:

```text
customer_service
account_service
ledger_service
transaction_service
payment_service
notification_service
mfa_service
auth_service
```

The chart provisions every listed database through the PostgreSQL first-boot
initializer and an idempotent Helm post-install/post-upgrade reconciliation
Job. The reconciliation step is important when the StatefulSet already has a
persistent volume: changing the values list alone would not cause PostgreSQL's
first-boot scripts to run again.

## Transfer Acceptance Fixture

`helm/transfer-acceptance-fixture` is a temporary, local Docker Desktop SIT
fixture for the transfer acceptance run. It renders no resources by default.
When explicitly enabled, its Job references the existing `postgres` Secret at
runtime and seeds fixed synthetic customer, account, and opening-ledger data.
It does not render or print the Secret values, expose a balance-change API, or
perform updates or deletes against financial data.

Run it only for a controlled acceptance execution:

```bash
helm upgrade --install transfer-acceptance-fixture helm/transfer-acceptance-fixture \
  --namespace digital-bank-sit \
  --values helm/transfer-acceptance-fixture/values-sit.yaml \
  --set fixtures.enabled=true \
  --wait \
  --timeout 5m
```

After the Job completes, verify the synthetic records with read-only queries:

```bash
kubectl exec -n digital-bank-sit statefulset/postgres -- \
  psql --username postgres --dbname customer_service --tuples-only --no-align \
  --command "SELECT customer_id, email FROM customers WHERE customer_id IN ('26100000-0000-4000-8000-000000000001', '26100000-0000-4000-8000-000000000002') ORDER BY customer_id;"

kubectl exec -n digital-bank-sit statefulset/postgres -- \
  psql --username postgres --dbname account_service --tuples-only --no-align \
  --command "SELECT id, current_balance, available_balance FROM accounts WHERE id = '26100000-0000-4000-8000-000000000101';"

kubectl exec -n digital-bank-sit statefulset/postgres -- \
  psql --username postgres --dbname ledger_service --tuples-only --no-align \
  --command "SELECT e.id, SUM(CASE WHEN l.line_type = 'DEBIT' THEN l.amount ELSE -l.amount END) AS balance FROM ledger_entries e JOIN ledger_entry_lines l ON l.entry_id = e.id WHERE e.id = '26100000-0000-4000-8000-000000000201' GROUP BY e.id;"
```

These are query-only commands. The controlled Job is the sole mechanism for
creating the fixture data; do not modify these records from a workstation.

## Transfer Saga Acceptance Runner

The guarded local-SIT runner uses the fixture through the normal gateway,
Kafka, and service contracts. It has a non-mutating inspection mode:

```bash
scripts/run-transfer-saga-acceptance.sh --help
scripts/run-transfer-saga-acceptance.sh --dry-run
```

See [docs/transfer-saga-acceptance.md](docs/transfer-saga-acceptance.md) for
the controlled execution boundary, runtime prerequisites, cleanup behavior,
and redacted evidence policy.

## MFA Service SIT Secret

MFA Service requires the externally managed `mfa-service-secrets` Kubernetes
Secret in `digital-bank-sit` with the `MFA_TOTP_ENCRYPTION_KEY` key. This is a
throwaway SIT encryption key for protecting TOTP secrets at rest. Never put the
key value in this repository, Config Server Git, Helm values, issue bodies,
comments, pull requests, shell history, or logs. UAT and PROD remain deferred
to controlled external secret management.

Generate and inject a new development-only key without placing the value in a
command argument or printing it:

```bash
openssl rand -base64 32 | tr -d '\n' | kubectl create secret generic mfa-service-secrets \
  --namespace digital-bank-sit \
  --from-file=MFA_TOTP_ENCRYPTION_KEY=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -
```

To inject or replace a key supplied through an approved secure channel, enter
it silently and pass it through standard input:

```bash
read -r -s -p "Local SIT MFA TOTP encryption key (base64, 32 decoded bytes): " MFA_TOTP_ENCRYPTION_KEY && printf '\n'

printf '%s' "$MFA_TOTP_ENCRYPTION_KEY" | kubectl create secret generic mfa-service-secrets \
  --namespace digital-bank-sit \
  --from-file=MFA_TOTP_ENCRYPTION_KEY=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -

unset MFA_TOTP_ENCRYPTION_KEY
```

Verify only that the Secret exists; do not decode or print its data:

```bash
kubectl get secret mfa-service-secrets --namespace digital-bank-sit
```

Remove the external Secret when resetting the local SIT environment or
rotating the key. This does not remove the `mfa_service` database or its data:

```bash
kubectl delete secret mfa-service-secrets \
  --namespace digital-bank-sit \
  --ignore-not-found
```

## Local Credentials

The local SIT Secret created above is suitable only for Docker Desktop SIT. Use a throwaway local password, not a reused personal or production credential.

The chart references the existing Kubernetes Secret instead of rendering a password into Helm output. This keeps credentials out of Git history, pull request diffs, and CI logs.

For AWS UAT and production, application databases should use Amazon RDS PostgreSQL and credentials should come from AWS Secrets Manager, typically exposed to Kubernetes through External Secrets Operator or an equivalent controlled mechanism.

## Install Shared Kafka

Install Kafka into the local SIT namespace:

```bash
helm upgrade --install kafka helm/kafka \
  --namespace digital-bank-sit \
  --create-namespace \
  --values helm/kafka/values-sit.yaml \
  --wait \
  --timeout 5m
```

Verify:

```bash
kubectl get pods,svc,pvc -n digital-bank-sit -l app.kubernetes.io/name=kafka
```

The in-cluster Kafka service name is:

```text
kafka.digital-bank-sit.svc.cluster.local:9092
```

Services in the same namespace can use:

```text
kafka:9092
```

## Install Shared Redis

Redis is shared local SIT infrastructure for gateway rate limiting and resilience state. It is not exposed outside the cluster.

Create the local SIT password outside Git before installing or upgrading Redis. Do not
put the value in Helm values, shell history, or a committed file:

```bash
read -r -s REDIS_PASSWORD
export REDIS_PASSWORD
kubectl create secret generic redis \
  --namespace digital-bank-sit \
  --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD" \
  --dry-run=client \
  --output=yaml | kubectl apply -f -
unset REDIS_PASSWORD
```

The Redis chart reads the REDIS_PASSWORD key from this existing Secret. Its
NetworkPolicy permits Redis traffic only from API Gateway pods in
digital-bank-sit; other workloads must not connect directly to Redis.

```bash
helm upgrade --install redis helm/redis \
  --namespace digital-bank-sit \
  --create-namespace \
  --values helm/redis/values-sit.yaml \
  --wait \
  --timeout 5m
```

Verify:

```bash
kubectl get pods,svc,pvc -n digital-bank-sit -l app.kubernetes.io/name=redis
```

The in-cluster Redis service name is:

```text
redis.digital-bank-sit.svc.cluster.local:6379
```

Services in the same namespace can use:

```text
redis:6379
```

This is a single-replica Redis StatefulSet with append-only persistence on a local Docker Desktop PVC. The PVC protects data across a pod restart, but local SIT does not provide production-grade high availability, backup, failover, or disaster recovery. Do not put production credentials or business-critical data in this instance.

Redis uses the `noeviction` memory policy for rate-limit state. When the configured memory limit is reached, Redis rejects writes instead of silently evicting counters and resetting quotas. Monitor capacity and address write failures before they affect gateway traffic.

This chart deploys a single Kafka broker in KRaft mode for local SIT only. It does not deploy ZooKeeper.

Kafka is required before implementing event-driven transaction flows such as:

- account reservation events;
- ledger posting events;
- transaction saga orchestration;
- future outbox/inbox integration tests.

The local SIT Kafka chart provisions the current event topics deterministically during `helm upgrade --install` and keeps Kafka auto topic creation disabled. The provisioned topics are:

```text
account.reservation.requested.v1
account.reservation.requested.v1.dlq
account.reservation.release-requested.v1
account.reservation.release-requested.v1.dlq
account.reservation.accepted.v1
account.reservation.accepted.v1.dlq
account.reservation.rejected.v1
account.reservation.rejected.v1.dlq
account.reservation.released.v1
account.reservation.released.v1.dlq
account.reservation.expired.v1
account.reservation.expired.v1.dlq
ledger.posting.requested.v1
ledger.posting.requested.v1.dlq
ledger.posting.completed.v1
ledger.posting.completed.v1.dlq
ledger.posting.failed.v1
ledger.posting.failed.v1.dlq
events.transfer.created.v1
events.transfer.created.v1.dlq
events.transfer.completed.v1
events.transfer.completed.v1.dlq
events.transfer.failed.v1
events.transfer.failed.v1.dlq
mfa.assurance.granted.v1
mfa.assurance.granted.v1.dlq
payment.instruction.state.v1
payment.instruction.state.v1.dlq
```

Notification Service consumes `events.transfer.created.v1` when its SIT consumer flag is enabled. The `.dlq` companion is provisioned for failed event handling.

MFA Service publishes `mfa.assurance.granted.v1` after a transfer-bound challenge succeeds. Transaction Service consumes the assurance event to resume the transfer saga, and the `.dlq` companion supports failed event handling.

Verify topic provisioning:

```bash
kubectl get jobs -n digital-bank-sit

kubectl logs -n digital-bank-sit job/kafka-topic-provisioning

kubectl exec -n digital-bank-sit kafka-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list
```

Verify Kafka auto topic creation is disabled:

```bash
kubectl exec -n digital-bank-sit kafka-0 -- printenv KAFKA_AUTO_CREATE_TOPICS_ENABLE
```

## Install OpenSearch and OpenSearch Dashboards

OpenSearch and OpenSearch Dashboards are deployed together by the `helm/opensearch` chart into `digital-bank-sit`. The chart uses OpenSearch `2.19.0`, a version supported by Amazon OpenSearch Service, and keeps both workloads behind internal `ClusterIP` Services.

Create the local-only admin Secret without putting the password into shell history:

```bash
read -r -s -p "Local SIT OpenSearch admin password: " OPENSEARCH_INITIAL_ADMIN_PASSWORD && printf '\n'

printf '%s' "$OPENSEARCH_INITIAL_ADMIN_PASSWORD" | kubectl create secret generic opensearch-admin \
  --namespace digital-bank-sit \
  --from-file=OPENSEARCH_INITIAL_ADMIN_PASSWORD=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -

unset OPENSEARCH_INITIAL_ADMIN_PASSWORD
```

Use a strong throwaway password for local SIT. OpenSearch 2.12 and later requires a custom initial admin password when the demo security configuration is enabled. The chart references this Secret and never renders the admin password into Helm values or manifests.

Create a separate Secret for the Dashboards service account. Keep the password local to the cluster and do not add it to Git:

```bash
read -r -s -p "Local SIT Dashboards password: " OPENSEARCH_DASHBOARDS_PASSWORD && printf '\n'

printf '%s' "$OPENSEARCH_DASHBOARDS_PASSWORD" | kubectl create secret generic opensearch-dashboards \
  --namespace digital-bank-sit \
  --from-file=OPENSEARCH_DASHBOARDS_PASSWORD=/dev/stdin \
  --dry-run=client -o yaml | kubectl apply -f -

unset OPENSEARCH_DASHBOARDS_PASSWORD
```

The chart uses the fixed non-secret username `kibanaserver` and injects only the password into the Dashboards container. On install and upgrade, a short-lived Helm hook runs the image's supported local demo security setup so its admin certificate files exist, then uses the OpenSearch security administration tool to back up the live internal-user configuration, replace only the `kibanaserver` hash, and reload that preserved configuration. The admin password is supplied from the existing Secret and the rendered manifests contain no password. This bootstrap is for local SIT only; use a managed, least-privilege identity with TLS verification enabled before UAT or PROD.

Install the chart:

```bash
helm upgrade --install opensearch helm/opensearch \
  --namespace digital-bank-sit \
  --create-namespace \
  --values helm/opensearch/values-sit.yaml \
  --wait \
  --timeout 10m
```

Verify the workloads, Services, and persistent volume claim:

```bash
kubectl get statefulset,deployment,pods,service,pvc \
  --namespace digital-bank-sit \
  -l app.kubernetes.io/instance=opensearch

kubectl rollout status statefulset/opensearch \
  --namespace digital-bank-sit \
  --timeout=10m

kubectl rollout status deployment/opensearch-dashboards \
  --namespace digital-bank-sit \
  --timeout=10m
```

The stable in-cluster endpoints are:

```text
opensearch.digital-bank-sit.svc.cluster.local:9200
opensearch-dashboards.digital-bank-sit.svc.cluster.local:5601
```

Check the OpenSearch cluster health locally. Keep the port-forward and password in temporary terminals only:

```bash
kubectl port-forward --namespace digital-bank-sit service/opensearch 9200:9200
```

```bash
export OPENSEARCH_INITIAL_ADMIN_PASSWORD="$(kubectl get secret opensearch-admin \
  --namespace digital-bank-sit \
  -o jsonpath='{.data.OPENSEARCH_INITIAL_ADMIN_PASSWORD}' | base64 -D)"

curl --fail --insecure --user "admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}" \
  'https://localhost:9200/_cluster/health?wait_for_status=yellow'

unset OPENSEARCH_INITIAL_ADMIN_PASSWORD
```

Expose Dashboards only to the local workstation when needed:

```bash
kubectl port-forward --namespace digital-bank-sit service/opensearch-dashboards 5601:5601
```

Open `http://localhost:5601` and sign in with the local OpenSearch admin password created above. Dashboards-to-OpenSearch requests use the `kibanaserver` password provisioned from the separate Secret above. This is local SIT bootstrap configuration only and must be replaced with a managed service identity before any UAT or production mapping.

This is intentionally a single-node, one-replica deployment. Persistence is enabled by default through a `ReadWriteOnce` PVC and can be changed with `opensearch.persistence.enabled`, `opensearch.persistence.size`, `opensearch.persistence.storageClassName`, and `opensearch.persistence.accessModes`. CPU, memory, JVM heap, Dashboards replica count, image tags, and namespace are configurable in `values.yaml` and `values-sit.yaml`. Disabling persistence uses `emptyDir` and loses all indexes when the pod is removed.

The default demo TLS certificates are used for the local HTTPS OpenSearch endpoint, so local probes and examples use `--insecure`. Neither Service is public by default. Centralized log collection, including Fluent Bit, is tracked separately in issue #94 and is intentionally not part of this deployment.

## Install AKHQ Kafka Dashboard

AKHQ is tooling, not a core banking runtime dependency. Install it into the tooling namespace:

```bash
helm upgrade --install akhq helm/akhq \
  --namespace digital-bank-tooling \
  --create-namespace \
  --values helm/akhq/values-sit.yaml \
  --wait \
  --timeout 5m
```

Verify:

```bash
kubectl get pods,svc -n digital-bank-tooling -l app.kubernetes.io/name=akhq
```

Expose the AKHQ UI to your Mac:

```bash
kubectl port-forward -n digital-bank-tooling svc/akhq 8088:8080
```

Open:

```text
http://localhost:8088
```

AKHQ connects to the SIT Kafka broker through the in-cluster address:

```text
kafka.digital-bank-sit.svc.cluster.local:9092
```

Keep AKHQ access local-only for SIT. Do not expose it with a public LoadBalancer or public Ingress.

## Install Zipkin Distributed Tracing

Zipkin is a local SIT observability dependency. It stores traces in memory and is intentionally
not exposed outside the cluster.

```bash
helm upgrade --install zipkin helm/zipkin \
  --namespace digital-bank-sit \
  --create-namespace \
  --values helm/zipkin/values-sit.yaml \
  --wait \
  --timeout 5m
```

Verify the deployment and service:

```bash
kubectl get pods,svc -n digital-bank-sit -l app.kubernetes.io/name=zipkin
```

For local inspection only, port-forward the ClusterIP service:

```bash
kubectl port-forward -n digital-bank-sit svc/zipkin 9411:9411
```

Open `http://localhost:9411` to inspect sampled SIT traces. UAT and production tracing
backends are deferred to the AWS observability design.

## Install Fluent Bit Log Collection

Fluent Bit runs as a DaemonSet in `digital-bank-sit`, so one collector runs on each Kubernetes node and reads the node's container stdout/stderr log files. The standard `/var/log/containers/*.log` CRI input and Kubernetes filter are the convention for production, UAT, and any runtime that exposes Kubernetes container logs there. Structured JSON records are parsed under `structured` and passed through the redaction filter before they are sent to OpenSearch. Plain-text records are retained as `unstructured` records with inline credential redaction.

Local Docker Desktop Kubernetes uses the chart's explicit `dockerFallback` mode in `helm/fluent-bit/values-sit.yaml`. When enabled, Fluent Bit also tails `/var/lib/docker/containers/*/*-json.log` with the Docker JSON parser and mounts the configured host path read-only. This fallback is disabled in the generic `values.yaml`; do not use it as the default for containerd, AWS, UAT, or PROD runtimes. The Lua enrichment reads only the matching container's `config.v2.json`, extracts the five Kubernetes metadata labels needed for pod name, namespace, container name, pod UID, and log path, and emits them under `kubernetes` with the container ID. It never emits the Docker config document or environment values.

The chart expects the existing local SIT OpenSearch Secret. It does not create or commit credentials:

```bash
helm upgrade --install fluent-bit helm/fluent-bit \
  --namespace digital-bank-sit \
  --create-namespace \
  --values helm/fluent-bit/values-sit.yaml \
  --wait \
  --timeout 5m
```

Verify the DaemonSet and collector health:

```bash
kubectl get daemonset,pods,svc -n digital-bank-sit -l app.kubernetes.io/name=fluent-bit
kubectl logs -n digital-bank-sit -l app.kubernetes.io/name=fluent-bit --tail=50
```

The collector sends to the configurable OpenSearch endpoint in `values-sit.yaml`. Local SIT uses the in-cluster `opensearch.digital-bank-sit.svc.cluster.local:9200` address over HTTPS, with the local-only TLS verification setting matching the local OpenSearch chart. UAT and PROD should replace the endpoint, TLS trust configuration, and credential reference through environment-specific deployment values; application services do not need to change.

Filesystem buffering is enabled for backpressure and transient OpenSearch failures. `Retry_Limit False` allows Fluent Bit to retry until the record is accepted or the configured storage limit is reached. The chart uses a dedicated node path for its buffer and tail database. Monitor buffer usage and Fluent Bit health in a real deployment.

Both input paths use filesystem-backed buffering, bounded in-memory chunks, and separate tail databases. Docker-mode parser failures are explicit invalid events: JSON-looking payloads are replaced with `REDACTED_INVALID_STRUCTURED_LOG`, while non-JSON payloads remain `unstructured` after inline redaction. Missing or malformed Docker metadata does not expose the config file and leaves the event observable with the Docker source marker.

JSON-looking records that cannot be parsed as structured JSON are retained as observable events with `logging_parse_status=invalid`, `logging_invalid_event=true`, and `invalid_event_reason=structured_json_parse_failed`. Their raw log field is replaced before output, preventing an invalid record from bypassing redaction. Plain-text records use `logging_parse_status=unstructured` and retain their message after inline credential redaction. Query the `digital-bank-sit-*` OpenSearch indexes for these fields when investigating application logging problems.

The collector redacts keys containing credentials or personal identifiers, including password, token, authorization, secret, API key, cookies, SSN, national ID, and tax ID. This is a defense-in-depth control; services must still avoid logging secrets and sensitive customer data.

Validate the chart without installing it:

```bash
bash tests/validate.sh
```

## AWS Mapping

```text
Local SIT:
PostgreSQL StatefulSet + PVC in Docker Desktop Kubernetes
Kafka StatefulSet + PVC in Docker Desktop Kubernetes
Redis StatefulSet + PVC in Docker Desktop Kubernetes
AKHQ Deployment in Docker Desktop Kubernetes tooling namespace
Fluent Bit DaemonSet in Docker Desktop Kubernetes
OpenSearch StatefulSet + PVC and OpenSearch Dashboards Deployment in Docker Desktop Kubernetes

AWS UAT/PROD:
Amazon RDS PostgreSQL, private subnets, IAM-controlled access, managed backups, Multi-AZ as needed
Amazon ElastiCache for Redis or Valkey, private subnets, encryption, authentication, replication, automatic failover, backups, and monitoring
Managed or separately operated Kafka-compatible event streaming, private networking, IAM or mTLS/SASL access control, encryption, monitoring, and retention policies
Kafka dashboard access only through private networking, SSO/RBAC, and audited administrative access
Managed log ingestion and OpenSearch-compatible storage with private networking, TLS verification, scoped credentials, retention, and monitoring
Amazon OpenSearch Service domain in private VPC subnets with IAM/SigV4, fine-grained access control, managed TLS, encryption, snapshots, scaling, and CloudWatch integration
Amazon OpenSearch Dashboards endpoint provided by the managed domain; do not carry the local Dashboards Deployment or demo credentials into UAT/PROD
```

## Local Kubernetes Dashboard

Headlamp Desktop is the preferred local Kubernetes GUI for Docker Desktop SIT.

Headlamp Desktop runs on the developer workstation and uses the local kubeconfig, so it does not require dashboard workloads inside the cluster.

Useful local views:

- Workloads > Deployments: inspect rollout state for `api-gateway`, `config-server`, `customer-service`, and `account-service`.
- Workloads > Pods: inspect pod status, restarts, logs, and events.
- Network > Services: inspect stable service names used by the gateway and service-to-service routing.
- Storage > Persistent Volume Claims: inspect local SIT PostgreSQL and Kafka storage.

Local Desktop access normally uses the same permissions as `kubectl` for the active context. On Docker Desktop Kubernetes, this usually means broad local administrative access. Use that only for local SIT.

## UAT and Production Dashboard Guidance

AWS EKS provides Kubernetes resource visibility through the AWS Console. Headlamp Desktop can also connect to EKS after kubeconfig is configured:

```bash
aws eks update-kubeconfig \
  --region <aws-region> \
  --name <eks-cluster-name>
```

For UAT and production, start with:

```text
AWS EKS Console + kubectl + Helm/GitHub Actions deployment history
```

Headlamp Desktop may be used later for UAT or production operations only when access is controlled by:

- private cluster endpoint access or VPN;
- AWS IAM authentication;
- strict Kubernetes RBAC with least-privilege roles;
- audit logging;
- no shared cluster-admin credentials.

This repository does not provision a Kubernetes cluster dashboard. Cloud infrastructure belongs in the future `platform-infra-aws` repository.

## Uninstall

```bash
helm uninstall akhq --namespace digital-bank-tooling
helm uninstall opensearch --namespace digital-bank-sit
helm uninstall redis --namespace digital-bank-sit
helm uninstall kafka --namespace digital-bank-sit
helm uninstall postgres --namespace digital-bank-sit
```

The persistent volume claim may remain depending on the storage class reclaim policy. Remove local SIT data only when you intentionally want to reset the database:

```bash
kubectl delete pvc -n digital-bank-sit -l app.kubernetes.io/instance=postgres
kubectl delete pvc -n digital-bank-sit -l app.kubernetes.io/instance=kafka
kubectl delete pvc -n digital-bank-sit data-opensearch-0
kubectl delete pvc -n digital-bank-sit -l app.kubernetes.io/instance=redis
```
