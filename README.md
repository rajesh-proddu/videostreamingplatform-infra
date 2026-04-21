# Video Streaming Platform — Infrastructure (GitOps)

Shared infrastructure **and** GitOps source of truth for the video streaming
platform. Terraform provisions AWS managed services; ArgoCD renders Helm
charts from this repo onto the target cluster.

## Components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| Kafka (KRaft) | Event streaming (video-events, watch-events) — local only | infra |
| LocalStack | AWS Glue Schema Registry (local dev) | infra |
| pgvector | Vector database for recommendation embeddings — local only | infra |
| ArgoCD | GitOps controller for all repos | argocd |

In AWS the `infra` namespace workloads are replaced by managed services:
MSK Serverless (Kafka), Glue (Schema Registry + catalog), Aurora Postgres
Serverless v2 (pgvector), S3 (Iceberg warehouse), OpenSearch Service
(video search index), and an Athena workgroup for ad-hoc Iceberg queries.

## Repository Layout

```
terraform/aws/     — MSK, Aurora pgvector, Glue, Iceberg S3, OpenSearch, Athena, IRSA
charts/            — Helm charts rendered by ArgoCD
  analytics/         values.yaml (local) + values-aws.yaml (AWS overlay)
  recommendations/   values.yaml (local) + values-aws.yaml (AWS overlay)
argocd/
  appprojects/     — platform, data
  apps/            — videostreamingplatform, infra, analytics, recommendations
kafka/             — local Kafka StatefulSet + topics-init Job
pgvector/          — local pgvector StatefulSet
schema-registry/   — local LocalStack (Glue emulation)
networking/        — namespaces + NetworkPolicies
rbac/              — per-namespace ServiceAccounts
```

## Local Development

```bash
make up           # Start Kafka, LocalStack, pgvector via Docker Compose
make apply-local  # Apply all K8s manifests to local cluster
make status       # Check service health
make down         # Stop all services
```

## AWS Deployment

1. Provision managed services:
   ```bash
   cd terraform/aws
   terraform init
   terraform apply
   ```
2. Substitute terraform outputs into `charts/*/values-aws.yaml`
   (`BOOTSTRAP_BROKERS_PLACEHOLDER`, `ROLE_ARN_PLACEHOLDER`,
   `PG_ENDPOINT_PLACEHOLDER`, `PG_SECRET_ARN_PLACEHOLDER`,
   `OPENSEARCH_ENDPOINT_PLACEHOLDER`) via external-secrets-operator
   or a bootstrap PR.
3. ArgoCD auto-syncs `analytics` and `recommendations` from the Helm charts.

Terraform remote state reads VPC + EKS OIDC provider from the platform
repo's state, so this repo only owns data-plane resources.

## ArgoCD Applications

| App | Source | Path | Target Namespace |
|-----|--------|------|-----------------|
| videostreamingplatform | videostreamingplatform | `k8s/local` | videostreamingplatform |
| infra | videostreamingplatform-infra | `.` (root manifests) | infra |
| analytics | videostreamingplatform-infra | `charts/analytics` (Helm) | analytics |
| recommendations | videostreamingplatform-infra | `charts/recommendations` (Helm) | recommendations |

Each data-plane Application uses `spec.source.helm.valueFiles: [values.yaml, values-aws.yaml]`.
Drop `values-aws.yaml` (or omit the `helm` block) to render the chart with
plain defaults against Docker Compose / Kind.

The service repos (`videostreamingplatform-analytics`,
`videostreamingplatform-recommendations`) own code and CI only — no K8s
manifests. CI builds and publishes container images; Helm charts here
reference them by tag.

## Networks & RBAC

- All app namespaces can access Kafka (port 9092) in `infra` namespace (local only)
- Only `recommendations` namespace accesses pgvector (port 5432) in `infra` namespace (local only)
- Each namespace has its own ServiceAccount; AWS overlays annotate them with IRSA role ARNs
