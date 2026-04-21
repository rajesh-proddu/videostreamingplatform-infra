# Video Streaming Platform — Infrastructure (GitOps)

Shared infrastructure **and** GitOps source of truth for the video streaming
platform. Terraform provisions a small set of AWS managed services (Glue +
Iceberg S3 + Athena + IRSA roles); everything else — Kafka, Elasticsearch,
pgvector — runs as in-cluster StatefulSets on both Kind (local) and EKS
(AWS), so the topology is identical across environments.

## Components

| Component | Purpose | Namespace | Where it runs |
|-----------|---------|-----------|---------------|
| Kafka (KRaft) | Event streaming (video-events, watch-events) | infra | in-cluster, local + AWS |
| pgvector | Vector database for recommendation embeddings | infra | in-cluster, local + AWS |
| Elasticsearch | Video search index | videostreamingplatform | in-cluster, local + AWS |
| LocalStack | Glue Schema Registry emulation (local only) | infra | local only |
| Glue + Iceberg S3 + Athena | Analytics catalog + warehouse + query engine | — | AWS only |
| ArgoCD | GitOps controller for all repos | argocd | in-cluster |

## Repository Layout

```
terraform/aws/     — Glue, Iceberg S3, Athena, IRSA roles
charts/            — Helm charts rendered by ArgoCD
  analytics/         values.yaml (defaults) + values-aws.yaml (AWS overlay)
  recommendations/   values.yaml (defaults) + values-aws.yaml (AWS overlay)
argocd/
  appprojects/     — platform project
  apps/            — videostreamingplatform, infra, elasticsearch, analytics, recommendations
kafka/             — Kafka StatefulSet + topics-init Job (infra ns)
pgvector/          — pgvector StatefulSet (infra ns)
elasticsearch/     — Elasticsearch StatefulSet (videostreamingplatform ns)
schema-registry/   — LocalStack (local only)
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

1. Provision the AWS-only resources:
   ```bash
   cd terraform/aws
   terraform init
   terraform apply
   ```
2. Paste the two IRSA role ARNs into the Helm overlays:
   ```bash
   terraform output analytics_irsa_role_arn
   terraform output recommendations_irsa_role_arn
   ```
   Update `charts/analytics/values-aws.yaml` and
   `charts/recommendations/values-aws.yaml` (`serviceAccount.roleArn`).
   If the Iceberg bucket / Athena workgroup / Athena results bucket names
   differ from the defaults baked into `values-aws.yaml`, update those too.
3. Commit + push. ArgoCD auto-syncs `analytics` and `recommendations` from
   the Helm charts, and the `infra` + `elasticsearch` apps bring up the
   in-cluster data plane.

Terraform remote state reads VPC + EKS OIDC provider from the platform
repo's state (same S3 bucket, key `dev/terraform.tfstate`), so this repo
only owns Glue/Iceberg/Athena/IRSA.

## ArgoCD Applications

| App | Source | Path | Target Namespace |
|-----|--------|------|-----------------|
| videostreamingplatform | videostreamingplatform | `k8s/local` | videostreamingplatform |
| infra | videostreamingplatform-infra | multi-source (kafka, pgvector, schema-registry, networking, rbac) | infra |
| elasticsearch | videostreamingplatform-infra | `elasticsearch` | videostreamingplatform |
| analytics | videostreamingplatform-infra | `charts/analytics` (Helm) | analytics |
| recommendations | videostreamingplatform-infra | `charts/recommendations` (Helm) | recommendations |

Each data-plane Application uses `spec.source.helm.valueFiles: [values.yaml, values-aws.yaml]`
on EKS and drops `values-aws.yaml` for Kind.

The service repos (`videostreamingplatform-analytics`,
`videostreamingplatform-recommendations`) own code and CI only — no K8s
manifests. CI builds and publishes container images; Helm charts here
reference them by tag.

## Networks & RBAC

- All app namespaces can access Kafka (port 9092) in `infra`
- Only `recommendations` namespace accesses pgvector (port 5432) in `infra` (policy permits all labeled namespaces)
- All app namespaces can access Elasticsearch (port 9200) in `videostreamingplatform`
- Each namespace has its own ServiceAccount; AWS overlays annotate `analytics-sa` and `recommendations-sa` with IRSA role ARNs
