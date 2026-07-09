# AGENTS.md

## Repository Purpose

`infra-sit` owns the local Kubernetes infrastructure required for the SIT environment.

It should model shared infrastructure concerns, not service business logic.

## Current Responsibilities

- shared PostgreSQL for local SIT
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
```

## Infrastructure Model

- Local SIT currently uses one shared PostgreSQL instance.
- Each service gets a separate logical database inside that instance.
- Service isolation is logical at the database level, while infrastructure reuse is physical at the instance level.

## Current Logical Databases

- `customer_service`
- `account_service`
- `ledger_service`
- `transaction_service`
- `payment_service`
- `notification_service`

## Production Mapping

- Local SIT may use shared infrastructure for efficiency.
- UAT and PROD may map the same responsibilities to managed cloud services such as Amazon RDS.
- Do not assume the local SIT packaging model must be identical to cloud production packaging.

## Working Rules

- Keep infrastructure changes small and explicit.
- Do not hide service-specific application settings here.
- If a service needs a new shared database or infrastructure dependency, add a supporting issue first.
