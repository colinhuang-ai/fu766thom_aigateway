variable "region" {
  description = "AWS region for the sandbox"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS CLI profile (IAM Identity Center / SSO) used by Terraform"
  type        = string
  default     = "bcp-sandbox"
}

variable "env" {
  description = "Environment name"
  type        = string
  default     = "sandbox"
}

variable "prefix" {
  description = "Resource name prefix"
  type        = string
  default     = "bcp"
}

variable "profile_sources" {
  description = "Map team => ARN of the system-defined inference profile to copy from"
  type        = map(string)

  validation {
    condition     = length(var.profile_sources) > 0
    error_message = "Provide at least one team in profile_sources."
  }
}

variable "trusted_principal_arns" {
  description = "IAM principals allowed to assume the gateway role"
  type        = list(string)
}

variable "budget_limit_usd" {
  description = "Monthly budget limit in USD"
  type        = number
  default     = 20
}

variable "alert_email" {
  description = "Email that receives budget alerts"
  type        = string
}
