#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-${DEPLOY_PROFILE:-default}}"
TOPIC_ARN="${TOPIC_ARN:-}"

usage() {
  cat <<USAGE
Usage:
  $0 list
  $0 add email1@example.com [email2@example.com ...]
  $0 remove email1@example.com [email2@example.com ...]

Environment:
  AWS_PROFILE   AWS CLI profile to use
  REGION        AWS region, default us-east-1
  TOPIC_ARN     SNS topic ARN; optional if Terraform output is available
USAGE
}

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

find_topic_arn() {
  if [ -n "$TOPIC_ARN" ]; then
    printf "%s" "$TOPIC_ARN"
    return 0
  fi

  arn="$(tf_output_raw sns_topic_arn)"
  if [ -n "$arn" ]; then
    printf "%s" "$arn"
    return 0
  fi

  arn="$(aws_p sns list-topics \
    --query "Topics[?contains(TopicArn, ':aws-root-login-alerts')].TopicArn | [0]" \
    --output text 2>/dev/null || true)"

  if [ "$arn" != "None" ] && [ -n "$arn" ]; then
    printf "%s" "$arn"
    return 0
  fi

  return 1
}

list_subscriptions() {
  aws_p sns list-subscriptions-by-topic \
    --topic-arn "$TOPIC_ARN" \
    --query 'Subscriptions[].{Protocol:Protocol,Endpoint:Endpoint,SubscriptionArn:SubscriptionArn}' \
    --output table
}

add_email() {
  local email="$1"

  echo "Adding email subscription: $email"
  aws_p sns subscribe \
    --topic-arn "$TOPIC_ARN" \
    --protocol email \
    --notification-endpoint "$email" \
    --output table

  echo "Confirmation email sent to $email."
}

remove_email() {
  local email="$1"

  sub_arn="$(aws_p sns list-subscriptions-by-topic \
    --topic-arn "$TOPIC_ARN" \
    --query "Subscriptions[?Protocol=='email' && Endpoint=='$email'].SubscriptionArn | [0]" \
    --output text 2>/dev/null || true)"

  if [ -z "$sub_arn" ] || [ "$sub_arn" = "None" ]; then
    echo "No subscription found for $email"
    return 0
  fi

  if [ "$sub_arn" = "PendingConfirmation" ]; then
    echo "Subscription for $email is still PendingConfirmation."
    echo "SNS cannot unsubscribe a pending email subscription by ARN from this topic listing."
    echo "Use the unsubscribe link in the confirmation email, or wait until it is confirmed."
    return 0
  fi

  echo "Removing email subscription: $email"
  aws_p sns unsubscribe --subscription-arn "$sub_arn"
}

need_cmd aws
need_cmd terraform

load_setup_env

ensure_profile_login "$PROFILE" || die "Could not authenticate with AWS profile: $PROFILE"

cmd="${1:-}"
shift || true

case "$cmd" in
  list|add|remove)
    ;;
  -h|--help|"")
    usage
    exit 0
    ;;
  *)
    usage
    die "Unknown command: $cmd"
    ;;
esac

TOPIC_ARN="$(find_topic_arn || true)"
[ -n "$TOPIC_ARN" ] || die "Could not find SNS topic ARN. Set TOPIC_ARN or run from initialized Terraform checkout."

echo "Profile: $PROFILE"
echo "Region:  $REGION"
echo "Topic:   $TOPIC_ARN"
echo

case "$cmd" in
  list)
    list_subscriptions
    ;;

  add)
    [ "$#" -gt 0 ] || die "Provide at least one email address to add."
    for email in "$@"; do
      add_email "$email"
    done
    echo
    list_subscriptions
    ;;

  remove)
    [ "$#" -gt 0 ] || die "Provide at least one email address to remove."
    for email in "$@"; do
      remove_email "$email"
    done
    echo
    list_subscriptions
    ;;
esac
