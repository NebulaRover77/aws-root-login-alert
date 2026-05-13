#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-${DEPLOY_PROFILE:-default}}"
RULE_NAME="${RULE_NAME:-aws-root-login-eventbridge-rule}"
TOPIC_NAME="${TOPIC_NAME:-aws-root-login-alerts}"

if [ -f .setup.env ]; then
  # shellcheck disable=SC1091
  source ./.setup.env
  PROFILE="${DEPLOY_PROFILE:-$PROFILE}"
fi

echo "Recent root ConsoleLogin events"
echo "-------------------------------"
aws --profile "$PROFILE" --region "$REGION" cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=ConsoleLogin \
  --max-results 10 \
  --query 'Events[].{Time:EventTime,User:Username,EventId:EventId}' \
  --output table

echo
echo "Latest root event detail"
echo "------------------------"
aws --profile "$PROFILE" --region "$REGION" cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=ConsoleLogin \
  --max-results 1 \
  --query 'Events[0].CloudTrailEvent' \
  --output text | python3 -m json.tool | python3 -c '
import json, sys
e=json.load(sys.stdin)
print("eventTime:", e.get("eventTime"))
print("eventSource:", e.get("eventSource"))
print("eventName:", e.get("eventName"))
print("eventType:", e.get("eventType"))
print("userIdentity.type:", e.get("userIdentity",{}).get("type"))
print("responseElements.ConsoleLogin:", e.get("responseElements",{}).get("ConsoleLogin"))
print("awsRegion:", e.get("awsRegion"))
print("recipientAccountId:", e.get("recipientAccountId"))
'

echo
echo "EventBridge metrics, last 60 minutes"
echo "------------------------------------"
start_time="$(date -u -v-60M +%Y-%m-%dT%H:%M:%SZ)"
end_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

aws --profile "$PROFILE" --region "$REGION" cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name Invocations \
  --dimensions Name=RuleName,Value="$RULE_NAME" \
  --statistics Sum \
  --period 300 \
  --start-time "$start_time" \
  --end-time "$end_time" \
  --query 'Datapoints[].{Time:Timestamp,Invocations:Sum}' \
  --output table

aws --profile "$PROFILE" --region "$REGION" cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name FailedInvocations \
  --dimensions Name=RuleName,Value="$RULE_NAME" \
  --statistics Sum \
  --period 300 \
  --start-time "$start_time" \
  --end-time "$end_time" \
  --query 'Datapoints[].{Time:Timestamp,Failed:Sum}' \
  --output table

echo
echo "SNS publish metrics, last 60 minutes"
echo "------------------------------------"
aws --profile "$PROFILE" --region "$REGION" cloudwatch get-metric-statistics \
  --namespace AWS/SNS \
  --metric-name NumberOfMessagesPublished \
  --dimensions Name=TopicName,Value="$TOPIC_NAME" \
  --statistics Sum \
  --period 300 \
  --start-time "$start_time" \
  --end-time "$end_time" \
  --query 'Datapoints[].{Time:Timestamp,Published:Sum}' \
  --output table
