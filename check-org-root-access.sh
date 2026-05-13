#!/usr/bin/env bash
set -euo pipefail

ORG_PROFILE="${ORG_PROFILE:-${AWS_PROFILE:-default}}"
TASK_POLICY_ARN="arn:aws:iam::aws:policy/root-task/IAMAuditRootUserCredentials"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "==> %s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*" >&2; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: Missing required command: $1" >&2
    exit 1
  }
}

aws_org() {
  aws --profile "$ORG_PROFILE" "$@"
}

json_value() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
path = sys.argv[2].split(".")
cur = data
for part in path:
    cur = cur[part]
print(cur)
PY
}

assume_member_root() {
  local account_id="$1"

  aws_org sts assume-root \
    --region us-east-1 \
    --target-principal "$account_id" \
    --task-policy-arn "arn=$TASK_POLICY_ARN" \
    --duration-seconds 900 \
    --output json 2>/dev/null || true
}

check_member_account() {
  local account_id="$1"
  local account_name="$2"

  assume_json="$(assume_member_root "$account_id")"

  if [ -z "$assume_json" ]; then
    printf "%-14s %-24s %-9s %-9s %-9s %-9s %s\n" \
      "$account_id" "$account_name" "unknown" "unknown" "unknown" "unknown" \
      "assume-root failed; feature/permissions/SCP may block it"
    return 0
  fi

  access_key_id="$(json_value "$assume_json" "Credentials.AccessKeyId")"
  secret_access_key="$(json_value "$assume_json" "Credentials.SecretAccessKey")"
  session_token="$(json_value "$assume_json" "Credentials.SessionToken")"

  summary="$(
    AWS_ACCESS_KEY_ID="$access_key_id" \
    AWS_SECRET_ACCESS_KEY="$secret_access_key" \
    AWS_SESSION_TOKEN="$session_token" \
    aws iam get-account-summary --output json 2>/dev/null || true
  )"

  if [ -z "$summary" ]; then
    printf "%-14s %-24s %-9s %-9s %-9s %-9s %s\n" \
      "$account_id" "$account_name" "unknown" "unknown" "unknown" "unknown" \
      "assume-root succeeded but get-account-summary failed"
    return 0
  fi

  password="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("SummaryMap",{}).get("AccountPasswordPresent","NA"))' <<< "$summary")"
  keys="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("SummaryMap",{}).get("AccountAccessKeysPresent","NA"))' <<< "$summary")"
  certs="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("SummaryMap",{}).get("AccountSigningCertificatesPresent","NA"))' <<< "$summary")"
  mfa="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("SummaryMap",{}).get("AccountMFAEnabled","NA"))' <<< "$summary")"

  if [ "$password" = "0" ] && [ "$keys" = "0" ] && [ "$certs" = "0" ]; then
    note="standing root credentials appear removed"
  elif [ "$keys" = "0" ] && [ "$certs" = "0" ]; then
    note="no root keys/certs detected; check password separately if needed"
  else
    note="root long-term credentials may exist"
  fi

  printf "%-14s %-24s %-9s %-9s %-9s %-9s %s\n" \
    "$account_id" "$account_name" "$password" "$keys" "$certs" "$mfa" "$note"
}

main() {
  need_cmd aws
  need_cmd python3

  bold "Org-wide root credential audit"
  info "Using org profile: $ORG_PROFILE"
  echo

  caller="$(aws_org sts get-caller-identity --query 'Arn' --output text)"
  info "Caller: $caller"

  org_id="$(aws_org organizations describe-organization --query 'Organization.Id' --output text)"
  mgmt_id="$(aws_org organizations describe-organization --query 'Organization.ManagementAccountId' --output text 2>/dev/null || true)"
  if [ -z "$mgmt_id" ] || [ "$mgmt_id" = "None" ]; then
    mgmt_id="$(aws_org organizations describe-organization --query 'Organization.MasterAccountId' --output text 2>/dev/null || true)"
  fi

  info "Organization: $org_id"
  info "Management account: $mgmt_id"

  echo
  bold "Centralized root access features"

  features="$(aws_org iam list-organizations-features --query 'EnabledFeatures' --output text 2>/dev/null || true)"
  info "Enabled features: ${features:-none}"

  case "$features" in
    *RootCredentialsManagement*) info "RootCredentialsManagement: enabled" ;;
    *) warn "RootCredentialsManagement: not enabled or not visible" ;;
  esac

  case "$features" in
    *RootSessions*) info "RootSessions: enabled" ;;
    *) warn "RootSessions: not enabled or not visible" ;;
  esac

  echo
  bold "Member account root credential indicators"
  printf "%-14s %-24s %-9s %-9s %-9s %-9s %s\n" \
    "Account" "Name" "Password" "Keys" "Certs" "MFA" "Notes"
  printf "%-14s %-24s %-9s %-9s %-9s %-9s %s\n" \
    "-------" "----" "--------" "----" "-----" "---" "-----"

  while IFS=$'\t' read -r account_id account_name; do
    [ -n "$account_id" ] || continue

    if [ "$account_id" = "$mgmt_id" ]; then
      printf "%-14s %-24s %-9s %-9s %-9s %-9s %s\n" \
        "$account_id" "$account_name" "n/a" "n/a" "n/a" "n/a" \
        "management account; check directly and keep alert"
      continue
    fi

    check_member_account "$account_id" "$account_name"
  done < <(
    aws_org organizations list-accounts \
      --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' \
      --output text
  )

  echo
  bold "Interpretation"
  echo "Password=0, Keys=0, Certs=0 means standing root credentials appear removed for that member account."
  echo "unknown usually means assume-root failed because centralized root sessions/permissions/SCPs are not allowing the audit."
  echo "The management account cannot be treated like a member account; keep the EventBridge/SNS alert there."
}

main "$@"
