variable "alert_email" {
  description = "Email address that receives root console sign-in alerts"
  type        = string
}

variable "name_prefix" {
  description = "Prefix used for created AWS resource names"
  type        = string
  default     = "aws-root-login"
}
