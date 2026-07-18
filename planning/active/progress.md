# Progress — Compact overlapping snapshots + partition by parameter to fix read scaling (#23)

## Session 2026-07-18

- Plan-mode exploration + Plan-agent design review (3 blockers, 7 gaps caught and folded in) — phases approved by user
- Verified assumptions against real July snapshot: within-snapshot key uniqueness holds, 0 NA-Date rows
- Created branch `23-compact-overlapping-snapshots-partition` off main
- Scaffolded PWF baseline from issue #23 with approved phases
- Phase 1: `scripts/compact-test.R` written — 9 sections (T0 watermark selection through T9 invariant gate), 27 assertions, plain-Rscript harness, exits 1 on failure. Confirmed red (clean "compact-functions.R not found" error). Contract in the header defines Phase 2's API: `compact_select_inputs()`, `compact_run()`, `compact_verify()`.
- Phase 2: `compact-functions.R` (core: select_inputs/run/verify, `params` filter for per-partition orchestration) + `compact.R` (S3 orchestrator: meta-as-commit-marker watermark, per-partition download→merge→verify→sync→free loop, param-set union so absent params survive). All 27 tests green. Findings: duckdb clamps ROW_GROUP_SIZE to ~2048 floor; `invisible()` on compact_run return; meta-fetch distinguishes 404 from transient errors (else loud failure, not silent bootstrap). jsonlite added to DESCRIPTION.
- Phase 3: snapshot.yml — compact step added after raw upload, compact_only dispatch input (boolean; gates Pull/Upload steps), timeout 180. YAML validated.
- Next: Phase 4 (bootstrap via compact_only dispatch, golden-number check 98,726,492, canonical lifecycle rule)
