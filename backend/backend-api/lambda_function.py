"""Lambda: backend API of skill-bridge, behind API Gateway (HTTP API).

Routes (doc section 3.1):
- POST /jobs: creates the job on the DynamoDB jobs table (source of
  truth of the processing state) and returns a presigned PUT URL; the
  file goes directly from the client to S3, never through the backend.
- GET /jobs/{jobId}: returns the job state (and result pointers) for
  the web app polling."""

import json
import os
import re
import uuid
from datetime import UTC, datetime
from typing import Any, Literal

import boto3
from botocore.config import Config
from pydantic import BaseModel, Field, ValidationError, field_validator

REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "eu-central-1"

# force the regional endpoint: presigned URLs built on the global
# endpoint get a 307 redirect that browsers block after the preflight
s3 = boto3.client(
    "s3",
    region_name=REGION,
    endpoint_url=f"https://s3.{REGION}.amazonaws.com",
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
)
dynamodb = boto3.client("dynamodb")
cloudwatch = boto3.client("cloudwatch")

##stats window shown in the web app dashboard
STATS_WINDOW_DAYS = 14

BUCKET = os.environ["BUCKET_NAME"]
JOBS_TABLE = os.environ["JOBS_TABLE"]

URL_TTL_SECONDS = 300
# 4.5 MB: hard limit of Bedrock Converse document blocks used by the
# parsing step (keep in sync with CvUpload.tsx)
MAX_SIZE_BYTES = int(4.5 * 1024 * 1024)

class CreateJobRequest(BaseModel):
    """Validated body of POST /jobs."""

    file_name: str = Field(alias="fileName")
    content_type: Literal[
        "application/pdf",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ] = Field(alias="contentType")
    size: float = Field(gt=0, le=MAX_SIZE_BYTES)

    @field_validator("file_name")
    @classmethod
    def _file_name_not_blank(cls, value: str) -> str:
        """Reject blank file names.

        Args:
            value: The raw fileName field.

        Returns:
            str: The validated value.

        Raises:
            ValueError: If the name is empty or whitespace only.
        """
        if not value.strip():
            raise ValueError("blank file name")
        return value


##user-facing message per invalid field (pydantic loc -> italian)
VALIDATION_MESSAGES = {
    "fileName": "fileName mancante",
    "contentType": "Formato non supportato: solo PDF, DOC o DOCX",
    "size": f"Dimensione non valida: max {MAX_SIZE_BYTES / (1024 * 1024):g} MB",
}


def _response(status_code: int, body: dict[str, Any]) -> dict[str, Any]:
    """Build an API Gateway HTTP response.

    Args:
        status_code: The HTTP status code.
        body: The payload to serialize as the JSON body.

    Returns:
        dict[str, Any]: The response in the API Gateway v2 format.
    """
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


class DailyPoint(BaseModel):
    """One day of the dashboard time series."""

    date: str
    jobs: int = 0
    cost_eur: float = 0.0


class StatsResponse(BaseModel):
    """Payload of GET /stats (window: STATS_WINDOW_DAYS)."""

    window_days: int
    total_jobs: int
    completed: int
    failed: int
    needs_review: int
    processing: int
    total_cost_eur: float
    avg_cost_per_cv_eur: float
    daily: list[DailyPoint]


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Route the API Gateway request.

    Args:
        event: The API Gateway v2 event; routing is based on routeKey.
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: The HTTP response of the matched route, or 404
            for unknown routes.
    """
    route = event.get("routeKey", "")

    if route == "POST /jobs":
        return _create_job(event)
    if route == "GET /jobs/{jobId}":
        return _get_job(event)
    if route == "GET /stats":
        return _get_stats()
    return _response(404, {"message": "Rotta non trovata"})


def _get_stats() -> dict[str, Any]:
    """Aggregate the dashboard stats for the web app.

    Job counts come from the jobs table (paginated scan: fine at this
    scale); costs come from the StepCostEur EMF metric (aggregate
    no-dimension series) already emitted by every pipeline lambda.

    Returns:
        dict[str, Any]: 200 with a StatsResponse body.
    """
    from datetime import UTC, datetime, timedelta

    now = datetime.now(UTC)
    ##anchor the window to UTC midnight: get_metric_data aligns its
    ##daily buckets to StartTime, so a mid-day start would label
    ##today's cost with yesterday's date (found in browser testing)
    window_start = (now - timedelta(days=STATS_WINDOW_DAYS)).replace(
        hour=0, minute=0, second=0, microsecond=0
    )

    ##--- job counts + daily series from the jobs table ---
    counts = {"COMPLETED": 0, "FAILED": 0, "NEEDS_REVIEW": 0}
    processing = total = 0
    daily_jobs: dict[str, int] = {}
    scan_kwargs: dict[str, Any] = {
        "TableName": JOBS_TABLE,
        "ProjectionExpression": "#s, created_at",
        "ExpressionAttributeNames": {"#s": "status"},
    }
    while True:
        page = dynamodb.scan(**scan_kwargs)
        for item in page.get("Items", []):
            total += 1
            status = item["status"]["S"]
            if status in counts:
                counts[status] += 1
            elif status in ("PROCESSING", "PENDING_UPLOAD"):
                processing += 1
            created = item["created_at"]["S"][:10]
            if created >= window_start.strftime("%Y-%m-%d"):
                daily_jobs[created] = daily_jobs.get(created, 0) + 1
        if "LastEvaluatedKey" not in page:
            break
        scan_kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    ##--- daily cost from the aggregate StepCostEur metric ---
    metric = cloudwatch.get_metric_data(
        MetricDataQueries=[{
            "Id": "cost",
            "MetricStat": {
                "Metric": {"Namespace": "SkillBridge/Pipeline", "MetricName": "StepCostEur"},
                "Period": 86400,
                "Stat": "Sum",
            },
        }],
        StartTime=window_start,
        EndTime=now,
    )["MetricDataResults"][0]
    daily_cost = {
        ts.strftime("%Y-%m-%d"): value
        for ts, value in zip(metric["Timestamps"], metric["Values"])
    }

    days = [(window_start + timedelta(days=i)).strftime("%Y-%m-%d") for i in range(STATS_WINDOW_DAYS + 1)]
    daily = [
        DailyPoint(date=d, jobs=daily_jobs.get(d, 0), cost_eur=round(daily_cost.get(d, 0.0), 4))
        for d in days
    ]
    total_cost = round(sum(p.cost_eur for p in daily), 4)
    completed_in_window = sum(p.jobs for p in daily)

    stats = StatsResponse(
        window_days=STATS_WINDOW_DAYS,
        total_jobs=total,
        completed=counts["COMPLETED"],
        failed=counts["FAILED"],
        needs_review=counts["NEEDS_REVIEW"],
        processing=processing,
        total_cost_eur=total_cost,
        avg_cost_per_cv_eur=round(total_cost / completed_in_window, 4) if completed_in_window else 0.0,
        daily=daily,
    )
    return _response(200, stats.model_dump())


def _create_job(event: dict[str, Any]) -> dict[str, Any]:
    """Create a job and return the presigned upload URL.

    Args:
        event: The API Gateway event; the JSON body must contain
            "fileName", "contentType" and "size".

    Returns:
        dict[str, Any]: 201 with "jobId", "uploadUrl" and "expiresIn",
            or 400 with the validation failure reason.
    """
    try:
        request = CreateJobRequest.model_validate_json(event.get("body") or "")
    except ValidationError as exc:
        loc = exc.errors()[0].get("loc") or ()
        message = VALIDATION_MESSAGES.get(str(loc[0]) if loc else "", "Body JSON non valido")
        return _response(400, {"message": message})

    ##the gateway has ALREADY validated the JWT (ADR-014): here we
    ##only read the verified claims for attribution
    claims = event.get("requestContext", {}).get("authorizer", {}).get("jwt", {}).get("claims", {})
    created_by = claims.get("email") or claims.get("sub") or "unknown"

    job_id = str(uuid.uuid4())
    safe_name = re.sub(r"[^\w.\-]+", "_", request.file_name)[-100:]
    # the job_id is embedded in the key: the starter lambda derives it
    # back from the S3 event
    key = f"cv/{job_id}/{safe_name}"
    now = datetime.now(UTC).isoformat()

    dynamodb.put_item(
        TableName=JOBS_TABLE,
        Item={
            "job_id": {"S": job_id},
            "status": {"S": "PENDING_UPLOAD"},
            "cv_key": {"S": key},
            "file_name": {"S": request.file_name},
            "created_by": {"S": created_by},
            "created_at": {"S": now},
            "updated_at": {"S": now},
        },
    )

    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key, "ContentType": request.content_type},
        ExpiresIn=URL_TTL_SECONDS,
    )

    return _response(
        201, {"jobId": job_id, "uploadUrl": upload_url, "expiresIn": URL_TTL_SECONDS}
    )


def _get_job(event: dict[str, Any]) -> dict[str, Any]:
    """Return the current state of a job.

    Args:
        event: The API Gateway event with the "jobId" path parameter.

    Returns:
        dict[str, Any]: 200 with "jobId", "status", "fileName",
            "createdAt", "updatedAt" and optionally "error", or 404
            if the job does not exist.
    """
    job_id = (event.get("pathParameters") or {}).get("jobId", "")

    item = dynamodb.get_item(
        TableName=JOBS_TABLE,
        Key={"job_id": {"S": job_id}},
    ).get("Item")

    if item is None:
        return _response(404, {"message": "Job non trovato"})

    body: dict[str, Any] = {
        "jobId": job_id,
        "status": item["status"]["S"],
        "fileName": item["file_name"]["S"],
        "createdAt": item["created_at"]["S"],
        "updatedAt": item["updated_at"]["S"],
    }
    if "error" in item:
        body["error"] = item["error"]["S"]
    if "results" in item:
        ##match report written by the SaveResults state (doc 2.1)
        body["results"] = json.loads(item["results"]["S"])

    return _response(200, body)
