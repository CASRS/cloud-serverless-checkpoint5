terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }

  }
}

provider "aws" {
  region = var.aws_region
}

#============================================================
#LOCALS
#============================================================
locals {
  common_tags = merge(
    var.tags,
    {
      Environment = var.environment
      Service     = "orders-workflow"
    }
  )

  lambda_name = "${var.project_name}-${var.environment}-orders-consumer"
  queue_name  = "${var.project_name}-${var.environment}-orders.fifo"
  dlq_name    = "${var.project_name}-${var.environment}-orders-dlq.fifo"
  table_name  = "${var.project_name}-${var.environment}-idempotency"
}

# ============================================================
# DATA
# ============================================================

data "aws_caller_identity" "current" {}

data "archive_file" "lambda_zip" {
  type = "zip"

  source_dir = "${path.module}/lambda"

  output_path = "${path.module}/lambda.zip"
}


#============================================================
#SQS - DEAD LETTER QUEUE
#============================================================
resource "aws_sqs_queue" "orders_dlq" {
  name                        = local.dlq_name
  fifo_queue                  = true
  content_based_deduplication = true

  message_retention_seconds = 1209600

  tags = merge(local.common_tags, {
    Component = "sqs-dlq"
  })
}

#============================================================
#SQS - MAIN QUEUE
#============================================================
resource "aws_sqs_queue" "orders" {
  name                        = local.queue_name
  fifo_queue                  = true
  content_based_deduplication = true

  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.orders_dlq.arn
    maxReceiveCount     = 3
  })

  tags = merge(local.common_tags, {
    Component = "sqs"
  })
}

#============================================================
#DYNAMODB - IDEMPOTENCY
#============================================================
resource "aws_dynamodb_table" "idempotency" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"

  hash_key = "idempotency_key"

  attribute {
    name = "idempotency_key"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = merge(local.common_tags, {
    Component = "dynamodb"
  })
}

#============================================================
#IAM ROLE - LAMBDA
#============================================================
resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "lambda.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]

  })

  tags = local.common_tags
}

#============================================================
#IAM - CLOUDWATCH LOGS
#============================================================
resource "aws_iam_role_policy" "lambda_logs" {
  name = "${var.project_name}-${var.environment}-lambda-logs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]

        Resource = "*"
      }
    ]

  })
}

#============================================================
#IAM - DYNAMODB
#============================================================
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${var.project_name}-${var.environment}-lambda-dynamodb"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]

        Resource = aws_dynamodb_table.idempotency.arn
      }
    ]

  })
}

#============================================================
#IAM - SQS
#============================================================
resource "aws_iam_role_policy" "lambda_sqs" {
  name = "${var.project_name}-${var.environment}-lambda-sqs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]

        Resource = aws_sqs_queue.orders.arn
      }
    ]

  })
}

#============================================================
#CLOUDWATCH LOG GROUP
#============================================================
resource "aws_cloudwatch_log_group" "lambda" {
  name = "/aws/lambda/${local.lambda_name}"

  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Component = "logging"
  })
}

#============================================================
#LAMBDA
#============================================================
resource "aws_lambda_function" "orders_consumer" {
  function_name = local.lambda_name

  role = aws_iam_role.lambda.arn

  runtime = "python3.12"
  handler = "handler.lambda_handler"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      IDEMPOTENCY_TABLE = aws_dynamodb_table.idempotency.name
      ENVIRONMENT       = var.environment
      METRICS_NAMESPACE = "${var.project_name}/Application"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda
  ]

  tags = merge(local.common_tags, {
    Component = "lambda"
  })
}

#============================================================
#LAMBDA PERMISSION PARA SQS
#============================================================
resource "aws_lambda_permission" "sqs" {
  statement_id  = "AllowExecutionFromSQS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orders_consumer.function_name
  principal     = "sqs.amazonaws.com"

  source_arn = aws_sqs_queue.orders.arn
}

#============================================================
#SQS -> LAMBDA
#============================================================
resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn = aws_sqs_queue.orders.arn
  function_name    = aws_lambda_function.orders_consumer.arn

  enabled = true

  batch_size                         = 1
  maximum_batching_window_in_seconds = 0

  function_response_types = [
    "ReportBatchItemFailures"
  ]
}

#============================================================
#SNS - ALERTAS
#============================================================
resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-${var.environment}-observability-alerts"

  tags = merge(local.common_tags, {
    Component = "alerting"
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

#============================================================
#CLOUDWATCH ALARM - LAMBDA ERRORS
#============================================================
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name = "${var.project_name}-${var.environment}-lambda-errors"

  alarm_description = "Detecta erros na Lambda de processamento."

  comparison_operator = "GreaterThanOrEqualToThreshold"

  evaluation_periods = 1

  metric_name = "Errors"
  namespace   = "AWS/Lambda"

  period    = 60
  statistic = "Sum"

  threshold = var.lambda_error_threshold

  dimensions = {
    FunctionName = aws_lambda_function.orders_consumer.function_name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  tags = merge(local.common_tags, {
    Component = "alarm"
  })
}

#============================================================
#CLOUDWATCH ALARM - LAMBDA THROTTLES
#============================================================
resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name = "${var.project_name}-${var.environment}-lambda-throttles"

  alarm_description = "Detecta throttling da Lambda."

  comparison_operator = "GreaterThanOrEqualToThreshold"

  evaluation_periods = 1

  metric_name = "Throttles"
  namespace   = "AWS/Lambda"

  period    = 60
  statistic = "Sum"

  threshold = var.lambda_throttle_threshold

  dimensions = {
    FunctionName = aws_lambda_function.orders_consumer.function_name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  tags = merge(local.common_tags, {
    Component = "alarm"
  })
}

#============================================================
#CLOUDWATCH ALARM - SQS BACKLOG
#============================================================
resource "aws_cloudwatch_metric_alarm" "sqs_backlog" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name = "${var.project_name}-${var.environment}-sqs-backlog"

  alarm_description = "Detecta crescimento do backlog da fila."

  comparison_operator = "GreaterThanOrEqualToThreshold"

  evaluation_periods = 3

  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"

  period    = 60
  statistic = "Maximum"

  threshold = var.sqs_visible_messages_threshold

  dimensions = {
    QueueName = aws_sqs_queue.orders.name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  tags = merge(local.common_tags, {
    Component = "alarm"
  })
}

#============================================================
#CLOUDWATCH ALARM - SQS OLDEST MESSAGE
#============================================================
resource "aws_cloudwatch_metric_alarm" "sqs_oldest_message" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name = "${var.project_name}-${var.environment}-sqs-oldest-message"

  alarm_description = "Detecta mensagens aguardando processamento por muito tempo."

  comparison_operator = "GreaterThanOrEqualToThreshold"

  evaluation_periods = 3

  metric_name = "ApproximateAgeOfOldestMessage"
  namespace   = "AWS/SQS"

  period    = 60
  statistic = "Maximum"

  threshold = var.sqs_oldest_message_threshold_seconds

  dimensions = {
    QueueName = aws_sqs_queue.orders.name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  tags = merge(local.common_tags, {
    Component = "alarm"
  })
}

#============================================================
#CLOUDWATCH ALARM - DLQ
#============================================================
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name = "${var.project_name}-${var.environment}-dlq"

  alarm_description = "Detecta mensagens na Dead Letter Queue."

  comparison_operator = "GreaterThanOrEqualToThreshold"

  evaluation_periods = 1

  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"

  period    = 60
  statistic = "Maximum"

  threshold = 1

  dimensions = {
    QueueName = aws_sqs_queue.orders_dlq.name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  tags = merge(local.common_tags, {
    Component = "alarm"
  })
}

#============================================================
#CLOUDWATCH ALARM - DYNAMODB THROTTLES
#============================================================
resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  count = var.enable_cloudwatch_alarms ? 1 : 0

  alarm_name = "${var.project_name}-${var.environment}-dynamodb-throttles"

  alarm_description = "Detecta throttling na tabela DynamoDB."

  comparison_operator = "GreaterThanOrEqualToThreshold"

  evaluation_periods = 1

  metric_name = "ThrottledRequests"
  namespace   = "AWS/DynamoDB"

  period    = 60
  statistic = "Sum"

  threshold = var.dynamodb_throttle_threshold

  dimensions = {
    TableName = aws_dynamodb_table.idempotency.name
  }

  treat_missing_data = "notBreaching"

  alarm_actions = [
    aws_sns_topic.alerts.arn
  ]

  tags = merge(local.common_tags, {
    Component = "alarm"
  })
}

#============================================================
#CLOUDWATCH DASHBOARD
#============================================================
resource "aws_cloudwatch_dashboard" "workflow" {
  dashboard_name = "${var.project_name}-${var.environment}-observability"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "Lambda - Invocations / Errors / Throttles"
          region = var.aws_region

          view    = "timeSeries"
          stacked = false

          metrics = [
            [
              "AWS/Lambda",
              "Invocations",
              "FunctionName",
              aws_lambda_function.orders_consumer.function_name
            ],
            [
              ".",
              "Errors",
              ".",
              "."
            ],
            [
              ".",
              "Throttles",
              ".",
              "."
            ]
          ]

          period = 60
          stat   = "Sum"
        }
      },

      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6

        properties = {
          title  = "Lambda - Duration"
          region = var.aws_region

          view = "timeSeries"

          metrics = [
            [
              "AWS/Lambda",
              "Duration",
              "FunctionName",
              aws_lambda_function.orders_consumer.function_name
            ]
          ]

          period = 60
          stat   = "Average"
        }
      },

      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6

        properties = {
          title  = "SQS - Backlog"
          region = var.aws_region

          view = "timeSeries"

          metrics = [
            [
              "AWS/SQS",
              "ApproximateNumberOfMessagesVisible",
              "QueueName",
              aws_sqs_queue.orders.name
            ]
          ]

          period = 60
          stat   = "Maximum"
        }
      },

      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6

        properties = {
          title  = "SQS - Oldest Message"
          region = var.aws_region

          view = "timeSeries"

          metrics = [
            [
              "AWS/SQS",
              "ApproximateAgeOfOldestMessage",
              "QueueName",
              aws_sqs_queue.orders.name
            ]
          ]

          period = 60
          stat   = "Maximum"
        }
      },

      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6

        properties = {
          title  = "DLQ"
          region = var.aws_region

          view = "timeSeries"

          metrics = [
            [
              "AWS/SQS",
              "ApproximateNumberOfMessagesVisible",
              "QueueName",
              aws_sqs_queue.orders_dlq.name
            ]
          ]

          period = 60
          stat   = "Maximum"
        }
      },

      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6

        properties = {
          title  = "DynamoDB - Throttling"
          region = var.aws_region

          view = "timeSeries"

          metrics = [
            [
              "AWS/DynamoDB",
              "ThrottledRequests",
              "TableName",
              aws_dynamodb_table.idempotency.name
            ]
          ]

          period = 60
          stat   = "Sum"
        }
      },

      {
        type   = "log"
        x      = 0
        y      = 18
        width  = 24
        height = 6

        properties = {
          title  = "Application Errors"
          region = var.aws_region

          query = <<-EOT
        SOURCE '${aws_cloudwatch_log_group.lambda.name}'
        | fields @timestamp, level, message, correlation_id, order_id, error_type, error
        | filter level = "ERROR"
        | sort @timestamp desc
        | limit 50
      EOT
        }
      }
    ]

  })
}