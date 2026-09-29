# Progress — Normalize historic/ parquet schemas (#19)

## Session 2026-09-28

- Plan-mode exploration: profiled all four historic files and canonical on S3 (schemas, spans, vocabularies, tz, overlap/revisions)
- Plan gate: user chose "fold into canonical" over separate store / in-place rewrite
- Created branch `19-normalize-historic-schemas` off main
- Scaffolded PWF baseline from issue #19 with approved phases
- Next: start Phase 1 (contract tests)

## Session 2026-09-29

- Plan review (Plan agent) plus code-check rounds 1-4. Rounds 2-4 each found a defect inside the previous fix; the loop ended on round 4's 25-row enumeration and a writer-interleaving table (findings.md)
- Measured: eccc tz is UTC (517,020 keys, 100% equal at offset 0); 20250521 carries 52.0M stale copies, which are now excluded
- Two dry-run folds: 110.8M → 212.2M rows, every acceptance check passes; monthly sim at 4GB/2 threads: p46 126 s, p47 114 s
- Filed #32 (sync-data.R --delete hazard)
- Commits: 0349bff (implementation), docs commit next
- Post-merge: publish the fold, dispatch compact_only, re-render index.html with update_query = TRUE
