data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  name       = "${var.prefix}-${var.env}"

  common_tags = {
    project = var.prefix
    env     = var.env
  }
}

# ---------------------------------------------------------------------------
# Invocation logging: S3 bucket + CloudWatch log group + role for Bedrock
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name}-bedrock-logs-${local.account_id}"
  force_destroy = true # sandbox only: lets `terraform destroy` empty the bucket
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-30d"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}

data "aws_iam_policy_document" "logs_bucket" {
  statement {
    sid       = "AllowBedrockPutLogs"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${local.account_id}/BedrockModelInvocationLogs/*"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }

    # Confused-deputy protection
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${var.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket     = aws_s3_bucket.logs.id
  policy     = data.aws_iam_policy_document.logs_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

resource "aws_cloudwatch_log_group" "bedrock" {
  name              = "/${var.prefix}/${var.env}/bedrock/invocations"
  retention_in_days = 14
}

data "aws_iam_policy_document" "bedrock_logging_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock:${var.region}:${local.account_id}:*"]
    }
  }
}

data "aws_iam_policy_document" "bedrock_logging" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.bedrock.arn}:*"]
  }
}

resource "aws_iam_role" "bedrock_logging" {
  name               = "${local.name}-bedrock-logging"
  assume_role_policy = data.aws_iam_policy_document.bedrock_logging_trust.json
}

resource "aws_iam_role_policy" "bedrock_logging" {
  name   = "write-cloudwatch-logs"
  role   = aws_iam_role.bedrock_logging.id
  policy = data.aws_iam_policy_document.bedrock_logging.json
}

# NOTE: text_data_delivery_enabled logs prompts and completions verbatim.
# Only use synthetic data in this sandbox.
resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  logging_config {
    embedding_data_delivery_enabled = true
    image_data_delivery_enabled     = true
    text_data_delivery_enabled      = true

    cloudwatch_config {
      log_group_name = aws_cloudwatch_log_group.bedrock.name
      role_arn       = aws_iam_role.bedrock_logging.arn
    }

    s3_config {
      bucket_name = aws_s3_bucket.logs.id
      key_prefix  = "AWSLogs"
    }
  }

  depends_on = [
    aws_s3_bucket_policy.logs,
    aws_iam_role_policy.bedrock_logging,
  ]
}

# ---------------------------------------------------------------------------
# One application inference profile per team (cost attribution via tags)
# ---------------------------------------------------------------------------
resource "aws_bedrock_inference_profile" "team" {
  for_each = var.profile_sources

  name        = "${local.name}-${each.key}"
  description = "Application inference profile for ${each.key}"

  model_source {
    copy_from = each.value
  }

  tags = {
    team    = each.key
    project = var.prefix
    env     = var.env
  }
}

locals {
  profile_arns = [for p in aws_bedrock_inference_profile.team : p.arn]
}

# ---------------------------------------------------------------------------
# Gateway role: may invoke models ONLY through the application profiles
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "gateway_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = var.trusted_principal_arns
    }
  }
}

data "aws_iam_policy_document" "gateway" {
  statement {
    sid       = "InvokeViaApplicationProfile"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"]
    resources = local.profile_arns
  }

  statement {
    sid     = "UnderlyingModelOnlyThroughProfile"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"]
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${local.account_id}:inference-profile/*",
    ]

    condition {
      test     = "ArnEquals"
      variable = "bedrock:InferenceProfileArn"
      values   = local.profile_arns
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${local.name}-gateway"
  assume_role_policy = data.aws_iam_policy_document.gateway_trust.json
}

resource "aws_iam_role_policy" "gateway" {
  name   = "invoke-via-profiles"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

# Deny direct model calls that bypass application profiles.
# Created on purpose but NOT attached to any principal yet.
data "aws_iam_policy_document" "deny_direct" {
  statement {
    sid     = "DenyDirectModelInvoke"
    effect  = "Deny"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"]
    resources = [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${local.account_id}:inference-profile/*",
    ]

    condition {
      test     = "StringNotLike"
      variable = "bedrock:InferenceProfileArn"
      values   = ["arn:aws:bedrock:*:${local.account_id}:application-inference-profile/*"]
    }
  }
}

resource "aws_iam_policy" "deny_direct" {
  name   = "${local.name}-deny-direct-invoke"
  policy = data.aws_iam_policy_document.deny_direct.json
}

# ---------------------------------------------------------------------------
# Budget (slow safety net: AWS Budgets refreshes only a few times a day)
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
