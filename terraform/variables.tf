variable "aws_region" {
  description = "Região AWS onde os recursos serão criados."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Nome do projeto."
  type        = string
  default     = "workflow-demo"
}

variable "environment" {
  description = "Ambiente da aplicação."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "O ambiente deve ser dev, staging ou prod."
  }
}

variable "log_retention_days" {
  description = "Quantidade de dias para retenção dos logs."
  type        = number
  default     = 30

  validation {
    condition     = var.log_retention_days > 0
    error_message = "log_retention_days deve ser maior que zero."
  }
}

variable "enable_cloudwatch_alarms" {
  description = "Habilita os alarmes do CloudWatch."
  type        = bool
  default     = true
}

variable "alarm_email" {
  description = "E-mail que receberá as notificações dos alarmes. Deixe vazio para não criar subscription."
  type        = string
  default     = ""
}

variable "lambda_error_threshold" {
  description = "Quantidade de erros da Lambda que dispara o alarme."
  type        = number
  default     = 1
}

variable "lambda_throttle_threshold" {
  description = "Quantidade de throttles da Lambda que dispara o alarme."
  type        = number
  default     = 1
}

variable "sqs_visible_messages_threshold" {
  description = "Quantidade de mensagens visíveis que dispara alerta de backlog."
  type        = number
  default     = 100
}

variable "sqs_oldest_message_threshold_seconds" {
  description = "Idade da mensagem mais antiga que dispara alerta."
  type        = number
  default     = 300
}

variable "dynamodb_throttle_threshold" {
  description = "Quantidade de throttles do DynamoDB que dispara alerta."
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags adicionais aplicadas aos recursos."
  type        = map(string)

  default = {
    ManagedBy = "terraform"
    Project   = "workflow-demo"
  }
}