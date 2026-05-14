# AWS Root Login Alert

Terraform module and helper scripts for alerting when the AWS account root user signs in to the AWS Console.

## What it creates

- EventBridge rule matching AWS root `ConsoleLogin` events
- SNS topic for notifications
- Initial email SNS subscription
- Optional SMS subscribers
- Optional multi-region CloudTrail trail for management event delivery
- S3 bucket for CloudTrail logs
- Helper scripts for setup, deploy, inspection, subscriber management, and diagnostics

## Why this exists

AWS root user access should be rare. A root console sign-in is usually a break-glass event and should generate an immediate alert.

Deploy this in the AWS Organizations management account first. You can also deploy it into individual accounts if needed.

## Requirements

- Terraform >= 1.5.0
- AWS provider >= 5.0
- AWS CLI v2
- Bash
- Python 3
- AWS CLI profile with permissions for EventBridge, SNS, CloudTrail, S3, IAM, and optionally AWS Organizations

## Files

| File | Purpose |
| --- | --- |
| `main.tf` | Terraform resources for EventBridge, SNS, and CloudTrail |
| `variables.tf` | Terraform input variables |
| `outputs.tf` | Terraform outputs |
| `versions.tf` | Terraform and provider requirements |
| `setup.sh` | Interactive first-time setup |
| `deploy.sh` | Runs Terraform plan/apply using saved setup answers |
| `list-install.sh` | Lists the installed rule, target, SNS topic, and subscriptions |
| `manage-subscribers.sh` | Adds/removes email and SMS subscribers |
| `check-recent-root-logins.sh` | Checks recent root logins and CloudWatch metrics |
| `check-org-root-access.sh` | Checks member account root credential status using centralized root access |

## Quick start

```bash
git clone https://github.com/NebulaRover77/aws-root-login-alert.git
cd aws-root-login-alert
./setup.sh
./deploy.sh
```

After deployment, confirm the SNS email subscription from the recipient inbox.

## Configuration

`terraform.tfvars` is written by `setup.sh` and is intentionally ignored by git.

Example:

```hcl
alert_email       = "security@example.com"
name_prefix       = "aws-root-login"
create_cloudtrail = true
```

### Variables

| Variable | Default | Description |
| --- | --- | --- |
| `alert_email` | required | Initial email address to subscribe to SNS |
| `name_prefix` | `aws-root-login` | Prefix for created resources |
| `create_cloudtrail` | `true` | Create a multi-region CloudTrail trail for management events |

## Managing subscribers

List subscribers:

```bash
./manage-subscribers.sh list
```

Add email subscribers:

```bash
./manage-subscribers.sh add security@example.com alerts@example.com
```

Remove email subscribers:

```bash
./manage-subscribers.sh remove security@example.com
```

Add SMS subscribers:

```bash
./manage-subscribers.sh add-sms +15551234567
```

Remove SMS subscribers:

```bash
./manage-subscribers.sh remove-sms +15551234567
```

SMS numbers must use E.164 format, such as `+15551234567`.

## Inspecting the install

```bash
./list-install.sh
```

This shows the EventBridge rule, target, SNS topic, and current subscriptions.

## Testing SNS delivery

Direct SNS topic test:

```bash
AWS_PROFILE=your-profile aws sns publish \
  --region us-east-1 \
  --topic-arn "$(terraform output -raw sns_topic_arn)" \
  --subject "Direct SNS test" \
  --message "Direct SNS test from aws-root-login-alert."
```

Direct SMS test:

```bash
AWS_PROFILE=your-profile aws sns publish \
  --region us-east-1 \
  --phone-number +15551234567 \
  --message "Direct AWS SNS SMS test."
```

## Testing root login alert delivery

After logging in as root, wait several minutes, then run:

```bash
./check-recent-root-logins.sh
```

A working path should show:

1. A recent CloudTrail `ConsoleLogin` event for `root`
2. EventBridge `Invocations`
3. SNS `NumberOfMessagesPublished`
4. Delivered email or SMS notification

CloudTrail and EventBridge can take several minutes. Wait 5-15 minutes before assuming the alert did not fire.

## EventBridge pattern

The rule matches root console sign-in events from CloudTrail:

```hcl
source        = ["aws.signin"]
"detail-type" = ["AWS Console Sign In via CloudTrail", "AWS API Call via CloudTrail"]

detail = {
  eventSource = ["signin.amazonaws.com"]
  eventName   = ["ConsoleLogin"]

  userIdentity = {
    type = ["Root"]
  }
}
```

Both detail types are included because console sign-in events may appear with different CloudTrail/EventBridge detail type strings.

## SMS troubleshooting

Check whether a number is opted out:

```bash
AWS_PROFILE=your-profile aws sns check-if-phone-number-is-opted-out \
  --region us-east-1 \
  --phone-number +15551234567
```

Check SMS attributes:

```bash
AWS_PROFILE=your-profile aws sns get-sms-attributes \
  --region us-east-1 \
  --attributes DefaultSMSType MonthlySpendLimit DeliveryStatusIAMRole DeliveryStatusSuccessSamplingRate
```

Find SMS delivery log groups:

```bash
AWS_PROFILE=your-profile aws logs describe-log-groups \
  --region us-east-1 \
  --query 'logGroups[].logGroupName' \
  --output text | tr '\t' '\n' | grep -Ei 'sns|sms'
```

Read a failure log group:

```bash
LOG_GROUP='sns/us-east-1/YOUR_ACCOUNT_ID/DirectPublishToPhoneNumber/Failure'

AWS_PROFILE=your-profile aws logs filter-log-events \
  --region us-east-1 \
  --log-group-name "$LOG_GROUP" \
  --start-time "$((($(date +%s)-3600)*1000))" \
  --query 'events[].message' \
  --output text
```

If direct SMS publishing fails, the issue is SNS SMS delivery, carrier filtering, spend limits, phone-number restrictions, or regional SMS settings rather than EventBridge.

## Root credential audit

To audit member accounts for standing root credentials:

```bash
ORG_PROFILE=your-management-profile ./check-org-root-access.sh
```

For member accounts, this is the strongest CLI signal that standing root credentials are removed:

```text
Password=0, Keys=0, Certs=0
```

The management account should still keep the root login alert.

## Local files not committed

The following are ignored because they may contain account-specific values:

- `backend.tf`
- `terraform.tfvars`
- `.setup.env`
- Terraform state files
- `tfplan`

## Inspiration

This project was inspired by Tobias Schmidt's post about making AWS root console sign-ins immediately visible:

https://x.com/tpschmidt_/status/2054455622708686954?s=46

## Cleanup

Review the plan carefully before destroying:

```bash
AWS_PROFILE=your-deploy-profile terraform destroy
```
