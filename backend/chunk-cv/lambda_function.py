"""Lambda: [Chunk] step of the cv-processing Step Function (doc 4.5).

Structural chunking, not semantic: CVs HAVE a recurring structure
even when the layout varies, so we ask the model to return the
canonical sections explicitly instead of estimating boundaries
statistically. Each section becomes a chunk with metadata (section
type, dates, language, parsing_version). The parsing_version metadata
enables targeted re-indexing when the parser improves."""

import os
from pathlib import Path
from typing import Any, Literal

import boto3
from pydantic import BaseModel

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")


class CvSection(BaseModel):
    """One canonical section extracted from the CV."""

    section_type: Literal[
        "summary", "experience", "education", "skills", "certifications", "languages", "other"
    ]
    title: str
    content: str
    date_start: str | None = None
    date_end: str | None = None
    language: Literal["it", "en", "other"]


class SectionList(BaseModel):
    """Validated payload of the record_cv_sections tool call."""

    sections: list[CvSection]


class CvChunk(CvSection):
    """A section enriched with its chunk id."""

    chunk_id: str


class ChunksFile(BaseModel):
    """The chunks artifact written to S3 for the embedding step."""

    job_id: str
    parsing_version: str
    sections: list[CvChunk]

MODEL_ID = os.environ["MODEL_ID"]
PARSING_VERSION = os.environ.get("PARSING_VERSION", "1")
# prompt.yaml: a single "prompt: |" block scalar; the runtime has no
# PyYAML, so the block is read directly (the file stays valid YAML)
_prompt_lines = (Path(__file__).parent / "prompt.yaml").read_text().splitlines()
PROMPT = "\n".join(
    line.removeprefix("  ") for line in _prompt_lines[_prompt_lines.index("prompt: |") + 1 :]
).strip()

# the tool schema enums are derived from the pydantic models: one
# source of truth for model-side and code-side validation
SECTION_TYPES = list(CvSection.model_fields["section_type"].annotation.__args__)
LANGUAGES = list(CvSection.model_fields["language"].annotation.__args__)

TOOL_NAME = "record_cv_sections"
TOOL_SPEC = {
    "name": TOOL_NAME,
    "description": "Record the canonical sections extracted from the CV.",
    "inputSchema": {
        "json": {
            "type": "object",
            "properties": {
                "sections": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "section_type": {"type": "string", "enum": SECTION_TYPES},
                            "title": {
                                "type": "string",
                                "description": "Short label, e.g. the role or degree.",
                            },
                            "content": {
                                "type": "string",
                                "description": "The full text of the section, verbatim.",
                            },
                            "date_start": {
                                "type": ["string", "null"],
                                "description": "YYYY or YYYY-MM when applicable.",
                            },
                            "date_end": {
                                "type": ["string", "null"],
                                "description": "YYYY, YYYY-MM, 'present', or null.",
                            },
                            "language": {"type": "string", "enum": LANGUAGES},
                        },
                        "required": ["section_type", "title", "content", "language"],
                    },
                }
            },
            "required": ["sections"],
        }
    },
}


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Split the normalized CV into canonical sections with metadata.

    Args:
        event: Step Function parameters with "job_id", "bucket" and
            "normalized_key" (output of the normalization step).
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: {"chunks_key": <S3 key of the chunks json>,
            "chunk_count": <int>}.

    Raises:
        ValueError: If the model response contains no tool call or
            returns zero sections.
    """
    job_id = event["job_id"]
    bucket = event["bucket"]
    normalized_key = event["normalized_key"]

    text = s3.get_object(Bucket=bucket, Key=normalized_key)["Body"].read().decode()

    response = bedrock.converse(
        modelId=MODEL_ID,
        messages=[{"role": "user", "content": [{"text": f"{PROMPT}\n\n---\n{text}"}]}],
        toolConfig={
            "tools": [{"toolSpec": TOOL_SPEC}],
            "toolChoice": {"tool": {"name": TOOL_NAME}},
        },
        inferenceConfig={"maxTokens": 8000, "temperature": 0},
    )

    sections = SectionList.model_validate(_tool_input(response)).sections
    if not sections:
        raise ValueError("chunking produced zero sections")

    chunks = ChunksFile(
        job_id=job_id,
        parsing_version=PARSING_VERSION,
        sections=[
            CvChunk(chunk_id=f"{job_id}#{index}", **section.model_dump())
            for index, section in enumerate(sections)
        ],
    )

    chunks_key = f"chunks/{job_id}/chunks.json"
    s3.put_object(
        Bucket=bucket,
        Key=chunks_key,
        Body=chunks.model_dump_json().encode(),
        ContentType="application/json",
    )

    return {"chunks_key": chunks_key, "chunk_count": len(chunks.sections)}


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
