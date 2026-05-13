#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-${DEPLOY_PROFILE:-default}}"
RULE_NAME="${RULE_NAME:-}"
TOPIC_ARN="${TOPIC_ARN:-}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

profile_has_sso_config() {
  local profile="$1"
  aws configure get "profile.${profile}.sso_start_url" >/dev/null 2>&1 && return 0
  aws configure get "profile.${profile}.sso_session" >/dev/null 2>&1 && return 0
  return 1
}

ensure_profile_login() {
  local profile="$1"

  if aws --profile "$profile" sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi

  if profile_has_sso_config "$profile"; then
    echo "AWS profile $profile is not logged in. Running aws sso login..."
    aws sso login --profile "$profile"
  fi

  aws --profile "$profile" sts get-caller-identity >/dev/null 2>&1
}

aws_p() {
  aws --profile "$PROFILE" --region "$REGION" "$@"
}

tf_output_raw() {
  local name="$1"
  terraform output -raw "$name" 2>/dev/null || true
}

load_setup_env() {
  if [ -f .setup.env ]; then
    # shellcheck disable=SC1091
    source ./.setup.env
    PROFILE="${DEPLOY_PROFILE:-$PROFILE}"
  fi
}

section() {
  echo
  echo "== $* =="
}

kv() {
  printf "  %-18s %s\n" "$1:" "$2"
}

need_cmd aws
need_cmd terraform

load_setup_env
ensure_profile_login "$PROFILE" || die "Could not authenticate with AWS profile: $PROFILE"

RULE_NAME="${RULE_NAME:-$(tf_output_raw event_rule_name)}"
TOPIC_ARN="${TOPIC_ARN:-$(tf_output_raw sns_topic_arn)}"

if [ -z "$RULE_NAME" ]; then
  RULE_NAME="aws-root-login-eventbridge-rule"
fi

caller="$(aws_p sts get-caller-identity --query 'Arn' --output text 2>/dev/null || true)"
account="$(aws_p sts get-caller-identity --query 'Account' --output text 2>/dev/null || true)"

echo "AWS root login alert installation"

section "Context"
kv "Profile" "$PROFILE"
kv "Region" "$REGION"
kv "Account" "${account:-unknown}"
kv "Caller" "${caller:-unknown}"

section "EventBridge"

rule_name="$(aws_p events describe-rule --name "$RULE_NAME" --query 'Name' --output text 2>/dev/null || true)"

if [ -z "$rule_name" ] || [ "$rule_name" = "None" ]; then
  kv "Rule" "not found: $RULE_NAME"
else
  rule_arn="$(aws_p events describe-rule --name "$RULE_NAME" --query 'Arn' --output text)"
  rule_state="$(aws_p events describe-rule --name "$RULE_NAME" --query 'State' --output text)"
  rule_desc="$(aws_p events describe-rule --name "$RULE_NAME" --query 'Description' --output text)"
  event_pattern="$(aws_p events describe-rule --name "$RULE_NAME" --query 'EventPattern' --output text)"

  kv "Rule name" "$rule_name"
  kv "State" "$rule_state"
  kv "Description" "$rule_desc"
  kv "ARN" "$rule_arn"
  kv "Pattern" "$event_pattern"

  target_count="$(aws_p events list-targets-by-rule --rule "$RULE_NAME" --query 'length(Targets)' --output text 2>/dev/null || echo 0)"
  kv "Targets" "$target_count"

  if [ "$target_count" != "0" ]; then
    targets_json="$(aws_p events list-targets-by-rule --rule "$RULE_NAME" --output json)"
    TARGETS_JSON="$targets_json" python3 - <<'PY2'
import json
import os

targets = json.loads(os.environ["TARGETS_JSON"]).get("Targets", [])
for target in targets:
    print(f"  Target ID:          {target.get('Id', '')}")
    print(f"  Target ARN:         {target.get('Arn', '')}")
PY2
  fi
fi

section "SNS"

if [ -z "$TOPIC_ARN" ]; then
  TOPIC_ARN="$(aws_p sns list-topics \
    --query "Topics[?contains(TopicArn, ':aws-root-login-alerts')].TopicArn | [0]" \
    --output text 2>/dev/null || true)"

  if [ "$TOPIC_ARN" = "None" ]; then
    TOPIC_ARN=""
  fi
fi

if [ -z "$TOPIC_ARN" ]; then
  kv "Topic" "not found"
  echo
  echo "Set TOPIC_ARN explicitly or run from an initialized Terraform checkout."
  exit 0
fi

attrs="$(aws_p sns get-topic-attributes --topic-arn "$TOPIC_ARN" --output json)"

owner="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Attributes"].get("Owner",""))' <<< "$attrs")"
confirmed="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Attributes"].get("SubscriptionsConfirmed","0"))' <<< "$attrs")"
pending="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Attributes"].get("SubscriptionsPending","0"))' <<< "$attrs")"
deleted="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Attributes"].get("SubscriptionsDeleted","0"))' <<< "$attrs")"

kv "Topic ARN" "$TOPIC_ARN"
kv "Owner" "$owner"
kv "Confirmed subs" "$confirmed"
kv "Pending subs" "$pending"
kv "Deleted subs" "$deleted"

section "Email subscriptions"

subs_json="$(aws_p sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" --output json)"

SUBS_JSON="$subs_json" python3 - <<'PY2'
import json
import os

data = json.loads(os.environ["SUBS_JSON"])
subs = data.get("Subscriptions", [])

email_subs = [s for s in subs if s.get("Protocol") == "email"]

if not email_subs:
    print("  No email subscriptions found.")
    raise SystemExit

print(f"  {'Status':<20} {'Email'}")
print(f"  {'------':<20} {'-----'}")

for sub in email_subs:
    endpoint = sub.get("Endpoint", "")
    arn = sub.get("SubscriptionArn", "")

    if arn == "PendingConfirmation":
        status = "pending"
    elif arn and arn != "None":
        status = "confirmed"
    else:
        status = "unknown"

    print(f"  {status:<20} {endpoint}")
PY2

echo
echo "Tip: pending email subscriptions must be confirmed from the recipient inbox."
