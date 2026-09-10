"""Lambda: [AgentMatching] state of the cv-processing Step Function (doc 5).

Runs the Strands agent loop: the framework drives the model->tool->
model cycle (tool schemas, toolUse/toolResult, message accumulation),
while the GOVERNANCE stays in our code (doc 5.1): tool-call budget
checked inside the tool, typed terminal outcomes, evidence rule
enforced on the output.

v0 scope (doc 10.1): ONLY the internal tool `search_jd` (deterministic
kNN on the pre-indexed JDs in pgvector). The external validation tool
arrives in v0.5 behind a feature flag, isolated in its own lambda.

Per-offer outcomes: match (with mandatory evidences), no_match,
not_verifiable — a legitimate terminal outcome, not an error. A match
without evidences is demoted to not_verifiable ("no evidence = no
match", doc 6)."""

import json
import os
import re
import time
from pathlib import Path
from typing import Any, Literal

import boto3
from pydantic import BaseModel, Field
from strands import Agent, tool
from strands.models import BedrockModel

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")
rds = boto3.client("rds-data")
dynamodb = boto3.client("dynamodb")
lambda_client = boto3.client("lambda")

MODEL_ID = os.environ["MODEL_ID"]
EMBED_MODEL_ID = os.environ["EMBED_MODEL_ID"]
CLUSTER_ARN = os.environ["CLUSTER_ARN"]
SECRET_ARN = os.environ["SECRET_ARN"]
DATABASE = os.environ["DATABASE"]

##budget (doc 5.1): steps axis = tool calls, time axis = deadline;
##the cost axis in v0 is the step cap itself (each step has a known
##bounded cost) — full cost tracking arrives with observability
MAX_TOOL_CALLS = int(os.environ.get("MAX_TOOL_CALLS", "8"))
TIME_BUDGET_SECONDS = int(os.environ.get("TIME_BUDGET_SECONDS", "180"))
TOP_K = int(os.environ.get("TOP_K", "5"))

##external tool (v0.5, doc 5.2-bis): feature flag + isolated executor
EXTERNAL_TOOL_ENABLED = os.environ.get("EXTERNAL_TOOL_ENABLED", "false") == "true"
EXECUTOR_FUNCTION = os.environ.get("EXECUTOR_FUNCTION", "")
GOVERNANCE_TABLE = os.environ.get("GOVERNANCE_TABLE", "")
MAX_EXTERNAL_CALLS = int(os.environ.get("MAX_EXTERNAL_CALLS", "3"))

##circuit breaker per SOURCE, shared across executions (doc 5.3):
##a hundred parallel jobs must see the same breaker, not each pay
##their own timeouts to discover the source is down
BREAKER_SOURCE_ID = "employer-source"
BREAKER_FAILURE_THRESHOLD = int(os.environ.get("BREAKER_FAILURE_THRESHOLD", "3"))
BREAKER_WINDOW_SECONDS = int(os.environ.get("BREAKER_WINDOW_SECONDS", "120"))
BREAKER_OPEN_SECONDS = int(os.environ.get("BREAKER_OPEN_SECONDS", "60"))

_prompt_lines = (Path(__file__).parent / "prompt.yaml").read_text().splitlines()
SYSTEM_PROMPT = "\n".join(
    line.removeprefix("  ") for line in _prompt_lines[_prompt_lines.index("prompt: |") + 1 :]
).strip()

##extra block appended when the external tool is enabled
_ext_lines = (Path(__file__).parent / "prompt_external.yaml").read_text().splitlines()
EXTERNAL_PROMPT = "\n".join(
    line.removeprefix("  ") for line in _ext_lines[_ext_lines.index("prompt: |") + 1 :]
).strip()

##mutable budget state shared with the tool closures (reset per invoke)
_budget = {"tool_calls": 0, "external_calls": 0, "deadline": 0.0, "exhausted": False}


class JdMatch(BaseModel):
    """The typed outcome of the agent for one job description."""

    jd_id: str
    title: str
    outcome: Literal["match", "no_match", "not_verifiable"]
    score: float = Field(ge=0, le=1, description="Confidence of the outcome")
    evidences: list[str] = Field(
        default_factory=list,
        description="Quotes/facts from the candidate profile supporting a match",
    )


class EmployerCheck(BaseModel):
    """The outcome of the external validation for one declared employer."""

    employer: str
    outcome: Literal["verified", "not_found", "not_verifiable"]


class MatchReport(BaseModel):
    """The final report of the matching agent."""

    matches: list[JdMatch]
    employer_checks: list[EmployerCheck] = Field(
        default_factory=list,
        description="External validation outcome for the declared employers",
    )


class EmployerValidation(BaseModel):
    """Contract of the isolated executor lambda (external content)."""

    employer: str
    exists: bool
    registry_name: str | None = None
    country: str | None = None
    source: str


class ChunksFile(BaseModel):
    """The chunks artifact read from S3 (contract with chunk-cv)."""

    class CvChunk(BaseModel):
        chunk_id: str
        section_type: str
        title: str
        content: str
        date_start: str | None = None
        date_end: str | None = None
        language: str

    job_id: str
    parsing_version: str
    sections: list[CvChunk]


@tool
def search_jd(query: str) -> str:
    """Search the pre-indexed job descriptions by semantic similarity.

    Args:
        query: A short description of the candidate profile angle to
            search for (skills, role, seniority).

    Returns:
        str: The most similar job descriptions with id, title, skills
            and content, or a message when nothing relevant is found.
    """
    ##governance inside the tool (doc 5.1): budget checked here
    if _budget["tool_calls"] >= MAX_TOOL_CALLS or time.time() >= _budget["deadline"]:
        _budget["exhausted"] = True
        return "BUDGET EXHAUSTED: no more searches allowed. Produce the final report now."
    _budget["tool_calls"] += 1

    embedding = json.loads(
        bedrock.invoke_model(
            modelId=EMBED_MODEL_ID,
            body=json.dumps({"texts": [query], "input_type": "search_query"}),
        )["body"].read()
    )["embeddings"][0]

    result = rds.execute_statement(
        resourceArn=CLUSTER_ARN,
        secretArn=SECRET_ARN,
        database=DATABASE,
        sql="""
            SELECT jd_id, title, skills::text, content,
                   round((1 - (embedding <=> (:v)::vector))::numeric, 3)::text
            FROM jd_chunks
            ORDER BY embedding <=> (:v)::vector
            LIMIT :k
        """,
        parameters=[
            {"name": "v", "value": {"stringValue": json.dumps(embedding)}},
            {"name": "k", "value": {"longValue": TOP_K}},
        ],
    )

    if not result["records"]:
        ##empty list is an answer, not an error to retry (doc 5.2)
        return "No job descriptions found for this query."

    blocks = []
    for rec in result["records"]:
        jd_id, title, skills, content, similarity = (f.get("stringValue", "") for f in rec)
        blocks.append(
            f"[{jd_id}] {title} (similarity {similarity})\n"
            f"required skills: {skills}\n{content}"
        )
    return "\n\n---\n\n".join(blocks)


@tool
def validate_employer(employer_name: str) -> str:
    """Validate a declared employer against external sources.

    Args:
        employer_name: The employer name exactly as declared in the
            candidate profile.

    Returns:
        str: The validation outcome. "Not found" and "source
            unavailable" are terminal outcomes: do not retry them.
    """
    ##the budget decrements in every case (doc 5.2-bis)
    if _budget["tool_calls"] >= MAX_TOOL_CALLS or time.time() >= _budget["deadline"]:
        _budget["exhausted"] = True
        return "BUDGET EXHAUSTED: no more calls allowed. Produce the final report now."
    _budget["tool_calls"] += 1
    if _budget["external_calls"] >= MAX_EXTERNAL_CALLS:
        return (
            "External validation budget exhausted: record remaining employers "
            "as not_verifiable and move on."
        )
    _budget["external_calls"] += 1

    ##giro of doc 5.2-bis: breaker check -> invoke -> pydantic
    ##validation + sanitization of external content -> breaker update
    if _breaker_is_open():
        return (
            f"Employer source unavailable (circuit open): record '{employer_name}' "
            "as not_verifiable. Do not retry."
        )

    try:
        response = lambda_client.invoke(
            FunctionName=EXECUTOR_FUNCTION,
            Payload=json.dumps({"employer_name": employer_name}).encode(),
        )
        payload = json.loads(response["Payload"].read())
        if response.get("FunctionError"):
            raise RuntimeError(str(payload)[:200])
        result = EmployerValidation.model_validate(payload)
    except Exception as exc:  # noqa: BLE001 - any executor failure feeds the
        # breaker and becomes a terminal not_verifiable outcome, never a retry
        _breaker_record(success=False)
        print(f"[external-tool] source error: {type(exc).__name__}: {str(exc)[:200]}")
        return (
            f"Employer source error: record '{employer_name}' as not_verifiable. "
            "Do not retry."
        )

    _breaker_record(success=True)

    if not result.exists:
        ##'not found' is a legitimate terminal outcome (doc 5.2), the
        ##structural cure against the tool that never fails and never finds
        return (
            f"Employer '{employer_name}' NOT FOUND in external sources: record it "
            "as not_found. This is a terminal outcome, do NOT retry with "
            "rephrased names."
        )

    registry = _sanitize_external(result.registry_name or "")
    country = _sanitize_external(result.country or "")
    return f"Employer '{employer_name}' verified: registered as '{registry}' ({country})."


def _sanitize_external(text: str) -> str:
    """Sanitize a string coming from an external source.

    External content enters the agent context: it is an injection
    channel mirroring the malicious CV (doc 5.2). Structural guardrail:
    hard length cap, control characters stripped, imperative injection
    markers neutralized.

    Args:
        text: The raw external string.

    Returns:
        str: The sanitized string.
    """
    cleaned = "".join(c for c in text[:120] if c.isprintable())
    if re.search(r"(?i)ignore|instruction|system prompt|assistant", cleaned):
        return "[sanitized external content]"
    return cleaned


def _breaker_is_open() -> bool:
    """Check the shared circuit breaker for the employer source.

    Returns:
        bool: True if the circuit is open (fail fast, zero invokes);
            False when closed or half-open (one probe allowed after
            the cool-down).
    """
    item = dynamodb.get_item(
        TableName=GOVERNANCE_TABLE,
        Key={"source_id": {"S": BREAKER_SOURCE_ID}},
    ).get("Item")
    if item is None or item["state"]["S"] != "OPEN":
        return False
    ##half-open: after the cool-down one probe goes through; its
    ##outcome closes or re-opens the circuit
    return time.time() - float(item["opened_at"]["N"]) < BREAKER_OPEN_SECONDS


def _breaker_record(success: bool) -> None:
    """Update the shared breaker state after a source call.

    Approximate counters (no transactions): concurrent executions may
    over/under count by one — acceptable for a breaker, which is a
    protection, not an accounting system.

    Args:
        success: Whether the source call succeeded.

    Returns:
        None
    """
    now = str(int(time.time()))
    if success:
        dynamodb.put_item(
            TableName=GOVERNANCE_TABLE,
            Item={
                "source_id": {"S": BREAKER_SOURCE_ID},
                "state": {"S": "CLOSED"},
                "failures": {"N": "0"},
                "window_start": {"N": now},
                "opened_at": {"N": "0"},
            },
        )
        return

    item = dynamodb.get_item(
        TableName=GOVERNANCE_TABLE,
        Key={"source_id": {"S": BREAKER_SOURCE_ID}},
    ).get("Item")

    failures = 1
    if item is not None and time.time() - float(item["window_start"]["N"]) < BREAKER_WINDOW_SECONDS:
        failures = int(item["failures"]["N"]) + 1

    state = "OPEN" if failures >= BREAKER_FAILURE_THRESHOLD else "CLOSED"
    dynamodb.put_item(
        TableName=GOVERNANCE_TABLE,
        Item={
            "source_id": {"S": BREAKER_SOURCE_ID},
            "state": {"S": state},
            "failures": {"N": str(failures)},
            "window_start": {"N": now if failures == 1 else item["window_start"]["N"]},
            "opened_at": {"N": now if state == "OPEN" else "0"},
        },
    )
    if state == "OPEN":
        print(f"[breaker] employer-source OPEN after {failures} failures")


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Run the matching agent for one processed CV.

    Args:
        event: Step Function parameters with "job_id", "bucket",
            "chunks_key" (candidate profile pointers — never contents)
            and "skills" (canonical ids from normalization).
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: {"status": "completed"|"budget_exhausted",
            "report": <MatchReport dump>, "budget": {...}}.
    """
    bucket = event["bucket"]
    chunks_key = event["chunks_key"]
    skills = event.get("skills", [])

    _budget.update(
        tool_calls=0, external_calls=0, exhausted=False,
        deadline=time.time() + TIME_BUDGET_SECONDS,
    )

    chunks = ChunksFile.model_validate_json(
        s3.get_object(Bucket=bucket, Key=chunks_key)["Body"].read()
    )
    profile = _compose_profile(chunks, skills)

    ##feature flag (doc 10.1): the external tool enters only when enabled
    tools = [search_jd]
    system_prompt = SYSTEM_PROMPT
    if EXTERNAL_TOOL_ENABLED:
        tools.append(validate_employer)
        system_prompt = f"{SYSTEM_PROMPT}\n\n{EXTERNAL_PROMPT}"

    agent = Agent(
        model=BedrockModel(model_id=MODEL_ID, temperature=0),
        tools=tools,
        system_prompt=system_prompt,
        callback_handler=None,
    )
    agent(f"Candidate profile:\n\n{profile}\n\nFind the matching job descriptions.")
    report = agent.structured_output(
        MatchReport,
        "Produce the final match report for every job description you evaluated.",
    )

    ##evidence rule (doc 6): no evidence = no match
    for match in report.matches:
        if match.outcome == "match" and not match.evidences:
            print(f"[evidence-rule] {match.jd_id} demoted: match without evidences")
            match.outcome = "not_verifiable"

    return {
        "status": "budget_exhausted" if _budget["exhausted"] else "completed",
        "report": report.model_dump(),
        "budget": {"tool_calls": _budget["tool_calls"], "max_tool_calls": MAX_TOOL_CALLS},
    }


def _compose_profile(chunks: ChunksFile, skills: list[str]) -> str:
    """Compose the candidate profile text from the normalized chunks.

    Args:
        chunks: The validated chunks artifact.
        skills: Canonical skill ids from the normalization step.

    Returns:
        str: The profile text handed to the agent (pseudonymized).
    """
    parts = [f"Canonical skills: {', '.join(skills)}"] if skills else []
    for section in chunks.sections:
        dates = f" ({section.date_start}..{section.date_end})" if section.date_start else ""
        parts.append(f"## {section.title}{dates} [{section.section_type}]\n{section.content}")
    return "\n\n".join(parts)
