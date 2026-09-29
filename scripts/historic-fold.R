#!/usr/bin/env Rscript
# scripts/historic-fold.R
#
# One-time fold of the pre-modernization archive into the canonical store
# (#19). Run locally with AWS credentials that can write the bucket:
#
#   Rscript scripts/historic-fold.R                        # dry run (default)
#   HISTORIC_FOLD_PUBLISH=1 Rscript scripts/historic-fold.R
#
# The dry run downloads, normalizes, merges and verifies every partition
# locally and uploads NOTHING. Publish repeats the same work and uploads.
#
# Flow:
#   1. Download the four frozen originals from data/historic/ (never
#      modified — they stay as provenance).
#   2. historic_normalize() each to the raw snapshot schema.
#   3. Per Parameter (normalized params ∪ canonical partitions): download the
#      canonical partition, compact_run() the normalized files into it (the
#      historic harvested_at values all predate every snapshot, so canonical
#      wins every overlapping key), compact_verify() against the meta's row
#      count, and — when publishing — sync the partition back.
#   4. Publishing only: upload the normalized files to
#      data/historic/normalized/ FIRST (the source compact.R's bootstrap
#      re-reads), then the partitions, then the meta. last_merged is left
#      alone (no snapshot was merged); historic_merged records the fold.
#
# Re-running is safe: the folded rows are already in canonical with the same
# harvested_at, so a second fold is a dedup no-op. A failure mid-publish
# leaves some partitions folded, the old meta, and data/canonical.lock in
# place: delete the lock, then re-run the fold to finish.
#
# Writers: while publishing, the fold holds data/canonical.lock, which
# compact.R checks before every upload; GHA runs of snapshot.yml are also
# checked for before and after taking it. compact.R compares the live meta
# before every upload, so a fold that finished during a local compact.R run
# stops that run. Still, do not run compact.R locally during a fold.
# Publish only once main carries this branch's compact_verify() floor and
# shard_keys (#19): the monthly run on an older main would fail verify on the
# 2002 dates every month. Do not run across the 1st of the month, when
# snapshot.yml rewrites the store (~12:00-14:00 UTC). Afterwards, dispatch
# snapshot.yml with compact_only=true to prove the monthly path on the
# runner against the larger store.

suppressPackageStartupMessages({
  library(fs)
})
source("scripts/compact-functions.R")
source("scripts/historic-functions.R")

BUCKET       <- "s3://water-temp-bc"
HIST_RAW     <- "data/historic"
HIST_PREFIX  <- "data/historic/normalized"
CANON_PREFIX <- "data/canonical"
META_KEY     <- "data/canonical_meta.json"
HIST_FILES   <- HISTORIC_FILES  # oldest pull first
# 20250521 re-carries rows of the two older files with metadata stripped;
# historic_normalize() removes those copies (see its header).
EXCLUDE      <- list(realtime_raw_20250521.parquet = c("realtime_raw_eccc_20221213.parquet",
                                                       "realtime_raw_20240119.parquet"))

PUBLISH      <- identical(Sys.getenv("HISTORIC_FOLD_PUBLISH"), "1")
# Not inside tempdir(): R deletes that on exit, taking the report, the
# would-be meta and the 2 GB of downloaded originals a re-run would reuse.
WORK         <- Sys.getenv("HISTORIC_WORK_DIR",
                           unset = fs::path(dirname(tempdir()), "water-temp-bc-historic-fold"))
MEMORY_LIMIT <- Sys.getenv("COMPACT_MEMORY_LIMIT", unset = "4GB")
fs::dir_create(WORK, recurse = TRUE)
message(if (PUBLISH) "PUBLISH run — canonical on S3 will be rewritten."
        else "DRY RUN — nothing will be uploaded. Set HISTORIC_FOLD_PUBLISH=1 to publish.")
message("Work dir: ", WORK)

aws <- function(...) {
  args <- c(...)
  out <- suppressWarnings(system2("aws", args, stdout = TRUE, stderr = TRUE))
  status <- attr(out, "status")
  if (!is.null(status) && status != 0) {
    stop("aws ", paste(args, collapse = " "), " failed (exit ", status, "):\n",
         paste(out, collapse = "\n"))
  }
  out
}

# --- 0. Meta: the row counts the verify gate compares against ----------------
meta_local <- fs::path(WORK, "canonical_meta.json")
aws("s3", "cp", paste0(BUCKET, "/", META_KEY), meta_local, "--only-show-errors")
meta <- jsonlite::read_json(meta_local)
if (!is.null(meta$historic_merged)) {
  message("NOTE: meta already records a historic fold (", meta$historic_merged$folded_at,
          ") — re-folding, which is a dedup no-op for rows already merged.")
}

# Belt to the lock's braces: a compaction that finished while the fold ran
# changed the meta the fold's row counts are based on. Checked before every
# upload that touches canonical, and before the meta write.
meta_unchanged <- function() {
  now_local <- fs::path(WORK, "canonical_meta_now.json")
  aws("s3", "cp", paste0(BUCKET, "/", META_KEY), now_local, "--only-show-errors")
  now <- jsonlite::read_json(now_local)
  if (!identical(now$completed_at, meta$completed_at)) {
    stop("canonical_meta.json changed during the fold (", meta$completed_at, " -> ",
         now$completed_at, "). Re-run the fold, then dispatch compact_only.")
  }
  invisible(TRUE)
}

# --- 1-2. Download and normalize ---------------------------------------------
raw_dir  <- fs::path(WORK, "historic_raw")
norm_dir <- fs::path(WORK, "historic_normalized")
fs::dir_create(c(raw_dir, norm_dir))
norm <- list()
for (f in HIST_FILES) {
  src <- fs::path(raw_dir, f)
  if (!fs::file_exists(src)) {
    aws("s3", "cp", paste0(BUCKET, "/", HIST_RAW, "/", f), src, "--only-show-errors")
  }
  out <- fs::path(norm_dir, f)
  t0 <- Sys.time()
  excl <- if (is.null(EXCLUDE[[f]])) character() else fs::path(raw_dir, EXCLUDE[[f]])
  norm[[f]] <- historic_normalize(src, out, exclude_matching = excl)
  message(sprintf("normalized %s: %s rows, harvested_at %s (%.0f s)", f,
                  format(norm[[f]]$rows, big.mark = ","),
                  format(norm[[f]]$harvested_at, "%Y-%m-%d %H:%M:%S"),
                  as.numeric(difftime(Sys.time(), t0, units = "secs"))))
}

# harvested_at is each file's max Date, so a bogus future Date would let a
# historic row outrank real snapshots. Refuse unless the four values are in
# pull order and all precede the first monthly snapshot.
hv <- vapply(norm, function(x) as.numeric(x$harvested_at), 0)
if (is.unsorted(hv, strictly = TRUE)) stop("historic harvested_at values are not in pull order")
first_snapshot <- as.POSIXct("2026-05-14", tz = "UTC")
if (max(hv) >= as.numeric(first_snapshot)) {
  stop("a historic harvested_at is on or after the first snapshot (", first_snapshot, ")")
}

# --- 3. Parameters = normalized ∪ canonical ----------------------------------
con <- DBI::dbConnect(duckdb::duckdb())
hist_params <- DBI::dbGetQuery(con, sprintf(
  "SELECT DISTINCT CAST(Parameter AS INTEGER) AS p FROM read_parquet('%s')
   WHERE Parameter IS NOT NULL ORDER BY p",
  sql_q(as.character(fs::path(norm_dir, "*.parquet")))))$p
DBI::dbDisconnect(con, shutdown = TRUE)

canon_listing <- aws("s3", "ls", paste0(BUCKET, "/", CANON_PREFIX, "/"))
canon_params <- as.integer(sub(".*Parameter=([0-9]+)/.*", "\\1",
                               grep("PRE Parameter=[0-9]+/", canon_listing, value = TRUE)))
if (length(canon_params) == 0) stop("No canonical partitions found — bootstrap canonical first.")
params_all <- sort(union(as.integer(hist_params), canon_params))
message("Parameters: ", paste(params_all, collapse = ", "))

# --- 4. Publish the normalized source before anything that depends on it -----
# Take the canonical lock first. compact.R refuses to run, or to upload, while
# it exists; a compaction already in flight is caught by the run check below,
# made both before and after taking the lock.
no_compaction_running <- function() {
  runs <- system2("gh", c("run", "list", "--workflow", "snapshot.yml", "--limit", "10",
                          "--json", "status", "-q", ".[].status"),
                  stdout = TRUE, stderr = TRUE)
  if (!is.null(attr(runs, "status"))) stop("gh run list failed: ", paste(runs, collapse = "\n"))
  live <- runs[runs %in% c("queued", "in_progress", "waiting", "requested", "pending")]
  if (length(live) > 0) stop("snapshot.yml has a run ", live[1], " — wait for it, then re-run the fold.")
  invisible(TRUE)
}
if (PUBLISH) {
  no_compaction_running()
  if (canonical_lock_present(aws)) {
    stop(BUCKET, "/", CANONICAL_LOCK_KEY, " already exists — another writer holds canonical/.")
  }
  lock_body <- fs::path(WORK, "canonical.lock")
  writeLines(sprintf("historic-fold.R (#19) %s", format(Sys.time(), tz = "UTC")), lock_body)
  aws("s3api", "put-object", "--bucket", sub("^s3://", "", BUCKET),
      "--key", CANONICAL_LOCK_KEY, "--body", lock_body)
  message("Took ", BUCKET, "/", CANONICAL_LOCK_KEY, ". If this run dies, delete it by hand ",
          "and re-run the fold: compact.R refuses to run while it exists.")
  # A run that started between the first check and the lock would now stop
  # at its next upload; release the lock so it can be re-run afterwards.
  tryCatch(no_compaction_running(), error = function(e) {
    aws("s3api", "delete-object", "--bucket", sub("^s3://", "", BUCKET), "--key", CANONICAL_LOCK_KEY)
    stop(conditionMessage(e), " (lock released; nothing was published)", call. = FALSE)
  })
  aws("s3", "sync", norm_dir, paste0(BUCKET, "/", HIST_PREFIX), "--only-show-errors")
}

per_param <- list()
report <- list()
for (p in params_all) {
  t0 <- Sys.time()
  canon_local <- fs::path(WORK, "canon")
  out_p       <- fs::path(WORK, sprintf("out_p%d", p))
  if (fs::dir_exists(canon_local)) fs::dir_delete(canon_local)

  have_canon <- p %in% canon_params
  if (have_canon) {
    aws("s3", "sync",
        paste0(BUCKET, "/", CANON_PREFIX, sprintf("/Parameter=%d", p)),
        fs::path(canon_local, sprintf("Parameter=%d", p)),
        "--only-show-errors")
  }

  res <- compact_run(
    norm_dir, out_p,
    canonical_dir = if (have_canon) canon_local else NULL,
    params        = p,
    memory_limit  = MEMORY_LIMIT,
    temp_dir      = fs::path(WORK, "duckdb-tmp")
  )
  prev_p <- as.numeric(meta$rows[[as.character(p)]])
  if (length(prev_p) == 0 || is.na(prev_p)) prev_p <- 0
  compact_verify(out_p, prev_rows = prev_p)

  con <- DBI::dbConnect(duckdb::duckdb())
  span <- DBI::dbGetQuery(con, sprintf(
    "SELECT strftime(min(CAST(Date AS TIMESTAMP)), '%%Y-%%m-%%d') AS mn,
            strftime(max(CAST(Date AS TIMESTAMP)), '%%Y-%%m-%%d') AS mx,
            count(DISTINCT STATION_NUMBER)::INTEGER AS n_stn
     FROM read_parquet('%s')",
    sql_q(as.character(fs::path(out_p, "**", "*.parquet")))))
  DBI::dbDisconnect(con, shutdown = TRUE)

  if (PUBLISH) {
    meta_unchanged()
    aws("s3", "sync", "--delete",
        fs::path(out_p, sprintf("Parameter=%d", p)),
        paste0(BUCKET, "/", CANON_PREFIX, sprintf("/Parameter=%d/", p)),
        "--only-show-errors")
  }

  per_param[[as.character(p)]] <- res$rows_written
  report[[as.character(p)]] <- data.frame(
    Parameter = p, rows_before = prev_p, rows_in = res$rows_in,
    rows_after = res$rows_written, added = res$rows_written - prev_p,
    null_dropped = res$null_dropped, min_date = span$mn, max_date = span$mx,
    stations = span$n_stn,
    secs = round(as.numeric(difftime(Sys.time(), t0, units = "secs"))))
  message("Parameter ", p, ": ", format(prev_p, big.mark = ","), " -> ",
          format(res$rows_written, big.mark = ","), " rows (", span$mn, " to ",
          span$mx, ")")

  if (fs::dir_exists(canon_local)) fs::dir_delete(canon_local)
  if (PUBLISH) {
    fs::dir_delete(out_p)
  } else {
    # Kept so the dry run's store can be inspected before anything is published.
    kept <- fs::path(WORK, "folded", sprintf("Parameter=%d", p))
    if (fs::dir_exists(kept)) fs::dir_delete(kept)
    fs::dir_create(fs::path_dir(kept), recurse = TRUE)
    fs::file_move(fs::path(out_p, sprintf("Parameter=%d", p)), kept)
    fs::dir_delete(out_p)
  }
}

report <- do.call(rbind, report)
print(report, row.names = FALSE)
utils::write.csv(report, fs::path(WORK, "historic-fold-report.csv"), row.names = FALSE)

# --- 5. Commit marker --------------------------------------------------------
new_meta <- meta
new_meta$rows       <- per_param
new_meta$total_rows <- sum(unlist(per_param))
new_meta$historic_merged <- list(
  files     = HIST_FILES,
  source    = paste0(BUCKET, "/", HIST_PREFIX),
  folded_at = format(Sys.time(), tz = "UTC", "%Y-%m-%dT%H:%M:%SZ")
)
jsonlite::write_json(new_meta, meta_local, auto_unbox = TRUE, pretty = TRUE)
if (PUBLISH) {
  meta_unchanged()
  aws("s3", "cp", meta_local, paste0(BUCKET, "/", META_KEY), "--only-show-errors")
  aws("s3api", "delete-object", "--bucket", sub("^s3://", "", BUCKET), "--key", CANONICAL_LOCK_KEY)
  message("Released ", BUCKET, "/", CANONICAL_LOCK_KEY, ".")
  message("Published. Meta: ", BUCKET, "/", META_KEY)
} else {
  message("Dry run complete — would-be meta at ", meta_local,
          "; folded store at ", fs::path(WORK, "folded"))
}
