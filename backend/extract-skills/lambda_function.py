"""Lambda: ExtractSkills step of the cv-processing Step Function.

Downloads the CV from S3 and attaches it as a document block to a
single Bedrock Converse call (no local text extraction: Claude reads
the PDF/DOC/DOCX directly, including layout and scans).

The output shape is enforced twice:
- model side: a forced tool call whose inputSchema is the JSON schema
  of the expected result (no free-text JSON to parse);
- code side: stdlib dataclasses that fail fast on missing fields and
  give typed access.

The markdown transcription is stored in S3 (markdown/ prefix, outside
the cv/ notification prefix) as a reusable artifact for future
features; the structured profile goes to DynamoDB in the next step."""

import os
from dataclasses import asdict, dataclass, fields
from pathlib import Path
from typing import Any

import boto3

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")

MODEL_ID = os.environ["MODEL_ID"]

# prompt shipped in the deploy zip next to this module; inference
# parameters come from the environment (set by terraform)
PROMPT = (Path(__file__).parent / "prompt.txt").read_text()
MAX_TOKENS = int(os.environ.get("MAX_TOKENS", "8000"))
TEMPERATURE = float(os.environ.get("TEMPERATURE", "0"))

# converse document blocks accept at most 4.5 MB
MAX_DOCUMENT_BYTES = int(4.5 * 1024 * 1024)

SUPPORTED_FORMATS = {"pdf", "doc", "docx"}

# the model is forced to "call" this tool: its input schema IS the
# contract of the extraction result
TOOL_NAME = "record_cv_extraction"
TOOL_SPEC = {
    "name": TOOL_NAME,
    "description": "Record the CV transcription and the extracted candidate profile.",
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
                },
                "profile": {
                    "type": "object",
                    "properties": {
                        "full_name": {"type": ["string", "null"]},
                        "summary": {
                            "type": "string",
                            "description": "2-3 sentences, same language as the CV.",
                        },
                        "skills": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Technical and soft skills, normalized names.",
                        },
                        "languages": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Spoken languages.",
                        },
                        "years_experience": {"type": ["number", "null"]},
                        "roles": {
                            "type": "array",
                            "items": {"type": "string"},
                            "description": "Job titles held, most recent first.",
                        },
                    },
                    "required": ["summary", "skills", "languages", "roles"],
                },
            },
            "required": ["markdown", "profile"],
        }
    },
}


@dataclass
class Profile:
    summary: str
    skills: list[str]
    languages: list[str]
    roles: list[str]
    full_name: str | None = None
    years_experience: float | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Profile":
        """Build a Profile from the model tool input.

        Args:
            data: The "profile" object of the tool call input; unknown
                keys are ignored.

        Returns:
            Profile: The typed profile.

        Raises:
            TypeError: If a required field is missing.
        """
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in known})


@dataclass
class Extraction:
    markdown: str
    profile: Profile

    @classmethod
    def from_tool_input(cls, data: dict[str, Any]) -> "Extraction":
        """Build an Extraction from the forced tool call input.

        Args:
            data: The tool call input, shaped by TOOL_SPEC's schema.

        Returns:
            Extraction: The typed extraction result.

        Raises:
            KeyError: If "markdown" or "profile" is missing.
            TypeError: If a required profile field is missing.
        """
        return cls(markdown=data["markdown"], profile=Profile.from_dict(data["profile"]))


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Extract the candidate profile from a CV stored in S3.

    Args:
        event: Step Function state, with "bucket" and "key" of the
            uploaded CV.
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: The extraction result with keys "analysis"
            (structured profile), "markdown_key" (S3 key of the saved
            transcription) and "model" (Bedrock model id used).

    Raises:
        ValueError: If the document format is unsupported, the file
            exceeds the Converse size limit, or the model response
            contains no tool call.
    """
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
                    {
                        "document": {
                            "name": "cv",
                            "format": doc_format,
                            "source": {"bytes": data},
                        }
                    },
                    {"text": PROMPT},
                ],
            }
        ],
        toolConfig={
            "tools": [{"toolSpec": TOOL_SPEC}],
            "toolChoice": {"tool": {"name": TOOL_NAME}},
        },
        inferenceConfig={"maxTokens": MAX_TOKENS, "temperature": TEMPERATURE},
    )

    extraction = Extraction.from_tool_input(_tool_input(response))

    markdown_key = _markdown_key(key)
    s3.put_object(
        Bucket=bucket,
        Key=markdown_key,
        Body=extraction.markdown.encode(),
        ContentType="text/markdown; charset=utf-8",
    )

    return {
        "analysis": asdict(extraction.profile),
        "markdown_key": markdown_key,
        "model": MODEL_ID,
    }


def _tool_input(response: dict[str, Any]) -> dict[str, Any]:
    """Extract the input of the forced tool call from a Converse response.

    Args:
        response: The raw bedrock-runtime converse response.

    Returns:
        dict[str, Any]: The tool call input, already parsed by Bedrock.

    Raises:
        ValueError: If the response contains no record_cv_extraction call.
    """
    content = response["output"]["message"]["content"]
    for block in content:
        if "toolUse" in block and block["toolUse"]["name"] == TOOL_NAME:
            return block["toolUse"]["input"]
    raise ValueError("model response contains no tool call")


def _markdown_key(key: str) -> str:
    """Derive the S3 key of the markdown artifact from the CV key.

    Args:
        key: The uploaded CV key, e.g. "cv/{uuid}/{file}.pdf".

    Returns:
        str: The markdown key, e.g. "markdown/{uuid}/{file}.md".
    """
    path = key.removeprefix("cv/")
    base = path.rsplit(".", 1)[0]
    return f"markdown/{base}.md"
