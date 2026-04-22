#!/usr/bin/env bash
#
# teardown-aws.sh — Clean AWS teardown for videostreamingplatform.
#
# Order matters. If you skip step 1, ArgoCD-managed LoadBalancer Services
# leave behind orphaned NLBs / security groups / ENIs that block VPC delete
# and cause `terraform destroy` to hang for 15-20 minutes before erroring on
# DependencyViolation.
#
# Steps:
#   1. Delete all ArgoCD Applications (wait for finalizers).
#   2. Delete any remaining LoadBalancer Services across all namespaces.
#   3. Wait for the VPC to be free of non-default ENIs / SGs.
#   4. terraform destroy in videostreamingplatform-infra/terraform/aws
#      (Glue, Athena, IRSA roles — downstream of the EKS OIDC issuer).
#   5. terraform destroy in videostreamingplatform/k8s/aws/terraform
#      (EKS, VPC, RDS, S3, OpenSearch, CloudFront, Redis).
#
# Usage:
#   ./scripts/teardown-aws.sh                        # interactive, prompts before destroy
#   ./scripts/teardown-aws.sh --yes                  # non-interactive
#   ./scripts/teardown-aws.sh --skip-k8s             # only run terraform destroys
#   ./scripts/teardown-aws.sh --only-k8s             # only drain the cluster
#
# Requires: kubectl, aws, terraform, and a kubeconfig pointing at the EKS
# cluster you intend to tear down. The script refuses to run if the current
# kube-context does not look like an EKS context.

set -euo pipefail

# ----------------------------------------------------------------------------
# Config — override via env if your paths differ.
# ----------------------------------------------------------------------------
INFRA_REPO_ROOT="${INFRA_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLATFORM_REPO_ROOT="${PLATFORM_REPO_ROOT:-$(cd "$INFRA_REPO_ROOT/../videostreamingplatform" && pwd)}"
PLATFORM_TF_DIR="$PLATFORM_REPO_ROOT/k8s/aws/terraform"
INFRA_TF_DIR="$INFRA_REPO_ROOT/terraform/aws"
TFVARS_FILE="${TFVARS_FILE:-terraform.dev.tfvars}"
LB_WAIT_SECONDS="${LB_WAIT_SECONDS:-300}"
ENI_WAIT_SECONDS="${ENI_WAIT_SECONDS:-300}"

YES=0
SKIP_K8S=0
ONLY_K8S=0

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m[teardown]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[teardown]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[teardown]\033[0m %s\n' "$*" >&2; exit 1; }

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
      --yes|-y)      YES=1 ;;
      --skip-k8s)    SKIP_K8S=1 ;;
      --only-k8s)    ONLY_K8S=1 ;;
      -h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
      *)             die "unknown arg: $1" ;;
    esac
    shift
  done
}

# ----------------------------------------------------------------------------
# Step 1+2: drain the cluster
# ----------------------------------------------------------------------------
drain_cluster() {
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "")
  [[ -z "$ctx" ]] && { warn "no kube-context; skipping cluster drain"; return 0; }

  log "current kube-context: $ctx"
  if [[ "$ctx" != *eks* && "$ctx" != *aws* ]]; then
    warn "context '$ctx' does not look like EKS — refusing to drain"
    confirm "continue anyway?" || die "aborted"
  fi

  if ! kubectl get ns argocd >/dev/null 2>&1; then
    log "argocd namespace not found; skipping ArgoCD app deletion"
  else
    log "deleting all ArgoCD Applications (waits for finalizers)"
    kubectl delete application --all -n argocd --wait=true --timeout="${LB_WAIT_SECONDS}s" || \
      warn "argocd application delete returned non-zero — continuing"
  fi

  log "deleting any remaining LoadBalancer Services"
  local lb_svcs
  lb_svcs=$(kubectl get svc --all-namespaces -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null || true)
  if [[ -n "$lb_svcs" ]]; then
    for svc in $lb_svcs; do
      ns="${svc%%/*}"; name="${svc##*/}"
      log "  kubectl delete svc $name -n $ns"
      kubectl delete svc "$name" -n "$ns" --wait=true --timeout="${LB_WAIT_SECONDS}s" || \
        warn "  failed to delete $svc — may already be gone"
    done
  else
    log "no LoadBalancer services to delete"
  fi

  log "waiting up to ${ENI_WAIT_SECONDS}s for AWS to release NLBs / ENIs"
  local vpc_id
  vpc_id=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=videostreamingplatform-*" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")
  if [[ "$vpc_id" == "None" || -z "$vpc_id" ]]; then
    log "no videostreamingplatform VPC found; nothing to wait for"
    return 0
  fi

  local deadline=$(( $(date +%s) + ENI_WAIT_SECONDS ))
  while (( $(date +%s) < deadline )); do
    local eni_count sg_count
    eni_count=$(aws ec2 describe-network-interfaces \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=status,Values=in-use,available" \
      --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo "0")
    sg_count=$(aws ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=k8s-*" \
      --query 'length(SecurityGroups)' --output text 2>/dev/null || echo "0")
    log "  vpc=$vpc_id  non-default_ENIs=$eni_count  k8s-elb_SGs=$sg_count"
    if [[ "$eni_count" == "0" && "$sg_count" == "0" ]]; then
      log "cluster drain complete"
      return 0
    fi
    sleep 15
  done

  warn "timed out waiting for AWS to release ENIs/SGs in $vpc_id"
  warn "terraform destroy may stall — run scripts/teardown-aws.sh again,"
  warn "or manually delete leftover k8s-elb-* SGs before retrying."
}

# ----------------------------------------------------------------------------
# Step 3+4: terraform destroy (downstream first, platform second)
# ----------------------------------------------------------------------------
terraform_destroy() {
  local dir="$1" label="$2"
  [[ -d "$dir" ]] || { warn "$label: $dir not found; skipping"; return 0; }
  if [[ ! -f "$dir/$TFVARS_FILE" ]]; then
    warn "$label: $TFVARS_FILE not present in $dir; skipping"
    return 0
  fi
  log "terraform destroy: $label  ($dir)"
  (
    cd "$dir"
    terraform init -input=false -upgrade=false >/dev/null
    # TF_VAR_rds_master_password is required by the platform module's variables
    # block even for destroy; safe placeholder works since RDS is being torn down.
    TF_VAR_rds_master_password="${TF_VAR_rds_master_password:-placeholder}" \
      terraform destroy -auto-approve -var-file="$TFVARS_FILE"
  )
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  parse_args "$@"
  require_cmd kubectl
  require_cmd aws
  require_cmd terraform

  log "plan:"
  [[ "$SKIP_K8S"  == 0 ]] && log "  1. drain EKS cluster (ArgoCD apps + LoadBalancer Services)"
  [[ "$ONLY_K8S"  == 0 ]] && log "  2. terraform destroy -> $INFRA_TF_DIR"
  [[ "$ONLY_K8S"  == 0 ]] && log "  3. terraform destroy -> $PLATFORM_TF_DIR"
  confirm "proceed?" || die "aborted"

  [[ "$SKIP_K8S" == 0 ]] && drain_cluster
  if [[ "$ONLY_K8S" == 0 ]]; then
    terraform_destroy "$INFRA_TF_DIR"     "infra (Glue/Athena/IRSA)"
    terraform_destroy "$PLATFORM_TF_DIR"  "platform (EKS/VPC/RDS/S3/OpenSearch/CloudFront/Redis)"
  fi

  log "done."
}

main "$@"
