"""Lambda: genera un presigned URL S3 (PUT) che il frontend usa per
caricare il CV direttamente sul bucket, senza passare dal backend.
Esposta tramite Lambda Function URL (POST con body JSON).
boto3 e' incluso nel runtime: nessuna dipendenza da pacchettizzare."""

import json
import os
import re
import uuid

import boto3
from botocore.config import Config

# force the regional endpoint: presigned URLs built on the global
# endpoint (s3.amazonaws.com) get a 307 redirect for eu-central-1
# buckets, which browsers block after a CORS preflight
REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "eu-central-1"

s3 = boto3.client(
    "s3",
    region_name=REGION,
    endpoint_url=f"https://s3.{REGION}.amazonaws.com",
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
)

BUCKET = os.environ["BUCKET_NAME"]
URL_TTL_SECONDS = 300
MAX_SIZE_BYTES = 5 * 1024 * 1024

# stessi vincoli applicati lato frontend (CvUpload.tsx)
ALLOWED_TYPES = {
    "application/pdf",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
}


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    if event.get("requestContext", {}).get("http", {}).get("method") != "POST":
        return _response(405, {"message": "Metodo non consentito"})

    try:
        payload = json.loads(event.get("body") or "")
    except json.JSONDecodeError:
        return _response(400, {"message": "Body JSON non valido"})

    if not isinstance(payload, dict):
        return _response(400, {"message": "Body JSON non valido"})

    file_name = payload.get("fileName")
    content_type = payload.get("contentType")
    size = payload.get("size")

    if not isinstance(file_name, str) or not file_name.strip():
        return _response(400, {"message": "fileName mancante"})
    if content_type not in ALLOWED_TYPES:
        return _response(
            400, {"message": "Formato non supportato: solo PDF, DOC o DOCX"}
        )
    if not isinstance(size, (int, float)) or size <= 0 or size > MAX_SIZE_BYTES:
        return _response(
            400,
            {"message": f"Dimensione non valida: max {MAX_SIZE_BYTES // (1024 * 1024)} MB"},
        )

    # chiave con uuid per evitare collisioni; nome file ripulito dai
    # caratteri non sicuri per S3/url
    safe_name = re.sub(r"[^\w.\-]+", "_", file_name)[-100:]
    key = f"cv/{uuid.uuid4()}/{safe_name}"

    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": BUCKET, "Key": key, "ContentType": content_type},
        ExpiresIn=URL_TTL_SECONDS,
    )

    return _response(
        200, {"uploadUrl": upload_url, "key": key, "expiresIn": URL_TTL_SECONDS}
    )
