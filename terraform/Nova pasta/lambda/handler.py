import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

SERVICE_NAME = "orders-consumer"

ENVIRONMENT = os.environ.get(
"ENVIRONMENT",
"dev"
)

METRICS_NAMESPACE = os.environ.get(
"METRICS_NAMESPACE",
"workflow-demo/Application"
)

TABLE_NAME = os.environ["IDEMPOTENCY_TABLE"]

dynamodb = boto3.resource("dynamodb")

table = dynamodb.Table(TABLE_NAME)

logger = logging.getLogger()

logger.setLevel(logging.INFO)

def log_event(
level,
message,
*,
context=None,
**fields
):
event = {
"timestamp": datetime.now(
timezone.utc
).isoformat(),
"level": level,
"service": SERVICE_NAME,
"environment": ENVIRONMENT,
"message": message
}

if context:
    event["aws_request_id"] = (
        context.aws_request_id
    )

event.update(fields)

serialized = json.dumps(
    event,
    default=str
)

if level == "ERROR":
    logger.error(serialized)

elif level == "WARNING":
    logger.warning(serialized)

else:
    logger.info(serialized)


def emit_metric(
metric_name,
value=1,
unit="Count"
):
metric = {
"_aws": {
"Timestamp": int(
time.time() * 1000
),
"CloudWatchMetrics": [
{
"Namespace": METRICS_NAMESPACE,
"Dimensions": [
["Environment"]
],
"Metrics": [
{
"Name": metric_name,
"Unit": unit
}
]
}
]
},
"Environment": ENVIRONMENT,
metric_name: value
}

logger.info(
    json.dumps(
        metric,
        default=str
    )
)


def register_idempotency(
idempotency_key,
order_id,
operation
):
try:
table.put_item(
Item={
"idempotency_key": (
idempotency_key
),
"status": "PROCESSING",
"order_id": order_id,
"operation": operation,
"created_at": datetime.now(
timezone.utc
).isoformat(),
"expires_at": (
int(time.time()) + 86400
)
},
ConditionExpression=(
"attribute_not_exists("
"idempotency_key)"
)
)

    return True

except ClientError as e:
    error_code = (
        e.response["Error"]["Code"]
    )

    if (
        error_code
        != "ConditionalCheckFailedException"
    ):
        raise

    response = table.get_item(
        Key={
            "idempotency_key": (
                idempotency_key
            )
        }
    )

    existing = response.get(
        "Item"
    )

    if not existing:
        raise

    status = existing.get(
        "status"
    )

    if status == "COMPLETED":
        return False

    table.update_item(
        Key={
            "idempotency_key": (
                idempotency_key
            )
        },
        UpdateExpression=(
            "SET #status = :status"
        ),
        ExpressionAttributeNames={
            "#status": "status"
        },
        ExpressionAttributeValues={
            ":status": "PROCESSING"
        }
    )

    return True


def lambda_handler(
event,
context
):
invocation_start = (
time.perf_counter()
)

records = event.get(
    "Records",
    []
)

log_event(
    "INFO",
    "lambda_invocation_started",
    context=context,
    record_count=len(records)
)

batch_item_failures = []

for record in records:
    message_start = (
        time.perf_counter()
    )

    message_id = record.get(
        "messageId"
    )

    body = record.get(
        "body",
        ""
    )

    correlation_id = None
    order_id = None
    operation = None
    idempotency_key = None

    try:
        body = body.lstrip(
            "\ufeff"
        )

        data = json.loads(
            body
        )

        correlation_id = (
            data.get(
                "correlation_id"
            )
            or str(uuid.uuid4())
        )

        order_id = data.get(
            "order_id"
        )

        operation = data.get(
            "operation"
        )

        idempotency_key = (
            data.get(
                "idempotency_key"
            )
        )

        log_event(
            "INFO",
            "message_received",
            context=context,
            message_id=message_id,
            correlation_id=correlation_id,
            order_id=order_id,
            operation=operation
        )

        if not idempotency_key:
            raise ValueError(
                "Campo idempotency_key é obrigatório"
            )

        if not order_id:
            raise ValueError(
                "Campo order_id é obrigatório"
            )

        if not operation:
            raise ValueError(
                "Campo operation é obrigatório"
            )

        is_new_operation = (
            register_idempotency(
                idempotency_key,
                order_id,
                operation
            )
        )

        if not is_new_operation:
            log_event(
                "INFO",
                "duplicate_message",
                context=context,
                message_id=message_id,
                correlation_id=correlation_id,
                order_id=order_id,
                operation=operation
            )

            emit_metric(
                "OrdersDuplicated"
            )

            continue

        log_event(
            "INFO",
            "business_processing_started",
            context=context,
            message_id=message_id,
            correlation_id=correlation_id,
            order_id=order_id,
            operation=operation
        )

        if data.get(
            "force_error"
        ) is True:
            raise RuntimeError(
                "Erro proposital para testar Retry/DLQ"
            )

        table.update_item(
            Key={
                "idempotency_key": (
                    idempotency_key
                )
            },
            UpdateExpression=(
                "SET #status = :status, "
                "completed_at = :completed_at"
            ),
            ExpressionAttributeNames={
                "#status": "status"
            },
            ExpressionAttributeValues={
                ":status": "COMPLETED",
                ":completed_at": (
                    datetime.now(
                        timezone.utc
                    ).isoformat()
                )
            }
        )

        duration_ms = (
            time.perf_counter()
            - message_start
        ) * 1000

        emit_metric(
            "OrdersProcessed"
        )

        emit_metric(
            "OrderProcessingDuration",
            value=round(
                duration_ms,
                2
            ),
            unit="Milliseconds"
        )

        log_event(
            "INFO",
            "order_processed",
            context=context,
            message_id=message_id,
            correlation_id=correlation_id,
            order_id=order_id,
            operation=operation,
            duration_ms=round(
                duration_ms,
                2
            ),
            status="COMPLETED"
        )

    except Exception as e:
        duration_ms = (
            time.perf_counter()
            - message_start
        ) * 1000

        if idempotency_key:
            try:
                table.update_item(
                    Key={
                        "idempotency_key": (
                            idempotency_key
                        )
                    },
                    UpdateExpression=(
                        "SET #status = :status, "
                        "failed_at = :failed_at"
                    ),
                    ExpressionAttributeNames={
                        "#status": "status"
                    },
                    ExpressionAttributeValues={
                        ":status": "FAILED",
                        ":failed_at": (
                            datetime.now(
                                timezone.utc
                            ).isoformat()
                        )
                    }
                )

            except Exception as update_error:
                log_event(
                    "ERROR",
                    "idempotency_failure_update_failed",
                    context=context,
                    message_id=message_id,
                    correlation_id=correlation_id,
                    error_type=type(
                        update_error
                    ).__name__,
                    error=str(
                        update_error
                    )
                )

        emit_metric(
            "OrdersFailed"
        )

        log_event(
            "ERROR",
            "order_processing_failed",
            context=context,
            message_id=message_id,
            correlation_id=correlation_id,
            order_id=order_id,
            operation=operation,
            duration_ms=round(
                duration_ms,
                2
            ),
            error_type=type(
                e
            ).__name__,
            error=str(e)
        )

        batch_item_failures.append(
            {
                "itemIdentifier": (
                    message_id
                )
            }
        )

invocation_duration_ms = (
    time.perf_counter()
    - invocation_start
) * 1000

result = {
    "batchItemFailures": (
        batch_item_failures
    )
}

log_event(
    "INFO",
    "lambda_invocation_finished",
    context=context,
    record_count=len(records),
    failed_records=len(
        batch_item_failures
    ),
    duration_ms=round(
        invocation_duration_ms,
        2
    )
)

return result