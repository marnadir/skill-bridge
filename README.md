# skill-bridge

CV parsing and job-description matching system on AWS — serverless pipeline
(S3, SQS, Step Functions, Bedrock, Aurora pgvector) with a React web app.

## TODO

- [ ] **JD ingestion flow via API**: replace the manual `scripts/seed_jds.py` with
      a proper ingestion flow that fetches job descriptions from an API (ATS /
      internal jobs endpoint) and upserts them into `jd_chunks` on pgvector:
      scheduled or event-driven Lambda, embedding with the shared multilingual
      model, idempotent upsert keyed on `jd_id` with versioning (same
      `doc_version`/`is_latest` pattern as `cv_chunks`), skills mapped to the
      canonical taxonomy, removal/deactivation of JDs no longer returned by the
      source.
- [ ] **Versioned taxonomy in the vector DB**: move the skill taxonomy from the
      bundled `taxonomy.json` to a `taxonomy_embeddings` table on pgvector, with a
      versioned ingestion flow (seed/update script, `taxonomy_version` on rows,
      re-embed on embedding-model change, atomic swap of the active version).
      `normalize-skills` stage 2 then switches from in-memory kNN to a DB kNN
      query, and the `[taxonomy-queue]` candidates can feed the taxonomy without
      a redeploy.
- [ ] External validation tool (v0.5, doc 5.2-bis): `validate_employer` behind a
      feature flag, isolated two-lambda setup (decision to the agent, execution
      outside), shared circuit breaker on DynamoDB, budget cost axis tracking.
- [ ] Auth on the backend API (API Gateway is currently unauthenticated; design
      calls for IAM/key — see ADR-002).
- [ ] KMS encryption + lifecycle/retention on the CV bucket; KMS CMK on the
      `pii-map` table (GDPR retention, doc section 8).
- [ ] Evaluation: golden set (~50 cases: typical / edge / adversarial),
      per-stage metrics, regression suite in CI (doc section 7).
- [ ] Observability: end-to-end tracing, cost per CV per step, actionable
      alerts (DLQ non-empty, sanity-check rate, cost anomaly).
- [ ] Web app: job status polling via `GET /jobs/{jobId}` (endpoint already
      live, FE deliberately stops at upload confirmation for now).
- [ ] Restrict presigned PUT further (content-length-range via presigned POST
      or size check at parsing) — today size is validated at job creation only.
