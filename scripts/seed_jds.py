"""Seed the pre-indexed job descriptions into the jd_chunks table.

One-time (idempotent) data seeding, run manually with AWS credentials:

    cd backend && poetry run python ../scripts/seed_jds.py

Reads data/job_descriptions.json, embeds each JD with the same
multilingual model used for the CV chunks (comparable spaces, doc
4.6) and upserts into jd_chunks via the RDS Data API. Re-running
overwrites the same jd_ids (upsert on chunk_id)."""

import json
import subprocess
import time
from pathlib import Path
from typing import Any

import boto3

REGION = "eu-central-1"
EMBED_MODEL_ID = "cohere.embed-multilingual-v3"
TF_DIR = Path(__file__).parent.parent / "infra" / "terraform" / "envs" / "dev"
DATA_FILE = Path(__file__).parent.parent / "data" / "job_descriptions.json"

bedrock = boto3.client("bedrock-runtime", region_name=REGION)
rds = boto3.client("rds-data", region_name=REGION)


def _tf_output(name: str) -> str:
    """Read a terraform output from the dev environment.

    Args:
        name: The output name.

    Returns:
        str: The raw output value.
    """
    return subprocess.check_output(
        ["terraform", f"-chdir={TF_DIR}", "output", "-raw", name], text=True
    ).strip()


def _execute(sql: str, parameters: list[dict[str, Any]], args: dict[str, str]) -> None:
    """Run a SQL statement via the Data API, waiting out a paused cluster.

    Args:
        sql: The SQL text with :named parameters.
        parameters: Data API parameter list.
        args: resourceArn/secretArn/database call arguments.

    Returns:
        None
    """
    deadline = time.time() + 120
    while True:
        try:
            rds.execute_statement(**args, sql=sql, parameters=parameters)
            return
        except Exception as exc:  # noqa: BLE001 - resuming is signalled via a
            # generic BadRequestException, matched on the message
            if "resuming" not in str(exc).lower() or time.time() >= deadline:
                raise
            time.sleep(5)


def main() -> None:
    """Embed and upsert all the JDs.

    Returns:
        None
    """
    args = {
        "resourceArn": _tf_output("vectorstore_cluster_arn"),
        "secretArn": _tf_output("vectorstore_secret_arn"),
        "database": "skillbridge",
    }

    jds = json.loads(DATA_FILE.read_text())["job_descriptions"]
    texts = [f"{jd['title']}\n{jd['content']}" for jd in jds]
    response = bedrock.invoke_model(
        modelId=EMBED_MODEL_ID,
        body=json.dumps({"texts": texts, "input_type": "search_document"}),
    )
    vectors = json.loads(response["body"].read())["embeddings"]

    for jd, vector in zip(jds, vectors):
        _execute(
            """
            INSERT INTO jd_chunks (chunk_id, jd_id, title, content, skills, embedding)
            VALUES (:chunk_id, :jd_id, :title, :content, (:skills)::jsonb, (:embedding)::vector)
            ON CONFLICT (chunk_id) DO UPDATE SET
                title = EXCLUDED.title,
                content = EXCLUDED.content,
                skills = EXCLUDED.skills,
                embedding = EXCLUDED.embedding
            """,
            parameters=[
                {"name": "chunk_id", "value": {"stringValue": f"{jd['jd_id']}#0"}},
                {"name": "jd_id", "value": {"stringValue": jd["jd_id"]}},
                {"name": "title", "value": {"stringValue": jd["title"]}},
                {"name": "content", "value": {"stringValue": jd["content"]}},
                {"name": "skills", "value": {"stringValue": json.dumps(jd["skills"])}},
                {"name": "embedding", "value": {"stringValue": json.dumps(vector)}},
            ],
            args=args,
        )
        print(f"seeded {jd['jd_id']}: {jd['title']}")

    print(f"done: {len(jds)} job descriptions in jd_chunks")


if __name__ == "__main__":
    main()
