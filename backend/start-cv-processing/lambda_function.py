"""Lambda: consumes S3 upload events from the SQS queue and starts
the CV processing Step Function, one execution per uploaded object.

Uses partial batch responses (ReportBatchItemFailures): only failed
messages go back to the queue, the rest of the batch is deleted."""

import json
import os
import urllib.parse

import boto3

sfn = boto3.client("stepfunctions")

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]


def lambda_handler(event, context):
    failures = []

    for record in event.get("Records", []):
        try:
            _process_message(record)
        except Exception:
            # let the message return to the queue (and eventually the DLQ)
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}


def _process_message(record):
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
