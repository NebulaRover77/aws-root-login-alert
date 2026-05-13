output "sns_topic_arn" {
  description = "SNS topic ARN"
  value       = aws_sns_topic.root_login_alerts.arn
}

output "event_rule_name" {
  description = "EventBridge rule name"
  value       = aws_cloudwatch_event_rule.root_console_login.name
}

output "event_pattern_json" {
  description = "EventBridge event pattern JSON"
  value       = jsonencode(local.root_console_login_event_pattern)
}

output "cloudtrail_name" {
  description = "CloudTrail trail name, if created"
  value       = try(aws_cloudtrail.management_events[0].name, null)
}
