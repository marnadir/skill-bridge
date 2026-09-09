"""Lambda: [Normalizza] step of the cv-processing Step Function (doc 4.4).

Maps raw skill mentions against the internal taxonomy BEFORE
chunking, for two reasons (doc): disambiguation needs the full
sentence context (chunking would break it), and normalized chunks
produce coherent embeddings (the canonical variant lives INSIDE the
indexed text).

Two-stage matching:
1. deterministic: lowercase exact match on canonical names and
   aliases ('Phyton' -> 'Python');
2. for the leftovers: embedding kNN of the mention against the
   taxonomy (Cohere multilingual, batched) -> the SLM picks among the
   top-k WITH the sentence context, with a legitimate 'none of these'
   outcome. Unmatched skills are logged as taxonomy candidates
   (doc failure modes: candidate queue for the taxonomy)."""

import json
import math
import os
import re
from pathlib import Path
from typing import Any

import boto3
from pydantic import BaseModel

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime")


class TaxonomyEntry(BaseModel):
    """One canonical skill of the internal taxonomy."""

    id: str
    name: str
    aliases: list[str] = []


class SkillMention(BaseModel):
    """A raw skill span found in the CV, with its sentence context."""

    text: str
    sentence: str


class MentionList(BaseModel):
    """Validated payload of the record_skill_mentions tool call."""

    mentions: list[SkillMention]


class SkillChoice(BaseModel):
    """The taxonomy id chosen for one ambiguous mention ('none' allowed)."""

    mention: str
    chosen_id: str


class ChoiceList(BaseModel):
    """Validated payload of the record_skill_choices tool call."""

    choices: list[SkillChoice]

MODEL_ID = os.environ["MODEL_ID"]
EMBED_MODEL_ID = os.environ["EMBED_MODEL_ID"]
# prompt.yaml: a single "prompt: |" block scalar; the runtime has no
# PyYAML, so the block is read directly (the file stays valid YAML)
_prompt_lines = (Path(__file__).parent / "prompt.yaml").read_text().splitlines()
PROMPT = "\n".join(
    line.removeprefix("  ") for line in _prompt_lines[_prompt_lines.index("prompt: |") + 1 :]
).strip()

TOP_K = 5

# taxonomy shipped in the deploy zip; embeddings computed lazily at
# first stage-2 need and cached for the lambda lifetime
TAXONOMY = [
    TaxonomyEntry.model_validate(raw)
    for raw in json.loads((Path(__file__).parent / "taxonomy.json").read_text())["skills"]
]
_taxonomy_vectors: list[list[float]] | None = None

# lowercase alias/name/id -> taxonomy entry
ALIAS_INDEX: dict[str, TaxonomyEntry] = {}
for entry in TAXONOMY:
    for variant in [entry.id, entry.name, *entry.aliases]:
        ALIAS_INDEX[variant.lower()] = entry

EXTRACT_TOOL = {
    "name": "record_skill_mentions",
    "description": "Record the skill mentions found in the CV text.",
    "inputSchema": {
        "json": {
            "type": "object",
            "properties": {
                "mentions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "text": {
                                "type": "string",
                                "description": "The exact skill span as it appears in the text.",
                            },
                            "sentence": {
                                "type": "string",
                                "description": "The sentence or line containing the mention.",
                            },
                        },
                        "required": ["text", "sentence"],
                    },
                }
            },
            "required": ["mentions"],
        }
    },
}

CHOOSE_TOOL = {
    "name": "record_skill_choices",
    "description": "Record the taxonomy match chosen for each ambiguous mention.",
    "inputSchema": {
        "json": {
            "type": "object",
            "properties": {
                "choices": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "mention": {"type": "string"},
                            "chosen_id": {
                                "type": "string",
                                "description": "A candidate taxonomy id, or 'none' if none fits.",
                            },
                        },
                        "required": ["mention", "chosen_id"],
                    },
                }
            },
            "required": ["choices"],
        }
    },
}


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Normalize skill mentions of the guarded CV text.

    Args:
        event: Step Function parameters with "job_id", "bucket" and
            "guarded_key" (output of the guardrail step).
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: {"normalized_key": <S3 key>, "skills":
            [canonical ids], "unmatched": [raw mentions]}.

    Raises:
        ValueError: If a model response contains no tool call.
    """
    job_id = event["job_id"]
    bucket = event["bucket"]
    guarded_key = event["guarded_key"]

    text = s3.get_object(Bucket=bucket, Key=guarded_key)["Body"].read().decode()

    mentions = _extract_mentions(text)

    matched: dict[str, TaxonomyEntry] = {}
    ambiguous: list[SkillMention] = []
    for mention in mentions:
        entry = ALIAS_INDEX.get(mention.text.lower().strip())
        if entry is not None:
            matched[mention.text] = entry
        else:
            ambiguous.append(mention)

    unmatched: list[str] = []
    if ambiguous:
        stage2 = _match_ambiguous(ambiguous)
        for mention_text, entry in stage2["matched"].items():
            matched[mention_text] = entry
        unmatched = stage2["unmatched"]

    # the canonical variant goes INSIDE the text (doc: coherent
    # embeddings and BM25 downstream). Word-boundary replace: a bare
    # str.replace would rewrite substrings inside words ('GenML' ->
    # 'GenMachine Learning', found by the E2E run)
    for mention_text, entry in matched.items():
        if mention_text != entry.name:
            pattern = re.compile(rf"(?<!\w){re.escape(mention_text)}(?!\w)")
            text = pattern.sub(lambda _m, name=entry.name: name, text)

    for raw in unmatched:
        # candidate queue for the taxonomy (doc failure modes)
        print(f"[taxonomy-queue] job={job_id} unmatched skill: {raw!r}")

    normalized_key = f"normalized/{job_id}/cv.md"
    s3.put_object(
        Bucket=bucket,
        Key=normalized_key,
        Body=text.encode(),
        ContentType="text/markdown; charset=utf-8",
    )

    skills = sorted({entry.id for entry in matched.values()})
    return {"normalized_key": normalized_key, "skills": skills, "unmatched": unmatched}


def _extract_mentions(text: str) -> list[SkillMention]:
    """Ask the SLM for the skill mentions present in the text.

    Args:
        text: The guarded CV text.

    Returns:
        list[SkillMention]: The validated mentions.

    Raises:
        ValueError: If the model response contains no tool call.
        pydantic.ValidationError: If the tool payload does not match
            the MentionList schema.
    """
    response = bedrock.converse(
        modelId=MODEL_ID,
        messages=[{"role": "user", "content": [{"text": f"{PROMPT}\n\n---\n{text}"}]}],
        toolConfig={
            "tools": [{"toolSpec": EXTRACT_TOOL}],
            "toolChoice": {"tool": {"name": EXTRACT_TOOL["name"]}},
        },
        inferenceConfig={"maxTokens": 3000, "temperature": 0},
    )
    return MentionList.model_validate(_tool_input(response, EXTRACT_TOOL["name"])).mentions


def _match_ambiguous(ambiguous: list[SkillMention]) -> dict[str, Any]:
    """Stage 2: embedding kNN on the taxonomy + SLM choice in context.

    Args:
        ambiguous: Mentions that did not match any alias.

    Returns:
        dict[str, Any]: {"matched": {mention text -> TaxonomyEntry},
            "unmatched": [mention texts with no acceptable candidate]}.

    Raises:
        ValueError: If the model response contains no tool call.
        pydantic.ValidationError: If the tool payload does not match
            the ChoiceList schema.
    """
    mention_texts = [m.text for m in ambiguous]
    mention_vectors = _embed(mention_texts, input_type="search_query")
    taxonomy_vectors = _taxonomy_embeddings()

    candidates_per_mention: dict[str, list[str]] = {}
    for mention, vector in zip(mention_texts, mention_vectors):
        scored = sorted(
            ((_cosine(vector, tv), entry.id) for tv, entry in zip(taxonomy_vectors, TAXONOMY)),
            reverse=True,
        )
        candidates_per_mention[mention] = [skill_id for _, skill_id in scored[:TOP_K]]

    lines = [
        f'- mention: "{m.text}" | sentence: "{m.sentence}" | '
        f"candidates: {candidates_per_mention[m.text]} or none"
        for m in ambiguous
    ]
    instruction = (
        "For each skill mention below, choose the taxonomy id that matches it, "
        "using the sentence as context. Answer 'none' when no candidate truly "
        "fits: do NOT force a match. Record with record_skill_choices.\n"
        + "\n".join(lines)
    )

    response = bedrock.converse(
        modelId=MODEL_ID,
        messages=[{"role": "user", "content": [{"text": instruction}]}],
        toolConfig={
            "tools": [{"toolSpec": CHOOSE_TOOL}],
            "toolChoice": {"tool": {"name": CHOOSE_TOOL["name"]}},
        },
        inferenceConfig={"maxTokens": 2000, "temperature": 0},
    )

    by_id = {entry.id: entry for entry in TAXONOMY}
    matched: dict[str, TaxonomyEntry] = {}
    unmatched: list[str] = []
    choices = ChoiceList.model_validate(_tool_input(response, CHOOSE_TOOL["name"])).choices
    decided = {c.mention: c.chosen_id for c in choices}
    for mention in mention_texts:
        chosen = decided.get(mention, "none")
        # the model must not invent ids outside the proposed candidates
        if chosen in by_id and chosen in candidates_per_mention[mention]:
            matched[mention] = by_id[chosen]
        else:
            unmatched.append(mention)
    return {"matched": matched, "unmatched": unmatched}


def _taxonomy_embeddings() -> list[list[float]]:
    """Embed the whole taxonomy once and cache it for the lambda lifetime.

    Returns:
        list[list[float]]: One vector per taxonomy entry.
    """
    global _taxonomy_vectors
    if _taxonomy_vectors is None:
        texts = [f"{e.name} ({', '.join(e.aliases)})" if e.aliases else e.name for e in TAXONOMY]
        _taxonomy_vectors = _embed(texts, input_type="search_document")
    return _taxonomy_vectors


def _embed(texts: list[str], input_type: str) -> list[list[float]]:
    """Embed a batch of texts with the multilingual Cohere model.

    Args:
        texts: The texts to embed (max 96 per call).
        input_type: "search_query" or "search_document".

    Returns:
        list[list[float]]: One vector per input text.
    """
    vectors: list[list[float]] = []
    for start in range(0, len(texts), 96):
        response = bedrock.invoke_model(
            modelId=EMBED_MODEL_ID,
            body=json.dumps({"texts": texts[start : start + 96], "input_type": input_type}),
        )
        vectors.extend(json.loads(response["body"].read())["embeddings"])
    return vectors


def _cosine(a: list[float], b: list[float]) -> float:
    """Cosine similarity between two vectors.

    Args:
        a: First vector.
        b: Second vector.

    Returns:
        float: The cosine similarity.
    """
    dot = sum(x * y for x, y in zip(a, b))
    norm = math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b))
    return dot / norm if norm else 0.0


def _tool_input(response: dict[str, Any], tool_name: str) -> dict[str, Any]:
    """Extract the input of the forced tool call from a Converse response.

    Args:
        response: The raw bedrock-runtime converse response.
        tool_name: The expected tool name.

    Returns:
        dict[str, Any]: The tool call input, already parsed by Bedrock.

    Raises:
        ValueError: If the response contains no expected tool call.
    """
    for block in response["output"]["message"]["content"]:
        if "toolUse" in block and block["toolUse"]["name"] == tool_name:
            return block["toolUse"]["input"]
    raise ValueError("model response contains no tool call")
