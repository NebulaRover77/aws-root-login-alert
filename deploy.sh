#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ask() {
  local prompt="$1"
  local default="${2:-}"
  local value

  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " value
    printf "%s" "${value:-$default}"
  else
    read -r -p "$prompt: " value
    printf "%s" "$value"
  fi
}

need_cmd aws
need_cmd terraform

echo "AWS root login alert deployment"
echo

[ -f backend.tf ] || die "backend.tf not found. Run ./setup.sh first."
[ -f terraform.tfvars ] || die "terraform.tfvars not found. Run ./setup.sh first."
[ -f .setup.env ] || die ".setup.env not found. Re-run ./setup.sh so deployment settings are saved."

# shellcheck disable=SC1091
source ./.setup.env

[ -n "${DEPLOY_PROFILE:-}" ] || die "DEPLOY_PROFILE missing from .setup.env"
[ -n "${DEPLOY_ACCOUNT_ID:-}" ] || die "DEPLOY_ACCOUNT_ID missing from .setup.env"

echo "Backend:"
echo "  profile: ${BACKEND_PROFILE:-unknown}"
echo "  bucket:  ${BACKEND_BUCKET:-unknown}"
echo "  key:     ${BACKEND_STATE_KEY:-unknown}"
echo
echo "Deployment target:"
echo "  profile: $DEPLOY_PROFILE"
echo "  account: $DEPLOY_ACCOUNT_ID ${DEPLOY_ACCOUNT_NAME:+($DEPLOY_ACCOUNT_NAME)}"
echo

actual_account="$(aws --profile "$DEPLOY_PROFILE" sts get-caller-identity --query Account --output text)"
if [ "$actual_account" != "$DEPLOY_ACCOUNT_ID" ]; then
  die "Profile $DEPLOY_PROFILE resolves to account $actual_account, expected $DEPLOY_ACCOUNT_ID"
fi

echo "Checking Terraform backend..."
terraform init -reconfigure

echo
echo "Running terraform plan..."
AWS_PROFILE="$DEPLOY_PROFILE" terraform plan -out=tfplan

echo
answer="$(ask "Apply this plan? yes/no" "yes")"

case "$answer" in
  yes|y|Y|YES)
    echo
    echo "Applying..."
    AWS_PROFILE="$DEPLOY_PROFILE" terraform apply tfplan
    ;;
  *)
    echo "Apply cancelled. Plan saved as ./tfplan"
    exit 0
    ;;
esac

echo
echo "Deployment complete."
echo "Important: confirm the SNS subscription email, or alerts will not be delivered."
echo
echo "Outputs:"
AWS_PROFILE="$DEPLOY_PROFILE" terraform output

if [ -n "${BACKEND_BUCKET:-}" ] && [ -n "${BACKEND_STATE_KEY:-}" ]; then
  echo
  echo "State object:"
  echo "s3://${BACKEND_BUCKET}/${BACKEND_STATE_KEY}"
fi
