locals {
  root_console_login_event_pattern = {
    source        = ["aws.signin"]
    "detail-type" = ["AWS Console Signin via CloudTrail", "AWS API Call via CloudTrail"]

    detail = {
      eventSource = ["signin.amazonaws.com"]
      eventName   = ["ConsoleLogin"]

      userIdentity = {
        type = ["Root"]
      }
    }
  }
}

resource "aws_sns_topic" "root_login_alerts" {
  name = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.root_login_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "allow_eventbridge_to_publish" {
  statement {
    sid    = "AllowEventBridgeToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.root_login_alerts.arn]
  }
}

resource "aws_sns_topic_policy" "allow_eventbridge_to_publish" {
  arn    = aws_sns_topic.root_login_alerts.arn
  policy = data.aws_iam_policy_document.allow_eventbridge_to_publish.json
}

resource "aws_cloudwatch_event_rule" "root_console_login" {
  name        = "${var.name_prefix}-eventbridge-rule"
  description = "Alert on AWS root user console sign-ins"

  event_pattern = jsonencode(local.root_console_login_event_pattern)
}

resource "aws_cloudwatch_event_target" "send_to_sns" {
  rule      = aws_cloudwatch_event_rule.root_console_login.name
  target_id = "send-root-login-alert-to-sns"
  arn       = aws_sns_topic.root_login_alerts.arn

  input_transformer {
    input_paths = {
      account = "$.detail.userIdentity.accountId"
      arn     = "$.detail.userIdentity.arn"
      time    = "$.detail.eventTime"
      ip      = "$.detail.sourceIPAddress"
      region  = "$.detail.awsRegion"
      result  = "$.detail.responseElements.ConsoleLogin"
      mfa     = "$.detail.additionalEventData.MFAUsed"
      login   = "$.detail.additionalEventData.LoginTo"
      eventid = "$.detail.eventID"
    }

    input_template = jsonencode(join("\n", [
      "AWS ROOT CONSOLE SIGN-IN",
      "",
      "The AWS account root user signed in to the console.",
      "",
      "Account: <account>",
      "ARN: <arn>",
      "Result: <result>",
      "Time: <time>",
      "Source IP: <ip>",
      "MFA used: <mfa>",
      "CloudTrail region: <region>",
      "Login target: <login>",
      "CloudTrail event ID: <eventid>",
      "",
      "Review this event unless it corresponds to an expected break-glass action."
    ]))
  }

  depends_on = [
    aws_sns_topic_policy.allow_eventbridge_to_publish
  ]
}
