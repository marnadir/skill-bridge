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

_prompt_lines = (Path(__file__).parent / "prompt.yaml").read_text().splitlines()
SYSTEM_PROMPT = "\n".join(
    line.removeprefix("  ") for line in _prompt_lines[_prompt_lines.index("prompt: |") + 1 :]
).strip()

##mutable budget state shared with the tool closure (reset per invoke)
_budget = {"tool_calls": 0, "deadline": 0.0, "exhausted": False}


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


class MatchReport(BaseModel):
    """The final report of the matching agent."""

    matches: list[JdMatch]


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

    _budget.update(tool_calls=0, exhausted=False, deadline=time.time() + TIME_BUDGET_SECONDS)

    chunks = ChunksFile.model_validate_json(
        s3.get_object(Bucket=bucket, Key=chunks_key)["Body"].read()
    )
    profile = _compose_profile(chunks, skills)

    agent = Agent(
        model=BedrockModel(model_id=MODEL_ID, temperature=0),
        tools=[search_jd],
        system_prompt=SYSTEM_PROMPT,
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
