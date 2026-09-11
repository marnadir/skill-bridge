"""Lambda: [PII redaction] step of the cv-processing Step Function (doc 4.2).

Pseudonymizes the parsed markdown BEFORE any downstream step: the
matching needs skills, not identities. Double pass (doc failure
modes): deterministic regexes for structured Italian patterns
(email, phone, codice fiscale) + LLM pass for free-form PII (names,
addresses, birth dates). Identifiers are replaced with tokens
([CANDIDATE_NAME_1], [EMAIL_1], ...); the token->value map is stored
in a dedicated DynamoDB table, separate from the pipeline data.

Note: Comprehend PII was discarded because it does not support
Italian; see ADR-004."""

import json
import os
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Literal

import boto3
from pydantic import BaseModel
from skillbridge_common.metrics import Metrics

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")
dynamodb = boto3.client("dynamodb")


class PiiEntity(BaseModel):
    """One free-form PII span found by the LLM pass."""

    text: str
    type: Literal["name", "address", "birthdate"]


class EntityList(BaseModel):
    """Validated payload of the record_pii_entities tool call."""

    entities: list[PiiEntity]

MODEL_ID = os.environ["MODEL_ID"]
PII_MAP_TABLE = os.environ["PII_MAP_TABLE"]
# prompt.yaml: a single "prompt: |" block scalar; the runtime has no
# PyYAML, so the block is read directly (the file stays valid YAML)
##per-invocation metrics instance (reset by the handler)
_metrics = Metrics("redact-pii")

_prompt_lines = (Path(__file__).parent / "prompt.yaml").read_text().splitlines()
PROMPT = "\n".join(
    line.removeprefix("  ") for line in _prompt_lines[_prompt_lines.index("prompt: |") + 1 :]
).strip()

# deterministic patterns for structured Italian PII
REGEX_PATTERNS: dict[str, re.Pattern[str]] = {
    "EMAIL": re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"),
    "PHONE": re.compile(r"(?:\+39[ .]?)?(?:3\d{2}[ .]?\d{6,7}|0\d{1,3}[ .]?\d{6,8})"),
    "CF": re.compile(r"\b[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]\b"),
}

# free-form PII types the LLM pass looks for -> token prefix
LLM_TYPES = {
    "name": "CANDIDATE_NAME",
    "address": "ADDRESS",
    "birthdate": "BIRTHDATE",
}

TOOL_NAME = "record_pii_entities"
TOOL_SPEC = {
    "name": TOOL_NAME,
    "description": "Record the personally identifying entities found in the text.",
    "inputSchema": {
        "json": {
            "type": "object",
            "properties": {
                "entities": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "text": {
                                "type": "string",
                                "description": "The exact span as it appears in the text.",
                            },
                            "type": {"type": "string", "enum": sorted(LLM_TYPES)},
                        },
                        "required": ["text", "type"],
                    },
                }
            },
            "required": ["entities"],
        }
    },
}


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Pseudonymize the parsed CV and store the redacted version.

    Args:
        event: Step Function parameters with "job_id", "bucket" and
            "markdown_key" (output of the parsing step).
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: {"redacted_key": <S3 key>, "pii_count": <int>}.

    Raises:
        ValueError: If the model response contains no tool call.
    """
    global _metrics
    _metrics = Metrics("redact-pii")
    job_id = event["job_id"]
    bucket = event["bucket"]
    markdown_key = event["markdown_key"]

    text = s3.get_object(Bucket=bucket, Key=markdown_key)["Body"].read().decode()

    pii_map: dict[str, str] = {}
    text = _redact_with_regex(text, pii_map)
    text = _redact_with_llm(text, pii_map)

    _store_pii_map(job_id, pii_map)

    redacted_key = f"redacted/{job_id}/cv.md"
    s3.put_object(
        Bucket=bucket,
        Key=redacted_key,
        Body=text.encode(),
        ContentType="text/markdown; charset=utf-8",
    )

    _metrics.add("PiiCount", len(pii_map))
    _metrics.flush(job_id)
    return {"redacted_key": redacted_key, "pii_count": len(pii_map)}


def _redact_with_regex(text: str, pii_map: dict[str, str]) -> str:
    """Replace structured PII (email, phone, CF) with tokens.

    Args:
        text: The text to redact.
        pii_map: Token -> original value map, updated in place.

    Returns:
        str: The text with structured PII replaced by tokens.
    """
    for prefix, pattern in REGEX_PATTERNS.items():
        # dedupe preserving order: the same value gets the same token
        values = list(dict.fromkeys(pattern.findall(text)))
        for index, value in enumerate(values, 1):
            token = f"[{prefix}_{index}]"
            pii_map[token] = value
            text = text.replace(value, token)
    return text


def _redact_with_llm(text: str, pii_map: dict[str, str]) -> str:
    """Replace free-form PII (names, addresses, birth dates) with tokens.

    Args:
        text: The text to redact (already regex-redacted).
        pii_map: Token -> original value map, updated in place.

    Returns:
        str: The text with free-form PII replaced by tokens.

    Raises:
        ValueError: If the model response contains no tool call.
    """
    response = bedrock.converse(
        modelId=MODEL_ID,
        messages=[{"role": "user", "content": [{"text": f"{PROMPT}\n\n---\n{text}"}]}],
        toolConfig={
            "tools": [{"toolSpec": TOOL_SPEC}],
            "toolChoice": {"tool": {"name": TOOL_NAME}},
        },
        inferenceConfig={"maxTokens": 2000, "temperature": 0},
    )

    _metrics.add_converse_usage(response, MODEL_ID)
    counters = dict.fromkeys(LLM_TYPES.values(), 0)
    for entity in EntityList.model_validate(_tool_input(response)).entities:
        span, prefix = entity.text, LLM_TYPES[entity.type]
        if not span or span not in text:
            continue
        counters[prefix] += 1
        token = f"[{prefix}_{counters[prefix]}]"
        pii_map[token] = span
        text = text.replace(span, token)
    return text


def _store_pii_map(job_id: str, pii_map: dict[str, str]) -> None:
    """Persist the token -> identity map, separate from pipeline data.

    Args:
        job_id: The job the map belongs to.
        pii_map: Token -> original value map.

    Returns:
        None
    """
    dynamodb.put_item(
        TableName=PII_MAP_TABLE,
        Item={
            "job_id": {"S": job_id},
            "pii_map": {"S": json.dumps(pii_map)},
            "created_at": {"S": datetime.now(UTC).isoformat()},
        },
    )


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
