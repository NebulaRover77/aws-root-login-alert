#!/usr/bin/env bash
set -euo pipefail

REGION="us-east-1"
STATE_KEY_DEFAULT="aws-root-login-alert/terraform.tfstate"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
info() { printf "==> %s\n" "$*"; }
warn() { printf "WARN: %s\n" "$*" >&2; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

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

aws_with_profile() {
  local profile="$1"
  shift
  aws --profile "$profile" "$@"
}

profile_has_sso_config() {
  local profile="$1"
  aws configure get "profile.${profile}.sso_start_url" >/dev/null 2>&1 && return 0
  aws configure get "profile.${profile}.sso_session" >/dev/null 2>&1 && return 0
  return 1
}

profile_account_id() {
  local profile="$1"
  aws_with_profile "$profile" sts get-caller-identity \
    --query Account \
    --output text 2>/dev/null || true
}

profile_arn() {
  local profile="$1"
  aws_with_profile "$profile" sts get-caller-identity \
    --query Arn \
    --output text 2>/dev/null || true
}

can_call() {
  local profile="$1"
  shift
  aws_with_profile "$profile" "$@" >/dev/null 2>&1
}

current_profile_name() {
  printf "%s" "${AWS_PROFILE:-default}"
}

show_current_context() {
  local current_profile
  current_profile="$(current_profile_name)"

  echo
  bold "Current AWS context"
  info "AWS_PROFILE: ${AWS_PROFILE:-not set}"
  info "Effective profile: $current_profile"

  if ensure_profile_login "$current_profile"; then
    current_account="$(profile_account_id "$current_profile")"
    current_arn="$(profile_arn "$current_profile")"

    info "Current account: $current_account"
    info "Current identity: $current_arn"

    if can_call "$current_profile" organizations describe-organization; then
      org_id="$(aws_with_profile "$current_profile" organizations describe-organization --query 'Organization.Id' --output text)"
      mgmt_account="$(aws_with_profile "$current_profile" organizations describe-organization --query 'Organization.ManagementAccountId' --output text 2>/dev/null || true)"

      if [ -z "$mgmt_account" ] || [ "$mgmt_account" = "None" ]; then
        mgmt_account="$(aws_with_profile "$current_profile" organizations describe-organization --query 'Organization.MasterAccountId' --output text 2>/dev/null || true)"
      fi

      info "Organization: $org_id"
      info "Management account: $mgmt_account"

      if can_call "$current_profile" organizations list-accounts; then
        echo
        bold "Accounts visible from current profile"
        aws_with_profile "$current_profile" organizations list-accounts \
          --query 'Accounts[].{Id:Id,Name:Name,Email:Email,Status:Status}' \
          --output table
      else
        warn "Current profile can describe the organization but cannot list accounts."
      fi
    else
      warn "Current profile cannot call organizations:DescribeOrganization, or this account is not in an organization."
    fi
  else
    warn "Effective profile $current_profile is not usable right now."
    if profile_has_sso_config "$current_profile"; then
      warn "It appears to be an SSO profile. The script can run: aws sso login --profile $current_profile"
    fi
  fi
}

ensure_profile_login() {
  local profile="$1"

  if [ -n "$(profile_account_id "$profile")" ]; then
    return 0
  fi

  if profile_has_sso_config "$profile"; then
    warn "Profile $profile is not currently logged in."
    local answer
    answer="$(ask "Run aws sso login --profile $profile now? yes/no" "yes")"

    case "$answer" in
      yes|y|Y|YES)
        aws sso login --profile "$profile"
        ;;
      *)
        return 1
        ;;
    esac
  fi

  [ -n "$(profile_account_id "$profile")" ]
}

list_profiles() {
  aws configure list-profiles 2>/dev/null || true
}

bucket_exists_for_profile() {
  local profile="$1"
  local bucket="$2"
  aws_with_profile "$profile" s3api head-bucket --bucket "$bucket" >/dev/null 2>&1
}

create_bucket() {
  local profile="$1"
  local bucket="$2"
  local region="$3"

  info "Creating S3 bucket: $bucket in $region"

  if [ "$region" = "us-east-1" ]; then
    aws_with_profile "$profile" s3api create-bucket --bucket "$bucket" >/dev/null
  else
    aws_with_profile "$profile" s3api create-bucket \
      --bucket "$bucket" \
      --create-bucket-configuration LocationConstraint="$region" >/dev/null
  fi

  aws_with_profile "$profile" s3api put-public-access-block \
    --bucket "$bucket" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  aws_with_profile "$profile" s3api put-bucket-versioning \
    --bucket "$bucket" \
    --versioning-configuration Status=Enabled

  aws_with_profile "$profile" s3api put-bucket-encryption \
    --bucket "$bucket" \
    --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  info "Created and hardened bucket: $bucket"
}


preview_bucket_state_paths() {
  local profile="$1"
  local bucket="$2"
  local limit="${3:-50}"

  echo
  bold "Current contents of s3://$bucket"
  echo "Showing up to $limit objects, trimmed to depth 4."
  echo

  objects="$(
    aws_with_profile "$profile" s3api list-objects-v2 \
      --bucket "$bucket" \
      --max-items "$limit" \
      --query 'Contents[].Key' \
      --output text 2>/dev/null || true
  )"

  if [ -z "$objects" ] || [ "$objects" = "None" ]; then
    echo "(bucket appears empty, or no objects are visible)"
    return 0
  fi

  printf "%s\n" "$objects" \
    | tr '\t' '\n' \
    | sed '/^$/d' \
    | awk -F/ '{
        if (NF <= 4) {
          print $0
        } else {
          print $1 "/" $2 "/" $3 "/" $4 "/..."
        }
      }' \
    | sort -u \
    | head -n "$limit"

  echo
}

write_backend_tf() {
  local bucket="$1"
  local key="$2"
  local region="$3"
  local profile="$4"

  cat > backend.tf <<BACKEND
terraform {
  backend "s3" {
    bucket  = "$bucket"
    key     = "$key"
    region  = "$region"
    profile = "$profile"
    encrypt = true
  }
}
BACKEND
}

write_tfvars() {
  local alert_email="$1"
  local name_prefix="$2"

  cat > terraform.tfvars <<TFVARS
alert_email = "$alert_email"
name_prefix = "$name_prefix"
TFVARS
}

discover_profiles() {
  mapfile -t profiles < <(list_profiles)

  if [ "${#profiles[@]}" -eq 0 ]; then
    die "No AWS CLI profiles found. Run aws configure sso or aws configure first."
  fi

  bold "Detected AWS profiles"
  printf "%-4s %-36s %-16s %s\n" "#" "Profile" "Account" "Identity"
  printf "%-4s %-36s %-16s %s\n" "---" "-------" "-------" "--------"

  usable_profiles=()
  sso_unusable_profiles=()

  for i in "${!profiles[@]}"; do
    profile="${profiles[$i]}"
    account="$(profile_account_id "$profile")"
    arn="$(profile_arn "$profile")"

    if [ -n "$account" ] && [ "$account" != "None" ]; then
      usable_profiles+=("$profile")
      printf "%-4s %-36s %-16s %s\n" "$((i + 1))" "$profile" "$account" "$arn"
    else
      if profile_has_sso_config "$profile"; then
        sso_unusable_profiles+=("$profile")
        printf "%-4s %-36s %-16s %s\n" "$((i + 1))" "$profile" "-" "SSO profile, login needed"
      else
        printf "%-4s %-36s %-16s %s\n" "$((i + 1))" "$profile" "-" "not currently usable"
      fi
    fi
  done
}

try_login_unusable_sso_profiles() {
  if [ "${#sso_unusable_profiles[@]}" -eq 0 ]; then
    return 0
  fi

  echo
  bold "SSO login"
  warn "Some AWS SSO profiles are not currently logged in."

  local answer
  answer="$(ask "Try logging in to SSO profiles so they can be checked? yes/no" "yes")"

  case "$answer" in
    yes|y|Y|YES)
      for profile in "${sso_unusable_profiles[@]}"; do
        echo
        info "Checking SSO profile: $profile"
        if ensure_profile_login "$profile"; then
          info "Logged in: $profile"
        else
          warn "Could not use profile: $profile"
        fi
      done
      echo
      discover_profiles
      ;;
    *)
      ;;
  esac
}

discover_organizations() {
  echo
  bold "AWS Organizations discovery"

  local current_profile
  current_profile="$(current_profile_name 2>/dev/null || printf "%s" "${AWS_PROFILE:-default}")"

  org_lookup_profiles=()

  # Try the current/effective profile first if it is usable.
  if [ -n "$(profile_account_id "$current_profile")" ]; then
    org_lookup_profiles+=("$current_profile")
  fi

  # Then try all other usable profiles.
  for profile in "${usable_profiles[@]}"; do
    if [ "$profile" != "$current_profile" ]; then
      org_lookup_profiles+=("$profile")
    fi
  done

  org_profile=""

  for profile in "${org_lookup_profiles[@]}"; do
    if can_call "$profile" organizations list-accounts; then
      org_profile="$profile"
      break
    fi
  done

  if [ -z "$org_profile" ]; then
    for profile in "${org_lookup_profiles[@]}"; do
      if can_call "$profile" organizations describe-organization; then
        org_profile="$profile"
        break
      fi
    done
  fi

  if [ -z "$org_profile" ]; then
    warn "No usable profile could read AWS Organizations."
    warn "This is okay for single-account use. To list org accounts, use a management-account or delegated-admin profile."
    return 0
  fi

  org_id="$(aws_with_profile "$org_profile" organizations describe-organization --query 'Organization.Id' --output text 2>/dev/null || true)"
  mgmt_account="$(aws_with_profile "$org_profile" organizations describe-organization --query 'Organization.ManagementAccountId' --output text 2>/dev/null || true)"

  if [ -z "$mgmt_account" ] || [ "$mgmt_account" = "None" ]; then
    mgmt_account="$(aws_with_profile "$org_profile" organizations describe-organization --query 'Organization.MasterAccountId' --output text 2>/dev/null || true)"
  fi

  info "Using profile for Organizations: $org_profile"
  info "Organization: $org_id"
  info "Management account: $mgmt_account"

  if can_call "$org_profile" organizations list-accounts; then
    echo
    bold "Accounts in organization"
    aws_with_profile "$org_profile" organizations list-accounts \
      --query 'Accounts[].{Id:Id,Name:Name,Email:Email,Status:Status}' \
      --output table
  else
    warn "Profile $org_profile can describe the organization but cannot list accounts."
  fi
}

score_profile_permissions() {
  local profile="$1"
  local score=0

  can_call "$profile" sts get-caller-identity && score=$((score + 1))
  can_call "$profile" s3api list-buckets && score=$((score + 1))
  can_call "$profile" events list-rules --region "$REGION" --limit 1 && score=$((score + 1))
  can_call "$profile" sns list-topics --region "$REGION" && score=$((score + 1))

  printf "%s" "$score"
}

recommend_profiles() {
  echo
  bold "Quick profile check"

  recommended_profiles=()

  printf "%-36s %-16s %-6s %-6s
" "Profile" "Account" "STS" "S3"
  printf "%-36s %-16s %-6s %-6s
" "-------" "-------" "---" "--"

  for profile in "${usable_profiles[@]}"; do
    account="$(profile_account_id "$profile")"

    sts="no"
    s3="no"

    can_call "$profile" sts get-caller-identity && sts="yes"
    can_call "$profile" s3api list-buckets && s3="yes"

    printf "%-36s %-16s %-6s %-6s
" "$profile" "$account" "$sts" "$s3"

    if [ "$sts" = "yes" ] && [ "$s3" = "yes" ]; then
      recommended_profiles+=("$profile")
    fi
  done

  echo
  if [ "${#recommended_profiles[@]}" -gt 0 ]; then
    info "Profiles with enough access for backend setup:"
    for profile in "${recommended_profiles[@]}"; do
      echo "  - $profile"
    done
  else
    warn "No profile passed the quick S3 backend check."
  fi
}



check_centralized_root_access() {
  local profile="$1"

  echo
  bold "Centralized root access check"

  if ! can_call "$profile" iam list-organizations-features; then
    warn "Could not check IAM centralized root access features with profile $profile."
    warn "This usually requires a management-account or delegated-admin profile with iam:ListOrganizationsFeatures."
    return 0
  fi

  features="$(aws_with_profile "$profile" iam list-organizations-features --query 'EnabledFeatures' --output text 2>/dev/null || true)"

  if [ -z "$features" ] || [ "$features" = "None" ]; then
    warn "No centralized root access features appear to be enabled."
    return 0
  fi

  info "Enabled centralized root access features: $features"

  case "$features" in
    *RootCredentialsManagement*)
      info "Root credentials management is enabled for member accounts."
      ;;
    *)
      warn "Root credentials management does not appear to be enabled."
      ;;
  esac

  case "$features" in
    *RootSessions*)
      info "Privileged root sessions are enabled for member accounts."
      ;;
    *)
      warn "Privileged root sessions do not appear to be enabled."
      ;;
  esac

  echo
  echo "Recommendation:"
  echo "- Always deploy this alert in the organization management account."
  echo "- For member accounts, centralized root access reduces risk, but the alert is still useful as defense in depth."
  echo "- If member root credentials were deleted, root console sign-in should be impossible unless password recovery is later allowed."
}

choose_backend_profile_and_bucket() {
  echo
  bold "Terraform state backend"

  echo "The S3 backend bucket can live in a different account from the account you deploy the alert into."
  echo "Common choices are a management, tooling, audit, log archive, or shared infrastructure account."
  echo

  printf "%-4s %-16s %-36s %s\n" "#" "Account" "Profile" "Default"
  printf "%-4s %-16s %-36s %s\n" "---" "-------" "-------" "-------"

  backend_profiles=()
  current_profile="$(current_profile_name)"
  backend_default_selection="1"

  # Put the current/effective profile first when it can access S3.
  if [ -n "$(profile_account_id "$current_profile")" ] && can_call "$current_profile" s3api list-buckets; then
    backend_profiles+=("$current_profile")
    backend_default_selection="1"
    printf "%-4s %-16s %-36s %s\n" "${#backend_profiles[@]}" "$(profile_account_id "$current_profile")" "$current_profile" "current"
  fi

  for profile in "${recommended_profiles[@]}"; do
    if [ "$profile" = "$current_profile" ]; then
      continue
    fi

    if can_call "$profile" s3api list-buckets; then
      backend_profiles+=("$profile")
      printf "%-4s %-16s %-36s %s\n" "${#backend_profiles[@]}" "$(profile_account_id "$profile")" "$profile" ""
    fi
  done

  if [ "${#backend_profiles[@]}" -eq 0 ]; then
    die "No profile with S3 access found for Terraform backend setup."
  fi

  echo
  backend_selection="$(ask "Use which profile/account for the Terraform state bucket" "$backend_default_selection")"

  if ! [[ "$backend_selection" =~ ^[0-9]+$ ]]; then
    die "Selection must be a number."
  fi

  backend_index=$((backend_selection - 1))

  if [ "$backend_index" -lt 0 ] || [ "$backend_index" -ge "${#backend_profiles[@]}" ]; then
    die "Selection out of range."
  fi

  backend_profile="${backend_profiles[$backend_index]}"
  backend_account_id="$(profile_account_id "$backend_profile")"

  echo
  info "Backend profile: $backend_profile"
  info "Backend account: $backend_account_id"

  echo
  info "Buckets visible to backend profile:"

  mapfile -t visible_buckets < <(
    aws_with_profile "$backend_profile" s3api list-buckets \
      --query 'Buckets[].Name' \
      --output text | tr '\t' '\n' | sed '/^$/d'
  )

  if [ "${#visible_buckets[@]}" -eq 0 ]; then
    warn "No buckets are visible to this profile."
  else
    printf "%-4s %s\n" "#" "Bucket"
    printf "%-4s %s\n" "---" "------"
    for i in "${!visible_buckets[@]}"; do
      printf "%-4s %s\n" "$((i + 1))" "${visible_buckets[$i]}"
    done
  fi

  echo
  bucket_choice="$(ask "Terraform state bucket name, bucket number, or NEW to create one" "")"

  if [ "$bucket_choice" = "NEW" ] || [ "$bucket_choice" = "new" ]; then
    suggested_bucket="tfstate-${backend_account_id}-${REGION}"
    bucket="$(ask "New bucket name" "$suggested_bucket")"
    create_bucket "$backend_profile" "$bucket" "$REGION"
  else
    if [[ "$bucket_choice" =~ ^[0-9]+$ ]] && [ "${#visible_buckets[@]}" -gt 0 ]; then
      bucket_index=$((bucket_choice - 1))
      if [ "$bucket_index" -lt 0 ] || [ "$bucket_index" -ge "${#visible_buckets[@]}" ]; then
        die "Bucket selection out of range."
      fi
      bucket="${visible_buckets[$bucket_index]}"
    else
      bucket="$bucket_choice"
    fi

    if bucket_exists_for_profile "$backend_profile" "$bucket"; then
      info "Bucket is accessible: $bucket"
    else
      warn "Bucket $bucket is not accessible or does not exist from backend profile $backend_profile."
      create_answer="$(ask "Create it now in backend account $backend_account_id? yes/no" "yes")"
      case "$create_answer" in
        yes|y|Y|YES)
          create_bucket "$backend_profile" "$bucket" "$REGION"
          ;;
        *)
          die "Cannot continue without an accessible Terraform state bucket."
          ;;
      esac
    fi
  fi

  preview_bucket_state_paths "$backend_profile" "$bucket" 50

  state_key="$(ask "Terraform state key" "$STATE_KEY_DEFAULT")"

  info "Writing backend.tf"
  write_backend_tf "$bucket" "$state_key" "$REGION" "$backend_profile"
}


check_deployment_permissions() {
  local profile="$1"

  echo
  bold "Deployment permission check"

  if can_call "$profile" events list-rules --region "$REGION" --limit 1; then
    info "OK: EventBridge access in $REGION"
  else
    warn "Could not verify EventBridge access in $REGION. terraform apply may fail."
  fi

  if can_call "$profile" sns list-topics --region "$REGION"; then
    info "OK: SNS access in $REGION"
  else
    warn "Could not verify SNS access in $REGION. terraform apply may fail."
  fi

  if can_call "$profile" iam get-user; then
    info "OK: IAM read access"
  else
    info "IAM get-user check skipped/failed; this is often normal for assumed roles."
  fi
}


profile_for_account() {
  local wanted_account="$1"

  for candidate in "${usable_profiles[@]}"; do
    if [ "$(profile_account_id "$candidate")" = "$wanted_account" ]; then
      printf "%s" "$candidate"
      return 0
    fi
  done

  return 1
}

management_account_id() {
  for profile in "${usable_profiles[@]}"; do
    if can_call "$profile" organizations describe-organization; then
      mgmt="$(aws_with_profile "$profile" organizations describe-organization --query 'Organization.ManagementAccountId' --output text 2>/dev/null || true)"
      if [ -z "$mgmt" ] || [ "$mgmt" = "None" ]; then
        mgmt="$(aws_with_profile "$profile" organizations describe-organization --query 'Organization.MasterAccountId' --output text 2>/dev/null || true)"
      fi
      if [ -n "$mgmt" ] && [ "$mgmt" != "None" ]; then
        printf "%s" "$mgmt"
        return 0
      fi
    fi
  done

  return 1
}

choose_deploy_profile() {
  echo
  bold "Deployment target account"

  mgmt_account="$(management_account_id || true)"
  default_selection="1"

  printf "%-4s %-16s %-24s %-36s %s\n" "#" "Account" "Name" "Best profile" "Role"
  printf "%-4s %-16s %-24s %-36s %s\n" "---" "-------" "----" "------------" "----"

  target_account_ids=()
  target_account_names=()
  target_account_profiles=()

  org_source_profile=""

  for profile in "${usable_profiles[@]}"; do
    if can_call "$profile" organizations list-accounts; then
      org_source_profile="$profile"
      break
    fi
  done

  if [ -n "$org_source_profile" ]; then
    while IFS=$'\t' read -r account_id account_name; do
      best_profile="$(profile_for_account "$account_id" || true)"

      target_account_ids+=("$account_id")
      target_account_names+=("$account_name")
      target_account_profiles+=("$best_profile")

      n="${#target_account_ids[@]}"
      role=""
      if [ -n "$mgmt_account" ] && [ "$account_id" = "$mgmt_account" ]; then
        role="management"
        default_selection="$n"
      fi

      display_profile="$best_profile"
      if [ -z "$display_profile" ]; then
        display_profile="no local profile found"
      fi

      printf "%-4s %-16s %-24s %-36s %s\n" "$n" "$account_id" "$account_name" "$display_profile" "$role"
    done < <(
      aws_with_profile "$org_source_profile" organizations list-accounts \
        --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' \
        --output text
    )
  else
    seen_accounts=""

    for profile in "${usable_profiles[@]}"; do
      account_id="$(profile_account_id "$profile")"
      [ -n "$account_id" ] || continue

      case " $seen_accounts " in
        *" $account_id "*) continue ;;
      esac

      seen_accounts="$seen_accounts $account_id"
      account_name="unknown"
      best_profile="$(profile_for_account "$account_id" || true)"

      target_account_ids+=("$account_id")
      target_account_names+=("$account_name")
      target_account_profiles+=("$best_profile")

      n="${#target_account_ids[@]}"
      role=""
      if [ -n "$mgmt_account" ] && [ "$account_id" = "$mgmt_account" ]; then
        role="management"
        default_selection="$n"
      fi

      printf "%-4s %-16s %-24s %-36s %s\n" "$n" "$account_id" "$account_name" "$best_profile" "$role"
    done
  fi

  echo
  echo "For the first install, the organization management account is the recommended default."
  selection="$(ask "Deploy alert into which account number" "$default_selection")"

  if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
    die "Selection must be a number."
  fi

  index=$((selection - 1))

  if [ "$index" -lt 0 ] || [ "$index" -ge "${#target_account_ids[@]}" ]; then
    die "Selection out of range."
  fi

  selected_account_id="${target_account_ids[$index]}"
  selected_account_name="${target_account_names[$index]}"
  selected_profile="${target_account_profiles[$index]}"

  if [ -z "$selected_profile" ]; then
    die "No local AWS profile was found for account $selected_account_id. Run aws configure sso and include that account, then rerun setup."
  fi

  echo
  info "Deployment account: $selected_account_id ($selected_account_name)"
  info "Deployment profile: $selected_profile"
}


write_setup_env() {
  cat > .setup.env <<EOF
BACKEND_PROFILE="$backend_profile"
BACKEND_ACCOUNT_ID="$backend_account_id"
BACKEND_BUCKET="$bucket"
BACKEND_REGION="$REGION"
BACKEND_STATE_KEY="$state_key"
DEPLOY_PROFILE="$selected_profile"
DEPLOY_ACCOUNT_ID="$account_id"
DEPLOY_ACCOUNT_NAME="$selected_account_name"
ALERT_EMAIL="$alert_email"
NAME_PREFIX="$name_prefix"
EOF
}

main() {
  need_cmd aws
  need_cmd terraform

  bold "AWS root login alert setup"
  echo

  show_current_context
  echo

  info "Looking for AWS CLI profiles..."
  discover_profiles

  try_login_unusable_sso_profiles

  if [ "${#usable_profiles[@]}" -eq 0 ]; then
    die "No usable profiles found. Run aws sso login --profile <profile> and try again."
  fi

  discover_organizations
  recommend_profiles

  org_check_profile="${AWS_PROFILE:-}"
  if [ -z "$org_check_profile" ] || ! can_call "$org_check_profile" iam list-organizations-features; then
    org_check_profile=""
    for profile in "${usable_profiles[@]}"; do
      if can_call "$profile" iam list-organizations-features; then
        org_check_profile="$profile"
        break
      fi
    done
  fi

  if [ -n "$org_check_profile" ]; then
    check_centralized_root_access "$org_check_profile"
  else
    echo
    bold "Centralized root access check"
    warn "No usable profile could call iam:list-organizations-features."
  fi

  choose_backend_profile_and_bucket

  choose_deploy_profile

  if ! ensure_profile_login "$selected_profile"; then
    die "Profile $selected_profile is not usable. Try aws sso login --profile $selected_profile."
  fi

  account_id="$(profile_account_id "$selected_profile")"
  arn="$(profile_arn "$selected_profile")"

  echo
  info "Using deployment profile: $selected_profile"
  info "Deployment account: $account_id"
  info "Deployment identity: $arn"

  check_deployment_permissions "$selected_profile"

  alert_email="$(ask "Alert email address" "")"
  [ -n "$alert_email" ] || die "Alert email is required."

  name_prefix="$(ask "Resource name prefix" "aws-root-login")"

  echo
  info "Writing terraform.tfvars"
  write_tfvars "$alert_email" "$name_prefix"

  info "Writing .setup.env"
  write_setup_env

  echo
  bold "Generated files"
  ls -1 backend.tf terraform.tfvars .setup.env

  echo
  init_answer="$(ask "Run terraform init now? yes/no" "yes")"
  case "$init_answer" in
    yes|y|Y|YES)
      terraform init
      ;;
    *)
      info "Skipping terraform init."
      ;;
  esac

  echo
  bold "Next steps"
  echo "1. Review generated files:"
  echo "   cat backend.tf"
  echo "   cat terraform.tfvars"
  echo
  echo "2. Run:"
  echo "   terraform plan"
  echo "   terraform apply"
  echo
  echo "3. Confirm the SNS subscription email after apply."
}

main "$@"
