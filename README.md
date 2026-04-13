# Video Streaming Platform — Infrastructure

Shared infrastructure for the video streaming platform, managed via ArgoCD GitOps.

## Components

| Component | Purpose | Namespace |
|-----------|---------|-----------|
| Kafka (KRaft) | Event streaming (video-events, watch-events) | infra |
| LocalStack | AWS Glue Schema Registry (local dev) | infra |
| pgvector | Vector database for recommendation embeddings | infra |
| ArgoCD | GitOps controller for all repos | argocd |

## Architecture

```
Single K8s Cluster
├── argocd namespace      — ArgoCD controller
├── infra namespace       — Kafka, LocalStack, pgvector (this repo)
├── videostreamingplatform — Go services + MySQL/MinIO/ES
├── analytics namespace   — Spark + Kafka→ES consumer
└── recommendations namespace — LangGraph AI agent
```

## Local Development

### Start shared infrastructure
```bash
make up      # Start Kafka, LocalStack, pgvector via Docker Compose
make status  # Check service health
make down    # Stop all services
```

### Apply to local K8s cluster
```bash
make apply-local  # Apply all K8s manifests
```

## ArgoCD Setup

ArgoCD manages deployments from all repos:

| App | Source Repo | Target Namespace |
|-----|-----------|-----------------|
| videostreamingplatform | videostreamingplatform | videostreamingplatform |
| analytics | videostreamingplatform-analytics | analytics |
| recommendations | videostreamingplatform-recommendations | recommendations |
| infra | videostreamingplatform-infra | infra |

## Networks & RBAC

- All app namespaces can access Kafka (port 9092) in `infra` namespace
- Only `recommendations` namespace can access pgvector (port 5432) in `infra` namespace
- Each namespace has its own ServiceAccount
