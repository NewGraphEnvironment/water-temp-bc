# Progress — Modernize storage: monthly OIDC snapshot into partitioned dataset (#17)

## Session 2026-05-14

- Verified cloud state via duckdb+httpfs queries: latest reading `2025-07-28 07:00`, gap ~9.5 months from today.
- Filed cross-repo blocker `NewGraphEnvironment/rtj#147` (reusable `modules/gha_s3_role/` Terraform module).
- Filed `NewGraphEnvironment/water-temp-bc#17` with 6-phase plan.
- Initialized `CLAUDE.md` with soul conventions (visibility: public).
- Plan-mode exploration of `scripts/`, `README.Rmd`, and CI infra — confirmed no GHA / DESCRIPTION / renv.lock exists; nothing in existing helpers is reusable for `snapshot.R` or `query.R`; existing station-union pattern in `update-temp-realtime.R:11–19` is the right reference.
- User approved phase breakdown.
- Created branch `17-modernize-storage-monthly-oidc-snapshot` off main.
- Scaffolded PWF baseline (`task_plan.md`, `findings.md`, `progress.md`).
- **Phase 1 done:** wrote `DESCRIPTION`, `scripts/snapshot.R`, carved `data/eccc/BC_Stations_withTW.xlsx` out of `.gitignore`. Local run produced `data/realtime/2026/05/snapshot_2026-05-14.parquet` (90.6M rows, 292 stations, max Date 2026-05-14 16:15, `harvested_at` 2026-05-14 09:07:17). Pull took ~40 min (faster than 87 min estimate — most ECCC-supplement stations fail-fast with no realtime data).
- **Phase 1 code-check:** 3 rounds. R1: 5 findings → 2 fixed (per-station `possibly()`, empty-pull `stop()`), 3 accepted. R2: 2 findings → 2 fixed (`DAYS_BACK = 581` pin, `stopifnot("Date" %in% names(dat))`). R3: clean.
- **Phase 2 done (scope narrowed):** moved 4 legacy parquets to `historic/` via `s3fs` (aws CLI broken — Python 3.14 dyld). Uploaded new snapshot to `realtime/2026/05/`. Discovered historic schemas are heterogeneous (Date tz, Grade type, divergent columns) — unified `arrow::open_dataset` fails; canonical source narrows to `realtime/` only. Also discovered `arrow` dplyr doesn't support grouped `slice_max` → `query_canonical()` must use `arrow::to_duckdb()` bridge for the dedup. Saved follow-up issue body to `/tmp/historic-normalize-issue.md` (file later with your OK).
- **Next:** Phase 3 — `scripts/query.R`, `query_canonical()` helper (using the duckdb bridge), `README.Rmd` rewrite.
