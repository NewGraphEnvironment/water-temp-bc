# Task: Modernize storage: monthly OIDC snapshot into partitioned dataset (#17)

Modernize how we capture and serve realtime water-temp data so it stays current automatically and the on-disk layout is easy to reason about — for both us and any collaborator who hits the bucket cold. Supersedes #15 (storage layout), folds in #14 (reader switch to `arrow::open_dataset`), closes the #8-class hardcoded-filename failure mode, and fixes #13 (region-explicit URLs).

Latest reading on the cloud right now is **2025-07-28 07:00** → gap of ~9.5 months. First scheduled run will close the gap in one shot since the 18-month API window covers it.

## Phase 0 — Auth unblocker (blocks Phase 4 only)

- [ ] Track `NewGraphEnvironment/rtj#147`. When merged + `terraform apply`-ed, capture the role ARN into Phase 4's workflow.

## Phase 1 — Write side ✅

Goal: produce a single `snapshot_<yyyy-mm-dd>.parquet` capturing 18mo of API state with a `harvested_at` column, ready to ship to S3.

- [x] Add minimal `DESCRIPTION` listing `Imports:` for `r-lib/actions/setup-r-dependencies`: `tidyhydat`, `duckdb`, `DBI`, `arrow`, `dplyr`, `purrr`, `readxl`, `glue`, `fs`, `lubridate`, plus `Remotes: NewGraphEnvironment/ngr`. Repo is not a package — `DESCRIPTION` is dep-manifest only.
- [x] Write `scripts/snapshot.R`:
  - Stations: union of `tidyhydat::realtime_stations('BC')` + `data/eccc/BC_Stations_withTW.xlsx` (matches `update-temp-realtime.R:11–19`).
  - Pull via `purrr::map(stations, ngr::ngr_hyd_realtime) |> purrr::discard(is.null) |> dplyr::bind_rows() |> ngr::ngr_tidy_cols_rm_na()`.
  - Add `harvested_at = Sys.time()` column.
  - Partition path: `data/realtime/<yyyy>/<mm>/snapshot_<yyyy-mm-dd>.parquet`. `fs::dir_create` parents.
  - Write via `arrow::write_parquet()`.
  - Print summary at the end (rows, distinct stations, max Date).
- [x] Run locally; verify file lands at expected path; `arrow::read_parquet()` shows `harvested_at` populated and `max(Date)` ≈ today. **Verified 2026-05-14:** 90.6M rows total, 4.1M for Parameter=5 (water temp) across 292 stations, max Date `2026-05-14 16:15`. ECCC carve-out tracked `data/eccc/BC_Stations_withTW.xlsx`.

## Phase 2 — Migrate legacy layout to `historic/` ✅ (scope narrowed)

- [x] Move the legacy files to `s3://water-temp-bc/data/historic/` via `s3fs::s3_file_move` (aws CLI on this machine is broken — Python 3.14 dyld error; out-of-band fix). Bucket versioning is on per #9.
  - `realtime_raw_eccc_20221213.parquet`
  - `realtime_raw_20240119.parquet`
  - `realtime_raw_20250521.parquet`
  - `realtime_raw_20250728.parquet`
- [x] Upload Phase 1 snapshot to `s3://water-temp-bc/data/realtime/2026/05/snapshot_2026-05-14.parquet` (32s, 690 MB).
- [x] Verify realtime/ dedup works. `Parameter == 5` slice returns 4,112,372 rows, 292 stations, max Date `2026-05-14 16:15`. Took 31.8s over the network.
- [x] **Architectural finding (key):** `dplyr::slice_max` on grouped data is not supported by arrow's dplyr backend (`arrow_not_supported`). The canonical dedup pattern must go through `arrow::to_duckdb()` for window-function support. Load-bearing for Phase 3's `query_canonical()`.
- [ ] ~Verify cross-prefix unified read~ **Deferred** — historic files have heterogeneous schemas (Parameter `string` vs `double`, Date naked vs `tz=UTC`, Grade `string` vs `double`, extra columns). `arrow::open_dataset(list(realtime, historic), unify_schemas = TRUE)` fails on Date tz mismatch. **Follow-up issue body saved at `/tmp/historic-normalize-issue.md` — file when ready.**
- [x] **Scope decision:** canonical source going forward is `realtime/` only. `historic/` is preserved-as-is for explicit archival reads. `query_canonical()` (Phase 3) reads from `realtime/` exclusively.

## Phase 3 — Read-side ergonomics ✅

Goal: make the canonical query path obvious so collaborators don't trip on read-time dedup.

- [x] `scripts/query.R` (new): top-to-bottom readable example covering open-dataset, canonical dedup pattern, parameterized "param 5, last N months, these stations" example, daily-mean aggregation across stations, latest-reading-per-station, and reading a historic file directly with explicit casts.
- [x] `query_canonical()` helper in new `scripts/query-helpers.R` (not `utils.R` — `utils.R` is a staticimports manifest; `functions.R` has pre-existing orphan top-level code I didn't want to depend on). Signature `query_canonical(parameter = NULL, stations = NULL, from = NULL, to = NULL, dataset_root = "s3://water-temp-bc/data/realtime/")`. Returns a lazy dplyr query (caller decides when to `collect()`). Uses `arrow::to_duckdb()` bridge per Phase 2 finding so the grouped `slice_max(harvested_at)` works. Verified anonymously usable (works without AWS env vars).
- [x] Rewrite `README.Rmd` query chunks to use `arrow::open_dataset()` + `query_canonical()`. Closes #14.
- [x] Add "Data layout" + "How to query" sections in `README.Rmd` linking to `scripts/query.R`.
- [x] Switch sample-link URLs to region-explicit `https://water-temp-bc.s3.us-west-2.amazonaws.com/...`. Closes #13.
- [x] Re-render `README.md` (github_document) and `index.html` (html_document). Both render clean. Refreshed `data/result.rds` against the new realtime/ ranges so the published table reflects current data.

## Phase 4 — Automate

- [ ] `.github/workflows/snapshot.yml`:
  - Triggers: `schedule: cron: '0 12 1 * *'` (1st of month, 12:00 UTC) + `workflow_dispatch`.
  - `permissions: { id-token: write, contents: read }`.
  - Steps: `actions/checkout`, `r-lib/actions/setup-r`, `r-lib/actions/setup-r-dependencies` (reads `DESCRIPTION`), `aws-actions/configure-aws-credentials` against rtj role ARN with `aws-region: us-west-2`, `Rscript scripts/snapshot.R`, `aws s3 cp` to the right partition.
- [ ] Pin `ngr` ref in `DESCRIPTION` (`Remotes: NewGraphEnvironment/ngr@<sha>`).
- [ ] Manual `workflow_dispatch` end-to-end run. Verify file lands at expected partition and `query_canonical()` returns it.
- [ ] Let cron take over.

## Phase 5 — Close out

- [ ] Open PR referencing #17.
- [ ] After merge: close #15, #14, #13. Update issue #17 with final summary.
- [ ] `/planning-archive`.

## Validation

- [ ] Phase 1 local run produces a non-empty `snapshot_<today>.parquet` with `harvested_at` set; `max(Date)` ≈ today.
- [ ] Phase 2 unified dedup query returns sensible per-station row counts spanning historic + new snapshot.
- [ ] Phase 3 README renders to both `README.md` (github_document) and `index.html` without errors and the published-page queries succeed.
- [ ] Phase 4 GHA `workflow_dispatch` run completes; new snapshot in S3; `query_canonical()` returns rows with new `harvested_at`.
- [ ] `/code-check` clean on each commit.
- [ ] PWF checkboxes match landed work.
- [ ] `/planning-archive` on completion.
