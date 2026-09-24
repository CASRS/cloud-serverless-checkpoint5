output "queue_url" {
  description = "URL da fila SQS principal."
  value       = aws_sqs_queue.orders.url
}

output "queue_arn" {
  description = "ARN da fila SQS principal."
  value       = aws_sqs_queue.orders.arn
}

output "dlq_url" {
  description = "URL da Dead Letter Queue."
  value       = aws_sqs_queue.orders_dlq.url
}

output "dlq_arn" {
  description = "ARN da Dead Letter Queue."
  value       = aws_sqs_queue.orders_dlq.arn
}

output "lambda_name" {
  description = "Nome da Lambda."
  value       = aws_lambda_function.orders_consumer.function_name
}

output "lambda_arn" {
  description = "ARN da Lambda."
  value       = aws_lambda_function.orders_consumer.arn
}

output "dynamodb_table" {
  description = "Tabela DynamoDB usada para idempotência."
  value       = aws_dynamodb_table.idempotency.name
}

output "lambda_log_group" {
  description = "CloudWatch Log Group da Lambda."
  value       = aws_cloudwatch_log_group.lambda.name
}

output "sns_alerts_topic_arn" {
  description = "ARN do SNS utilizado pelos alarmes."
  value       = aws_sns_topic.alerts.arn
}

output "cloudwatch_dashboard_name" {
  description = "Nome do dashboard de observabilidade."
  value       = aws_cloudwatch_dashboard.workflow.dashboard_name
}

output "cloudwatch_dashboard_arn" {
  description = "ARN do dashboard de observabilidade."
  value       = "arn:aws:cloudwatch::${data.aws_caller_identity.current.account_id}:dashboard/${aws_cloudwatch_dashboard.workflow.dashboard_name}"
}

output "lambda_error_alarm_arn" {
  description = "ARN do alarme de erros da Lambda."
  value       = try(aws_cloudwatch_metric_alarm.lambda_errors[0].arn, null)
}

output "lambda_throttle_alarm_arn" {
  description = "ARN do alarme de throttling da Lambda."
  value       = try(aws_cloudwatch_metric_alarm.lambda_throttles[0].arn, null)
}

output "sqs_backlog_alarm_arn" {
  description = "ARN do alarme de backlog do SQS."
  value       = try(aws_cloudwatch_metric_alarm.sqs_backlog[0].arn, null)
}

output "sqs_oldest_message_alarm_arn" {
  description = "ARN do alarme de idade da mensagem."
  value       = try(aws_cloudwatch_metric_alarm.sqs_oldest_message[0].arn, null)
}

output "dlq_alarm_arn" {
  description = "ARN do alarme da DLQ."
  value       = try(aws_cloudwatch_metric_alarm.dlq_messages[0].arn, null)
}

output "dynamodb_throttle_alarm_arn" {
  description = "ARN do alarme de throttling do DynamoDB."
  value       = try(aws_cloudwatch_metric_alarm.dynamodb_throttles[0].arn, null)
}