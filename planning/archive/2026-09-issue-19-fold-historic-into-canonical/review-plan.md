# Plan review (#19) — Plan agent, 2026-09-28

Read-only agent; findings returned as reply text and written here by the parent. Triage verdicts in the right column were probed before acting.

| id | finding (condensed) | verdict |
|---|---|---|
| B1 | 20250521 (superset, NULL metadata) outranks eccc/20240119 on shared keys, so it would overwrite their Grade/Approval/Symbol with NULLs. The amalgamation deduped on (key, Value), so its within-file duplicate keys are old+revised pairs, and the Value DESC tiebreak is a coin flip | Probed: 20250521 keeps eccc's Symbol (ICE 807 / ES 938 in both files), but the 20240119 Grade/Approval loss and the stale-vs-revised tiebreak are real → fixed by excluding from 20250521 every row that exactly matches (key + Value) a row in an older file (see findings) |
| B2 | Shards are sized by input rows; arg_max state scales with distinct keys. A key-dense canonical after the fold puts ~4.3M keys per shard, above the level that OOM'd | Real → shard count also bounded by an approximate distinct-key count |
| O1 | Publishing the fold before main has the lower date floor makes every monthly run fail verify; the next cron is 2026-10-01 12:00 UTC | Real → publish is a post-merge step, followed by a compact_only dispatch; the fold re-reads the meta and aborts if a compaction ran meanwhile |
| O2 | Measure A1/B1 before building fixtures | Done |
| G1 | Meta rows/total_rows must be the post-fold counts; historic_merged must survive monthly runs | Already done: the fold writes per_param rows; compact.R carries historic_merged forward |
| G2 | sync-data.R `--delete` would wipe canonical/realtime/historic from a sparse local data/ | Pre-existing hazard → filed as #32, not fixed here |
| G3 | TRY_CAST hides bad strings | Already CAST; test proves an unparseable Value errors |
| G4 | Grade '-1' exists only in 20240119; the current feed uses NULL | Map -1 → NULL, pinned in a test |
| G5 | 20240119 Approval values are 'Provisional'/'Final' | False: profile shows 'Provisional/Provisoire' / 'Final/Finales', the same as canonical |
| G6 | Bootstrap input must be checked against a manifest, appended to raw_dirs not todo, and sit flat | Manifest check added; the rest was already so |
| G7 | Fold loop needs params = p, the union of params, and memory_limit/temp_dir | Already so in historic-fold.R |
| G8 | Floor 2000 loosens the garbage-date check | Floor set to 2002-01-01 |
| G9 | Sort the normalized files by Parameter so row groups prune | Adopted |
| A1 | eccc tz is unproven; functions.R stamps CSV times as UTC | Disproved: eccc ⋈ 20240119 p5 at offset 0 gives 517,020 keys with 100% equal values, against ~7% at ±7/8 h; eccc p6 stamps are 08:00/07:00 UTC like realtime |
| A2 | ICU/session-TZ cast | Already handled (text + '+00'); test runs under TZ=America/Vancouver with naked fixture types |
| A3 | harvested_at from max(Date) is data-dependent | The fold asserts the values are strictly increasing and below canonical's min harvested_at |
| A4 | Unit strings must match canonical bytes | Probed (see findings) |
| A5 | arrow first-fragment schema | Every missing column is typed; the exact-schema test covers every output file |
| S1 | Params 1/18 are frozen and small | Kept, labelled frozen in the docs |
| S2 | query_canonical() without `from` returns far more rows | Noted in README and wet#25 comment |
| S3 | Issue Done-when to be rewritten | Phase 5 |
| AC1-AC7 | Collect one row per partition; p6 same-day check; independent distinct-key count; ICE count; runner dispatch; fixture via compact_run with naked harvested_at and small shard_rows; render with update_query | Folded into the dry-run verification and the tests |
| docs | Stale lines in compact.R, compact-functions.R, compact-test.R, snapshot.yml, README.Rmd, CLAUDE.md | Phase 4 |
