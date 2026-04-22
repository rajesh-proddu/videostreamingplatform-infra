.PHONY: up down status apply-local bootstrap-aws teardown-aws help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: ## Start local infra services (Kafka, LocalStack, pgvector)
	docker compose -f docker-compose.infra.yml up -d

down: ## Stop local infra services
	docker compose -f docker-compose.infra.yml down

status: ## Show status of local infra services
	docker compose -f docker-compose.infra.yml ps

apply-local: ## Apply K8s manifests to local cluster
	kubectl apply -f networking/namespaces.yaml
	kubectl apply -f rbac/service-accounts.yaml
	kubectl apply -f kafka/
	kubectl apply -f schema-registry/
	kubectl apply -f pgvector/
	kubectl apply -f networking/network-policies.yaml

bootstrap-aws: ## Bring up AWS: state bucket + terraform + ArgoCD (see scripts/bootstrap-aws.sh)
	./scripts/bootstrap-aws.sh $(ARGS)

teardown-aws: ## Tear down EKS workloads + all AWS Terraform (see scripts/teardown-aws.sh)
	./scripts/teardown-aws.sh $(ARGS)

validate: ## Validate K8s manifests
	@echo "Validating manifests..."
	@find . -name '*.yaml' -not -path './.github/*' -not -path './docker-compose*' | while read f; do \
		kubectl apply --dry-run=client -f "$$f" 2>/dev/null && echo "✓ $$f" || echo "✗ $$f"; \
	done
