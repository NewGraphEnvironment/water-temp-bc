# Review: follow-up round 2 (fixes for round 1)

Reviewer probes are in `scratchpad/f2work/`. They were read-only against `fold/work/folded` and `meta_before.json`, with no S3 writes.

## Findings

- **[Medium]** `scripts/historic-fold-check.R:93-103` with `scripts/historic-fold.R:272`: an empty `rows_before` makes the new "canonical kept / canonical won" check pass without testing anything.
  - **How it happens.** On a re-fold, the fold copies `meta$historic_merged$rows_before` forward. If the live meta has a `historic_merged` without `rows_before`, that value is `NULL`. `list(rows_before = NULL, ...)` keeps the NULL element, and `write_json` serializes it as `"rows_before": {}`.
  - **What the check does with `{}`.** `fromJSON` reads it back as an empty named `list()`, which is not NULL. So "pre-fold row counts available" (`!is.null`) passes. Every `before[[k]]` then defaults to 0, so `from_snapshots >= 0` passes. `all(names(before) %in% ...)` over `character(0)` is TRUE. All three checks pass. Probed in `f2work/rt.R`: output `5 46 / 0 0`, and the "present" check is `TRUE`.
  - **Two ways the meta gets there.**
    - main's `historic-fold.R` (PR #33, at `9881099`) writes `historic_merged` without `rows_before`. The archive README says to publish "From `main`". If the publish runs before this branch merges, the S3 check fails loudly with "pre-fold row counts available". The natural fix is to re-run the fold with this branch's code. That re-fold writes `{}`, and the check then passes.
    - A compact.R bootstrap writes `historic_merged <- list(files, source)` (compact.R:143). A later re-fold on that meta gives the same `{}`.
  - The same vacuous pass happens in local mode if the given meta has `"rows": {}`.
  - **Fix, two parts:**
    - In the check, test `length(before) > 0`, not `!is.null(before)`.
    - In the fold, `stop()` when re-folding a meta whose `historic_merged` has no `rows_before`. The true pre-fold counts cannot be rebuilt from a folded meta; its `rows` already include the historic rows.
  - **Ordering:** merge this branch before the publish, or make publish-from-main impossible.

- **[Low]** `scripts/historic-fold-check.R:100` (and the header at lines 20-24): the `>=` never fails wrongly as months pass, but its power to detect a loss shrinks.
  - **Why it stays valid.** A monthly compact can only add snapshot keys or swap one snapshot row for a newer one. It never turns a snapshot row into a historic row, so the count never falls below `rows_before` by itself.
  - **Why it gets weaker.** Once a monthly run with new keys lands, a loss of up to that month's new-key count passes. If the fold lost or replaced N canonical rows, a check run after that month passes whenever N is at most the new keys added.
  - While `last_merged` is unchanged, the count is exactly equal. That covers right after the fold and after a `compact_only` re-merge of the same snapshot, which keeps the same `harvested_at`.
  - **Fix.** Record `last_merged` in `historic_merged` at fold time. Assert `==` while the live `last_merged` still matches, and print that the check has weakened to `>=` once it no longer does. Otherwise the post-publish run must happen before the next 1st-of-month run. That holds for the current plan (step 1 before step 2), but nothing enforces it.

- **[Low]** `scripts/historic-fold-check.R:91` with `scripts/historic-fold.R:95`: local mode reads `$rows` from `canonical_meta_before.json`. On a re-fold dry run, when the live meta is already folded, that file is the folded meta, whose `rows` include the historic rows.
  - The check then compares snapshot-only counts against post-fold totals and **fails every parameter wrongly**.
  - This fails loudly, not toward pass, but it blocks the documented pre-publish check for any re-fold.
  - **Fix.** In local mode, prefer `historic_merged$rows_before` when the given meta has one, as the S3 path does. That fix also needs the `length > 0` guard from the Medium finding.

## Checked and sound

- **`harvested_at >= FIRST_SNAPSHOT` picks out exactly the snapshot rows today.**
  - `harvested_at` is a naive `TIMESTAMP` compared with a `TIMESTAMP` literal, so there is no time-zone or ICU dependence. The literal is built with an explicit `%H:%M:%S`, so it keeps midnight.
  - Distinct values in the dry-run store: the historic ones end at `2025-07-28 07:25:00`. The snapshot ones start at `2026-05-14 21:06:19`, followed by 2026-06-01, 2026-07-01 and 2026-09-13.
  - Snapshot rows sum to 2,903,426 + 5,061,318 + 11,979,889 + 90,878,878 = 110,823,511. That equals the pre-fold `total_rows`.
  - It stays exact in future: the fold refuses any historic `harvested_at >= FIRST_SNAPSHOT`, and snapshots stamp scrape time.
- **compact.R carries `rows_before` forward whole.** It copies `historic_merged` as a unit (compact.R:128, 221). Probed round trip: fold write, then compact.R read (`read_json`) and write, then the check's `fromJSON`. Result: a named list of ints (`5: 4996180`, ...), and `before[[k]]` indexes it correctly.
- **A first fold writes the right numbers.** `rows_before = meta$rows` from the pre-fold meta, and `meta_before.json` has exactly the four partitions {5, 6, 46, 47}. A re-fold over a meta that already has a real `rows_before` keeps it.
- **Wrong files as the 3rd argument fail loudly:**
  - The post-fold `canonical_meta.json`: its rows are larger, so the check fails.
  - A JSON with no `rows`: `before` is NULL, so the check fails.
  - An `s3://` URL: `read_json` errors.
  - A 3rd argument on an S3 run is ignored, and the live meta is used.
- **Parameters absent before the fold (1, 18)** default to 0 and pass correctly. A parameter that was in the pre-fold meta but is gone from the store is caught by "every pre-fold parameter still present", but only when `before` is non-empty (see Medium).

---

## Resolution (parent session, 2026-09-29)

All three were fixed. The check treats empty, missing or non-numeric `rows_before` as a failure, and in local mode it prefers `historic_merged$rows_before`. The fold refuses to re-fold a meta that lacks `rows_before`, and it records `at_last_merged`. The check asserts `==` while the live `last_merged` equals it, and `>=` after that.

The loop ended by enumerating the pre-fold-count states through the check against the dry-run store:

| meta given | result |
|---|---|
| pre-fold (`rows`, no `historic_merged`) | PASS, exact equality |
| folded, with `rows_before` | PASS, exact equality |
| folded, `rows_before` absent | FAIL (3) |
| folded, `rows_before: {}` | FAIL (3) |
| `rows: {}` | FAIL (3) |
| `rows` with a non-numeric value | FAIL (3) |
| live S3 before the fold (no `historic_merged`) | FAIL (7, `data-raw/logs/historic_fold/20260929_check_s3_prefold.log`) |
