variable "alert_email" {
  description = "Email address that receives root console sign-in alerts"
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for created AWS resource names"
  type        = string
  default     = "aws-root-login"
}

variable "create_cloudtrail" {
  description = "Create a multi-region CloudTrail trail for management events so EventBridge receives root sign-in events"
  type        = bool
  default     = true
}
