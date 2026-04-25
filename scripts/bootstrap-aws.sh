#!/usr/bin/env bash
#
# bootstrap-aws.sh — End-to-end AWS bring-up for videostreamingplatform.
#
# Runs three phases, each individually re-runnable:
#
#   1. AWS state backend
#      Create the S3 state bucket + DynamoDB lock table if missing. These are
#      the prerequisites for every `terraform init` that uses the remote
#      backend. Idempotent — skips creation if resources already exist.
#
#   2. Terraform apply
#      a. Platform module (videostreamingplatform/k8s/aws/terraform):
#         VPC, EKS, RDS, S3, OpenSearch, CloudFront, Redis.
#      b. Infra module (videostreamingplatform-infra/terraform/aws):
#         Glue catalog, Athena, IRSA roles (reads EKS OIDC from module a).
#      Order matters — module b reads remote state from module a.
#
#   3. Deploy workloads (two modes)
#      Default mode: direct — applies raw manifests with kubectl and installs
#      Helm charts directly. Fastest path; no GitOps reconciliation loop.
#      With --argocd: installs ArgoCD from the argo/argo-cd Helm chart and
#      applies AppProjects + Applications from argocd/. ArgoCD then reconciles
#      the cluster to match Git. Use this when you want GitOps in the long run.
#
# Usage:
#   ./scripts/bootstrap-aws.sh                       # all phases, direct deploy
#   ./scripts/bootstrap-aws.sh --argocd              # all phases, ArgoCD deploy
#   ./scripts/bootstrap-aws.sh --only-state          # phase 1 only
#   ./scripts/bootstrap-aws.sh --only-terraform      # phase 2 only
#   ./scripts/bootstrap-aws.sh --only-deploy         # phase 3 only (direct)
#   ./scripts/bootstrap-aws.sh --only-deploy --argocd   # phase 3 only (ArgoCD)
#   ./scripts/bootstrap-aws.sh --skip-state          # phases 2+3
#   ./scripts/bootstrap-aws.sh --yes                 # non-interactive
#
# Env overrides:
#   AWS_REGION                 (default: us-east-1)
#   TF_STATE_BUCKET            (default: videostreamingplatform-terraform-state)
#   TF_LOCK_TABLE              (default: terraform-locks)
#   TFVARS_FILE                (default: terraform.dev.tfvars)
#   ARGOCD_CHART_VERSION       (default: 7.7.10 — argo/argo-cd Helm chart)
#   ENVIRONMENT                (default: dev — used to derive cluster name)
#   DEPLOY_MODE                (default: direct — set to "argocd" to force)
#
# RDS password:
#   The platform module sets `manage_master_user_password = true`, so AWS RDS
#   generates a random password on create and stores it in Secrets Manager
#   (ARN available via `terraform output rds_master_user_secret_arn`).
#   No password needs to be supplied here.
#
# Requires: aws, terraform, kubectl, helm.

set -euo pipefail

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
INFRA_REPO_ROOT="${INFRA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLATFORM_REPO_ROOT="${PLATFORM_REPO_ROOT:-$(cd "$INFRA_REPO_ROOT/../videostreamingplatform" && pwd)}"
PLATFORM_TF_DIR="$PLATFORM_REPO_ROOT/k8s/aws/terraform"
INFRA_TF_DIR="$INFRA_REPO_ROOT/terraform/aws"
PLATFORM_MANIFESTS_DIR="$PLATFORM_REPO_ROOT/k8s/aws/manifests"
ARGOCD_DIR="$INFRA_REPO_ROOT/argocd"

AWS_REGION="${AWS_REGION:-us-east-1}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-videostreamingplatform-terraform-state}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-terraform-locks}"
TFVARS_FILE="${TFVARS_FILE:-terraform.dev.tfvars}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.10}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CLUSTER_NAME="${CLUSTER_NAME:-videostreamingplatform-${ENVIRONMENT}}"
DEPLOY_MODE="${DEPLOY_MODE:-direct}"

YES=0
PHASE_STATE=1
PHASE_TERRAFORM=1
PHASE_DEPLOY=1

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  [[ "$YES" == 1 ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y)          YES=1 ;;
      --argocd)          DEPLOY_MODE="argocd" ;;
      --direct)          DEPLOY_MODE="direct" ;;
      --only-state)      PHASE_TERRAFORM=0; PHASE_DEPLOY=0 ;;
      --only-terraform)  PHASE_STATE=0; PHASE_DEPLOY=0 ;;
      --only-deploy)     PHASE_STATE=0; PHASE_TERRAFORM=0 ;;
      --only-argocd)     PHASE_STATE=0; PHASE_TERRAFORM=0; DEPLOY_MODE="argocd" ;;
      --skip-state)      PHASE_STATE=0 ;;
      --skip-terraform)  PHASE_TERRAFORM=0 ;;
      --skip-deploy)     PHASE_DEPLOY=0 ;;
      --skip-argocd)     PHASE_DEPLOY=0 ;;
      -h|--help)         sed -n '2,50p' "$0"; exit 0 ;;
      *)                 die "unknown arg: $1" ;;
    esac
    shift
  done
  [[ "$DEPLOY_MODE" == "direct" || "$DEPLOY_MODE" == "argocd" ]] || \
    die "DEPLOY_MODE must be 'direct' or 'argocd', got: $DEPLOY_MODE"
}

# ----------------------------------------------------------------------------
# Phase 1 — AWS state backend
# ----------------------------------------------------------------------------
phase_state() {
  log "phase 1: ensure terraform state backend"

  if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
    log "  bucket $TF_STATE_BUCKET already exists"
  else
    log "  creating bucket $TF_STATE_BUCKET"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION"
    else
      aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$AWS_REGION" \
        --create-bucket-configuration "LocationConstraint=$AWS_REGION"
    fi
    aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" \
      --versioning-configuration Status=Enabled
    aws s3api put-bucket-encryption --bucket "$TF_STATE_BUCKET" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    aws s3api put-public-access-block --bucket "$TF_STATE_BUCKET" \
      --public-access-block-configuration \
      'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
  fi

  if aws dynamodb describe-table --table-name "$TF_LOCK_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
    log "  table $TF_LOCK_TABLE already exists"
  else
    log "  creating DynamoDB table $TF_LOCK_TABLE"
    aws dynamodb create-table \
      --region "$AWS_REGION" \
      --table-name "$TF_LOCK_TABLE" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST >/dev/null
    aws dynamodb wait table-exists --table-name "$TF_LOCK_TABLE" --region "$AWS_REGION"
  fi
}

# ----------------------------------------------------------------------------
# Phase 2 — terraform apply (platform, then infra)
# ----------------------------------------------------------------------------
terraform_apply() {
  local dir="$1" label="$2"
  [[ -d "$dir" ]] || die "$label: $dir not found"
  [[ -f "$dir/$TFVARS_FILE" ]] || die "$label: $TFVARS_FILE missing in $dir"
  log "  terraform apply: $label  ($dir)"
  (
    cd "$dir"
    terraform init -input=false -upgrade=false >/dev/null
    terraform apply -auto-approve -var-file="$TFVARS_FILE"
  )
}

phase_terraform() {
  log "phase 2: terraform apply (platform -> infra)"
  log "  RDS master password: AWS-managed (manage_master_user_password=true) — stored in Secrets Manager"

  terraform_apply "$PLATFORM_TF_DIR" "platform (EKS/VPC/RDS/S3/OpenSearch/CloudFront/Redis)"
  terraform_apply "$INFRA_TF_DIR"    "infra (Glue/Athena/IRSA)"

  log "  RDS master user secret ARN:"
  ( cd "$PLATFORM_TF_DIR" && terraform output -raw rds_master_user_secret_arn 2>/dev/null ) || \
    warn "  (could not read rds_master_user_secret_arn — check platform outputs)"
  echo
}

# ----------------------------------------------------------------------------
# Phase 3 — deploy workloads (direct | argocd)
# ----------------------------------------------------------------------------
kubeconfig_update() {
  log "  aws eks update-kubeconfig  cluster=$CLUSTER_NAME  region=$AWS_REGION"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
}

# Create a dockerconfigjson Secret `ghcr-pull` in every namespace that
# consumes private ghcr.io images, using the local `gh auth` token (requires
# `read:packages` scope). Also patches the Helm-managed service accounts
# (analytics-sa, recommendations-sa) so their pods pick up the pull secret
# without chart modifications. videostreamingplatform-sa / infra-sa already
# reference `ghcr-pull` via rbac/service-accounts.yaml.
# Override via GHCR_USERNAME / GHCR_TOKEN / GHCR_EMAIL env vars.
seed_ghcr_secret() {
  log "  seeding ghcr-pull imagePullSecret"
  local user pass email
  user="${GHCR_USERNAME:-$(gh api user --jq .login 2>/dev/null)}"
  pass="${GHCR_TOKEN:-$(gh auth token 2>/dev/null)}"
  email="${GHCR_EMAIL:-${user}@users.noreply.github.com}"
  [[ -n "$user" && -n "$pass" ]] || { warn "    no gh token (run 'gh auth login' or set GHCR_TOKEN) — skipping"; return 0; }

  local ns
  for ns in videostreamingplatform analytics recommendations; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create secret docker-registry ghcr-pull \
      --namespace "$ns" \
      --docker-server=ghcr.io \
      --docker-username="$user" \
      --docker-password="$pass" \
      --docker-email="$email" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  log "    ghcr-pull Secret applied in 3 namespaces"
}

# Patch a Helm-created ServiceAccount to reference the ghcr-pull secret.
# Idempotent — `kubectl patch` re-applies the same pullsecret list on reruns.
patch_sa_ghcr_pull() {
  local ns="$1" sa="$2"
  kubectl -n "$ns" get sa "$sa" >/dev/null 2>&1 || { warn "    sa $ns/$sa not found — skipping patch"; return 0; }
  kubectl patch serviceaccount "$sa" -n "$ns" \
    -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}' >/dev/null
  log "    patched $ns/$sa with imagePullSecrets=ghcr-pull"
}

# Fetch the RDS master credentials from AWS Secrets Manager (populated by
# `manage_master_user_password = true`) and project them into a Kubernetes
# Secret named `rds-credentials` in the `videostreamingplatform` namespace.
# Keys match what metadata-service / data-service deployments consume:
#   host, port, username, password, database
# Idempotent — uses `kubectl apply -f -` via a dry-run manifest so re-running
# this phase just updates the Secret in place.
seed_rds_secret() {
  log "  seeding rds-credentials Secret from Secrets Manager"

  local secret_arn rds_endpoint rds_address rds_db user pass host port
  secret_arn=$( cd "$PLATFORM_TF_DIR" && terraform output -raw rds_master_user_secret_arn 2>/dev/null ) || \
    { warn "    rds_master_user_secret_arn missing — skipping (apps will fail to connect)"; return 0; }
  rds_endpoint=$( cd "$PLATFORM_TF_DIR" && terraform output -raw rds_endpoint 2>/dev/null ) || rds_endpoint=""
  rds_address=$( cd "$PLATFORM_TF_DIR" && terraform output -raw rds_address 2>/dev/null ) || rds_address=""
  rds_db=$( cd "$PLATFORM_TF_DIR" && terraform output -raw rds_database_name 2>/dev/null ) || rds_db="videoplatform"

  host="${rds_address:-${rds_endpoint%:*}}"
  port="3306"
  if [[ "$rds_endpoint" == *:* ]]; then port="${rds_endpoint##*:}"; fi
  [[ -n "$host" ]] || { warn "    could not resolve RDS host — skipping"; return 0; }

  # Secrets Manager stores the value as JSON: {"username":"...","password":"..."}.
  # We parse without jq (not guaranteed to be installed) using python3.
  local json
  json=$(aws secretsmanager get-secret-value \
           --region "$AWS_REGION" \
           --secret-id "$secret_arn" \
           --query 'SecretString' --output text 2>/dev/null) || \
    { warn "    failed to read secret from Secrets Manager — skipping"; return 0; }
  user=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["username"])' 2>/dev/null)
  pass=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])' 2>/dev/null)
  [[ -n "$user" && -n "$pass" ]] || { warn "    Secrets Manager payload missing username/password — skipping"; return 0; }

  kubectl create namespace videostreamingplatform --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl create secret generic rds-credentials \
    --namespace videostreamingplatform \
    --from-literal=host="$host" \
    --from-literal=port="$port" \
    --from-literal=username="$user" \
    --from-literal=password="$pass" \
    --from-literal=database="$rds_db" \
    --dry-run=client -o yaml | kubectl apply -f -

  log "    rds-credentials Secret applied (host=$host, db=$rds_db, user=$user)"
}

# Load init-db.sql from the platform repo into a ConfigMap and run the
# db-init Job (applies schema to RDS using the rds-credentials Secret).
# Idempotent — the SQL uses CREATE TABLE IF NOT EXISTS, and the Job has
# ttlSecondsAfterFinished so successful runs auto-clean.
init_rds_schema() {
  local sql_file="$PLATFORM_REPO_ROOT/scripts/init-db.sql"
  local job_file="$PLATFORM_MANIFESTS_DIR/db-init-job.yaml"
  [[ -f "$sql_file" ]] || { warn "    $sql_file not found — skipping schema init"; return 0; }
  [[ -f "$job_file" ]] || { warn "    $job_file not found — skipping schema init"; return 0; }

  log "  loading init-db.sql into ConfigMap db-init-schema"
  kubectl create configmap db-init-schema \
    --namespace videostreamingplatform \
    --from-file=init-db.sql="$sql_file" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  log "  applying db-init Job"
  # Delete any prior Job so we can re-run with the latest schema — Jobs
  # are immutable once created.
  kubectl delete job db-init -n videostreamingplatform --ignore-not-found >/dev/null
  kubectl apply -f "$job_file"

  log "  waiting up to 5m for db-init Job to complete"
  if kubectl wait -n videostreamingplatform --for=condition=complete job/db-init --timeout=5m; then
    log "    db-init Job completed"
  else
    warn "    db-init Job did not complete within 5m — check: kubectl logs -n videostreamingplatform job/db-init"
  fi
}

# Export all the template variables referenced as ${VAR} in
# videostreamingplatform/k8s/aws/manifests/*.yaml. Sourced from terraform
# outputs (for AWS-provisioned resources) and static in-cluster DNS (for
# components that run as StatefulSets — kafka, elasticsearch). These are
# the exact keys used by `envsubst` in `apply_rendered_manifests`.
export_manifest_vars() {
  # Static in-cluster endpoints (identical on local + AWS per CLAUDE.md)
  export KAFKA_BROKERS="${KAFKA_BROKERS:-kafka.infra.svc.cluster.local:9092}"
  export OPENSEARCH_ENDPOINT="${OPENSEARCH_ENDPOINT:-http://elasticsearch.videostreamingplatform.svc.cluster.local:9200}"
  export AWS_REGION

  # Terraform outputs from the platform module
  if [[ -d "$PLATFORM_TF_DIR" ]]; then
    export S3_BUCKET="$(cd "$PLATFORM_TF_DIR" && terraform output -raw s3_videos_bucket 2>/dev/null || echo '')"
    export REDIS_ENDPOINT="$(cd "$PLATFORM_TF_DIR" && terraform output -raw redis_endpoint 2>/dev/null || echo '')"
    export CDN_DISTRIBUTION_ID="$(cd "$PLATFORM_TF_DIR" && terraform output -raw cloudfront_distribution_id 2>/dev/null || echo '')"
    export IRSA_METADATA_ROLE_ARN="$(cd "$PLATFORM_TF_DIR" && terraform output -raw metadata_service_irsa_role_arn 2>/dev/null || echo '')"
    export IRSA_DATA_ROLE_ARN="$(cd "$PLATFORM_TF_DIR" && terraform output -raw data_service_irsa_role_arn 2>/dev/null || echo '')"
  fi

  # Warn on any still-empty required vars (envsubst would leave them blank,
  # yielding an invalid manifest — easier to catch here than at apply time).
  local var
  for var in S3_BUCKET REDIS_ENDPOINT CDN_DISTRIBUTION_ID IRSA_METADATA_ROLE_ARN IRSA_DATA_ROLE_ARN; do
    [[ -n "${!var}" ]] || warn "    $var is empty — rendered manifest will have a blank field"
  done
}

# Render every YAML in a directory through envsubst and apply. Uses a
# space-delimited list of allowed variables so unrelated ${...} references
# in manifest bodies (e.g. shell patterns in inline scripts) are preserved.
apply_rendered_manifests() {
  local src_dir="$1"
  [[ -d "$src_dir" ]] || { warn "    $src_dir not found — skipping"; return 0; }
  command -v envsubst >/dev/null 2>&1 || die "envsubst not found (install gettext-base)"

  local vars='$AWS_REGION $S3_BUCKET $OPENSEARCH_ENDPOINT $REDIS_ENDPOINT $KAFKA_BROKERS $CDN_DISTRIBUTION_ID $IRSA_METADATA_ROLE_ARN $IRSA_DATA_ROLE_ARN'
  local f
  while IFS= read -r -d '' f; do
    # db-init-job is applied separately by init_rds_schema (needs ordering
    # against the Secret + ConfigMap, no templating required).
    [[ "$(basename "$f")" == "db-init-job.yaml" ]] && continue
    log "    applying (rendered) $f"
    envsubst "$vars" < "$f" | kubectl apply -f -
  done < <(find "$src_dir" -maxdepth 1 -type f -name '*.yaml' -print0)
}

# Apply raw manifests + Helm charts directly. No GitOps controller.
phase_deploy_direct() {
  log "phase 3: direct deployment (kubectl + helm)"
  kubeconfig_update

  # 3.1 Namespaces + RBAC
  log "  applying namespaces"
  kubectl apply -f "$INFRA_REPO_ROOT/networking/namespaces.yaml"
  log "  applying RBAC (service accounts)"
  kubectl apply -f "$INFRA_REPO_ROOT/rbac/"

  # 3.1.a.0 Seed ghcr-pull Secret in namespaces that consume private
  # ghcr.io images. Must run before any pod that references the Secret,
  # i.e. before core services / Helm installs.
  seed_ghcr_secret

  # 3.1.a Seed rds-credentials Secret from Secrets Manager (needed by
  # metadata-service / data-service before they start).
  seed_rds_secret

  # 3.1.b Load init-db.sql into a ConfigMap and run the one-shot db-init
  # Job so MySQL schema exists before services connect.
  init_rds_schema

  # 3.2 Shared in-cluster infra (Kafka + pgvector)
  log "  applying shared infra (kafka, pgvector)"
  kubectl apply -f "$INFRA_REPO_ROOT/kafka/"
  kubectl apply -f "$INFRA_REPO_ROOT/pgvector/"

  # 3.3 Network policies (applied after pods so labels match)
  log "  applying network policies"
  kubectl apply -f "$INFRA_REPO_ROOT/networking/network-policies.yaml" || \
    warn "  network-policies apply failed — continuing"

  # 3.4 Core services (videostreamingplatform/k8s/aws/manifests)
  # Manifests contain ${VAR} placeholders (IRSA ARNs, S3 bucket, CloudFront
  # ID, Redis endpoint, etc.) — render via envsubst before apply.
  if [[ -d "$PLATFORM_MANIFESTS_DIR" ]]; then
    log "  rendering + applying core services from $PLATFORM_MANIFESTS_DIR"
    export_manifest_vars
    apply_rendered_manifests "$PLATFORM_MANIFESTS_DIR"
  else
    warn "  $PLATFORM_MANIFESTS_DIR not found — skipping core services"
  fi

  # 3.5 Helm charts (analytics + recommendations)
  # IRSA role ARNs come from the infra TF module outputs. values-aws.yaml
  # carries a literal ROLE_ARN_PLACEHOLDER that Helm would otherwise pass
  # through untouched, leaving pods with no valid IAM identity. Substitute
  # via --set-string so we never commit per-account ARNs to Git.
  local analytics_role_arn recommendations_role_arn
  analytics_role_arn=$( cd "$INFRA_TF_DIR" && terraform output -raw analytics_irsa_role_arn 2>/dev/null ) || analytics_role_arn=""
  recommendations_role_arn=$( cd "$INFRA_TF_DIR" && terraform output -raw recommendations_irsa_role_arn 2>/dev/null ) || recommendations_role_arn=""
  [[ -n "$analytics_role_arn"       ]] || warn "    analytics_irsa_role_arn output missing — SA will have placeholder ARN"
  [[ -n "$recommendations_role_arn" ]] || warn "    recommendations_irsa_role_arn output missing — SA will have placeholder ARN"

  log "  helm upgrade --install analytics"
  helm upgrade --install analytics "$INFRA_REPO_ROOT/charts/analytics" \
    --namespace analytics --create-namespace \
    -f "$INFRA_REPO_ROOT/charts/analytics/values.yaml" \
    -f "$INFRA_REPO_ROOT/charts/analytics/values-aws.yaml" \
    ${analytics_role_arn:+--set-string serviceAccount.roleArn="$analytics_role_arn"} \
    --wait --timeout 5m || warn "  analytics chart did not reach ready in 5m"
  patch_sa_ghcr_pull analytics analytics-sa

  log "  helm upgrade --install recommendations"
  helm upgrade --install recommendations "$INFRA_REPO_ROOT/charts/recommendations" \
    --namespace recommendations --create-namespace \
    -f "$INFRA_REPO_ROOT/charts/recommendations/values.yaml" \
    -f "$INFRA_REPO_ROOT/charts/recommendations/values-aws.yaml" \
    ${recommendations_role_arn:+--set-string serviceAccount.roleArn="$recommendations_role_arn"} \
    --wait --timeout 5m || warn "  recommendations chart did not reach ready in 5m"
  patch_sa_ghcr_pull recommendations recommendations-sa

  log "  final pod status:"
  kubectl get pods -A -o \
    custom-columns='NS:.metadata.namespace,NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[*].ready' \
    | grep -v '^kube-system' || true
}

# Install ArgoCD and hand the cluster over to GitOps reconciliation.
phase_deploy_argocd() {
  log "phase 3: install ArgoCD + apply apps"
  kubeconfig_update

  # Seed imagePullSecret + rds-credentials before ArgoCD-managed workloads
  # sync. ArgoCD does not manage secrets that originate outside Git, so
  # bootstrap owns both.
  seed_ghcr_secret
  seed_rds_secret

  log "  installing ArgoCD via Helm (chart version $ARGOCD_CHART_VERSION)"
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update >/dev/null
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --version "$ARGOCD_CHART_VERSION" \
    --wait --timeout 10m

  [[ -d "$ARGOCD_DIR" ]] || die "$ARGOCD_DIR not found — can't apply AppProjects/Applications"

  log "  applying AppProjects"
  kubectl apply -f "$ARGOCD_DIR/appprojects/"

  log "  applying Applications"
  kubectl apply -f "$ARGOCD_DIR/apps/"

  log "  waiting up to 10m for each Application to reach Synced + Healthy"
  sleep 15
  local apps exit_code=0
  apps=$(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  for app in $apps; do
    log "  - $app"
    kubectl wait -n argocd "application/$app" \
      --for=jsonpath='{.status.sync.status}'=Synced --timeout=600s || \
      { warn "    $app did not reach Synced"; exit_code=1; }
    kubectl wait -n argocd "application/$app" \
      --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s || \
      { warn "    $app did not reach Healthy"; exit_code=1; }
  done

  log "  final Application status:"
  kubectl get applications -n argocd -o \
    custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' || true

  log "  ArgoCD admin password:"
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || \
    warn "  (secret not found — either already rotated or not yet created)"
  echo
  return $exit_code
}

phase_deploy() {
  if [[ "$DEPLOY_MODE" == "argocd" ]]; then
    phase_deploy_argocd
  else
    phase_deploy_direct
  fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_cmd aws
  require_cmd terraform
  require_cmd kubectl
  require_cmd helm
  require_cmd gh

  log "plan (deploy mode: $DEPLOY_MODE):"
  [[ "$PHASE_STATE"     == 1 ]] && log "  1. ensure S3 state bucket + DynamoDB lock table"
  [[ "$PHASE_TERRAFORM" == 1 ]] && log "  2. terraform apply -> platform + infra"
  if [[ "$PHASE_DEPLOY" == 1 ]]; then
    if [[ "$DEPLOY_MODE" == "argocd" ]]; then
      log "  3. install ArgoCD + apply AppProjects/Applications"
    else
      log "  3. kubectl apply manifests + helm install charts (direct deploy)"
    fi
  fi
  confirm "proceed?" || die "aborted"

  [[ "$PHASE_STATE"     == 1 ]] && phase_state
  [[ "$PHASE_TERRAFORM" == 1 ]] && phase_terraform
  [[ "$PHASE_DEPLOY"    == 1 ]] && phase_deploy

  log "done."
}

main "$@"
