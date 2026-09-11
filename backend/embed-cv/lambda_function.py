"""Lambda: [Embed] step of the cv-processing Step Function (doc 4.6).

Embeds the CV chunks with the multilingual model (the same one used
for the pre-indexed JDs: comparable spaces) and upserts them into the
Aurora pgvector store via the RDS Data API — no VPC attachment
needed, IAM-authenticated (see ADR-006).

Hard requirement from the doc: atomic upsert per document
(doc_version + is_latest) so mixed versions are never served. The
insert of the new version and the demotion of the old one happen in
a single Data API transaction.

The cluster scales to zero: the first call after a pause gets a
DatabaseResumingException, handled with a bounded retry loop."""

import json
import os
import time
from typing import Any

import boto3
from pydantic import BaseModel
from skillbridge_common.metrics import Metrics

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")
rds = boto3.client("rds-data")


class CvChunk(BaseModel):
    """One CV section as produced by the chunking step."""

    chunk_id: str
    section_type: str
    title: str
    content: str
    date_start: str | None = None
    date_end: str | None = None
    language: str


class ChunksFile(BaseModel):
    """The chunks artifact read from S3 (contract with chunk-cv)."""

    job_id: str
    parsing_version: str
    sections: list[CvChunk]

EMBED_MODEL_ID = os.environ["EMBED_MODEL_ID"]
CLUSTER_ARN = os.environ["CLUSTER_ARN"]
SECRET_ARN = os.environ["SECRET_ARN"]
DATABASE = os.environ["DATABASE"]

EMBEDDING_DIM = 1024

##per-invocation metrics instance (reset by the handler)
_metrics = Metrics("embed-cv")
# waking a paused cluster takes ~15s: bounded retry
RESUME_MAX_WAIT_SECONDS = 90

DDL = [
    "CREATE EXTENSION IF NOT EXISTS vector",
    f"""
    CREATE TABLE IF NOT EXISTS cv_chunks (
        chunk_id        text PRIMARY KEY,
        doc_id          text NOT NULL,
        doc_version     integer NOT NULL,
        is_latest       boolean NOT NULL,
        section_type    text NOT NULL,
        title           text NOT NULL,
        content         text NOT NULL,
        language        text NOT NULL,
        parsing_version text NOT NULL,
        embedding       vector({EMBEDDING_DIM}) NOT NULL,
        created_at      timestamptz NOT NULL DEFAULT now()
    )
    """,
    "CREATE INDEX IF NOT EXISTS cv_chunks_doc ON cv_chunks (doc_id, is_latest)",
    ##same shape for the pre-indexed job descriptions (seeded separately)
    f"""
    CREATE TABLE IF NOT EXISTS jd_chunks (
        chunk_id   text PRIMARY KEY,
        jd_id      text NOT NULL,
        title      text NOT NULL,
        content    text NOT NULL,
        skills     jsonb NOT NULL DEFAULT '[]',
        embedding  vector({EMBEDDING_DIM}) NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )
    """,
]

_schema_ready = False


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Embed the CV chunks and upsert them atomically into pgvector.

    Args:
        event: Step Function parameters with "job_id", "bucket" and
            "chunks_key" (output of the chunking step).
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: {"chunks_indexed": <int>, "doc_version": <int>}.
    """
    global _metrics
    _metrics = Metrics("embed-cv")
    job_id = event["job_id"]
    bucket = event["bucket"]
    chunks_key = event["chunks_key"]

    chunks = ChunksFile.model_validate_json(
        s3.get_object(Bucket=bucket, Key=chunks_key)["Body"].read()
    )
    sections = chunks.sections

    ##one embedding per section; title gives the vector extra signal
    vectors = _embed([f"{s.title}\n{s.content}" for s in sections])

    _ensure_schema()
    doc_version = _next_doc_version(job_id)

    ##atomic upsert (doc 4.6): new rows + demotion of the previous
    ##version in ONE transaction — mixed versions are never visible
    tx = _execute_with_resume(rds.begin_transaction, resourceArn=CLUSTER_ARN,
                              secretArn=SECRET_ARN, database=DATABASE)["transactionId"]
    try:
        for section, vector in zip(sections, vectors):
            _sql(
                """
                INSERT INTO cv_chunks (chunk_id, doc_id, doc_version, is_latest,
                    section_type, title, content, language, parsing_version, embedding)
                VALUES (:chunk_id, :doc_id, :doc_version, true, :section_type,
                    :title, :content, :language, :parsing_version, (:embedding)::vector)
                ON CONFLICT (chunk_id) DO NOTHING
                """,
                transaction_id=tx,
                parameters={
                    "chunk_id": f"{section.chunk_id}@v{doc_version}",
                    "doc_id": job_id,
                    "doc_version": doc_version,
                    "section_type": section.section_type,
                    "title": section.title,
                    "content": section.content,
                    "language": section.language,
                    "parsing_version": chunks.parsing_version,
                    "embedding": json.dumps(vector),
                },
            )
        _sql(
            "UPDATE cv_chunks SET is_latest = false "
            "WHERE doc_id = :doc_id AND doc_version < :doc_version",
            transaction_id=tx,
            parameters={"doc_id": job_id, "doc_version": doc_version},
        )
        rds.commit_transaction(resourceArn=CLUSTER_ARN, secretArn=SECRET_ARN, transactionId=tx)
    except Exception:
        rds.rollback_transaction(resourceArn=CLUSTER_ARN, secretArn=SECRET_ARN, transactionId=tx)
        raise

    _metrics.add("ChunksIndexed", len(sections))
    _metrics.flush(job_id)
    return {"chunks_indexed": len(sections), "doc_version": doc_version}


def _ensure_schema() -> None:
    """Create extension and tables if missing (idempotent, once per runtime).

    Returns:
        None
    """
    global _schema_ready
    if _schema_ready:
        return
    for statement in DDL:
        _sql(statement)
    _schema_ready = True


def _next_doc_version(doc_id: str) -> int:
    """Compute the next version number for a document.

    Args:
        doc_id: The document (job) id.

    Returns:
        int: max(existing versions) + 1, starting at 1.
    """
    result = _sql(
        "SELECT coalesce(max(doc_version), 0) FROM cv_chunks WHERE doc_id = :doc_id",
        parameters={"doc_id": doc_id},
    )
    return result["records"][0][0]["longValue"] + 1


def _sql(
    statement: str,
    parameters: dict[str, Any] | None = None,
    transaction_id: str | None = None,
) -> dict[str, Any]:
    """Run a SQL statement through the RDS Data API.

    Args:
        statement: The SQL text with :named parameters.
        parameters: Parameter name -> python value (str/int).
        transaction_id: Optional Data API transaction to run inside.

    Returns:
        dict[str, Any]: The raw ExecuteStatement response.
    """
    kwargs: dict[str, Any] = {
        "resourceArn": CLUSTER_ARN,
        "secretArn": SECRET_ARN,
        "database": DATABASE,
        "sql": statement,
    }
    if parameters:
        kwargs["parameters"] = [
            {
                "name": name,
                "value": {"longValue": value} if isinstance(value, int) else {"stringValue": value},
            }
            for name, value in parameters.items()
        ]
    if transaction_id:
        kwargs["transactionId"] = transaction_id
    return _execute_with_resume(rds.execute_statement, **kwargs)


def _execute_with_resume(operation: Any, **kwargs: Any) -> dict[str, Any]:
    """Call a Data API operation, waiting out a paused cluster.

    Args:
        operation: The boto3 rds-data method to call.
        kwargs: The arguments for the call.

    Returns:
        dict[str, Any]: The operation response.

    Raises:
        Exception: The last error, if the cluster does not resume in time.
    """
    deadline = time.time() + RESUME_MAX_WAIT_SECONDS
    while True:
        try:
            return operation(**kwargs)
        except Exception as exc:
            # a generic BadRequestException, matched on the message
            resuming = "resuming" in str(exc).lower() or "DatabaseResumingException" in str(exc)
            if not resuming or time.time() >= deadline:
                raise
            time.sleep(5)


def _embed(texts: list[str]) -> list[list[float]]:
    """Embed a batch of texts with the multilingual Cohere model.

    Args:
        texts: The texts to embed.

    Returns:
        list[list[float]]: One vector per input text.
    """
    vectors: list[list[float]] = []
    for start in range(0, len(texts), 96):
        response = bedrock.invoke_model(
            modelId=EMBED_MODEL_ID,
            body=json.dumps(
                {"texts": texts[start : start + 96], "input_type": "search_document"}
            ),
        )
        _metrics.add_invoke_usage(response, EMBED_MODEL_ID)
        vectors.extend(json.loads(response["body"].read())["embeddings"])
    return vectors
