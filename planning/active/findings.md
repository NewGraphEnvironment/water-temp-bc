# Findings — Modernize storage: monthly OIDC snapshot into partitioned dataset (#17)

## Issue context

Modernize how we capture and serve realtime water-temp data so it stays current automatically and the on-disk layout is easy to reason about — for both us and any collaborator who hits the bucket cold. Supersedes #15 (storage layout), folds in #14 (reader switch to `arrow::open_dataset`), and closes the #8-class hardcoded-filename failure mode. Also fixes #13 (region-explicit URLs).

### Current state (verified 2026-05-14)

| File on s3://water-temp-bc/data/ | Date range (Parameter=5) | Rows |
| --- | --- | --- |
| `realtime_raw_eccc_20221213.parquet` | 2002-04-30 → **2022-12-13** | 9.7 M |
| `realtime_raw_20240119.parquet` | 2022-06-17 → 2024-01-19 | 1.8 M |
| `realtime_raw_20250521.parquet` | 2002-04-30 → 2025-05-21 | **13.8 M** (consolidated) |
| `realtime_raw_20250728.parquet` | 2023-12-27 → **2025-07-28 07:00** | 3.4 M (unmerged delta) |

Latest reading on the cloud: **2025-07-28 07:00** → gap of ~9.5 months. First scheduled run will close the gap in one shot since the 18-month API window covers it.

### Decisions

- **Cadence:** monthly cron on a GitHub-hosted runner. No always-on machine.
- **Pull window:** full 18 months every run. Same API call as a narrow pull; lets ECCC QC corrections to older readings flow through automatically.
- **Storage layout** — Hive-style, partitioned by harvest write date:
  ```
  s3://water-temp-bc/data/
  ├── realtime/
  │   ├── 2026/05/snapshot_2026-05-14.parquet
  │   ├── 2026/06/snapshot_2026-06-…parquet
  │   └── …
  ├── historic/                                    # frozen pre-modernization files
  │   ├── realtime_raw_eccc_20221213.parquet
  │   ├── realtime_raw_20250521.parquet
  │   ├── realtime_raw_20240119.parquet
  │   └── realtime_raw_20250728.parquet
  └── stations_realtime.parquet
  ```
- **Filename:** `snapshot_<yyyy-mm-dd>.parquet`. Parent dir already says `realtime/`; filename describes *when the API was captured*.
- **Dedup at read time, not write time.** Every snapshot carries the API response verbatim plus a new `harvested_at` column. Reader picks `arg_max(value, harvested_at)` grouped by `(STATION_NUMBER, Parameter, Date)` so corrected ECCC values win over earlier provisional ones.
- **Reader pattern:** `arrow::open_dataset("s3://water-temp-bc/data/realtime/")` exposes the partitioned tree as one virtual table — kills the hardcoded-filename rot in #14 / #8 permanently.

### Why monthly + full 18mo (not weekly + narrow)

- Water-temp data is consumed retrospectively; same-week freshness isn't required.
- Full 18mo pulls catch ECCC QC corrections to older readings; narrow pulls would miss them silently.
- ~12 files/year × ~600 MB ≈ ~7 GB/yr on S3 (~$0.15/mo). Storage redundancy is rounding error vs the QC robustness gain.
- 12 GHA runs/yr vs 52: 4× cheaper, 4× fewer silent-failure surfaces.

## Codebase exploration (2026-05-14)

### Closest existing analog: `scripts/update-temp-realtime.R`

- Station-list union pattern (`tidyhydat::realtime_stations('BC')` + ECCC Excel) at lines 11–19 — reuse pattern.
- DuckDB `COPY ... TO 'foo.parquet'` write pattern.
- Append/dedup logic at lines 62–101 is incomplete — treat as reference, not import.

### Helper inventory (none directly reusable for `snapshot.R` or `query.R`)

- `scripts/functions.R`: `my_tab_caption_rmd(...)`, `eccc_csv_extract(path)` — README rendering + one-off CSV parser.
- `scripts/utils.R`: only `@staticimports pkg:staticimports` declaration; no functions defined.
- `scripts/staticimports.R`: comments declaring `my_dt_table`, `my_tab_caption` as imports.

### `scripts/extract_stations.R` — out of scope

Builds `stations_realtime.parquet` (metadata, not data). Stays as its own manual job; mention quarterly regeneration as a follow-up.

### CI / dep infrastructure

- **No `.github/workflows/`** — bootstrap from scratch.
- **No `DESCRIPTION`, `renv.lock`, `.Rprofile`, `.Renviron.example`** — create minimal `DESCRIPTION` listing Imports so `r-lib/actions/setup-r-dependencies` works in Phase 4.
- All `ngr::` usage is namespace-qualified, no version pin → workflow must install from GitHub with pinned ref (`Remotes: NewGraphEnvironment/ngr@<sha>`).

### AWS auth posture

- `scripts/sync-data.R` uses `processx::run('aws','s3','sync',...)`. New workflow writes via `aws s3 cp` from inside the runner.
- DuckDB+httpfs in existing scripts reads `Sys.getenv("AWS_ACCESS_KEY_ID" / "AWS_SECRET_ACCESS_KEY")`. GHA's `aws-actions/configure-aws-credentials` sets those env vars automatically when OIDC role-assume succeeds — no additional client config needed.

## Cross-repo dependency

- **`NewGraphEnvironment/rtj#147`** — proposes `modules/gha_s3_role/` Terraform module; first consumer is `water-temp-bc`. Blocks Phase 4 only. Phases 1–3 are local + S3-write-with-existing-keys and can proceed in parallel.
