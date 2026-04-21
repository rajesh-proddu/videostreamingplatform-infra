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
| `data` | videostreamingplatform-infra, videostreamingplatform-analytics, videostreamingplatform-recommendations | `analytics`, `recommendations` |

### Applications

| App | Source Repo | Source Path | Render | Namespace |
|-----|------------|-------------|--------|-----------|
| `videostreamingplatform` | videostreamingplatform | `k8s/local` | raw manifests | videostreamingplatform |
| `infra` | videostreamingplatform-infra | multi-source: `kafka`, `pgvector`, `schema-registry`, `networking`, `rbac` | raw manifests | infra |
| `analytics` | videostreamingplatform-infra | `charts/analytics` | Helm (`values.yaml` + `values-aws.yaml`) | analytics |
| `recommendations` | videostreamingplatform-infra | `charts/recommendations` | Helm (`values.yaml` + `values-aws.yaml`) | recommendations |

ArgoCD watches `main` branch on all repos. Changes merged to `main` deploy automatically.

This repo is the GitOps source of truth: analytics/recommendations Helm charts
live here, not in the service repos. The service repos own code and CI
(container image builds) only; Helm charts reference published image tags.

## Helm Charts

`charts/analytics/` and `charts/recommendations/` each contain:

- `Chart.yaml`
- `values.yaml` — local defaults (plaintext Kafka, Ollama LLM, in-cluster pgvector)
- `values-aws.yaml` — AWS overlay (MSK IAM, Bedrock, Aurora pgvector, IRSA role ARN annotation)
- `templates/` — ServiceAccount, ConfigMap, Deployments/Job/CronJob as applicable

Dynamic values (MSK brokers, OpenSearch + Aurora endpoints, pgvector secret
ARN, Iceberg warehouse, Glue registry, Athena workgroup + results bucket)
are *not* set in values-aws.yaml. Terraform writes them to AWS SSM Parameter
Store at `/videostreamingplatform/<env>/*` (`terraform/aws/ssm.tf`); the
`external-secrets-operator` app and its `ClusterSecretStore` (via the
`charts/external-secrets-config` chart) materialize them into per-namespace
Secrets mounted via `envFrom`. The only remaining bootstrap value is the
ServiceAccount IRSA role ARN in each chart's `values-aws.yaml` — SA
annotations can't be rendered by ESO, and the role name is deterministic
from terraform.

## External Secrets Operator

Two ArgoCD apps wire up the secret-substitution pipeline:

| App | Sync-wave | Source | Purpose |
|-----|-----------|--------|---------|
| `external-secrets-operator` | -10 | upstream `charts.external-secrets.io/external-secrets` | Installs ESO + CRDs |
| `external-secrets-config` | -5 | `charts/external-secrets-config` | ClusterSecretStore `aws-ssm` pointing at SSM Parameter Store |

ESO runs as `external-secrets:external-secrets` ServiceAccount with an
IRSA role (`terraform/aws/eso.tf`) scoped to read the
`/videostreamingplatform/${env}/*` SSM prefix plus the pgvector
Secrets Manager secret. Each consuming chart declares an `ExternalSecret`
CR (e.g. `charts/analytics/templates/externalsecret.yaml`) with
`sync-wave: -1` so the Secret exists before workload pods start.

## Terraform (AWS)

`terraform/aws/` provisions data-plane AWS resources and reads VPC + EKS
OIDC provider via remote state from the platform repo:

| File | Resources |
|------|-----------|
| `msk.tf` | MSK Serverless cluster (SASL/IAM) |
| `pgvector.tf` | Aurora Postgres Serverless v2 + Secrets Manager password |
| `glue.tf` | Glue catalog database, Schema Registry, Iceberg S3 bucket |
| `opensearch.tf` | OpenSearch Service (VPC, fine-grained IAM auth) — video search index |
| `athena.tf` | Athena workgroup (engine v3 for Iceberg) + results S3 bucket |
| `iam.tf` | IRSA roles for `analytics-sa` and `recommendations-sa` |
| `outputs.tf` | Bootstrap brokers, endpoints, role ARNs, secret ARN |

IAM scope per IRSA role:

- `analytics-sa` → Glue catalog + Schema Registry, Iceberg S3 RW, MSK produce/consume, **OpenSearch index RW**, **Athena query + results bucket RW**
- `recommendations-sa` → Bedrock invoke (ranking + embedding), Secrets Manager read, MSK consume, **OpenSearch read**

## CI

GitHub Actions (`infra-ci.yml`) runs on push/PR to `master`:
- Validates all non-ArgoCD `*.yaml` files with `kubeconform -strict`
- Validates `argocd/` CRDs separately using the datreeio CRDs catalog
- Lints `docker-compose.infra.yml` with `docker compose config --quiet`

ArgoCD manifests are excluded from standard kubeconform and validated with CRD schemas instead.
