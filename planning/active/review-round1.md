# Review round 1 — staged diff for #19 (2026-09-28)

Scope: the **staged** versions of scripts/historic-functions.R, historic-test.R,
compact-functions.R and compact.R (`git show :scripts/<f>`). Staged suites were run in a
copy (`scratchpad/r1work/staged/`): historic-test.R 0 failures, compact-test.R 0 failures.

## Findings

- **[bug — data loss in the published store]** scripts/historic-functions.R:92-101 (`harvested_at` = file max Date)
  combined with compact-functions.R:140-145 (whole-row `arg_max` on `harvested_at`), and pinned by
  historic-test.R:238. 20250521 gets a later `harvested_at` than 20240119 (2025-05-21 vs 2024-01-19),
  so on every key the two files share, 20250521's row replaces 20240119's **whole row**.
  20250521 has `Grade`, `Unit` and `Approval` NULL on all post-2022-06-17 rows. Measured anonymously on S3 today:
  - 20240119 carries Grade and Approval on 100% of its 42.6M rows. p1 (463,749 rows) and p18
    (301,487) are **fully** present in 20250521, confirmed by a key join. So after the fold, canonical p1 and p18 would
    have Grade and Approval 100% NULL.
  - 20240119 rows dated before 2023-12-24 (so not re-superseded by 20250728) number p46 19.68M and p47 18.47M,
    including **10.35M `Final/Finales` rows**, plus p5 1.71M. 20250521 has Approval on 0 of its p46/p47 rows and
    Grade on 0 of any row. Those rows lose their approval status and grade in canonical.
  - The originals stay frozen, so this can be recovered. But the served store silently drops the Provisional-vs-Final
    distinction for 2022-06 → 2023-12. The E1 test checks only `Value` on the d_mid overlap, so it passes.
    Its fixture's 20240119 row also has Grade '-1' and Approval 'Provisional', so a check on Grade or Approval would
    have caught this.
  - The eccc side is fine. 20250521 carries eccc's Symbol on the same keys (4,044/4,044 non-NULL p6 Symbols match),
    and it carries eccc's Approval on all 307,724 p6 keys.
  - Note: the unstaged working tree already adds `exclude_matching` to address this. It is not part of this
    diff and was not reviewed.

- **[bug — nondeterministic winner on revisions]** compact-functions.R:127-143 plus historic-functions.R:101.
  All rows of one historic file share one `harvested_at`. So 20250521's within-file duplicate keys (1.94M rows vs 1.88M
  distinct in findings.md; the parent's later note puts them at 3.14M stale-copy + revision pairs) tie on
  `harvested_at` and fall through to `Value DESC`. The fold keeps whichever of the old and revised value
  is **larger**, not the revision. The comment "rows tying on both are interchangeable in practice (within-pull keys
  are unique in real snapshots)" does not hold for this input. The historic-test fixture's 20250521 duplicate
  (d_new, 23 twice) has identical values, so it cannot reach this failure mode.

- **[fragile — working tree vs staged]** Heads-up rather than a defect in the staged diff: the unstaged
  `nullif(CAST("Grade" AS DOUBLE), -1)` in the working tree makes the staged test fail
  (`N3 FAIL: 20240119 Grade '-1' -> -1, '20' -> 20`, reproduced from the repo root). Update N3 along with it before
  staging.

## Checked, not flagged

- The Date projection in `strftime(...) || '+00'` → TIMESTAMPTZ keeps the wall clock under TZ=America/Vancouver.
  It does not depend on icu, and NULL Date stays NULL.
- The `HISTORIC_UNITS` literal bytes (`C2 B0 43`) match the Unit bytes in 20240119 and in canonical p5.
- Every value interpolated into SQL goes through `sql_q`, so I found no injection path.
- The compact.R bootstrap is safe on a missing prefix: `aws s3 ls` exits non-zero and `aws()` stops, and an empty
  listing stops explicitly. `meta$historic_merged` on a NULL meta is NULL.
- Not measured: a GHA bootstrap now also scans roughly 275M historic rows once per shard, per partition. That is
  under `timeout-minutes: 180`, and bootstrap is normally a manual/local run.
