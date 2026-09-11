# skill-bridge

CV parsing and job-description matching system on AWS — serverless pipeline
(S3, SQS, Step Functions, Bedrock, Aurora pgvector) with a React web app.

## TODO

- [ ] **Company registry via external API**: replace the bundled `registry.json`
      with a real external company-registry API in `tool-validate-employer`
      (business registry / OpenCorporates-like source): HTTP call restricted to
      an egress domain whitelist, per-source circuit breaker already in place on
      the agent side, response validated against the same `EmployerValidation`
      contract, sanitization of external content unchanged. Requires the
      contractual/legal basis for the source (doc 10.3 open question).
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
- [ ] Auth on the backend API (API Gateway is currently unauthenticated; design
      calls for IAM/key — see ADR-002).
- [ ] KMS encryption + lifecycle/retention on the CV bucket; KMS CMK on the
      `pii-map` table (GDPR retention, doc section 8).
- [ ] Web app: job status polling via `GET /jobs/{jobId}` (endpoint already
      live, FE deliberately stops at upload confirmation for now).
- [ ] Restrict presigned PUT further (content-length-range via presigned POST
      or size check at parsing) — today size is validated at job creation only.
