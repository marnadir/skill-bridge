"""Lambda: consumes S3 upload events from the SQS queue and starts
the CV processing Step Function, one execution per uploaded object.

Uses partial batch responses (ReportBatchItemFailures): only failed
messages go back to the queue, the rest of the batch is deleted."""

import json
import os
import urllib.parse
from typing import Any

import boto3

sfn = boto3.client("stepfunctions")

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Consume S3 upload events from SQS and start the Step Function.

    Args:
        event: The SQS batch event with "Records".
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: A partial batch response with
            "batchItemFailures" listing the message ids to retry.
    """
    failures = []

    for record in event.get("Records", []):
        try:
            _process_message(record)
        except Exception:  # noqa: BLE001 - any failure must go back to
            # the queue (and eventually the DLQ), never crash the batch
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}


def _process_message(record: dict[str, Any]) -> None:
    """Start one Step Function execution per S3 object in the message.

    Args:
        record: A single SQS record whose body is an S3 event (or the
            S3 test event, which is skipped).

    Returns:
        None

    Raises:
        json.JSONDecodeError: If the message body is not valid JSON.
        KeyError: If the S3 event does not have the expected shape.
    """
    body = json.loads(record["body"])

    # S3 sends a test event when the notification is configured: skip it
    if body.get("Event") == "s3:TestEvent":
        return

    for s3_record in body.get("Records", []):
        bucket = s3_record["s3"]["bucket"]["name"]
        # object keys arrive url-encoded (spaces become '+')
        key = urllib.parse.unquote_plus(s3_record["s3"]["object"]["key"])

        sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            input=json.dumps({"bucket": bucket, "key": key}),
        )
