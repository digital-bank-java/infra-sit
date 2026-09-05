# AGENTS.md

## Repository Purpose

`infra-sit` owns the local Kubernetes infrastructure required for the SIT environment.

It should model shared infrastructure concerns, not service business logic.

## Current Responsibilities

- shared PostgreSQL for local SIT
- shared Kafka for local SIT event streaming
- shared Redis for local SIT gateway rate limiting and resilience state
- AKHQ dashboard for local SIT Kafka inspection
- future shared tooling needed by the local integrated environment
- infrastructure README and rollout guidance

## Current Non-Responsibilities

- application domain logic
- service code
- externalized runtime config for services

## Key Commands

```bash
helm lint helm/postgres --values helm/postgres/values-sit.yaml
helm template postgres helm/postgres --values helm/postgres/values-sit.yaml
helm upgrade --install postgres helm/postgres --namespace digital-bank-sit --create-namespace --values helm/postgres/values-sit.yaml

helm lint helm/kafka --values helm/kafka/values-sit.yaml
helm template kafka helm/kafka --values helm/kafka/values-sit.yaml
helm upgrade --install kafka helm/kafka --namespace digital-bank-sit --create-namespace --values helm/kafka/values-sit.yaml

helm lint helm/akhq --values helm/akhq/values-sit.yaml
helm template akhq helm/akhq --values helm/akhq/values-sit.yaml
helm upgrade --install akhq helm/akhq --namespace digital-bank-tooling --create-namespace --values helm/akhq/values-sit.yaml

helm lint helm/zipkin --values helm/zipkin/values-sit.yaml
helm template zipkin helm/zipkin --values helm/zipkin/values-sit.yaml
helm upgrade --install zipkin helm/zipkin --namespace digital-bank-sit --create-namespace --values helm/zipkin/values-sit.yaml

helm lint helm/opensearch --values helm/opensearch/values-sit.yaml
helm template opensearch helm/opensearch --values helm/opensearch/values-sit.yaml
helm upgrade --install opensearch helm/opensearch --namespace digital-bank-sit --create-namespace --values helm/opensearch/values-sit.yaml

helm lint helm/redis --values helm/redis/values-sit.yaml
helm template redis helm/redis --values helm/redis/values-sit.yaml
helm upgrade --install redis helm/redis --namespace digital-bank-sit --create-namespace --values helm/redis/values-sit.yaml
```

## Infrastructure Model

- Local SIT currently uses one shared PostgreSQL instance.
- Each service gets a separate logical database inside that instance.
- Service isolation is logical at the database level, while infrastructure reuse is physical at the instance level.
- Local SIT uses one shared Kafka broker for event-driven integration testing.
- Kafka is local-only infrastructure here; UAT and PROD should map this responsibility to a managed or separately operated event streaming platform.
- AKHQ runs in `digital-bank-tooling` because it is an inspection tool, not an application runtime dependency.
- Redis runs in `digital-bank-sit` because it is a shared application runtime dependency for local SIT gateway rate limiting and resilience state.

## Current Logical Databases

- `customer_service`
- `account_service`
- `ledger_service`
- `transaction_service`
- `payment_service`
- `notification_service`
- `mfa_service`
- `auth_service`

## Shared Redis

Local SIT uses a single Redis instance exposed as the stable service `redis` in `digital-bank-sit`.
It is a single-replica StatefulSet with a local PVC and is suitable for repeatable local testing only. It is not a highly available Redis topology and its local Docker Desktop storage is not a production durability or disaster-recovery guarantee.

UAT and PROD should use a managed Redis-compatible service such as Amazon ElastiCache for Redis or Valkey, with encryption, authentication, high availability, backups, monitoring, and network access controls managed outside this chart.

## Production Mapping

- Local SIT may use shared infrastructure for efficiency.
- UAT and PROD may map the same responsibilities to managed cloud services such as Amazon RDS.
- Do not assume the local SIT packaging model must be identical to cloud production packaging.

## Working Rules

- Keep infrastructure changes small and explicit.
- Do not hide service-specific application settings here.
- If a service needs a new shared database or infrastructure dependency, add a supporting issue first.
