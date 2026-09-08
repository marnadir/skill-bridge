"""Lambda: [Parsing] step of the cv-processing Step Function (doc 4.1).

Downloads the CV from S3 and attaches it as a Bedrock Converse
document block: the multimodal model transcribes PDF/DOC/DOCX
(including scans and multi-column layouts) to markdown. A mandatory
sanity check rejects broken transcriptions BEFORE they enter the
pipeline: a broken parsing produces a broken matching three steps
later, much harder to diagnose. Failures raise SanityCheckFailed,
which the state machine routes to the review queue (job status
NEEDS_REVIEW), not forward."""

import os
from pathlib import Path
from typing import Any

import boto3
from pydantic import BaseModel

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")


class CvMarkdown(BaseModel):
    """Validated payload of the record_cv_markdown tool call."""

    markdown: str

MODEL_ID = os.environ["MODEL_ID"]
# prompt.yaml: a single "prompt: |" block scalar; the runtime has no
# PyYAML, so the block is read directly (the file stays valid YAML)
_prompt_lines = (Path(__file__).parent / "prompt.yaml").read_text().splitlines()
PROMPT = "\n".join(
    line.removeprefix("  ") for line in _prompt_lines[_prompt_lines.index("prompt: |") + 1 :]
).strip()
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "8000"))

# converse document blocks accept at most 4.5 MB
MAX_DOCUMENT_BYTES = int(4.5 * 1024 * 1024)
SUPPORTED_FORMATS = {"pdf", "doc", "docx"}

# sanity check thresholds (doc 4.1: length, alphanumeric ratio,
# recognizable structure)
MIN_CHARS = 300
MIN_ALNUM_RATIO = 0.5
MIN_LINES = 5

TOOL_NAME = "record_cv_markdown"
TOOL_SPEC = {
    "name": TOOL_NAME,
    "description": "Record the markdown transcription of the CV.",
    "inputSchema": {
        "json": {
            "type": "object",
            "properties": {
                "markdown": {
                    "type": "string",
                    "description": (
                        "Faithful markdown transcription of the whole CV, "
                        "preserving headings, lists and section order."
                    ),
                }
            },
            "required": ["markdown"],
        }
    },
}


class SanityCheckFailed(Exception):
    """Raised when the transcription fails the structural sanity check.

    The exception class name is the error name the state machine
    matches on to route the job to the review queue."""


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Transcribe the CV to markdown and store it on S3.

    Args:
        event: Step Function state with "job_id", "bucket" and "key".
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: {"markdown_key": <S3 key of the transcription>}.

    Raises:
        ValueError: If the document format is unsupported, the file is
            too large, or the model response contains no tool call.
        SanityCheckFailed: If the transcription fails the sanity check.
    """
    job_id = event["job_id"]
    bucket = event["bucket"]
    key = event["key"]

    doc_format = key.rsplit(".", 1)[-1].lower()
    if doc_format not in SUPPORTED_FORMATS:
        raise ValueError(f"unsupported document format: {doc_format}")

    obj = s3.get_object(Bucket=bucket, Key=key)
    data = obj["Body"].read()
    if len(data) > MAX_DOCUMENT_BYTES:
        raise ValueError(f"document too large for converse: {len(data)} bytes")

    response = bedrock.converse(
        modelId=MODEL_ID,
        messages=[
            {
                "role": "user",
                "content": [
                    {"document": {"name": "cv", "format": doc_format, "source": {"bytes": data}}},
                    {"text": PROMPT},
                ],
            }
        ],
        toolConfig={
            "tools": [{"toolSpec": TOOL_SPEC}],
            "toolChoice": {"tool": {"name": TOOL_NAME}},
        },
        inferenceConfig={"maxTokens": MAX_TOKENS, "temperature": 0},
    )

    markdown = CvMarkdown.model_validate(_tool_input(response)).markdown
    _sanity_check(markdown)

    markdown_key = f"markdown/{job_id}/cv.md"
    s3.put_object(
        Bucket=bucket,
        Key=markdown_key,
        Body=markdown.encode(),
        ContentType="text/markdown; charset=utf-8",
    )

    return {"markdown_key": markdown_key}


def _sanity_check(markdown: str) -> None:
    """Reject transcriptions that are structurally broken.

    Args:
        markdown: The transcription produced by the model.

    Returns:
        None

    Raises:
        SanityCheckFailed: With the list of failed checks.
    """
    problems = []

    stripped = "".join(markdown.split())
    if len(markdown) < MIN_CHARS:
        problems.append(f"too short: {len(markdown)} chars < {MIN_CHARS}")
    if stripped and sum(c.isalnum() for c in stripped) / len(stripped) < MIN_ALNUM_RATIO:
        problems.append("alphanumeric ratio below threshold")
    if sum(1 for line in markdown.splitlines() if line.strip()) < MIN_LINES:
        problems.append(f"fewer than {MIN_LINES} non-empty lines")

    if problems:
        raise SanityCheckFailed("; ".join(problems))


def _tool_input(response: dict[str, Any]) -> dict[str, Any]:
    """Extract the input of the forced tool call from a Converse response.

    Args:
        response: The raw bedrock-runtime converse response.

    Returns:
        dict[str, Any]: The tool call input, already parsed by Bedrock.

    Raises:
        ValueError: If the response contains no expected tool call.
    """
    for block in response["output"]["message"]["content"]:
        if "toolUse" in block and block["toolUse"]["name"] == TOOL_NAME:
            return block["toolUse"]["input"]
    raise ValueError("model response contains no tool call")
