"""Regression eval harness (doc section 7).

Runs the golden set against the BRANCH code (the point is evaluating
the new prompts/models, not the deployed ones): lambda modules are
loaded from backend/, their S3 client is replaced with an in-memory
fake fed by the golden cases, while Bedrock and the pgvector store
are REAL. Three per-stage evals:

- normalization: recall on expected canonical skills + forbidden hits
- retrieval:     recall@k and MRR on jd_chunks (separate from generation)
- matching:      agent outcome accuracy on synthetic profiles
                 (includes an adversarial injection case)

Scores are compared against data/golden_set/baseline.json: hard
floors + max regression vs baseline; a violation exits non-zero (CI
blocks the merge). With no baseline file the run only records scores.

Usage (from backend/, needs AWS credentials):
    poetry run python ../scripts/run_eval.py [--report report.md]
"""

import argparse
import importlib.util
import io
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import boto3

ROOT = Path(__file__).resolve().parent.parent
##the lambdas import skillbridge_common from the layer: locally it
##lives in backend/shared
sys.path.insert(0, str(ROOT / "backend" / "shared"))
GOLDEN = ROOT / "data" / "golden_set"
BASELINE_FILE = GOLDEN / "baseline.json"

MODEL_ID = "eu.anthropic.claude-haiku-4-5-20251001-v1:0"
EMBED_MODEL_ID = "cohere.embed-multilingual-v3"
REGION = "eu-central-1"

##hard floors (fail below) and max allowed regression vs baseline
FLOORS = {
    "normalization_recall": 0.75,
    "retrieval_recall_at_k": 0.80,
    "retrieval_mrr": 0.60,
    "matching_accuracy": 0.70,
}
MAX_REGRESSION = 0.10

bedrock = boto3.client("bedrock-runtime", region_name=REGION)
rds = boto3.client("rds-data", region_name=REGION)


class FakeS3:
    """In-memory S3 stand-in: golden inputs go in, artifacts stay local."""

    def __init__(self) -> None:
        """Initialize the empty store."""
        self.objects: dict[str, bytes] = {}

    def get_object(self, Bucket: str, Key: str) -> dict[str, Any]:
        """Return a stored object like boto3 would.

        Args:
            Bucket: Ignored (single in-memory store).
            Key: The object key.

        Returns:
            dict[str, Any]: {"Body": <stream>}.
        """
        return {"Body": io.BytesIO(self.objects[Key])}

    def put_object(self, Bucket: str, Key: str, Body: bytes, **kwargs: Any) -> None:
        """Store an object like boto3 would.

        Args:
            Bucket: Ignored.
            Key: The object key.
            Body: The content.
            kwargs: Ignored boto3 extras.

        Returns:
            None
        """
        self.objects[Key] = Body


def _load_lambda(folder: str, module_name: str) -> Any:
    """Load a lambda module from backend/<folder> under a unique name.

    Args:
        folder: The lambda folder name.
        module_name: Unique module name (avoids lambda_function clashes).

    Returns:
        Any: The loaded module with a FakeS3 already patched in.
    """
    path = ROOT / "backend" / folder / "lambda_function.py"
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    module.s3 = FakeS3()
    return module


def _tf_output(name: str) -> str:
    """Read a terraform output from the dev environment.

    Args:
        name: The output name.

    Returns:
        str: The raw output value.
    """
    return subprocess.check_output(
        ["terraform", f"-chdir={ROOT / 'infra/terraform/envs/dev'}", "output", "-raw", name],
        text=True,
    ).strip()


def _rds_execute(args: dict[str, str], **kwargs: Any) -> dict[str, Any]:
    """Run a Data API statement, waiting out a paused cluster.

    Args:
        args: resourceArn/secretArn/database call arguments.
        kwargs: execute_statement arguments (sql, parameters).

    Returns:
        dict[str, Any]: The raw response.
    """
    deadline = time.time() + 120
    while True:
        try:
            return rds.execute_statement(**args, **kwargs)
        except Exception as exc:
            # generic BadRequestException, matched on the message
            if "resuming" not in str(exc).lower() or time.time() >= deadline:
                raise
            time.sleep(5)


def eval_normalization() -> dict[str, float]:
    """Run the normalization golden set.

    Returns:
        dict[str, float]: normalization_recall and forbidden hit count.
    """
    import os

    os.environ.setdefault("MODEL_ID", MODEL_ID)
    os.environ.setdefault("EMBED_MODEL_ID", EMBED_MODEL_ID)

    cases = json.loads((GOLDEN / "normalization.json").read_text())["cases"]
    found_expected = total_expected = forbidden_hits = 0

    for case in cases:
        module = _load_lambda("normalize-skills", f"eval_norm_{case['id']}")
        module.s3.objects["guarded/eval/cv.md"] = case["text"].encode()
        result = module.lambda_handler(
            {"job_id": f"eval-{case['id']}", "bucket": "eval", "guarded_key": "guarded/eval/cv.md"},
            None,
        )
        skills = set(result["skills"])
        hits = skills & set(case["expected"])
        bad = skills & set(case["forbidden"])
        found_expected += len(hits)
        total_expected += len(case["expected"])
        forbidden_hits += len(bad)
        status = "OK " if len(hits) == len(case["expected"]) and not bad else "MISS"
        print(f"  [{status}] {case['id']}: {len(hits)}/{len(case['expected'])} attese"
              f"{', VIETATE: ' + str(sorted(bad)) if bad else ''}")

    return {
        "normalization_recall": round(found_expected / total_expected, 3),
        "normalization_forbidden_hits": float(forbidden_hits),
    }


def eval_retrieval(db_args: dict[str, str]) -> dict[str, float]:
    """Run the retrieval golden set against the real jd_chunks store.

    Args:
        db_args: Data API resourceArn/secretArn/database.

    Returns:
        dict[str, float]: retrieval_recall_at_k and retrieval_mrr.
    """
    data = json.loads((GOLDEN / "retrieval.json").read_text())
    k, cases = data["k"], data["cases"]
    hits, reciprocal_ranks = 0, []

    for case in cases:
        response = bedrock.invoke_model(
            modelId=EMBED_MODEL_ID,
            body=json.dumps({"texts": [case["query"]], "input_type": "search_query"}),
        )
        vector = json.loads(response["body"].read())["embeddings"][0]
        result = _rds_execute(
            db_args,
            sql="SELECT jd_id FROM jd_chunks ORDER BY embedding <=> (:v)::vector LIMIT :k",
            parameters=[
                {"name": "v", "value": {"stringValue": json.dumps(vector)}},
                {"name": "k", "value": {"longValue": k}},
            ],
        )
        ranked = [r[0]["stringValue"] for r in result["records"]]
        if case["expected_jd"] in ranked:
            rank = ranked.index(case["expected_jd"]) + 1
            hits += 1
            reciprocal_ranks.append(1 / rank)
            print(f"  [OK ] {case['id']}: {case['expected_jd']} al rango {rank}")
        else:
            reciprocal_ranks.append(0.0)
            print(f"  [MISS] {case['id']}: {case['expected_jd']} non in top-{k} {ranked}")

    return {
        "retrieval_recall_at_k": round(hits / len(cases), 3),
        "retrieval_mrr": round(sum(reciprocal_ranks) / len(cases), 3),
    }


def eval_matching(db_args: dict[str, str]) -> dict[str, float]:
    """Run the matching golden set through the real agent loop.

    Args:
        db_args: Data API resourceArn/secretArn/database (for the tool).

    Returns:
        dict[str, float]: matching_accuracy over the expected outcomes.
    """
    import os

    os.environ.setdefault("MODEL_ID", MODEL_ID)
    os.environ.setdefault("EMBED_MODEL_ID", EMBED_MODEL_ID)
    os.environ["CLUSTER_ARN"] = db_args["resourceArn"]
    os.environ["SECRET_ARN"] = db_args["secretArn"]
    os.environ["DATABASE"] = db_args["database"]
    ##matching quality only: the external tool has its own tests
    os.environ["EXTERNAL_TOOL_ENABLED"] = "false"

    cases = json.loads((GOLDEN / "matching.json").read_text())["cases"]
    correct = total = 0

    for case in cases:
        module = _load_lambda("agent-matching", f"eval_match_{case['id']}")
        chunks = {
            "job_id": f"eval-{case['id']}",
            "parsing_version": "eval",
            "sections": [
                {"chunk_id": f"eval#{i}", **section}
                for i, section in enumerate(case["sections"])
            ],
        }
        module.s3.objects["chunks/eval/chunks.json"] = json.dumps(chunks).encode()
        result = module.lambda_handler(
            {
                "job_id": f"eval-{case['id']}",
                "bucket": "eval",
                "chunks_key": "chunks/eval/chunks.json",
                "skills": case["skills"],
            },
            None,
        )
        outcomes = {m["jd_id"]: m["outcome"] for m in result["report"]["matches"]}
        for jd_id, expected in case["expected_outcomes"].items():
            total += 1
            actual = outcomes.get(jd_id, "no_match")
            ok = actual == expected
            correct += ok
            print(f"  [{'OK ' if ok else 'MISS'}] {case['id']}: {jd_id} atteso={expected} avuto={actual}")

    return {"matching_accuracy": round(correct / total, 3)}


def main() -> int:
    """Run all stages, compare with the baseline, write the report.

    Returns:
        int: 0 when thresholds hold, 1 on any violation.
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, default=None)
    args = parser.parse_args()

    db_args = {
        "resourceArn": _tf_output("vectorstore_cluster_arn"),
        "secretArn": _tf_output("vectorstore_secret_arn"),
        "database": "skillbridge",
    }

    scores: dict[str, float] = {}
    print("=== normalization ===")
    scores.update(eval_normalization())
    print("=== retrieval ===")
    scores.update(eval_retrieval(db_args))
    print("=== matching ===")
    scores.update(eval_matching(db_args))

    baseline = json.loads(BASELINE_FILE.read_text()) if BASELINE_FILE.exists() else None
    violations: list[str] = []
    lines = ["## Eval report (golden set)", "", "| Metrica | Valore | Baseline | Floor | Esito |",
             "|---|---|---|---|---|"]
    for name, value in scores.items():
        floor = FLOORS.get(name)
        base = baseline.get(name) if baseline else None
        outcome = "OK"
        if floor is not None and value < floor:
            outcome = "SOTTO FLOOR"
            violations.append(f"{name}={value} < floor {floor}")
        elif base is not None and value < base - MAX_REGRESSION:
            outcome = "REGRESSIONE"
            violations.append(f"{name}={value} vs baseline {base} (max -{MAX_REGRESSION})")
        lines.append(
            f"| {name} | {value} | {base if base is not None else '-'} | "
            f"{floor if floor is not None else '-'} | {outcome} |"
        )

    report = "\n".join(lines)
    print("\n" + report)
    if args.report:
        args.report.write_text(report + "\n")

    if baseline is None:
        print("\nNessuna baseline: run di sola registrazione. Scores:")
        print(json.dumps(scores, indent=2))
        return 0
    if violations:
        print("\nVIOLAZIONI:\n- " + "\n- ".join(violations))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
