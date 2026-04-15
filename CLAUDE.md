# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Local development — Docker Compose (Kafka, LocalStack, pgvector)
make up       # start all services
make down     # stop all services
make status   # show container status

# Kubernetes — apply all manifests (order matters, see below)
make apply-local

# Validate manifests locally (kubectl dry-run)
make validate

# CI validation uses kubeconform (not kubectl):
kubeconform -strict -summary <manifest.yaml>
```

## Local Infrastructure (Docker Compose)

`docker-compose.infra.yml` starts four containers:

| Container | Image | Port | Purpose |
|-----------|-------|------|---------|
| `kafka` | apache/kafka:3.9.0 | 9092 | KRaft broker (no ZooKeeper) |
| `kafka-init` | apache/kafka:3.9.0 | — | One-shot: creates `video-events` (3p) and `watch-events` (6p) topics |
| `localstack` | localstack/localstack:3.5 | 4566 | AWS Glue + S3 (for Iceberg warehouse) |
| `localstack-init` | amazon/aws-cli:2.17.0 | — | One-shot: creates `s3://iceberg-warehouse` bucket + `analytics` Glue database |
| `pgvector` | pgvector/pgvector:pg16 | 5432 | Postgres with vector extension; db=`recommendations`, user=`recouser`, pass=`recopass` |

The `kafka-init` and `localstack-init` containers run once and exit. They depend on healthcheck-gated startup of their respective services.

## Kubernetes Architecture

### Apply Order (`make apply-local`)

`apply-local` must be run in this fixed sequence — each step depends on the prior:
1. `networking/namespaces.yaml` — creates all four namespaces: `infra`, `videostreamingplatform`, `analytics`, `recommendations`
2. `rbac/service-accounts.yaml` — one ServiceAccount per namespace
3. `kafka/` — Kafka StatefulSet + headless Service + topics-init Job
4. `schema-registry/localstack-glue.yaml` — LocalStack Deployment + Service (Glue only in K8s, no S3)
5. `pgvector/` — pgvector StatefulSet + Service + Secret
6. `networking/network-policies.yaml` — ingress rules (applied last, after pods exist)

### Network Policies

All network policies are in `networking/network-policies.yaml`, applied to the `infra` namespace:

| Policy | Allows | Port |
|--------|--------|------|
| `allow-kafka-access` | All namespaces labeled `app.kubernetes.io/part-of: videostreamingplatform` | 9092 |
| `allow-pgvector-access` | All namespaces with same label | 5432 |
| `allow-localstack-access` | All namespaces with same label | 4566 |

In practice pgvector is only consumed by the `recommendations` namespace, but the policy allows all labeled namespaces.

### Kafka Configuration Note

The `CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qk` is hardcoded identically in both docker-compose and the K8s StatefulSet — changing it requires coordinated update in both files. The K8s `KAFKA_ADVERTISED_LISTENERS` uses the full cluster-internal DNS `kafka.infra.svc.cluster.local:9092`, while docker-compose uses `localhost:9092`.

## ArgoCD GitOps

`argocd/` defines two AppProjects and four Applications — all with `automated: {prune: true, selfHeal: true}`.

### AppProjects

| Project | Source Repos | Target Namespaces |
|---------|-------------|-------------------|
| `platform` | videostreamingplatform, videostreamingplatform-infra | `videostreamingplatform`, `infra` |
| `data` | videostreamingplatform-analytics, videostreamingplatform-recommendations | `analytics`, `recommendations` |

### Applications

| App | Source Repo | Source Path | Namespace |
|-----|------------|-------------|-----------|
| `videostreamingplatform` | videostreamingplatform | `k8s/local` | videostreamingplatform |
| `infra` | videostreamingplatform-infra | `k8s` (root) | infra |
| `analytics` | videostreamingplatform-analytics | `k8s` | analytics |
| `recommendations` | videostreamingplatform-recommendations | `k8s` | recommendations |

ArgoCD watches `main` branch on all repos. Changes merged to `main` deploy automatically.

## CI

GitHub Actions (`infra-ci.yml`) runs on push/PR to `master`:
- Validates all non-ArgoCD `*.yaml` files with `kubeconform -strict`
- Validates `argocd/` CRDs separately using the datreeio CRDs catalog
- Lints `docker-compose.infra.yml` with `docker compose config --quiet`

ArgoCD manifests are excluded from standard kubeconform and validated with CRD schemas instead.
