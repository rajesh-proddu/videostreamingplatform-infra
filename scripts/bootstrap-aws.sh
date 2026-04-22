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
#   3. ArgoCD install + apps
#      Install ArgoCD from upstream manifests, wait for its server to be
#      ready, then apply AppProjects + Applications from argocd/. ArgoCD
#      reconciles the cluster to match Git from this point on.
#
# Usage:
#   ./scripts/bootstrap-aws.sh                       # all three phases
#   ./scripts/bootstrap-aws.sh --only-state          # phase 1 only
#   ./scripts/bootstrap-aws.sh --only-terraform      # phase 2 only
#   ./scripts/bootstrap-aws.sh --only-argocd         # phase 3 only
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
#   TF_VAR_rds_master_password (required for phase 2)
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
ARGOCD_DIR="$INFRA_REPO_ROOT/argocd"

AWS_REGION="${AWS_REGION:-us-east-1}"
TF_STATE_BUCKET="${TF_STATE_BUCKET:-videostreamingplatform-terraform-state}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-terraform-locks}"
TFVARS_FILE="${TFVARS_FILE:-terraform.dev.tfvars}"
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.10}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
CLUSTER_NAME="${CLUSTER_NAME:-videostreamingplatform-${ENVIRONMENT}}"

YES=0
PHASE_STATE=1
PHASE_TERRAFORM=1
PHASE_ARGOCD=1

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
      --only-state)      PHASE_TERRAFORM=0; PHASE_ARGOCD=0 ;;
      --only-terraform)  PHASE_STATE=0; PHASE_ARGOCD=0 ;;
      --only-argocd)     PHASE_STATE=0; PHASE_TERRAFORM=0 ;;
      --skip-state)      PHASE_STATE=0 ;;
      --skip-terraform)  PHASE_TERRAFORM=0 ;;
      --skip-argocd)     PHASE_ARGOCD=0 ;;
      -h|--help)         sed -n '2,34p' "$0"; exit 0 ;;
      *)                 die "unknown arg: $1" ;;
    esac
    shift
  done
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

  if [[ -z "${TF_VAR_rds_master_password:-}" ]]; then
    die "TF_VAR_rds_master_password must be set for phase 2 (platform RDS)"
  fi

  terraform_apply "$PLATFORM_TF_DIR" "platform (EKS/VPC/RDS/S3/OpenSearch/CloudFront/Redis)"
  terraform_apply "$INFRA_TF_DIR"    "infra (Glue/Athena/IRSA)"
}

# ----------------------------------------------------------------------------
# Phase 3 — ArgoCD install + apps
# ----------------------------------------------------------------------------
phase_argocd() {
  log "phase 3: install ArgoCD + apply apps"

  log "  aws eks update-kubeconfig  cluster=$CLUSTER_NAME  region=$AWS_REGION"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

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

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_cmd aws
  require_cmd terraform
  require_cmd kubectl
  require_cmd helm

  log "plan:"
  [[ "$PHASE_STATE"     == 1 ]] && log "  1. ensure S3 state bucket + DynamoDB lock table"
  [[ "$PHASE_TERRAFORM" == 1 ]] && log "  2. terraform apply -> platform + infra"
  [[ "$PHASE_ARGOCD"    == 1 ]] && log "  3. install ArgoCD + apply AppProjects/Applications"
  confirm "proceed?" || die "aborted"

  [[ "$PHASE_STATE"     == 1 ]] && phase_state
  [[ "$PHASE_TERRAFORM" == 1 ]] && phase_terraform
  [[ "$PHASE_ARGOCD"    == 1 ]] && phase_argocd

  log "done."
}

main "$@"
