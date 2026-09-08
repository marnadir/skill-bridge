"""Lambda: consumes S3 upload events from the SQS queue and starts
the CV processing Step Function, one execution per uploaded object.

Two idempotency levels (doc section 3.2 — SQS is at-least-once):
1. conditional update on the jobs table: the PENDING_UPLOAD ->
   PROCESSING transition succeeds only once, duplicates are skipped;
2. execution name = job_id: on Step Functions Standard the name is
   unique for 90 days, so a duplicate StartExecution fails cleanly.

Uses partial batch responses (ReportBatchItemFailures): only failed
messages go back to the queue, the rest of the batch is deleted."""

import json
import os
import urllib.parse
from datetime import UTC, datetime
from typing import Any

import boto3

sfn = boto3.client("stepfunctions")
dynamodb = boto3.client("dynamodb")

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
JOBS_TABLE = os.environ["JOBS_TABLE"]


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
        job_id = _job_id_from_key(key)

        if not _claim_job(job_id):
            # duplicate SQS delivery: the job is already being processed
            continue

        try:
            sfn.start_execution(
                stateMachineArn=STATE_MACHINE_ARN,
                name=job_id,
                input=json.dumps({"job_id": job_id, "bucket": bucket, "key": key}),
            )
        except sfn.exceptions.ExecutionAlreadyExists:
            # second idempotency level: another delivery won the race
            pass


def _job_id_from_key(key: str) -> str:
    """Derive the job id from the S3 key created by backend-api.

    Args:
        key: The uploaded CV key, shaped "cv/{job_id}/{file}".

    Returns:
        str: The job id segment of the key.

    Raises:
        ValueError: If the key does not have the expected shape.
    """
    parts = key.split("/")
    if len(parts) < 3 or parts[0] != "cv":
        raise ValueError(f"unexpected cv key shape: {key}")
    return parts[1]


def _claim_job(job_id: str) -> bool:
    """Atomically move the job from PENDING_UPLOAD to PROCESSING.

    Args:
        job_id: The job to claim.

    Returns:
        bool: True if this invocation claimed the job, False if it was
            already claimed (duplicate message).
    """
    try:
        dynamodb.update_item(
            TableName=JOBS_TABLE,
            Key={"job_id": {"S": job_id}},
            UpdateExpression="SET #s = :processing, updated_at = :now",
            ConditionExpression="#s = :pending",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":processing": {"S": "PROCESSING"},
                ":pending": {"S": "PENDING_UPLOAD"},
                ":now": {"S": datetime.now(UTC).isoformat()},
            },
        )
        return True
    except dynamodb.exceptions.ConditionalCheckFailedException:
        return False
