output "log_bucket" {
  value = aws_s3_bucket.logs.id
}

output "log_group" {
  value = aws_cloudwatch_log_group.bedrock.name
}

output "gateway_role_arn" {
  value = aws_iam_role.gateway.arn
}

output "profile_arns" {
  value = { for k, p in aws_bedrock_inference_profile.team : k => p.arn }
}

output "deny_direct_policy_arn" {
  value = aws_iam_policy.deny_direct.arn
}
