# skill-bridge

CV parsing and job-description matching system on AWS — serverless pipeline
(S3, SQS, Step Functions, Bedrock, Aurora pgvector) with a React web app.

## TODO

- [ ] **Versioned taxonomy in the vector DB**: move the skill taxonomy from the
      bundled `taxonomy.json` to a `taxonomy_embeddings` table on pgvector, with a
      versioned ingestion flow (seed/update script, `taxonomy_version` on rows,
      re-embed on embedding-model change, atomic swap of the active version).
      `normalize-skills` stage 2 then switches from in-memory kNN to a DB kNN
      query, and the `[taxonomy-queue]` candidates can feed the taxonomy without
      a redeploy.
- [ ] Matching agent (tranche 3): JD seeding on `jd_chunks`, Strands agent with
      the internal `search_jd` tool, typed outcomes (match / no match / not
      verifiable), budget on steps/time/cost, results saved on the job.
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
