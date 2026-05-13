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

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "cloudtrail_logs" {
  count = var.create_cloudtrail ? 1 : 0

  bucket_prefix = "${var.name_prefix}-cloudtrail-"
}

resource "aws_s3_bucket_public_access_block" "cloudtrail_logs" {
  count = var.create_cloudtrail ? 1 : 0

  bucket                  = aws_s3_bucket.cloudtrail_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudtrail_logs" {
  count = var.create_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail_logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudtrail_logs" {
  count = var.create_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

data "aws_iam_policy_document" "cloudtrail_bucket_policy" {
  count = var.create_cloudtrail ? 1 : 0

  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["s3:GetBucketAcl"]

    resources = [
      aws_s3_bucket.cloudtrail_logs[0].arn
    ]
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.cloudtrail_logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail_logs" {
  count = var.create_cloudtrail ? 1 : 0

  bucket = aws_s3_bucket.cloudtrail_logs[0].id
  policy = data.aws_iam_policy_document.cloudtrail_bucket_policy[0].json
}

resource "aws_cloudtrail" "management_events" {
  count = var.create_cloudtrail ? 1 : 0

  name                          = "${var.name_prefix}-management-events"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_logs[0].id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  depends_on = [
    aws_s3_bucket_policy.cloudtrail_logs
  ]
}
