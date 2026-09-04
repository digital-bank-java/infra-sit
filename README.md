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
| Fluent Bit | `helm/fluent-bit` | Local SIT Kubernetes log collector that enriches, redacts, buffers, and forwards logs to OpenSearch. |
| Redis | `helm/redis` | Shared local SIT state store for API Gateway rate limiting and resilience coordination. |

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
transaction_service
payment_service
notification_service
mfa_service
```

The currently active service databases are:

```text
customer_service
account_service
```

The remaining databases are provisioned for planned services and are not active yet.

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
ledger.posting.completed.v1
ledger.posting.completed.v1.dlq
ledger.posting.failed.v1
ledger.posting.failed.v1.dlq
```

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

## Install Fluent Bit Log Collection

Fluent Bit runs as a DaemonSet in `digital-bank-sit`, so one collector runs on each Kubernetes node and reads the node's container stdout/stderr log files. The Kubernetes filter enriches records with pod, namespace, container, and node metadata. Structured JSON records are parsed under `structured` and passed through the redaction filter before they are sent to OpenSearch. Plain-text records are retained as `unstructured` records with inline credential redaction.

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

AWS UAT/PROD:
Amazon RDS PostgreSQL, private subnets, IAM-controlled access, managed backups, Multi-AZ as needed
Amazon ElastiCache for Redis or Valkey, private subnets, encryption, authentication, replication, automatic failover, backups, and monitoring
Managed or separately operated Kafka-compatible event streaming, private networking, IAM or mTLS/SASL access control, encryption, monitoring, and retention policies
Kafka dashboard access only through private networking, SSO/RBAC, and audited administrative access
Managed log ingestion and OpenSearch-compatible storage with private networking, TLS verification, scoped credentials, retention, and monitoring
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

This repository does not provision a Kubernetes dashboard. Cloud infrastructure belongs in the future `platform-infra-aws` repository.

## Uninstall

```bash
helm uninstall akhq --namespace digital-bank-tooling
helm uninstall redis --namespace digital-bank-sit
helm uninstall kafka --namespace digital-bank-sit
helm uninstall postgres --namespace digital-bank-sit
```

The persistent volume claim may remain depending on the storage class reclaim policy. Remove local SIT data only when you intentionally want to reset the database:

```bash
kubectl delete pvc -n digital-bank-sit -l app.kubernetes.io/instance=postgres
kubectl delete pvc -n digital-bank-sit -l app.kubernetes.io/instance=kafka
kubectl delete pvc -n digital-bank-sit -l app.kubernetes.io/instance=redis
```
