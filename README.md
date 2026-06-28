# Platform Infra Local

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
| Headlamp | `helm/headlamp` | Local-only Kubernetes dashboard for inspecting SIT workloads. |

## Repository Model

```text
platform-config
  Runtime configuration served by Config Server.

platform-infra-local
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

Create the local SIT namespace and Secret:

```bash
kubectl create namespace digital-bank-sit --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic postgres \
  --namespace digital-bank-sit \
  --from-literal=POSTGRES_DB=postgres \
  --from-literal=POSTGRES_USER=postgres \
  --from-literal=POSTGRES_PASSWORD=postgres \
  --dry-run=client -o yaml | kubectl apply -f -
```

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
```

The currently active service databases are:

```text
customer_service
account_service
```

The remaining databases are provisioned for planned services and are not active yet.

## Local Credentials

The local SIT Secret shown above is suitable only for Docker Desktop SIT. These values are not production credentials.

The chart references the existing Kubernetes Secret instead of rendering a password into Helm output. This keeps credentials out of Git history, pull request diffs, and CI logs.

For AWS UAT and production, application databases should use Amazon RDS PostgreSQL and credentials should come from AWS Secrets Manager, typically exposed to Kubernetes through External Secrets Operator or an equivalent controlled mechanism.

## AWS Mapping

```text
Local SIT:
PostgreSQL StatefulSet + PVC in Docker Desktop Kubernetes

AWS UAT/PROD:
Amazon RDS PostgreSQL, private subnets, IAM-controlled access, managed backups, Multi-AZ as needed
```

## Install Local Kubernetes Dashboard

Headlamp is installed in a dedicated local tooling namespace and accessed through `kubectl port-forward`.

This dashboard is for local SIT visibility only. It is not part of the banking runtime path and is not exposed through the API Gateway.

Build the chart dependency:

```bash
helm dependency build helm/headlamp
```

Install Headlamp:

```bash
helm upgrade --install headlamp helm/headlamp \
  --namespace digital-bank-tooling \
  --create-namespace \
  --values helm/headlamp/values-sit.yaml \
  --wait \
  --timeout 5m
```

Verify:

```bash
kubectl get pods,svc -n digital-bank-tooling
```

Create a short-lived read-only login token:

```bash
kubectl create token headlamp --namespace digital-bank-tooling
```

Open local access:

```bash
kubectl port-forward -n digital-bank-tooling svc/headlamp 4466:80
```

Then open:

```text
http://localhost:4466
```

Use the token from `kubectl create token` to sign in.

Useful local views:

- Workloads > Deployments: inspect rollout state for `api-gateway`, `config-server`, `customer-service`, and `account-service`.
- Workloads > Pods: inspect pod status, restarts, logs, and events.
- Network > Services: inspect stable service names used by the gateway and service-to-service routing.
- Storage > Persistent Volume Claims: inspect local SIT PostgreSQL storage.

The local chart binds Headlamp to the Kubernetes `view` ClusterRole. This keeps the dashboard read-only. Use Helm and `kubectl` for operational changes so changes remain scripted and reviewable.

## UAT and Production Dashboard Guidance

AWS EKS provides Kubernetes resource visibility through the AWS Console. For UAT and production, start with:

```text
AWS EKS Console + kubectl + Helm/GitHub Actions deployment history
```

Headlamp may be added later as an internal admin tool, but only with:

- private network access or VPN;
- SSO/OIDC authentication;
- strict Kubernetes RBAC;
- audit logging;
- no public internet exposure.

This repository does not provision UAT or production dashboards. Cloud infrastructure belongs in the future `platform-infra-aws` repository.

## Uninstall

```bash
helm uninstall postgres --namespace digital-bank-sit
```

Remove Headlamp:

```bash
helm uninstall headlamp --namespace digital-bank-tooling
```

The persistent volume claim may remain depending on the storage class reclaim policy. Remove local SIT data only when you intentionally want to reset the database:

```bash
kubectl delete pvc -n digital-bank-sit -l app.kubernetes.io/instance=postgres
```
