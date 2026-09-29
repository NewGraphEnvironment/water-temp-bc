# Progress — Normalize historic/ parquet schemas (#19)

## Session 2026-09-28

- Plan-mode exploration: profiled all four historic files and canonical on S3 (schemas, spans, vocabularies, tz, overlap/revisions)
- Plan gate: user chose "fold into canonical" over separate store / in-place rewrite
- Created branch `19-normalize-historic-schemas` off main
- Scaffolded PWF baseline from issue #19 with approved phases
- Next: start Phase 1 (contract tests)
