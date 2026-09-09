# Transfer Saga Acceptance

`scripts/run-transfer-saga-acceptance.sh` is a guarded, local-only SIT runner
for the transfer saga. It is not a balance-management tool and must not be
used in UAT or production.

## Safety Boundary

The runner rejects every context except `docker-desktop` and every namespace
except `digital-bank-sit`. It creates no public API and sends no fabricated
Kafka record. The duplicate scenario resets the inactive
`transaction-service-ledger` group to the original
`ledger.posting.completed.v1` record only.

The script creates a random in-memory password and BCrypt hash for the
temporary `transfer-orchestrator` Auth fixture. It changes only
`AUTH_FIXTURE_USERNAME` and `AUTH_FIXTURE_PASSWORD_HASH` Secret references,
then restores the two original entries and deletes the temporary Secret via a
shell trap. JWTs, passwords, hash values, Secret values, and Authorization
headers are never written to evidence or printed.

## Inspect First

```bash
scripts/run-transfer-saga-acceptance.sh --help
scripts/run-transfer-saga-acceptance.sh --dry-run
```

`--dry-run` does not contact Kubernetes or mutate SIT. A normal run requires
`kubectl`, `helm`, `curl`, `jq`, `openssl`, `htpasswd`, `uuidgen`, and `rg`.

## Run

After the Ledger acceptance-fixture switch and the gateway/transaction
workflow route are deployed to local SIT:

```bash
scripts/run-transfer-saga-acceptance.sh
```

The runner uses the fixed synthetic fixture accounts:

| Role | Identifier |
| --- | --- |
| Source AED account | `26100000-0000-4000-8000-000000000101` |
| Destination AED account | `26100000-0000-4000-8000-000000000102` |
| Opening ledger entry | `26100000-0000-4000-8000-000000000201` |

It runs one successful transfer, one insufficient-funds transfer, one governed
Ledger failure/compensation transfer, then one original-record redelivery. It
fails before mutation when the expected deployments, Auth Secret-reference
variables, SIT profile, gateway route, Kafka tools, or consumer-group contract
does not match.

## Evidence And Cleanup

Redacted evidence is retained beneath the gitignored `tmp/transfer-saga-acceptance/`
directory. It contains only scenario names, HTTP statuses, synthetic IDs,
Kafka topic/partition/offset, and read-only row counts. The trap removes the
temporary Secret, restores Auth and Ledger environment references, restores
Transaction Service replicas, removes transient raw Kafka output, and clears
in-memory credential variables on normal exit, failure, or interruption.

Do not edit database data, reset an active consumer group, replay a DLQ record,
or use a manually produced Kafka message as a substitute for this procedure.
