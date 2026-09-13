# water-temp-bc

Document and serve out BC water temperature data. Scrapes the Environment Canada (ECCC) realtime web service for all BC stations and publishes parquet files to S3 (`s3://water-temp-bc/data`) for direct querying via `duckdb` + `httpfs` — no database required. Also wrangles bulk historic data forwarded by ECCC into the same parquet layout.

## Repository Context

- **Repository:** NewGraphEnvironment/water-temp-bc (public)
- **Primary language:** R (scripts + R Markdown — not an R package; no `R/` or `NAMESPACE`)
- **Published site:** http://www.newgraphenvironment.com/water-temp-bc (rendered from `README.Rmd` → `index.html`)
- **S3 bucket:** `s3://water-temp-bc/data` mirrors local `data/`

## Layout

- `README.Rmd` — source of truth; renders to `README.md` (github_document) and `index.html` (published page with DT tables of station metadata + sample queries)
- `scripts/`
  - `extract-temp-realtime.R` — initial pull of realtime data via `tidyhydat` + `ngr::ngr_hyd_realtime`, amalgamated with prior sqlite snapshot
  - `update-temp-realtime.R` — incremental scrape; writes `data/realtime_raw_<YYYYMMDD>.parquet`
  - `extract-eccc.R` — wrangles the bulk historic ECCC dump into parquet
  - `extract_stations.R` — builds `data/stations_realtime.parquet`
  - `sqlite_to_parquet.R`, `update-table-name.R` — one-time migration helpers
  - `sync-data.R` — `aws s3 sync data/ s3://water-temp-bc/data --delete`
  - `functions.R`, `utils.R`, `staticimports.R` — helpers used by `README.Rmd`
  - `snapshot.R` — the monthly GHA pull (`.github/workflows/snapshot.yml`). Its station resolution lives in `snapshot-functions.R` and is contract-tested by `snapshot-test.R` (`Rscript scripts/snapshot-test.R`)
- `data/` — published parquet files (mirrored to S3); also a stray `water-temp-bc.duckdb`
- `data-raw/` — hex sticker assets
- `research/` — settled facts that outlive their issue. `eccc-realtime-access.md` covers the ECCC hosts, timeouts and retries, the offline station list, and runner reachability samples

## Known state / modernization targets

- **Realtime window is ~18 months** — to maintain a long record, the scrape must run on a schedule and append to a canonical parquet rather than producing dated snapshots.
- **Multiple dated `realtime_raw_*.parquet` files in `data/`** (`20240119`, `20250728`, plus an ECCC historic `20221213`) — README flags "we will need to put them all together soon. TO DO." Consolidating these into a single canonical store is the central modernization task.
- **README.Rmd hardcodes a parquet filename** (`realtime_raw_20250521.parquet`) in its query chunks — that file isn't currently in `data/`, so queries against the published page may be stale or broken. A canonical filename (e.g. `realtime_raw.parquet`) would fix this.
- **Stations list** is the union of `tidyhydat::realtime_stations('BC')` and an Excel of ECCC-forwarded station IDs (`data/eccc/BC_Stations_withTW.xlsx`). If the ECCC datamart can't be reached, the live half is retried, then replaced by the station table bundled with tidyhydat, `tidyhydat::allstations` (#27). A fallback run stays green with only a `::warning::`, and the bundled list is frozen at tidyhydat's build date.

<!-- BEGIN SOUL CONVENTIONS — DO NOT EDIT BELOW THIS LINE -->


# Cartography

## Style Registry

Use the `gq` package for all shared layer symbology. Never hardcode hex color values when a registry style exists.

```r
library(gq)
reg <- gq_reg_main()  # load once per script — 51+ layers
```

**Core pattern:** `reg$layers$lake`, `reg$layers$road`, `reg$layers$bec_zone`, etc.

### Translators

| Target | Simple layer | Classified layer |
|--------|-------------|-----------------|
| tmap | `gq_tmap_style(layer)` → `do.call(tm_polygons, ...)` | `gq_tmap_classes(layer)` → field, values, labels |
| mapgl | `gq_mapgl_style(layer)` → paint properties | `gq_mapgl_classes(layer)` → match expression |

### Custom styles

For project-specific layers not in the main registry, use a hand-curated CSV and merge:

```r
reg <- gq_reg_merge(gq_reg_main(), gq_reg_custom("path/to/custom.csv"))
```

Install: `pak::pak("NewGraphEnvironment/gq")`

## Map Targets

| Output | Tool | When |
|--------|------|------|
| PDF / print figures | `tmap` v4 | Bookdown PDF, static reports |
| Interactive HTML | `mapgl` (MapLibre GL) | Bookdown gitbook, memos, web pages |
| QGIS project | Native QML | Field work, Mergin Maps |

## Key Rules

- **`sf_use_s2(FALSE)`** at top of every mapping script
- **Compute area BEFORE simplify** in SQL
- **No map title** — title belongs in the report caption
- **Legend over least-important terrain** — swap legend and logo sides when it reduces AOI occlusion. No fixed convention for which side.
- **Four-corner rule** — legend, logo, scale bar, keymap each get their own corner. Never stack two in the same quadrant.
- **Bbox must match canvas aspect ratio** — compute the ratio from geographic extents and page dimensions. Mismatch causes white space bands.
- **Consistent element-to-frame spacing** — all inset elements should have visually equal margins from the frame edge
- **Map fills to frame** — basemap extends edge-to-edge, no dead bands. Use near-zero `inner.margins` and `outer.margins`.
- **Suppress auto-legends** — build manual ones from registry values
- **ALL CAPS labels appear larger** — use title case for legend labels (gq `gq_tmap_classes()` handles this automatically via `to_title()` fallback)

## Self-Review (after every render)

Read the PNG and check before showing anyone.

### Placement

1. Correct polygon/study area shown? (verify source data, not just the bbox)
2. Map fills the page? (no white/black bands)
3. Keymap inside frame with spacing from edge?
4. No element overlap? (each in its own corner)
5. Legend over least-important terrain?
6. Consistent spacing across all elements?
7. Scale bar breaks appropriate for extent?

### Does it communicate?

Every check above is about **where elements sit**. A map can satisfy all seven
and still fail to say what it is about — so these are not optional extras, they
are the half of the review that the placement list structurally cannot reach.

8. **Is every prominent feature in the legend?** Work the other direction from
   the usual one: rank what draws the eye *in the rendered image*, then confirm
   each of the top few appears in the legend. Building the legend from the layer
   list instead answers "did I list my layers", which is a different question and
   always says yes.
9. **Is the subject obvious to someone who has never seen this area?** An AOI
   that renders identically to its surroundings is not delineated by a thin
   boundary line — the reader has to be told where to look. Containment (a fill,
   a dimmed exterior, a mask) is what does it.
10. **Does the symbology have a hierarchy, or is it flat?** If one class holds
    the great majority of the features, it will dominate regardless of how
    correct its size is. Ask what the map is *for* and de-emphasise or filter
    accordingly — and say in the caption or prose that you did.
11. **Does the basemap earn its contrast cost?** A basemap that adds no readable
    terrain is not neutral: it lowers the contrast of everything drawn over it.
    Blend parameters that mute it into a flat field are worse than no basemap.
12. **Is the type sized for the width it is published at, not rendered at?** A
    7 in figure squeezed into a ~700 px column loses roughly 40% — text set at
    `size = 0.5` for the render lands at a few pixels on the page. Check the
    figure at its delivered width.

### Why this half exists

Added 2026-08-26 after gq's flagship vignette map was reported as passing all
seven placement checks and was, on being looked at, unreadable: 89% of its point
symbols were one modelled class, the basemap was a featureless grey field, the
AOI was indistinguishable from its surroundings, and the single most prominent
feature on the map — a bright red 397-feature habitat network — **was not in the
legend at all**, while the prose beneath the figure described its styling in
detail (gq#61).

The seven checks had returned green, accurately. They were simply not asking.

See the `cartography` skill for full reference: basemap blending, BC spatial data queries, label hierarchy, mapgl gotchas, and worked examples.

## Land Cover Change

Use [drift](https://github.com/NewGraphEnvironment/drift) and [flooded](https://github.com/NewGraphEnvironment/flooded) together for riparian land cover change analysis. flooded delineates floodplain extents from DEMs and stream networks; drift tracks what's changing inside them over time.

**Pipeline:**

```r
# 1. Delineate floodplain AOI (flooded)
valleys <- flooded::fl_valley_confine(dem, streams, area_field = "upstream_area_ha")

# 2. Fetch, classify, summarize (drift)
rasters   <- drift::dft_stac_fetch(aoi, source = "io-lulc", years = c(2017, 2020, 2023))
classified <- drift::dft_rast_classify(rasters, source = "io-lulc")
summary    <- drift::dft_rast_summarize(classified, unit = "ha")

# 3. Interactive map with layer toggle
drift::dft_map_interactive(classified, aoi = aoi)
```

- Class colors come from drift's shipped class tables (IO LULC, ESA WorldCover)
- For production COGs on S3, `dft_map_interactive()` serves tiles via titiler — set `options(drift.titiler_url = "...")`
- See the [drift vignette](https://www.newgraphenvironment.com/drift/articles/neexdzii-kwa.html) for a worked example (Neexdzii Kwa floodplain, 2017-2023)


# CI Monitoring

When this repo has GitHub Actions workflows, scan recent runs on session start. Catches failed pkgdown deploys, broken vignette builds, and stale citation regenerations that would otherwise linger until the user manually checks.

## On Session Start

```bash
gh run list --limit 5 --json status,conclusion,name,createdAt,databaseId \
  --jq '.[] | select(.conclusion == "failure")'
```

If any failures since the last visit, surface to the user before starting other work:

> Workflow `<name>` failed `<time>` ago (run `<id>`). Investigate with `gh run view <id> --log-failed`. Fix or proceed with current task?

User decides; do not auto-fix.

## Particular Failures Worth Naming

- **pkgdown** — docs site on GitHub Pages broken
- **R-CMD-check** — package may not install
- **Vignette / build-vignettes** — vignette docs incomplete
- **update-citation-cff** — CITATION.cff stale

## Why This Matters

Without this scan, post-merge workflow failures linger until someone (often the user) notices a stale docs site or a missing vignette. The session-start sweep catches them on the first re-entry into the repo.

## Pairs with `/gh-pr-merge`

The skill watches workflows triggered by a fresh merge in real time — that's the targeted catch. This convention is the backstop for failures that landed when no one was watching (merges via web UI, scheduled triggers, manually-triggered workflows).

## A green run does not mean the site is current

CI conclusion and published content are two different facts. Check the second one
directly when it matters — the deploy commit, not the run status:

```bash
git fetch -q origin gh-pages && git log -1 --format='%s' FETCH_HEAD
# "Deploying to gh-pages from @ owner/repo@<sha> 🚀"  <- is <sha> your HEAD?
```

GitHub can create a workflow run minutes after the push that triggered it, and
out of order with a later push. Observed 2026-08-26 in `fly`: `7a7700c` built and
deployed at 17:21, then its own *parent* `be77eca` had its run created at 17:22:52
— twelve minutes after that push — and deployed over it. Both runs green, `gh run
list` all success, published site one commit stale.

Things that do **not** fix this, so don't reach for them:

- `cancel-in-progress: true` — cancels an *overlapping* run. Here the runs never
  overlapped (`created == started` on both, second created after first finished),
  so there was nothing to cancel.
- A `concurrency:` group — the r-lib pkgdown template already sets one at the job
  level (`group: pkgdown-${{ github.event_name != 'pull_request' || github.run_id }}`).
  Grepping for a top-level `concurrency:` key misses it and invites a redundant
  "fix". Serializing runs doesn't order events that arrive late.

There is no workflow-side fix, because the reordering happens before the workflow
exists. The remedy is detection: check the deploy provenance, and re-dispatch
(`gh workflow run <file> --ref main`) if it's behind. Harmless when the stale
commit changed nothing the site publishes — confirm via `.Rbuildignore` / `_pkgdown.yml`
rather than assuming.

## Don't push to the default branch between a merge and its CI settling

The r-lib templates set `concurrency` with `cancel-in-progress: true`, so a second push
to `main` cancels the first push's still-running workflows. That is correct behaviour and
it is not the problem; the problem is that a **cancelled** run and a **failed** run look
the same in the status column, so a routine follow-up push turns a green merge into
something the next person has to go read a log about — and the log does not exist.

The routine follow-up is the one that bites, because it is the one nobody counts as a
push: a `CLAUDE.md` drift sync, a typo fix, a `.gitignore` line. `/compact-prep` step 6
runs `claude_md_drift.sh apply`, which **pushes**, and after `/gh-pr-merge` that lands
seconds after the merge.

Order them: watch the merge's runs to completion, *then* push anything else. Measured
2026-09-08 in gq — the merge's pkgdown and R-CMD-check were allowed to finish green and
the deploy provenance checked before the sync went out, and the sync's own runs then went
green on their own SHA. Holding it cost about three minutes.

Where a push has already gone out and cancelled something, `/gh-pr-merge` step 10 has the
reading: `cancelled`/`skipped` is `⊘ superseded`, not `✗ failed`, and the thing to confirm
is that the **newer** SHA's run passed. Do not re-dispatch the cancelled one.

## Don't use `gh run watch` to wait

It polls hard enough to trip GitHub's *secondary* rate limit, which `gh api
/rate_limit` does not report — every primary bucket reads full while calls return
403. Retrying extends it. Poll sparsely with `gh run view <id> --json status,conclusion`,
and prefer `git fetch` over the REST API for anything git can answer.

## A setup failure and a build failure look identical in the status column

`gh pr checks` and the Actions UI report one word per job. A run that died fetching its
own toolchain and a run that died because the code is broken both read `fail`, and only
the second says anything about what you just shipped.

```
Error in download.file(...) : status was 'SSL connect error'
download of package 'pak' failed
Error in loadNamespace(x) : there is no package called 'pak'
```

That is `setup-r-dependencies` failing before the package was ever built. Seen
2026-09-02 on a tagged spacehakr release, where the same workflow had passed on the merge
commit minutes earlier with identical content — the natural but wrong reading is "the
release is broken".

**Read which step failed before drawing a conclusion**, especially on a release commit
where the instinct is to distrust the tag:

```bash
gh run view <id> --log-failed | grep -iE 'error|fatal' | head
```

If it died in dependency setup, rerun once. If it dies the same way again it is the
upstream CDN, and the honest move is to say so and stop — not to keep spending runs on
something no change in the repo can fix.


# Code Check — Shell

Tool-level traps in bash, sed, git and `gh`, and in the host toolchain those commands
depend on. These load everywhere because they are about the shell the agent runs
commands in, not about `.sh` files in the repo.
The general mechanisms — a guard that fails toward pass, a fixture that cannot
reach the failure mode — live in `code-check.md`; this file is the quirks.

### `git diff a..b` compares TIPS; a change on `a` shows up as the branch's

Two-dot is the difference between two commits. Three-dot (`a...b`) is the difference from
their **merge base** — what the branch actually did, and what GitHub shows in a PR.

So anything that landed on the base since the branch forked appears **inverted** in a
two-dot diff: a file `main` *deleted* reads as a file the branch *added*.

Measured 2026-09-04 in rtj. A branch touched four files. `git diff --stat main..branch`
listed five, the extra being a one-line addition to a CSV. `main` had removed that line in a
merged PR; the branch had never touched the file at all:

```
two-dot   : CLAUDE.md docs/… env/prod/main.tf progress.md manifest.csv
three-dot : CLAUDE.md docs/… env/prod/main.tf progress.md
```

It cost a wrong merge-order rationale written into a PR description ("merge #279 first,
both touch this file"), caught by the PR reviewer reading the diff GitHub renders. The
failure is quiet because the two-dot output is *correct* — it answers a question nobody
asked.

- Use `a...b` for "what does this branch change", which is nearly always the question.
- `git log a..b` is the opposite convention and two-dot is right there — it lists commits
  reachable from `b` and not `a`. The asymmetry between `log` and `diff` is the trap.
- Confirm against the branch's own commits when it matters:
  `git log --oneline a...b -- <path>` shows *which* side touched a file.

### git pathspec excludes: use the long form
- `:!path` is short-form magic, and git keeps parsing magic characters after the
  `!`. A path starting with one aborts the whole command:
  `:!_pkgdown.yml` → `fatal: Unimplemented pathspec magic '_'`.
- Use `:(exclude)path`. `:!./path` also works, but the long form says what it means.
- Anything building pathspecs from a file (`.Rbuildignore`, `.gitignore`) will
  eventually meet a leading `_`, `(`, or `^`.

### `sed 1d f1 f2 f3` strips only the FIRST file's header

`sed` treats multiple file arguments as one concatenated stream, so a line-address
script applies once across the whole set rather than per file. Stripping CSV headers
this way — especially via `find … -exec sed 1d {} +`, which batches many files into one
invocation — leaves every header but the first embedded in the data.

It is silent, and it lands rows that parse. Caught 2026-08-30 concatenating 24 paged WFS
responses: 23 stray header rows entered a 223,667-row analysis and showed up only as a
row-count reconciliation failing by exactly 23.

```bash
for f in pages/*.csv; do sed 1d "$f"; done > combined.csv   # per file
awk 'FNR>1' pages/*.csv > combined.csv                      # or FNR, which resets
```

Reconcile the row count against what the source said it would be. That is the check that
catches this, and it costs one line.

### `sed -n '/X/,$d' file` prints nothing at all

`-n` suppresses auto-print, and `d` only deletes — so nothing is ever emitted and the
output is empty. The intent (print up to a marker) needs `sed '/X/,$d'` without `-n`, or
`sed -n '1,/X/p'`.

Fails toward an **empty file**, which downstream reads as "no matches" rather than as a
broken command. Same family as "A guard that fails toward pass" in `code-check.md`: the
silent direction is the dangerous one.

### Reading a file line-by-line drops the last line without a trailing newline
- `while IFS= read -r line; do ...; done < file` skips a final line that has no
  newline after it. Use `while IFS= read -r line || [ -n "$line" ]`.

### Empty arrays under `set -u` on bash 3.2
- macOS still ships bash **3.2**, where `"${ARR[@]}"` on an empty array is an
  unbound-variable error under `set -u`. Guard with `[ ${#ARR[@]} -gt 0 ]`
  before expanding. Scripts written and tested on Linux bash 5 hit this only on
  a Mac, and only when the array happens to be empty.

### Quoting
- Variables in double-quoted strings containing single quotes break if value has `'`
- `"echo '${VAR}'"` — if VAR contains `'`, shell syntax breaks
- Use `printf '%s\n' "$VAR" | command` to pipe values safely
- Heredocs: unquoted `<<EOF` expands variables locally, `<<'EOF'` does not — know which you need
- Unquoted heredocs also run **command substitution**: backticks in prose (markdown code spans!) execute and are replaced by their output, usually empty. Writing markdown through an unquoted heredoc silently deletes every `` `word` `` in it — no error, and the damage only shows on re-read. Seen 2026-08-06 writing a memory index line: a markdown code span followed by "gone as a concept" landed as "gone as a concept", subject removed. Any heredoc carrying prose or markdown wants `<<'EOF'`.
  - **The rule collapses the moment you also need interpolation.** `<<'EOF'` is
    the fix for prose and `<<EOF` is the fix for variables, and a heredoc that
    needs both has no safe form — which is exactly when the trap fires, because
    the quoting choice now looks forced rather than careless. Seen again
    2026-08-26 in rfp#186 writing a findings file that had to carry a generated
    project name: `` `normal` `` in a markdown table ran as a command and its
    empty output replaced the word, leaving `| enabled, , **resolves** |`.
    Escaping the backticks individually is not a fix either — you have to get
    every one, and the misses are silent.
  - Fix: keep the heredoc quoted and substitute afterwards, or write the file
    from Python where there is no substitution layer at all:
    ```bash
    cat > out.md <<'EOF'      # prose safe, placeholder left literal
    Project: __NAME__
    EOF
    sed -i '' "s|__NAME__|$NAME|" out.md
    ```
  - Detection is cheap and worth doing whenever prose went through an unquoted
    heredoc: `grep -n ', ,\|(( ))\|  |' file` finds the empty spans a swallowed
    code span leaves behind.
- Pass-through-ssh args: `printf '%q'` escapes per-arg so workload paths with spaces / quotes / metacharacters survive the local-shell → ssh-argv → remote-shell round-trip. Without it, `ssh host 'cmd' "$path"` joins args with spaces on remote and re-parses, losing argument boundaries.
- **A plain `git commit -m "…"` runs command substitution too, and unlike the heredoc cases it
  SUCCEEDS.** The rules above are about forms that fail loudly. This one does not: backticks in a
  double-quoted `-m` string execute, bash prints `something: command not found` to **stderr**, and
  the commit lands anyway with the span replaced by empty output. Seen 2026-09-02 in floodplains:
  a message reading ``prov_keys() now takes a `part` argument`` committed as "now takes a
  argument". The only signal was one stderr line scrolling past above a successful commit.
  - Markdown code spans are exactly what a good commit message is full of — function names,
    arguments, file paths — so the failure targets careful messages, not sloppy ones.
  - Fix is the one already prescribed for multi-line bodies, applied to single-line ones too:
    write the message to a file and `git commit -F`, or use single quotes when the text has no
    apostrophes. `git commit --amend -F msg.txt` repairs it after the fact.
  - Detection, since the commit is already made: `git log -1 --format=%B | grep -n "  \|takes a $"`
    finds the collapsed double spaces an eaten span leaves behind.
- `git commit -m "$(cat <<'EOF' ... EOF)"` chokes on apostrophes in prose bodies in some contexts — the bash parser surfaces an unmatched-quote error even though heredoc bodies should be quote-neutral. Resilient default for multi-line commit messages: write the body to `/tmp/msg.txt` and use `git commit -F /tmp/msg.txt`.
- **The same trap has a silent variant: `Rscript -e` / `python -c` carrying backslash escapes.** The heredoc case above fails loudly, which costs a retry. Passing a regex inline does not: `\\b` reaches the interpreter mangled, so `grepl()` returns 0 matches against text it matches perfectly from a file. Nothing errors. Seen 2026-07-31 in rfp#93 — the 0 read as "my regex is wrong" and nearly triggered a rewrite of working code; the identical regex scored 4 matches the moment it ran from `/tmp/x.R`.
  - Rule: anything carrying a regex, nested quotes or backslashes gets written to a file and run (`Rscript /tmp/x.R`). Inline `-e` is for trivial one-liners only.
  - Diagnostic: when an inline command returns a surprising *result* rather than an error, suspect the quoting layer before the code, and re-run from a file to find out which is wrong. That one step separates a real bug from a shell artifact.

### Heredoc precedence in pipelines
- `cmd1 | cmd2 <<EOF` — the heredoc binds to `cmd2` (the rightmost simple command). If you intended `cmd1` to receive it, put `<<EOF` on cmd1 explicitly: `cmd1 <<EOF | cmd2`.
- Symptom when wrong: ssh body silently echoed by tee/cat/etc, ssh side gets empty stdin, exits 0 (or near-0) without doing anything. Caught the hard way 2026-05-01 in cypher_restore-fwapg.sh.

### Paths
- Hardcoded absolute paths (`/Users/airvine/...`) break for other users
- Use `REPO_ROOT="$(cd "$(dirname "$0")/<relative>" && pwd)"`
- After moving scripts, verify `../` depth still resolves correctly
- Usage comments should match actual script location

### Diagnose env/PATH problems in the shell that actually runs, not the ambient one
- Get ground truth **before** forming any theory:
  `env -i HOME=$HOME TERM=$TERM bash -lc 'echo $PATH | tr ":" "\n" | nl'`
  (swap in `zsh` to check the other side). Numbering shows ordering and
  duplication in one read.
- **Claude Code runs bash regardless of the user's login shell**, so a PATH
  measured from an agent shell says nothing about the terminal the user sees.
  Establish which shell is interactive (`echo $0`, or the prompt style) before
  opening any rc file.
- **The mutation is usually one level down from the obvious file.** A
  `for file in ~/.{path,exports,aliases,extra}; do source "$file"; done` loop in
  `.bash_profile` hides real `PATH=` assignments in files you never opened. Grep
  every sourced file, not just the rc files.
- Caught 2026-08-19: a 39-entry PATH with 12 duplicates took **three** wrong
  diagnoses — `.zprofile` (which did run `brew shellenv` five times, but the
  interactive shell was bash, so it was irrelevant), then `.bashrc` sourcing
  `.bash_profile`, then tmux inheriting a stale env. The cause was `~/.path`
  hand-prepending what `brew shellenv` already sets, plus three directories that
  no longer existed. One `env -i` run ended it.
- The same mistake closed an infra issue prematurely: MacPorts was removed and
  verified **in bash**, while `.zprofile` kept exporting `/opt/local/bin` on
  every zsh login for months. Verified in one shell, broken in the one that runs.

### Parallel writers sharing one output file interleave mid-record
- `xargs -P N ... >> shared_file` (or any fan-out where N processes append to the same fd/path) is only safe while each record fits in a single `write()`. O_APPEND makes individual `write()` calls atomic, but a large record (anything beyond pipe/stdio buffer size, ~64 KB) spans multiple writes — concurrent jobs interleave mid-record and corrupt the file.
- The trap is latent: small records never trip it, so the pattern looks proven until the first large payload arrives. Caught 2026-07-11 in rtj's `stac_register-pypgstac.sh` — 20 parallel `curl | jq -c` jobs appending STAC items to one NDJSON worked for every prior collection (KB-scale items), then 9 MB floodplain items interleaved and produced an orjson decode error ~864 KB into line 1.
- Fix pattern: each parallel job writes its own temp file (unique name, e.g. md5 of the input), concatenate after the fan-out completes:
  ```bash
  cat urls.txt | xargs -P 20 -I {} fetch_one.sh {} "$OUT_DIR"   # each writes $OUT_DIR/<md5>.json
  find "$OUT_DIR" -maxdepth 1 -name '*.json' -exec cat {} + > combined.ndjson
  ```
- **Concatenate with `find -exec … +`, never `cat "$OUT_DIR"/*`.** This fix is what
  creates the file count that then blows `ARG_MAX` — see "`cmd dir/*` dies on
  ARG_MAX at scale" below. The two traps are a matched pair, and writing the glob
  form here is what put the bug into rtj's registration script twice.
- Pair with a count guard — parallel `curl` failures under xargs are also silent: `[ "$(wc -l < combined.ndjson)" -eq "$EXPECTED" ] || exit 1` before any downstream load.

### `mktemp` template needs enough X's, and a failed `mktemp` leaves an empty var
- BSD/macOS `mktemp -d -t <name>` requires the template to contain at least 3 `X`s (`XXXXXX` is the safe default). Without them, mktemp errors to stderr (`too few X's in template`) and **prints nothing to stdout**.
- Pattern: `SCRATCH=$(mktemp -d -t aider-smoke) && cd "$SCRATCH" && <destructive>`. When mktemp fails, `$SCRATCH=""`. `cd ""` is a no-op that **leaves you in the caller's cwd**. The destructive command (`rm`, `git init`, `git add+commit`) then runs in cwd instead of a throwaway tmpdir.
- Caught the hard way 2026-05-13: a Claude smoke test inside the rtj checkout did exactly this, accidentally committed a `demo.R` to the active feature branch, which then rode the squash-merge into rtj/main and had to be cleaned up post-merge.
- Fix patterns:
  - Always use `XXXXXX` (6 X's) in the template: `mktemp -d -t aider-smoke.XXXXXX`.
  - Guard the result: `SCRATCH=$(mktemp -d ...) || exit 1; [ -n "$SCRATCH" ] || exit 1`.
  - Use `set -euo pipefail` so the failed command-substitution kills the script.

### `cmd dir/*` dies on ARG_MAX at scale — and only after the expensive work succeeded

- A glob expands to argv. 98k filenames is roughly 6 MB against a ~2 MB limit, so
  `cat "$DIR"/*.json` fails with `argument list too long` — **after** whatever
  produced those files already succeeded. Silent-after-success: the costly stage
  worked and the cheap one threw it away.
- Caught 2026-07 in rtj#196: it killed a STAC registration following a completed
  80-minute download.
- **Recurred 2026-08-29 in the same script**, because #196 wrote this entry but
  never repaired `rtj/scripts/geoserv/stac_register-pypgstac.sh`, and the
  parallel-writers entry above still prescribed the glob. 102,460 downloaded item
  JSONs concatenated fine with `find`; the load then took 27 seconds. The costly
  stage had already succeeded both times.
- The cost is worse than a wasted download when the script **deletes before it
  loads**: that registration removes the collection in step 2, so failing in step
  4 left a live public API serving zero items until it was repaired by hand. A
  destructive-then-rebuild sequence turns "retry it" into an outage.
- Safe form — `find` batches under the limit itself:
  ```bash
  find "$DIR" -maxdepth 1 -name '*.json' -exec cat {} + > combined.ndjson
  ```
- The trap is latent, and it rides in on the fix for a different one:
  per-file fan-out (see "Parallel writers sharing one output file interleave
  mid-record" above) is correct, and it is exactly what produces the file count
  that later blows argv. Small sets look proven for as long as you test on them.

### A `curl` in a parallel fan-out needs `--max-time`

- Without it, one hung connection pins a worker slot indefinitely. Since a fan-out
  usually prints nothing until it finishes, a wedged pool and a slow pool look
  identical from outside — there is no signal to distinguish "still working" from
  "will never finish".
- Set `--max-time` on every per-URL fetch, and pair any silent multi-minute stage
  with a periodic progress line (a file count is enough). Same reasoning as
  `statement_timeout` on long DB work: the point is to fail loud rather than hang
  quiet.

### BSD vs GNU sed/grep portability (macOS hits this constantly)
- macOS ships BSD `sed`/`grep`. Linux CI/cloud-init hosts ship GNU. Snippets that work on one silently misbehave on the other.
- **`\+` and `\|` are GNU BRE extensions.** On BSD they're treated as literal `+` and `|`, so the regex still "matches" but matches nothing useful — leaving raw input unchanged.
  - Symptom seen 2026-05-28: `sed 's/[^a-z0-9]\+/-/g'` on macOS left spaces in an issue-title slug, producing an invalid git branch name.
  - Fix: use `sed -E` (POSIX ERE) so `+`, `|`, `?`, `(...)` all work without escapes on both flavors. The same regex becomes `sed -E 's/[^a-z0-9]+/-/g'`.
- **`s|pat|repl|` delimiter conflicts with `|` in alternation/replacement on BSD.** Pick a delimiter that does not appear in pattern or replacement (`#`, `,`, `:` are common choices). Compound `s|x|y|; s|^| /||` chains where the trailing `||` looks like an empty delimiter break on BSD sed even when GNU accepts them.
- **Don't parse `ls`.** BSD `ls` emits ANSI colour codes when stdout is a TTY *or* when `CLICOLOR_FORCE` is set in env (often by shell rc files), and the codes leak through pipes. Downstream `grep`/`sed` chokes on the embedded escapes (`[01;31m...[0m`).
  - **A third cause, and the one that bites agents: an alias in the invoking shell.** Measured 2026-08-28 — in an agent Bash call `ls` was aliased to `command ls --color`, so `ls -A dir | grep -v '^\.gitkeep$'` returned `^[[0m^[[00m.gitkeep^[[0m`, the grep failed to filter it, and a directory-empty guard false-failed on a correct tree. The identical command was fine inside a script file, where no alias applies and `ls` resolved to GNU coreutils — so testing it from a script *proves nothing about how it will run inline*. `CLICOLOR_FORCE` was not involved in that instance; check `type ls` before trusting either.
  - Use `find <dir> -maxdepth 1 -mindepth 1 -type d -exec basename {} \;` for directory listings, or `printf '%s\n' <dir>/*/` for a glob, or `for d in <dir>/*/; do basename "$d"; done`.
- **When writing a snippet you expect to ship in a `skills/` SKILL.md or any cloud-init runcmd**: it must be POSIX-portable. Default to `sed -E`, avoid `\+`/`\|`, and don't pipe `ls`.

### On this Mac `stat` and `date` are GNU, so the same flag letter means something else

The section above says macOS ships BSD tools. That is true of `sed` and `grep` and false of
coreutils here: Homebrew's `coreutils` puts `/opt/homebrew/opt/coreutils/libexec/gnubin`
ahead of `/usr/bin`, so an agent Bash call gets **GNU** `stat`, `date`, `ls`, `cp`, `du` and
friends. Measured 2026-09-08: `type stat` → `/opt/homebrew/opt/coreutils/libexec/gnubin/stat`,
`stat --version` → `stat (GNU coreutils) 9.11`, while `/usr/bin/stat --version` errors with
`illegal option -- -`.

The overlap is the trap, because the letters collide with different meanings:

| written for BSD | GNU reads it as | what happens |
|---|---|---|
| `stat -f '%m %N' f` | `-f` = stat the **filesystem** | prints `Inodes: …`, no mtime |
| `date -r 1729570470` | `-r` = mtime of a **reference file** | `date: 1729570470: No such file or directory` |

Both failed loudly in one session, twice, on a fleet mtime sweep — and loud is the lucky
direction. The dangerous one is a script written and *proven* on this Mac then run on a stock
Mac or a CI Linux box, where the same flags flip meaning back and the output is wrong rather
than absent. Same family as "A verification command can be shadowed by a shell function or
alias" below, arriving through PATH order rather than through a function — and `find` is
*both* here: a shell function wrapping the binary.

- For anything whose output you will parse or treat as evidence, call the flavour you mean by
  absolute path: `/usr/bin/stat -f '%m'`, `/bin/date -r "$epoch"`. `gstat`/`gdate` name the
  GNU side explicitly where that is what you want.
- Prefer a form with no flavour dispute at all: `find … -newermt` for age comparisons,
  `git log --format=%ad` for anything git already knows, `python3` for arithmetic on epochs.
- `type <cmd>` before believing a surprising result, and note it answers for *this* shell
  only — the convention's own premise about what macOS ships is not a substitute for asking
  the machine.

### `&` binds to the whole `&&` list, so assignments never reach the parent

- `cmd1 && VAR=$(...) && nohup prog > "$VAR.log" & disown` backgrounds the
  **entire list**, not just `nohup`. `VAR` is assigned inside the background
  subshell, so it is empty in the parent — and a following `tail -f "$VAR.log"`
  reads the wrong path or errors while the job runs fine, writing somewhere you
  are not looking.
- The symptom lies about which side failed: the `tail` says
  `No such file or directory`, which reads as "the job never started". It started.
- Fix: assign **before** the list — `VAR=$(...); cmd1 && nohup ... &` — or
  `printf` the resolved path from inside the backgrounded shell so the parent can
  read it from output.
- Hit twice in one floodplains session (2026-08-27) launching detached runs.
- **The same shape makes `$!` the wrong PID, and that failure hands you a plausible
  number instead of an error.** `mkdir -p "$D" && : > "$D/rss.txt" && Rscript job.R &`
  then `PID=$!` gives the *list's* subshell, not `Rscript` — so a sampler built on it
  (`ps -o rss= -p $PID`) records the shell. Measured 2026-09-05 in drift#62: 39 samples
  alternating 3104 / 1488 KiB, from a run whose R process peaked at 14.2 **GiB**. Nothing
  errors, the trace is well-formed, and it was committed as the evidence record before a
  reviewer compared its peak against the other three groups'. Start the long command
  **alone** — `Rscript job.R > "$D/run.log" 2>&1 &` on its own line, every `mkdir`/`: >`
  before it — and sanity-check the first sample's magnitude against what the job should
  use, because the wrong-PID trace is off by three orders of magnitude and looks fine.

### `gh` CLI
- **`gh pr create` resolves branch from CWD, not `--repo`**. Specifying `--repo NewGraphEnvironment/X` does NOT switch branch resolution — the command still reads the current working directory's checked-out branch. To open a PR in repo X, `cd` into X's checkout first, or pass `--head <branch>` explicitly.
- **`gh issue create` / `gh pr create` with heredoc bodies fail on prose containing special shell characters** (apostrophes, dollar signs, backticks). Use `--body-file /tmp/issue.md` instead — every project's `newgraph.md` convention specifies this; codified here for the underlying class. The two are written interchangeably, so the trap applies to both: `gh pr create --body "$(cat <<'EOF' … EOF)"` breaks the parser on a prose apostrophe and bash reports `unexpected EOF while looking for matching '"'`, aborting the whole command before anything runs.
- **`gh issue create` resolves the target repo from the remotes, preferring `upstream` over `origin`.** A checkout that carries an `upstream` remote — a template it was seeded from, a fork parent — files the issue against **upstream**, not the repo you are working in. It is silent: the only tell is the URL that comes back. Pass `--repo OWNER/NAME` explicitly whenever a checkout has more than one remote.
  - Detect before filing: `git remote -v | awk '{print $1}' | sort -u` — anything beyond `origin` means pass `--repo`.
  - Recovery is not a transfer. `gh issue transfer` refuses to move an issue out of a private repo into a public one (`Old issue cannot be transferred from private repository to public repository`), which is exactly the direction this misfire takes when the template is private and the working repo is public. The fix is: create again with `--repo`, then close the stray with a comment naming where it went.
  - Caught 2026-08-28 in `hsp`, which has `upstream = NewGraphEnvironment/mybookdown-template`: a CABIN/formalin safety issue filed from the `hsp` checkout landed on `mybookdown-template#94`.
- **Do not let a base-branch deletion decide a stacked PR's fate.** Merging the base
  does not retarget the child: it still points at a merged branch, `gh pr view` reports
  it `MERGEABLE`/`CLEAN`, and merging it there is a no-op against history already on
  main (seen 2026-08-30 merging rfp#231 then rfp#234). GitHub documents auto-retargeting
  when the base branch is *deleted*, and it is not dependable: measured 2026-08-31 in
  rfp, `--delete-branch` on the base **closed** the child two seconds after the merge
  (`base_ref_deleted` and `closed` share a timestamp), left `base` unchanged, and
  `gh pr edit --base` then refused with *"Cannot change the base branch of a closed
  pull request"*. Commits are safe either way — the head branch survives on origin —
  but the PR, its review thread and its CI attach have to be recreated. Retarget
  explicitly **while the child is still open**, then merge the base:
  ```bash
  gh pr edit "$CHILD_PR" --base main      # FIRST, and while it is open
  gh pr merge "$BASE_PR" --merge --delete-branch
  gh pr view "$CHILD_PR" --json mergeable,mergeStateStatus,statusCheckRollup
  ```
  Checks are attached to the head SHA, not the base, so they survive the
  retarget — but confirm rather than assume, since a required check configured
  per-base may not. If the child is already closed, reopen it *then* retarget, or
  open a fresh PR from the surviving head branch.
- **Before you *cut* a branch, verify local is current with origin.** The mirror of the
  rule below, and easier to miss because everything about the working tree looks fine. A
  clean tree and the right branch name say nothing about whether that branch is 19 commits
  behind. A branch cut from a stale base regenerates its content from stale input, and the
  PR either conflicts (loud, cheap) or auto-merges non-overlapping hunks and quietly
  reverts someone's newer edit (silent, expensive). Assert it:
  ```bash
  git fetch -q origin
  [ "$(git rev-list --count HEAD..@{u})" -eq 0 ] || { echo "local behind origin"; exit 1; }
  ```
  Caught 2026-08-28 syncing CLAUDE.md across 25 repos: preconditions checked clean-tree
  and on-default-branch but not up-to-date. `nrp-nutrient-loading-2025` was 19 behind, one
  of those commits having touched the same file, and the PR conflicted. The 24 that merged
  cleanly still had to be proven safe after the fact — by asserting the sync commit changed
  nothing above the CLAUDE.md marker, which is the invariant the operation actually claimed.
- **A per-item loop reports the wrapper's exit, not the items'.** `for r in ...; do
  script "$r"; done` exits 0 whenever the *last* item succeeds, however many failed before
  it. The task notification then says "completed (exit code 0)" over a batch with real
  failures in it. Same family as "A wrapper's exit is not the work" in `code-check.md`, and
  the fix is the same shape:
  gate on in-band markers. Print a per-item `OK`/`FAIL` line and count the FAILs, or
  accumulate `RC=$((RC+1))` and `exit "$RC"`. Never read a loop's exit as "all items
  succeeded".
- **Distinguish "the action failed" from "the cleanup after it failed".** A wrapper that
  treats any non-zero from `gh pr merge` as *merge failed* will report a false negative
  when the merge succeeded and only `--delete-branch` errored. Two of three failures in the
  same 2026-08-28 run were misreported this way — one had already merged. Re-read the
  authoritative state (`gh pr view --json state`) before acting on a failure report, rather
  than trusting the exit code of the compound command.
- **And the same compound can half-succeed while reporting success.**
  `gh pr merge --delete-branch` deletes the local branch before the remote one, so a local
  delete that fails takes the remote delete with it — and the command still reports the
  merge as done, because it was. Observed 2026-08-31: a **worktree** held the branch, `gh`
  printed `failed to delete local branch ... used by worktree at ...`, and the remote
  branch survived. Nothing else in the output suggested a branch had been left behind.
  Benign in isolation; it matters because a surviving branch reads as unmerged work to the
  next person, and because the worktree-per-session rule in `code-check.md` ("A shared
  working tree") makes the trigger routine rather than exotic. Confirm the deletion rather than assuming it, and
  verify the branch is merged before cleaning up by hand:
  ```bash
  gh pr merge "$PR" --merge --delete-branch
  git ls-remote --heads origin "$BRANCH"        # expect empty
  git merge-base --is-ancestor "$BRANCH_SHA" origin/main \
    && git push origin --delete "$BRANCH"
  ```
- **Never send a push's stderr to `/dev/null`.** The rule below assumes you *notice* an
  unpushed branch. Suppressing the push's error removes the only signal that it happened,
  and the very next step in the usual sequence — `git branch -D` after a merge — then turns
  the commit into a dangling object. `git push -q ... 2>/dev/null` is the shape; `-q`
  already silences success, so the redirect can only ever hide a failure. Caught 2026-08-29
  in soul: a suppressed rejection meant `gh pr create` had no branch to open against, the
  cleanup deleted the branch anyway, and the commit survived only via `git reflog`. Keep
  stderr, or test the exit status explicitly:
  ```bash
  git push -u origin "$BRANCH" || { echo "push failed"; exit 1; }
  ```
- **Before `gh pr merge`, verify the branch is fully pushed.** `gh pr merge` merges the REMOTE branch — commits made locally but never pushed are silently excluded, so the PR merges "successfully" while `main` is missing work you know you committed. Check `git status -sb` shows no `ahead N` before merging (or that `git rev-list --count @{u}..HEAD` is 0). Worse: if you then delete the local branch (`--delete-branch`, or a follow-up `git branch -D`), the unpushed commits become **dangling** — recoverable via `git reflog` / `git fsck --lost-found` then `git cherry-pick`, but only if you notice they're missing. Caught twice 2026-07 in `floodplains`: PR #6 merged 1 of 3 branch commits (the drift#34 `changes_only` fix + a CLAUDE.md update were unpushed → stranded as danglers → recovered and re-merged via a follow-up PR); a second branch sat 4-ahead-unpushed at compact time. The same check belongs in the `gh-pr-merge` skill's pre-merge step.

- **GitHub does not parse negation in a closing keyword, so "does not close #N" closes #N.**
  The grep this skill prescribes above finds the line and a human reads it as a denial;
  GitHub reads the adjacency. Measured 2026-09-07 on rtj#315, whose body carried the heading
  `## This does not close #105` deliberately explaining why the issue should stay open — and
  `closingIssuesReferences` reported #105 as a closing reference. Merging would have closed
  the issue the PR existed to argue should remain open, and every text-based check passed.
  The same trap fires on "no longer fixes #12", "this doesn't resolve #7", or a changelog line
  quoting an older `Fixes #3`.
  - Ask GitHub what it parsed, rather than grepping what you wrote. It is the only source
    that agrees with what the merge will do:
    ```bash
    gh api graphql -f query='
    { repository(owner:"OWNER", name:"REPO") {
        pullRequest(number:NNN) { closingIssuesReferences(first:10) { totalCount nodes { number } } } } }' \
      -q '.data.repository.pullRequest.closingIssuesReferences.totalCount'
    ```
  - Fix by removing the adjacency, not by adding more words: reword the heading so no
    `clos*`/`fix*`/`resolv*` token sits before the `#N`. Then **re-query until it reads 0** —
    the field updates on edit, but confirming is one call and assuming is how it ships.
  - Worth running whenever a PR deliberately does *not* close the issue it references. When it
    is meant to close it, the field failing to list it is the same check pointing the other way.

### On a fork, `main` may track upstream by design — comparing it answers nothing

`gh api repos/ORG/REPO/compare/upstream:main...ORG:main` returning
`ahead: 0, behind: 0, status: identical` reads as *"this fork has no local work"*. On a
fork whose workflow keeps `main` synced to upstream and puts the org's own commits on a
**named branch**, it means the opposite of nothing: it is the branch model working, and
every local commit is somewhere the comparison never looked.

Measured 2026-09-05 on `NewGraphEnvironment/db_newgraph`, a fork of `smnorris/db_newgraph`:
`main` was byte-identical to upstream while `newgraph` was **12 commits ahead**, plus five
other branches and a merged PR history against `newgraph` as the base. The identical result
was reported to the user as "a pristine fork, no local commits at all", and the work being
asked about was on an unmerged branch off `newgraph`.

Enumerate the branches before comparing anything:

```bash
gh api repos/ORG/REPO/branches --jq '.[] | "\(.name)  \(.commit.sha[0:8])"'
gh pr list --repo ORG/REPO --state all --limit 20 \
  --json number,state,headRefName,baseRefName \
  --jq '.[] | "#\(.number) \(.state) \(.headRefName) -> \(.baseRefName)"'
```

**The PR list is the tell** — a `baseRefName` that is not `main` names the branch the fork
actually develops on. It is also the cheapest way to find the convention, because a fork's
own `CLAUDE.md` documenting the pattern is itself on that branch and invisible from `main`.

Same family as "The probe is broken before the world is" in `code-check.md`: the comparison
ran correctly and answered a question nobody asked. The tell is a result that is *too clean*
for a repo someone just told you has commits in it.

### A destructive setup and its undo must not share one timeout-able command

```bash
git stash -q && Rscript -e 'lint_package()' && git stash pop -q
```

`lint_package()` exceeded the 120 s Bash timeout, the command was killed, and
**`stash pop` never ran** — an entire branch's work sat in the stash with a clean
working tree while a review subagent was concurrently reading those files. Recovered
with `git stash pop`, and only because the next command printed a suspiciously empty
`git status`.

Any `save; do-slow-thing; restore` chain has a window where a timeout, a crash or an
interrupt leaves the system in the saved state, and the longer the middle step the
wider it gets. `&&` does not help — the undo simply never executes.

- **Never stash to compare against a baseline.** `git show HEAD:path > /tmp/x` is
  non-destructive and answers the same question.
- Where a save/restore genuinely is needed, put the restore in a `trap … EXIT` (one
  handler per signal — see "A second `trap … EXIT` replaces the first" below), or run
  the two halves as separate commands so a timeout cannot swallow the second.

### `git checkout <path>` restores from the index, not from HEAD

After a `git add`, `git checkout <path>` reinstates the broken *staged* copy — so the
"fix" reproduces the failure and reads as though the edit was wrong.
`git checkout HEAD -- <path>` is the one that means what people expect.

### A value validated with one numeric grammar and consumed with another

`test` and `case` read base 10. `$(( ))` reads a leading zero as **octal**. GNU `seq`
silently produces nothing for a descending range (BSD `seq 0 -1` prints `0` and `-1`,
so the same input fails differently on a stock Mac). Three predicates disagreeing
about the grammar gave five distinct failures of one guard (link#250, 2026-09-01 —
four review rounds, each finding a defect inside the previous round's fix):

| input | what happens |
|---|---|
| `0` | GNU `seq 0 -1` empty → loop body never runs → hang |
| `abc` | `[ abc -lt 1 ]` **exits 2**; `if` reads that as false → falls through → hang |
| `08` | `$((08-1))` → "value too great for base" → hang |
| `010` | **silently** becomes 8; the banner reports 10 |
| `99999999999999999999` | `10#` wraps to 7766279631452241919 → passes `>= 1` → hang |

Fix by **normalising once**, not by adding a fourth predicate: shape check
(`case ''|*[!0-9]*`), then `x=$((10#$x))`, then a bounded range. Put it where every
caller meets it, not only on the CLI flag that happens to have its own validation.

The complete candidate set for a string consumed as a count is **shape / sign / value
/ base / magnitude**. Enumerate all five or the class recurs one axis over.

### `wait` with no argument waits for every background job in the shell

Not just the ones the function started. A pool that ends with a bare `wait` silently
couples itself to whatever else the caller has backgrounded, and hangs outright if any
of them is long-lived — with all its own work already finished and nothing on screen
to say so. A 2-second sampler loop in a benchmark script wedged a pool whose four jobs
had all completed (link#250).

Track the pids you spawn and wait on those:

```bash
recompute_one "$w" &
all_pids="$all_pids $!"
...
for pid in $all_pids; do wait "$pid" 2>/dev/null || true; done
```

### A `pgrep -f` waiter matches its own command line, so it never exits

`until ! pgrep -f "job" >/dev/null; do sleep 30; done` is the obvious way to wait for a
background job, and it cannot terminate: the loop's **own** command line contains the
string `job`, so `pgrep -f` finds the waiter itself and the condition stays true after
the real process is long gone.

It fails quietly and expensively. Nothing errors, the job finishes normally, and the
waiter spins until something kills it — so a session that launched three of them for
three stages sits waiting on a stage that ended, with the log on disk saying `Done`.
Measured 2026-09-06 in rtj: two waiters were still looping after their refresh had
written its completion block, and `pgrep -fl` showed each matching only *the other
waiter and itself*.

Wait on the **PID**, which cannot self-match:

```bash
nohup Rscript long_job.R > run.log 2>&1 &
PID=$!
while kill -0 "$PID" 2>/dev/null; do sleep 30; done
```

`kill -0` tests for existence without signalling. Note the `&`-binding trap above —
assign `PID` on its own line, and start the long command alone, or `$!` is the
subshell's.

Where only a pattern is available, exclude the waiter explicitly (`pgrep -f "job" |
grep -v $$`), or match on something the loop's own text does not contain — but the PID
is the form that has no failure mode.

**Diagnose it with `pgrep -fl`, not `pgrep -f`.** The count alone says "still running";
the listing shows *what* matched, and a waiter matching itself is obvious the moment
you can read the command lines. This is the refinement of `always-away.md`'s "check
`pgrep` before declaring a run dead": checking is right, and looping on the check is
where it goes wrong.

### `timeout` is GNU coreutils — a portable deadline

An assertion around something that might hang can only pass or hang, never fail
(`code-check.md`, "Restore the bug and prove the guard fires"). The deadline that
makes it able to fail cannot be `timeout`: that is GNU coreutils and absent from a
stock macOS, so depending on it makes the assertion skip on the machine it was
written for. Portable:

```bash
with_deadline() {  # $1 = seconds, rest = command; returns 124 on deadline
  local secs="$1"; shift
  "$@" & local cmd_pid=$!
  ( sleep "$secs"; kill -9 "$cmd_pid" 2>/dev/null ) & local killer=$!
  local rc=0; wait "$cmd_pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true; wait "$killer" 2>/dev/null || true
  [ "$rc" -ge 128 ] && return 124
  return "$rc"
}
```

Distinguish 124 from a real non-zero, or a hang gets reported as a refusal. Same
reasoning as `--max-time` on a fan-out `curl` above: fail loud rather than hang quiet.

### `aws s3 cp` cannot tell a missing key from a missing bucket

Measured 2026-08-31, aws-cli 2.34.34. Both cases return **exit 1** with identical text:

```
fatal error: An error occurred (404) when calling the HeadObject operation: Key "..." does not exist
```

So absence cannot be inferred from a transfer command. Any "the object isn't there
yet, so create it" branch built on `s3 cp` also fires on a typo'd bucket or prefix —
and then writes the "first" copy somewhere nobody will look for it.

Establish absence positively with two probes: `s3api head-bucket` (reachable? exit 0
vs 254) then `s3api head-object` (present? exit 0 vs 254). Only *reachable AND
missing* is a confirmed absence. `head-object` returns **403, not 404**, for a missing
key when the caller lacks `s3:ListBucket`, so 403 must not count as absence either —
or a permissions problem reads as a first run.

Related: match error tokens anchored — `\(PreconditionFailed\)`, `\(412\)`, `\(404\)`
— never a bare `412`/`404` substring, which matches any request id or byte count
containing those digits.

### A verification command can be shadowed by a shell function or alias
- The shell is initialized from the user's profile, so `diff`, `grep`, `ls`, `cat` and friends may resolve to a wrapper rather than the binary you assume. Measured 2026-08-24 in gq: `diff` was a shell **function** delegating to `git diff`, so `diff -q a b` — a byte-comparison in an idempotency check — died on ``unknown switch `q' `` and the step reported **NOT IDEMPOTENT** for two files that were in fact identical.
- That direction is survivable because it is loud. The dangerous one is a wrapper that exits 0 on a comparison it never performed, which reads as "verified".
- For anything whose output you are about to treat as evidence, bypass the lookup: `command diff`, `\diff`, or a tool with no common wrapper — `cmp -s` for byte-equality, `md5` / `sha256sum` for a value you can print. Printing the digest beats printing a verdict: it stays checkable after the fact.
- `type <cmd>` tells you what you actually have. Worth running the first time a verification step returns something surprising, before believing the surprise.

### psql does not interpolate `:'var'` inside a dollar-quoted string, and `\quit N` exits 0

Two traps in the same file type, both of which read perfectly and fail at run time.

**Interpolation.** psql substitutes its `-v` variables in the query buffer, but a
dollar-quoted body is a *string literal* to it, so nothing inside `$$ … $$` is
substituted. The natural form dies with a message that points at SQL syntax rather
than at the quoting layer:

```sql
DO $$ DECLARE v text := :'run_uid'; BEGIN ... END $$;
-- ERROR:  syntax error at or near ":"
```

Pass parameters through session settings instead, set outside the block:

```sql
SELECT set_config('app.run_uid', :'run_uid', false) \gset
DO $$ DECLARE v text := current_setting('app.run_uid'); BEGIN ... END $$;
```

**`\quit` takes no exit code.** `\quit 1` warns `extra argument "1" ignored` and
exits **0** (measured, psql 16.10 and 18.3). So a guard written as

```
\echo 'FATAL: …'
\quit 1
```

prints FATAL in red and then reports **success** — fail-toward-pass on precisely the
branch that exists to stop a silent zero-row pass. Raise instead, with
`\set ON_ERROR_STOP on` at the top of the file:

```sql
DO $$ BEGIN RAISE EXCEPTION 'no run_uid supplied'; END $$;
```

Related, same family: a `.sql` file whose checks are all bare `SELECT`s has no exit
status at all — a human reading output is the only verdict. If the script is invoked
by anything, at least one check must `RAISE`.

Caught 2026-09-01 in link#262, in a verify script whose own header advertised that it
"exits non-zero on a real failure".

### A second `trap … EXIT` replaces the first

`trap` registers **one** handler per signal. Registering cleanup for a temp file and
then cleanup for a database schema leaves only the second — the first is silently
discarded, and nothing warns.

```bash
trap 'rm -f "$TMP"' EXIT
trap 'drop_schema' EXIT        # the rm never runs again
```

One handler, both jobs:

```bash
cleanup() { rm -f "$TMP"; [ "$MADE" = 1 ] && drop_schema; }
trap cleanup EXIT
```

**Arm it before the thing it cleans up exists**, guarded by a flag. Registering the
trap *after* the resource is created leaves a window in which `set -euo pipefail` can
exit with no handler installed — and that window is exactly where a failure lands.

The two halves interact, which is how this survives review: adding `ON_ERROR_STOP` to
a psql call can turn a previously exit-0 setup step into an abort *inside* that
window, reopening a leak the early trap was added to close. Both changes individually
right; neither measured against the other. Caught 2026-09-01 in link#262.

### A `local` statement cannot read a variable it is assigning in the same statement

`local a="$1" lab="$2" m="/tmp/marker_${lab}"` expands `${lab}` **before** `lab` is
assigned. Under `set -u` that is a fatal `lab: unbound variable`; without it, the
variable is silently empty and whatever it was building points at the wrong path.

It reads as one tidy declaration, which is the whole trap — the same three
assignments on three lines are correct.

```bash
run_one () {
  local a="$1" lab="$2" m="/tmp/fp_${lab}"   # WRONG: ${lab} is empty here
  local a="$1"                                # right: one per line
  local lab="$2"
  local m="/tmp/fp_${lab}"
}
```

**And the wrapper reported exit 0.** Caught 2026-09-02 in floodplains: the function
aborted on its first call, the script died before its `ALL RUNS DONE` line, and the
background task notification still said *completed (exit code 0)*. The only signal was
one line in a redirected output file. This is "A wrapper's exit is not the work"
(`code-check.md`) meeting a `local` bug — gate on the in-band marker (`ALL RUNS DONE`), never on the wrapper.

Same shape for `declare`, `readonly`, and `export` with multiple assignments, and for
`local -r`. If two names on one line have a dependency between them, they belong on
two lines.

### Inside an `EnterWorktree` session, the Bash tool refuses command text that names git

The harness applies an isolation guard to a session that entered a worktree: *"a
worktree-isolated session's git operations must target its own worktree."* It decides by
scanning the **command text**, not by what the command would do. Measured 2026-09-02 on
soul#166, four refusals in one session:

| refused | why |
|---|---|
| `cd "$WT" && git … && …` | compound with `cd` |
| `git -C "$WT" archive … \| tar -x` | a pipe containing git |
| `git -C "$WT" add a b && git -C "$WT" commit …` | two git commands chained |
| `python3 - <<'PY' … "git worktree" … PY` | a heredoc whose *prose* contained the word |

The last one is the trap: a multi-file text edit whose replacement strings happen to
mention git is refused for the mention, and the error reads as a git problem.

What works: one plain command per call, absolute paths (the shell cwd resets between
calls, so relative paths resolve outside the worktree after the first), `git -C
<worktree-path> <verb>`, and `--output=<file>` in place of pipes — `git diff --output=…`,
`git archive --output=…`. For edits that mention git, **write the script to a file with the
Write tool and run `python3 <path>`**: the command text then names no git. Do not spend
turns on phrasings; it is a property of the harness, not a setting.

Three more shapes, measured 2026-09-03 on soul#168, and the second is the one that
costs something:

- A `for` loop whose body runs `gh` with a path built from a shell variable is refused
  too — *"runs gh with a value computed at runtime … cannot be shown not to be git"*.
  Spell each `gh` call out with literal absolute paths.
- **`gh pr merge` from inside a worktree merges, then errors** — `fatal: 'main' is
  already used by worktree at …` — because its post-merge `git checkout main` cannot
  run. The merge has landed and the error says nothing about it; `--delete-branch` has
  *not* deleted the remote branch. Same recovery as the half-succeeding `--delete-branch`
  under `gh` CLI above: read `gh pr view --json state,mergeCommit`, then `git ls-remote
  --heads origin <branch>`, and delete by hand after `merge-base --is-ancestor`.
- `ExitWorktree(remove)` refuses while the local default branch is behind origin,
  because it counts the just-merged commits as unmerged. Exit with `keep`, `git pull
  --ff-only` on main, then `git worktree remove <path>` and `git branch -d <branch>` —
  lowercase `-d`, so git itself checks the branch is merged.

### A `git filter-repo` seed carries the source repo's tags, and a path sed misses the language's path constructor

Two traps from seeding one repo out of another's history (fish_passage_template_reporting#236,
2026-09-02), both silent.

- **Tags survive the path filter** whenever the commit they point at does. The first
  `git push -u origin main` of the filtered clone pushed three of the source repo's release tags
  into the new repo, where they squat on the names its own first releases need — the stray-tag
  trap in the seeding direction. `git tag -l` on the filtered clone before pushing; delete what is
  not the new repo's own.
- **`sed 's#data/planning#data#'` rewrites the string form only.** Every
  `file.path("data", "planning", ...)` — eight sites in four scripts — survived, and the grep that
  followed the sed reported zero remaining hits because it searched for the same string. Nothing
  static found it; running one consumer did (it aborted writing to a directory that no longer
  existed). After any path repoint, grep the constructor form too (`"planning"` as a bare
  segment, `os.path.join`, `Path(...) /`), and run one script that writes.

### `git check-ignore -v` prints the matching pattern, and its exit status is not a per-file verdict

`-v` reports the **last matching pattern**, negations included. So a path un-ignored by a `!` rule
prints a line *and exits 0* — which reads as "still ignored" when the file is in fact tracked.

Measured 2026-09-04 in stac_floodplains_bc, adding `!data/readme_items.rds` under `data/*.rds`:

```
$ git check-ignore -v data/readme_items.rds
.gitignore:9:!data/readme_items.rds   data/readme_items.rds     # exit 0 — but NOT ignored
```

`planning.md`'s "expect no output" is right for a plainly-unignored path (nothing prints, exit 1);
it does not hold once a negation is involved. Test each path and branch on the status:

```bash
for f in a b c; do git check-ignore -q "$f" && echo "IGNORED $f" || echo "ok $f"; done
```

And **not-ignored is not tracked.** The predicate that matters for anything a reader will fetch is
`git ls-files --error-unmatch <path>` — see "A link to a repo-hosted artifact must be *tracked*"
in `code-check.md`.

### `sips -Z` scales up as well as down

`sips -Z N` resamples so the longest side is N — in **either** direction. Run over a mixed set to
"shrink images for the web", it enlarges everything already smaller than N, and the batch can come
back barely smaller than it started.

Measured 2026-09-04 over 104 images: `-Z 1400` took a 934x700 PNG **up** to 1400x1049, and the set
went 60 MB → 51 MB where the intent was a quarter of that. Guard on the source dimension:

```bash
mx=$(sips -g pixelWidth -g pixelHeight "$f" | awk '/pixel/{if($2>m)m=$2}END{print m+0}')
if [ "$mx" -gt 1200 ]; then sips -Z 1200 "$f" --out "$o"; else sips "$f" --out "$o"; fi
```

The tell is a resize pass whose total barely moves. `-resampleHeightWidthMax` behaves the same way;
ImageMagick's `convert -resize '1200x1200>'` is the form that only shrinks.

### Assert capabilities, not versions — a tool upgrade can remove one silently

A tool upgrade across the fleet can remove a capability without reporting failure.
Version numbers do not predict the loss, exit codes stay zero, and the break surfaces
later somewhere unrelated. Four instances on one host in one session (2026-08-20):

- **GDAL silently lost its Parquet driver.** `brew upgrade` moved `apache-arrow` out
  from under a compiled link in libgdal. `ogr2ogr --version` still answered; `Parquet`
  simply stopped appearing in `--formats`. Exit 0 throughout.
- **GDAL 3.13.3 turned a GeoPackage-extension warning into a hard error.** Identical
  source: 0 failures on 3.13.0, 10 on 3.13.3. Package CI was green, so the repository
  alone could not surface it (rfp#149).
- **A checkout sat 93 commits behind** while `git status` reported in-sync, because it
  had not fetched; a package installed from it was reported as "latest".
- **Uncommitted work sat 15 days on one machine**, staged and never committed,
  invisible to every other host.

Two of these were mis-reported in-session before being caught — including an A/B test
"proving" a regression whose comparison keg was itself broken (a missing dylib meant
`ogr2ogr` never ran, producing a coincidentally identical failure count). The common
shape is real state with no signal.

- **Probe the operation, not the version.** `ogr2ogr --version` says nothing about
  whether Parquet works; `ogr2ogr -f Parquet` round-tripping two features does. Every
  check that matters performs the thing the fleet depends on: Parquet write and
  read-back with field types preserved, the PostgreSQL vector driver present, COG
  creation, `mergin push` incrementing the server version, a package's exported
  functions callable, QGIS at or above what the report templates target.
- **Probe, upgrade, re-probe, diff.** Never a bare `brew upgrade` (or `pak::pak`, or
  `uv tool upgrade`) on a working host. A capability that flips pass→fail becomes a
  loud failure with a named rollback instead of a silent one. Same reasoning as "A
  wrapper's exit is not the work" in `code-check.md` — a package manager is another
  wrapper that reports success while the work did not survive.
- **Declare what a repo needs.** Repos that shell out to external tools state the set
  (GDAL with COG support, `aws`, `jq`, `python3` for the STAC repos) so "can this host
  run this?" is answerable before a long job starts rather than halfway through.
- The probe also flags checkouts behind origin and uncommitted work older than N days —
  neither is visible from any single machine's routine output.

The honest failure mode is that this rots because nobody runs it: run the probe at
session start beside the CI scan, schedule it unattended, and commit the results per
host so any machine can see what the others measured. Implementation is kdot#37 (soul#69).

### An amd64-only image needs `--platform`, and it works on your machine because it is cached

`docker run` resolves from the local image store before it reaches a registry, so on an
arm64 Mac an amd64-only image runs fine once pulled — **and the command that pulled it is
not necessarily the one in the code.** Measured 2026-09-05, macOS/arm64:

```
$ docker run --rm qgis/qgis:4.2 echo hi
docker: no matching manifest for linux/arm64/v8 in the manifest list entries
$ docker run --rm --platform linux/amd64 qgis/qgis:4.2 echo hi
hi
```

It fails on a clean machine, a new laptop, CI, or after `docker system prune` — never on
the machine it was written on. The tell is a `docker run` in code beside a `docker pull`
in a README or a test helper, where only one carries the flag.

That split is the usual shape: rfp's **test harness** passed `--platform linux/amd64` and
resolved a pinned digest, while three **runtime** call sites did neither, so the shipped
functions worked only while a rolling tag happened to be cached (rfp#282). A container
invocation in test code and in runtime code are two invocations of one operation, and only
the test one runs in CI — build the argv in one place.

Two adjacent settings worth reading before blaming emulation for being slow, both **off by
default** and both one checkbox:

```bash
python3 -c "import json;d=json.load(open('$HOME/Library/Group Containers/group.com.docker/settings.json'));
print({k:d.get(k) for k in ['useVirtualizationFrameworkRosetta','useVirtualizationFrameworkVirtioFS']})"
```

`useVirtualizationFrameworkRosetta` false means x86_64 containers run on QEMU when Rosetta
is available on the host; `useVirtualizationFrameworkVirtioFS` false puts bind mounts on
gRPC-FUSE, which is the slow path for the many-small-file reads a container workload
usually opens with. Check the Docker Desktop version too — 4.17.0 was still installed on a
macOS 26.2 machine, so the Rosetta support present was its earliest form.

### `s3cmd ls` given several paths lists only the FIRST, and says nothing

```
$ s3cmd ls s3://b/x/README.md s3://b/y/README.md
2026-09-06  7258  s3://b/x/README.md          <- y/ never queried
$ s3cmd ls s3://b/y/README.md
2026-09-06  4280  s3://b/y/README.md          <- it was there all along
```

Exit 0, no warning, no "extra arguments ignored". So a spot-check written to confirm
two objects reports the second as **absent**, which reads as a partial upload — the
expensive direction, because the natural next move is to re-run the transfer or start
hunting a bug in the sync.

Measured 2026-09-06 verifying a 205 MB s3cmd sync to DigitalOcean Spaces: both files
were present and byte-identical, and only the per-path re-query showed it. Same family
as `\quit N` exiting 0 under psql — a CLI silently discarding an argument it accepted.

Query one path per call, or use `--recursive` on the common prefix and `grep`, which
sees every key:

```bash
s3cmd ls --recursive s3://b/prefix/ | grep README
```

And prefer a **set** comparison to a count when verifying a sync. A destination that
legitimately holds more than the source — older objects, anything deleted locally by a
sync that does not `--delete-removed` — makes `remote >= local` pass trivially; the
property you want is that every local file has a remote object, which is `comm -23`
over two sorted key lists. Strip to relative keys with `sed -E 's|^.*(s3://)|\1|'`
rather than taking the last whitespace field: object names contain spaces
(`Track_27-SEP-22 155217.gpx`).


### `grep -c` prints the count AND exits 1 when it is zero

So the natural fallback appends a second line rather than supplying a default:

```bash
$ n=$(grep -c '^# ' file-with-no-headings || echo 0)
$ printf '[%s]\n' "$n"
[0
0]
$ [ "$n" -eq 1 ]
bash: [: 0
0: integer expression expected      # exit 2
```

`[` exiting 2 takes the same branch as false, so a guard written this way usually
*refuses* — correct by luck, not by design, and the refusal message reports its count
across two lines. The direction is not guaranteed: invert the test (`[ "$n" -ne 1 ] && …`)
and the same input passes.

Measured 2026-09-12 in soul#218, in a guard checking that each internal-only convention
has exactly one `# ` heading.

- Assign without the fallback — `grep -c` already prints `0` — then normalise the shape
  once: `case "$n" in ''|*[!0-9]*) n=0 ;; esac`. That also covers the missing-file case,
  where grep prints nothing and exits 2.
- `|| n=0` as an *assignment* is safe; `|| echo 0` inside a command substitution is not.
  The two read alike, which is the trap.
- Same family as "A value validated with one numeric grammar and consumed with another"
  above: normalise once rather than adding a predicate.


# Code Check — Spatial

terra, sf, bcdata, GDAL/OGR CLIs. Same gate as `cartography.md`, verbatim: report
repos do spatial work without being packages, so this loads wherever a bookdown
project, anything carrying a `DESCRIPTION`, or a QGIS project exists.

### Negative coordinates get parsed as CLI options — every BC bbox hits this
- BC longitudes are all negative, so `--bounds -124.73 49.485 -124.595 49.565` fails with `Error: No such option: -1`. The parser sees a leading `-` and reads it as a flag. Affects click/argparse-based tools generally, not just bcdata.
- Use the **bracketed single-argument form with `=`**: `--bounds="[-124.73, 49.485, -124.595, 49.565]"`. The `=` keeps the value attached to the option, and the brackets keep it one token. A bare comma-joined string (`--bounds "-124.73,49.485,..."`) is not equivalent — it threw an unrelated traceback.
- Same class: any CLI taking negative numbers (elevation offsets, `--nodata -9999`, buffer distances). Reach for `--opt=value` by default rather than discovering it per-tool.

### bcdata: an empty result raises AttributeError, it does not return an empty collection
- A bbox query matching nothing exits non-zero with `AttributeError: You are calling a geospatial method on the GeoDataFrame, but the active geometry column to use has not been set.` — geopandas complaining about an empty frame, several layers below the query.
- The trap: that reads as a broken query, not as "zero features," so a real and meaningful **absence** looks like tooling failure. Don't conclude a layer is unavailable from this error.
- **Prove absence before acting on it.** Re-run the same query against a wider bbox known to contain features; if that returns rows, the empty result is real data. Caught 2026-08-22 establishing that BC's FTEN trail layers are genuinely empty over an entire island — the wider-box control returned 851 features, which is what turned "the query is broken" into "the province has no trails here."
- Wrap counts defensively: `try: json.load(...)` around the parse, and treat the failure as `0 features` only after the wider-box control passes.

### bcdata: `BBOX()` rejecting a bbox that is a length-4 numeric vector — seen once, unquoting fixed it

The two entries above are the bcdata Python CLI; this is the R package. Observed once
(fly#35, bcdata version not recorded):

```r
bb <- unname(as.numeric(sf::st_bbox(sf::st_transform(aoi, 3005))))
length(bb)   # 4
bcdata::filter(qry, bcdata::BBOX(bb, crs = "EPSG:3005"))
#> Error: 'coords' must be a length 4 numeric vector
bcdata::filter(qry, bcdata::BBOX(!!bb, crs = "EPSG:3005"))   # worked
```

**The mechanism is not established.** `filter()` on a bcdc promise goes through
dbplyr's translation, and on bcdata 0.5.3 / dbplyr 2.6.0 a global or function-local
`bb` translates correctly with or without `!!` (measured 2026-09-03, no network). So
this is a diagnostic hint, not a rule: if that error appears for a vector that is
numeric and length 4, try `!!` before rewriting the bbox code — the error names the
right argument and a constraint the input satisfies, so it reads as a data problem
and cost two failed attempts and an inspection of `st_bbox()` output. Same family as
`code-check-shell.md`'s `Rscript -e` entry: *when a command returns a surprising
result, suspect the quoting layer before the code*. If it recurs, record the bcdata
and dbplyr versions and the calling context, which is what would turn this into a
rule.

### terra: operator dispatch and edge cases in package code
- **SpatRaster `%in%` is not dispatched when terra is *imported* (only when *attached*).** Inside a package (terra in `Imports`, used via `::`), `some_raster %in% vec` falls through to base `match()` and errors with `'match' requires vector arguments`. A `library(terra)` smoke test passes (attaching installs the S4 method), so the bug hides until package context. Use `terra::subst(x, from, to, others = ...)` or `terra::classify()` for code-set membership/masking instead of the `%in%` operator. Same trap for any operator terra defines via S4 that base also defines as an ordinary function. (drift#34)
- **`terra::freq()` errors on an all-NA raster** (`replacement has length zero`) rather than returning a 0-row table. Any path that can yield an all-NA layer (an impossible filter, everything masked out) must guard: `f <- tryCatch(terra::freq(r), error = function(e) NULL)`, then treat `NULL`/0 rows as "no values". Don't assume the empty case gives `nrow(freq(r)) == 0`. (drift#34)
- **`terra::minmax()` reports *cached* statistics, not computed ones.** It defaults to `compute = FALSE` and returns `Inf`/`-Inf` for any raster whose min/max have never been calculated — which is every file-backed raster until something touches it. A guard written on top of it therefore fires on real data:
  ```r
  r <- terra::rast("a_richly_varied_image.png")
  terra::hasMinMax(r)              # FALSE FALSE FALSE FALSE
  terra::minmax(r)                 # min Inf ... / max -Inf ...
  terra::minmax(r, compute = TRUE) # min 0 0 0 0 / max 11 18 18 255
  ```
- The trap is that it *appears* to work, because plenty of upstream operations compute min/max as a side effect — `terra::crop()` does, so anything arriving via `maptiles::get_tiles(crop = TRUE)` has them. Correct by accident, through an internal that is not a contract. Pass `compute = TRUE`, and test the guard against a **file-backed** fixture: one built by `rast(vals = ...)` is in memory, has statistics cached, and cannot reach this. (gq#57, 2026-08 — a flat-tile detector called every file-backed raster flat, and the whole fixture set shared the one property that hid it.)

### terra: `extract()` returns no row for ground beyond the raster, and counts cells by centre

- Two traps in one call, and both make a partial result look complete.
- **Ground past the raster's *extent* yields no row at all**, not an `NA` row. So measuring
  coverage as the non-`NA` share of what came back reports a footprint hanging half off the
  data as fully covered. A raster cropped to an AOI is exactly this shape — no `NA`
  interior, it simply stops — which is how most people obtain one, so this is the common
  case rather than the exotic one. Measured in fly#9: every frame reported coverage `1`
  while the sampled elevation was wrong by 83 m.
- **`extract()` takes a cell when its *centre* falls inside the polygon.** So a denominator
  computed from the polygon's *area* in cell units is a different measurement from the
  numerator, low by roughly `2/k` for a polygon `k` cells across. On a raster with no
  missing data at all and room to spare, that reported 91% coverage at 900 m cells.
  Count the denominator the same way — cells on a grid aligned to the raster's own via
  `terra::align()` — or use `exact = TRUE` and accept it being ~23x slower.
- Do the alignment **per feature**, not once over their union: the union's bounding box
  spans the whole set, so one outlying feature sizes the grid to the *gap*. Two points
  700 km apart went to 243 million cells against 16 thousand counted separately.
  `terra::extend()` has the same failure — it sizes to the union of raster and features.
- Fine test rasters hide all of this. A 30 m grid makes the `2/k` error invisible, and a
  fixture whose CRS matches the data leaves every reprojection branch unexecuted. Test at
  two resolutions, with anisotropic cells, and in a geographic CRS.

### A `...` constructor may discard trailing arguments based on the class of the first one

- A constructor that takes `...` is free to branch on **what its first argument
  is** and build the result from that alone. Everything you passed after it is
  then dropped — silently, with no warning and no error, because from the
  constructor's point of view nothing went wrong.
- The live case is `sf::st_sf()`, whose attribute frame is chosen by a chain
  ending:
  ```r
  df = if (inherits(x, c("tbl_df", "tbl"))) x
       else if (length(x) == 1) data.frame(row.names = row.names)
       else if (!sfc_last && inherits(x, "data.frame")) x
       else if (sfc_last  && inherits(x, "data.frame")) x[-all_sfc_columns]
       else if (inherits(x[[1]], c("tbl_df", "tbl"))) x[[1]]     # <-- keeps ONLY arg 1
       else cbind(data.frame(row.names = row.names), as.data.frame(x[-all_sfc_columns], ...))
  ```
  So `st_sf(df, a = , b = , geometry = )` keeps `a` and `b`, and
  `st_sf(tbl, a = , b = , geometry = )` throws them away. **Same call, same
  data, different class — different columns out.**
- **The failure is invisible for as long as your fixtures share one class.** In
  fly#35 four columns recording how each airphoto footprint had been sized never
  reached a single caller of the package's own documented data source, because
  `bcdata::collect()` returns a tibble and every fixture in the package read back
  as plain `sf, data.frame`. Two releases shipped that way with a green suite:
  geometry and every downstream number stayed correct, and only the audit trail
  went missing, so nothing errored and nothing looked wrong.
- **Fix: build the frame first, then hand the constructor one argument.** The
  columns are then inside the argument the branch keeps, whichever branch it is,
  and the caller's class is untouched:
  ```r
  attrs <- sf::st_drop_geometry(x)
  attrs$a <- a
  attrs$b <- b
  result <- sf::st_sf(attrs, geometry = g)      # not st_sf(x, a =, b =, geometry =)
  ```
  Coercing instead — `st_sf(as.data.frame(st_drop_geometry(x)), a =, ...)` — also
  restores the columns, but downgrades a tibble caller's class as a side effect.
  Prefer the version that changes one thing.
- **Test by sweeping the class axis, not by adding cases along it.** Assert
  identical names *and values* across plain / tibble / grouped / vendor-classed
  shapes of the same data. Read the tibble honestly (`st_read(as_tibble = TRUE)`)
  rather than overwriting `class()`, and assert that premise inline so a future
  upstream change fails by naming the real cause.
- **Do not over-state what survives.** `sf::st_transform()` moves `sf` to the
  front of the class vector, so `bcdc_sf, sf, ...` returns `sf, bcdc_sf, ...`.
  The class *set* is carried; the order is not. An
  `expect_identical(class(out), class(in))` written from three shapes that all
  lead with `sf` passes, and then fails on the one real caller you wrote it for.
- Swept 2026-08-29 across all 61 repos in `~/Projects/repo` — 1500 `.R` files and
  389 purled `.Rmd` chunks, parsed with R rather than grepped, looking for
  `st_sf()` with a non-literal first positional argument plus trailing column
  arguments. **`fly` was the only instance.** A regex misses this: the original
  defect was a multi-line call. Validate any such scanner against both known
  answers before believing a clean result — the pre-fix file must be flagged and
  the fixed one must not, or "no hits" is indistinguishable from a broken scan.
- Generalizes past `sf`. Ask it of anything taking `...`: *does this constructor
  decide what to keep by looking at the first argument?* Same shape in any
  language where a variadic builder dispatches on an argument's type.

### terra: `mask()` is `touches = TRUE`, so two "clip to the polygon" routines disagree by a cell ring

Swapping one polygon clip for another looks like a refactor and is a **methodology
change**. `terra::mask()` defaults to `touches = TRUE` — every cell the polygon
touches is kept — while most other clips rasterize at **cell centre**:
`terra::rasterize()` without `touches`, `gdalcubes::filter_geom()`, and
`gdal_rasterize` without `-at`. Nothing errors, nothing warns, and the values
agree exactly where both have data. Only the *footprint* moves.

```r
mask(r, v)                  # 150 cells   <- the default
mask(r, v, touches = FALSE) # 122 cells
# true polygon area: 123.4 cells
```

The magnitude is a perimeter-to-area ratio, so it is worst exactly where these
clips get used — thin corridors, floodplains, riparian buffers. Measured
2026-09-01 in drift#47 on a 3.3 km reach: **−15.5%** of the analysed footprint
(49,244 → 41,608 cells) from a change whose entire stated purpose was to remove a
redundant step. Against a parity tolerance of ±1 ha on 943 ha, that is 30–150×.

- **Do not describe a clip without naming its rule.** drift's roxygen said "cells
  whose centre falls outside become `NA`" for a `terra::mask()` call, and was
  wrong for two releases. Anyone reasoning about boundary hectares from that doc
  was off by a ring.
- **An axis-aligned fixture cannot catch this.** A rectangle on a cell boundary
  makes both rules agree, so the test passes for nothing. Use a polygon with
  fractional coordinates and no edge parallel to the grid, and assert the premise
  beside the property — `expect_gt(touch, centre)` — so a future terra default
  change fails by naming the real cause.
- **To swap in a cell-centre clip without moving the footprint**, buffer the
  polygon by `>= res * sqrt(2)/2` first: if a polygon intersects a cell square,
  that cell's centre is within a half-diagonal of it, so the buffered
  cell-centre footprint is a guaranteed superset of `touches = TRUE`. Then keep
  the `mask()` to trim back, and the output is byte-identical.

Generalises past terra: whenever two libraries both offer "clip raster to
polygon", assume they disagree at the boundary until measured. Count the cells.

### terra: `sources()` on a derived raster is `""` or a random temp path, never the input

- A raster that came out of `crop()`, `project()`, `mask()`, or arithmetic is **derived**, so it
  has no source file. `terra::sources()` returns `""` when the result fits in memory — and a
  **random per-process temp path** when terra spills to disk:
  ```r
  sources(rast(file))                      #> /…/dem.tif
  sources(crop(...))                       #> ""    inMemory TRUE
  sources(project(...))                    #> ""    inMemory TRUE
  terraOptions(todisk = TRUE); sources(crop(...))
                                           #> /private/tmp/RtmpFcjh9X/spat_ad2f168560ce_44335_Sskvi….tif
  ```
- The reach for it is provenance — *"what file did this raster come from?"* — and both branches
  answer wrongly. The empty branch is survivable: it reads as absent and a fallback fires. **The
  disk branch is the dangerous one**, because a temp path is a plausible-looking string that
  differs on every run and every machine, so it silently destroys byte-stability in whatever
  record it lands in, and nothing flags a value that *looks* like a path.
- Worse, which branch you get depends on **size**: small AOIs stay in memory and large ones spill.
  So a fixture proves the empty case and production hits the poisoned one.
- If a function crops or reprojects before returning, `sources()` cannot answer this **at all** —
  do not reach for it. Record the resolver plus the raster's measurable geometry (`crs`, `res`,
  `ncell`, `ext`), or have the package expose what it resolved (`attr(out, "source") <- source`).
- Caught 2026-09-01 in floodplains#33: `flooded::fl_dem_aoi()` builds its MRDEM-30 URL inside its
  body, so `formals()` does not expose it either. `sources()` looked like the way to measure the
  output instead of restating the input — the right instinct, applied to an object that cannot
  carry the answer.

### `sf::st_as_binary()` returns a LIST of raw vectors, so `is.raw()` on it is FALSE

The obvious way to feed WKB into a canonicalizer is a `is.raw(x)` branch that hex-encodes
it. That branch never matches: `st_as_binary()` returns a **list** of raw vectors classed
`"WKB"` — one element per feature — so `typeof()` is `list` and `is.raw()` is `FALSE`.

```r
w <- sf::st_as_binary(sf::st_geometry(g), endian = "little")
class(w); typeof(w); is.raw(w)      # "WKB"  "list"  FALSE
```

Branch on `is.list()` **before** any vector branch and recurse, or the geometry member
falls through to whatever the numeric/character fallback does — which either errors or,
worse, hashes a stringified list. Join the per-feature hex on a separator so two feature
*orderings* of the same set still key apart.

Nothing else is lost by hex-encoding the raw content: Z and M dimensions live in the WKB
geometry **type code**, not in an R attribute, and an empty geometry has its own distinct
bytes. The `"WKB"` class attribute and `endian = "little"` are constants at the call
site, so dropping them from the hash removes no distinction — and the hardcoded endian is
why such a key is already platform-independent.

Caught 2026-09-03 in drift#48, before shipping, by a reviewer rather than by a test — a
raw-only branch reads as obviously correct.

### Canonicalize geometry before hashing it — ring order and orientation are not fixed by topology

`code-check.md`'s cache-key row prescribes hashing WKB
(`sf::st_as_binary(sf::st_geometry(x), endian = "little")`) rather than the sfc
object. Correct as far as it goes, and it misses a step that sits *before*
serialization: **the geometry itself is not canonical.** Two topologically identical
polygons can differ in ring order, ring orientation, or start vertex, and produce
different WKB and different hashes. A cache keyed that way misses on input that is
geometrically the same; a content hash built that way reports a change where there is
none.

Prior art is `bcgov/FIT_changedetector` (GeoBC's change-detection tool,
`src/fit_changedetector/changedetector.py` at `5adde29`; it was `diff.py` when #95 was
filed and moved seven hours later), whose hash canonicalizes first — two steps, both
load-bearing:

```python
df[df.geometry.name].normalize().set_precision(precision, mode="pointwise")
```

- **`normalize()`** — GEOS canonical form: consistent ring order and orientation.
- **`set_precision()`** — snap coordinates to a stated grid, so floating-point noise
  below the precision of the data does not register as a difference (they default to
  0.01 m, 1e-7 for geographic CRS).

**Record the precision alongside the hash** — a hash at an unstated precision is not
comparable to one at another.

The R side needs care, because the obvious name is wrong. **`sf::st_normalize()` is
not GEOS normalize** — it rescales geometry to the unit bounding box, and recommending
it here would be actively wrong. sf 1.1.2 wraps GEOSNormalize as the internal
`sf:::CPL_geos_normalize(sfc)` with no exported caller (swept the namespace, 2026-09-02).
The exported route is the `geos` package: `geos::geos_normalize()` then
`geos::geos_set_precision()`, then hash the WKB (`sf::st_as_binary()` also takes a
`precision` argument for the second half on its own). Mind the two conventions for the
number: sf's `precision` is a **scale factor** — `st_set_precision(x, 100)` rounds to
0.01 units — while FIT_changedetector's `set_precision(0.01)` and
`geos::geos_set_precision()` take a **grid size**. Record which one the stated
precision means, or a hash comparison across the two is off by orders of magnitude.
Verify whichever you use against both known answers — one pair of polygons that differ only in ring order must hash
equal, and one that differs in a vertex must not (the `geos` sequence passed both with
default arguments, geos 0.2.5, 2026-09-03).

Filed from floodplains#45, where byte-level determinism was the goal and this turned
out to be the durable answer to the adjacent question — "did the *content* change?"

### sf: `st_join(largest = TRUE)` ignores the join predicate
- `sf::st_join(x, y, join = predicate, largest = TRUE)` does **not** use `predicate` to decide matches — with `largest = TRUE`, sf runs `st_intersection(x, y)` and keeps the feature of greatest overlap area, so matching is *always* intersection-based regardless of what `join =` is set to. A function that exposes a configurable predicate AND a largest-overlap mode therefore silently mis-attributes when both are combined: pass `st_within` expecting containment, get anything that merely *overlaps*. Verify against sf source, not the argument list — the `join` arg is accepted and ignored, not rejected. Fix: abort when a non-default predicate is combined with the largest-overlap mode, rather than honouring one and dropping the other. (drift#42)
- Corollary: `largest = TRUE` also drops zero-area geometries from consideration — so a predicate join against **point** or **line** overlays cannot use largest mode at all (no area to compare). Point/line attribution must go through the plain (`largest = FALSE`) predicate path.

### sf: name validation must account for the geometry column
- The active geometry column is a named entry in `names(x)`, but its name is **not fixed** — `"geometry"` from `sf::st_read()` of some sources, `"geom"` from a GeoPackage/PostGIS layer, `"geometry"` or `"_ogr_geometry_"` elsewhere. Code that validates user-supplied column names with `cols %in% names(x)` will happily accept the geometry column, then break downstream (`st_join` drops `y`'s geometry, so a requested "attribute" column silently never appears; a 0-row short-circuit path may instead attach a stray empty sfc). A same-name collision check across two sf objects also misses this when the two layers name their geometry differently. Guard explicitly with `attr(x, "sf_column")` — reject it from the caller-supplied column set. (drift#42)

### sf: `st_intersection()` / `st_difference()` return a GEOMETRYCOLLECTION that QGIS will not draw
- Intersecting or differencing two polygon layers yields a `GEOMETRYCOLLECTION` wherever the inputs *also* touch along a line or at a point. The polygonal part is real and `st_area()` reports it correctly, so every numeric check passes — but QGIS renders the feature as nothing, and it reads to the user as "one row with no geometry".
- The failure is silent in exactly the wrong direction: written to a GeoPackage the layer reports its `geometry_type` as `Geometry Collection` and its area as correct. Nothing errors. It surfaces only when someone opens it.
- Whether it fires depends on the geometry, not the code, so the same call can be clean on one input and a collection on the next. Do not conclude from one working case that a path is safe.
- Fix: `sf::st_collection_extract(g, "POLYGON")` then cast to a single type before writing. Areas are unchanged — the discarded fragments have zero area.
- **Assert it on anything you hand over**, not just the layer you expect to be interesting: no `GEOMETRYCOLLECTION` in `st_geometry_type()`, and `sum(st_is_empty())` is 0, across *every* layer in the file. Caught 2026-08-31 in floodplains only because the user opened the deliverable and asked why a layer looked empty.

### sf: reproject the polygon to get a lat/lon bbox, never transform the projected bbox corners
- To hand a geographic (EPSG:4326) bounding box to a bbox-filtered query (WFS/OGC features, `?bbox=`), reproject the whole AOI **geometry** then take its bbox: `sf::st_bbox(sf::st_transform(aoi, 4326))`. Do **not** compute the bbox in the projected CRS and transform its two corner points — a projected rectangle's edges bow under reprojection, so the corner-transformed box is skewed and generally too short on one axis. The pre-filter then silently under-covers the true extent: features inside the AOI but outside the shrunken box are never fetched, and a downstream clip can only *remove*, never recover them. Symptom: counts a few percent low near the north/south extremes of an area, with no error. A native-CRS bbox filter (e.g. ogr2ogr `-spat <bounds> -spat_srs EPSG:3005`) is unaffected — only the reproject-the-corners step is the bug. (rfp#12)

### An offset regex must be anchored to a time, or a date looks like a zone
- Refusing or stripping a trailing UTC offset with something like `[+-][0-9]{2}(:?[0-9]{2})?$` also matches the end of a plain ISO date: `"2026-08-15"` ends in `-15`, which reads as a −15 hour zone. Require the offset to follow `HH:MM[:SS[.fff]]`.
- The mirror mistake is requiring four offset digits. `±hh` is valid ISO 8601 and is what Postgres emits for whole-hour zones; a two-digit-offset value then falls through the guard, gets stripped as trailing junk, and the instant moves by hours with nothing reported.

### A reader that accepts a UTC offset may not be applying it

- The rule above is about parsing an offset correctly. This is the case where the
  parse never happens: the value is accepted, no error is raised, and the offset is
  **silently discarded**. GDAL does this with a GeoPackage `DATETIME` — it returns
  the wall-clock digits, which the caller then reads in the machine's zone.
- So the same file yields a different instant on every machine. Measured 2026-09-01
  on `trap`, writing one value and reading it back under three zones:

  ```
  stored                      TZ=America/Vancouver   TZ=UTC       TZ=Asia/Tokyo
  2026-07-21T14:04:28Z        14:04:28Z              14:04:28Z    14:04:28Z
  2026-07-21T14:04:28-07      21:04:28Z              14:04:28Z    05:04:28Z
  2026-07-21T14:04:28+05:30   21:04:28Z              14:04:28Z    05:04:28Z
  ```

  **The tell is that the two offsets give identical answers.** Only the `Z` row is a
  fact about the file; the other two are facts about the reader.
- **The test that let it through asserted `-07` on a `-07` machine**, where a
  wholly-ignored offset and a correctly-applied one produce the same number. The
  coincidence was written into the fixture by choosing an offset equal to the local
  one, so no amount of running it locally could have found it — CI on a UTC runner
  did. Same family as "a fixture set that cannot reach the failure mode", with the
  blind spot supplied by the machine rather than by the data.
- Two things follow, and the second is the general one:
  - **Refuse what you cannot read.** Where every real value carries `Z`, accepting an
    offset buys nothing and costs a silent multi-hour error. Refusing it with its own
    message — a missing zone and an untrusted zone are different failures — is
    strictly better than honouring a parse you have not verified.
  - **Test a timezone-sensitive property in more than one zone**, and make one of them
    differ from the developer's. `withr::with_timezone()` costs nothing. The property
    worth asserting is *the instant is the same in every zone*, which a single-zone
    test structurally cannot check.
- Generalises past GDAL to anything that returns a naive local timestamp from a
  zone-bearing source: some JDBC drivers, `datetime.fromisoformat` before 3.11 on
  certain shapes, spreadsheet readers. If a library hands back a value with no zone
  attached, assume the zone was dropped rather than applied, and prove otherwise.

### Ask the file about its field names, not R

`sf::st_read()` returns a data frame, and R makes column names syntactic on the way in.
A field the GeoPackage stores as `Site/Site` arrives as `Site.Site`; an accent survives,
a slash does not. So a claim about *what the file contains* cannot be checked by reading
the file into R — that measures R's name mangling, not the writer's behaviour.

```r
sf::st_read(gpkg, "sites") |> names()   # "Site.Site"  "Year.Année"  <- R's names
system2("ogrinfo", c("-so", gpkg, "sites"))  # Site/Site, Year/Année  <- the file's
```

The practical consequence, not just a documentation nicety: a SQL `-where` / `query`
against such a layer must use the **file's** field name, quoted. The name visible in the
session is not the name the query engine sees.

Bilingual slash-separated headers (`Site/Site`, `Year/Année`) are a general shape of
Canadian federal open data rather than one publisher's quirk, so this comes up whenever
that data is ingested. Verified against GDAL 3.x, 2026-09-02 (spacehakr#21) — where the
first check read the layer back with `st_read()` and nearly recorded R's behaviour as
GDAL's.

Related: the geometry-column naming note above, which is the same hazard on the geometry
rather than the attributes.

### QGIS embeds a layer's style in the `.qgs`, so rewriting the `.qml` sidecar changes nothing

A `.qgs` carries each layer's style **inside** its `<maplayer>` node — the sidecar's
children are copied in when the layer is declared. QGIS does not re-read that sidecar
for a layer the project already holds. So a tool that rewrites a GeoPackage and its
`.qml` leaves the project describing the *old* schema, and the two disagree silently.

The failure is invisible to every ordinary check. Measured on a live field project
whose form went from 39 to 41 columns:

```
 Form CABIN Visit    fieldConfig= 38  attrEditorField= 37  defaults= 38
   date_time_start in fieldConfig: FALSE
```

The table has the new columns; the layout does not name them. A tab layout renders
only what `attributeEditorForm` names, so the fields are **unreachable**, and the
`now()` defaults live in `<defaults>`, so they are **NULL** as well. Row counts,
file checks, schema parity against the GeoPackage and **QGIS Desktop itself** all
pass — the form opens and looks correct. It is wrong only on the device, in front of
a crew.

Two consequences worth carrying:

- **Assert against the `<maplayer>`, not the GeoPackage.** Compare the node's
  `fieldConfiguration`, `attributeEditorField` and non-empty `defaults` against the
  sidecar the writer just produced. Comparing the node to the *table's columns*
  instead fails on correct data — a shipped style deliberately omits identity and
  relation keys (measured: 40 config / 39 editor for a parent, 4 / 3 for its child).
- **Refresh the node in place, reusing its own `<id>` and `<layername>`.** Removing
  and re-adding the layer changes the id, and every surface holding it — layer tree,
  `layerorder`, map themes, `custom-order`, the legacy legend, `<relation>` entries —
  either follows or silently does not. Read the id from the node; a digest-derived id
  reproduces only for projects the same tool built, never for one QGIS touched.

rfp ships this as `rfp_qgs_form_add(restyle = TRUE)` (rfp#260, 0.57.0).

Same shape wherever a consumer caches a copy of an artifact at declare time rather
than resolving it at read time — check whether the consumer re-reads, before assuming
that rewriting the source is enough.

### A GeoPackage is a SQLite database, and that leaks in three ways

Writing to one directly (a `layer_styles` row, an attribute fix) is a plain `INSERT` and needs
no GDAL. But the container's own machinery then shows up in places that have nothing to do with
your write. All three measured 2026-09-03 in stac_floodplains_bc#46.

- **SQLite bumps a header change counter on ANY write transaction.** So a step that rewrites
  identical rows still moves the file's bytes — and with them any published `file:checksum`.
  Idempotence has to mean *skipping the write*, not writing the same thing again: read the rows
  back, compare, and return before opening a transaction. One pass over a virgin file was
  byte-reproducible; the second pass was not, until the skip was added. `AUTOINCREMENT` is a
  second source of the same problem (`sqlite_sequence` only ever grows) — assign ids explicitly.
- **GDAL lists non-spatial tables as layers.** `ogrinfo` and `sf::st_layers()` both return
  `layer_styles` alongside the real ones, with or without a `gpkg_contents` row, so any loop of
  the form *for every layer, assert this column exists* breaks the day someone adds an
  attributes table. Filter on the **property** — a geometry, via `geomtype` being non-`NA` or
  `gpkg_contents.data_type = 'features'` — never on the table's name, which passes the day a
  second non-spatial table appears. And guard the filter: if it removed everything, the
  assertions below it are vacuous.
- **A feature table's rtree triggers call SpatiaLite functions plain `sqlite3` does not have.**
  An `UPDATE` on a spatial layer from Python dies with `no such function: ST_IsEmpty`. Fine in
  production if you only touch non-spatial tables; it bites when a *test* wants to mutate real
  geometry-bearing rows. Drop the triggers on the throwaway copy first, and say in a comment
  that it is test-only.

Related, and worth knowing before adding a style table: QGIS's own writer registers
`layer_styles` in `gpkg_contents` and adds triggers. Neither is needed — QGIS auto-styles
without them — and the registration costs a second wall-clock timestamp
(`gpkg_contents.last_change`) beside `layer_styles.update_time`, so writing *less* than QGIS
does removes a churn vector. `OGR_CURRENT_DATE` does not reach either one, because a `sqlite3`
write never goes through GDAL.


### The same leak reaches R and OGR SQL, and a GeoPackage's bytes are not its content

Four more measurements of the section above, all 2026-09-05 in rtj#285 against live
Mergin projects. Each was found by a driver failing after it had already written, which is
the expensive place to find any of them.

- **RSQLite can `DELETE` from a spatial layer but not `UPDATE` or `INSERT`.** The asymmetry
  is which triggers call SpatiaLite: the rtree *insert* and *update* triggers use
  `ST_IsEmpty`, and the `rtree_<t>_<g>_delete` and `trigger_delete_feature_count_<t>`
  triggers do not — verified by reading the trigger SQL out of `sqlite_master`. So a
  delete-one-row driver works through DBI and an edit-one-row driver dies with
  `no such function: ST_IsEmpty`. The remedy in production is not dropping triggers, it is
  GDAL: `ogrinfo -sql "UPDATE ..."` registers those functions.
- **`DBI::dbExecute()` reports `total_changes()`, not the rows you changed.** A one-row
  `DELETE` on a form table returned **5** — the row plus the rtree and feature-count trigger
  writes — so `deleted == 1L` fails on a completely correct delete and sends the operator to
  restore a good file. Assert the **state** instead: the target row was there before and is
  gone after. A control delete on a trigger-free table returns 1, which is exactly what makes
  this look like a working check until it meets a spatial layer.
- **`SELECT fid FROM <table>` through `sf::st_read(query = )` returns 0 rows and 0 columns.**
  OGR treats a lone FID selection as selecting no fields, so `nrow()` is 0 whatever the table
  holds — measured 0 against an unmodified 16-row layer, while `SELECT site_id ...` returned
  16 and `SELECT count(*) AS n ...` returned 16. A row-count guard built on it can only ever
  read "empty", which is the direction that reads as success for a *deletion* check. Select a
  real column, or `count(*)`.
- **A GeoPackage's file hash is not a content identity, and a read can move it.** Two copies
  of one Mergin version — one taken by `file.copy` before a conversion, one downloaded from
  the server afterwards — differed in **5 bytes**, all SQLite header change-counter and
  version fields, with content identical (60 tables, 312,896 rows, same per-table counts).
  Separately, a `journal_mode` round trip changes the sha256 while a plain GDAL update-mode
  open/close does not. So "did anyone edit this file" cannot be asked with a checksum over
  `.gpkg`s — QGIS merely opening one is enough. Ask it of the **content** (row and style-row
  counts per layer, or a canonical digest), and keep checksums for the text files, where a
  save really does rewrite the bytes. The client's own change predicate agrees: a Mergin
  working tree whose store differed from its basefile by 373,732 bytes reported clean,
  because geodiff compares content and not bytes.

### A coordinate stored as an attribute can disagree with the geometry it describes

A spatial layer that also carries `LATITUDE` / `LONGITUDE` columns has the same fact twice, and
nothing keeps them consistent. BC's EMS monitoring locations
(`bcdc_query_geodata("634ee4e0-c8f7-4971-b4de-12901b0b4be6")`) store **`LONGITUDE` positive** —
`127.1931` for a station whose geometry is correctly at `-127.1931`.

Differencing the attribute against another source therefore puts every feature ~16,000 km away:

```r
sf::st_drop_geometry(ems)$LONGITUDE[1]              #>  127.1931
sf::st_coordinates(sf::st_transform(ems, 4326))[1,] #>  X -127.1931   Y 54.8039
```

**The failure presents as a broken join, not a sign error.** A 100% mismatch rate across 74 joined
records reads as "the key is wrong" and sends you back to the join — which is the one place the bug
is not. Measured 2026-09-04 joining CABIN sites to EMS.

Take coordinates from the geometry (`st_coordinates()`), always. If you must use the attribute,
assert it against the geometry once rather than trusting it — and note the sanity check `all(lon <
0)` passes on the *geometry* and fails on the *attribute*, so check the one you are about to use.

### GeoJSON in a projected CRS is silently non-portable

`sf::st_write()` and `ogr2ogr` will write GeoJSON from a projected object and emit a `crs` member
naming it:

```json
"crs": {"type":"name","properties":{"name":"urn:ogc:def:crs:EPSG::3005"}},
"coordinates": [956783.23, 1042595.57]
```

RFC 7946 **mandates WGS84 and removed the `crs` member**. QGIS honours it, so the file opens
perfectly on the desktop where it was written — and GitHub's map preview, Leaflet and Mapbox all
read those numbers as lon/lat and place the feature in the Atlantic.

So the format that renders it correctly is the one least likely to be used to check it. Transform
explicitly and say so:

```r
sf::st_write(sf::st_transform(x, 4326), path, layer_options = c("RFC7946=YES"))
```

Assert on the written file, not the object: no `crs` key, and coordinates inside
`[-180,180] x [-90,90]`. Caught 2026-09-04 in `stewardship_upper_wedzin_kwa`.

Related: prefer GeoJSON over GeoPackage for a **tracked** layer. Git deltas text and stores a whole
new copy of binary SQLite on every write — four commits of one 196 KB layer had already put 692 KB
of blobs into history. Ship the gpkg as a gitignored rebuild.

### `sf::st_perimeter()` needs lwgeom on projected data, and lwgeom is not a dependency of sf

An exported sf function whose body branches on `requireNamespace("lwgeom")` is an
undeclared dependency: `R CMD check` does not report it, and a test suite cannot see it
on a machine that happens to have lwgeom installed. `st_perimeter()` is the live case —
on a projected CRS it delegates to lwgeom and errors without it (sf 1.1.2), so a package
that rejects lon/lat input takes that branch on **every** call. Caught 2026-09-04 in
drift#44 by a review round, not by tests: the suite was green, the exported function
would have failed on first use for any install without lwgeom, and the pkgdown CI
(Imports + Suggests only) would have gone red on the examples.

```r
as.numeric(sf::st_length(sf::st_boundary(sf::st_geometry(x))))   # no lwgeom
```

Measured identical to `st_perimeter()` (max abs diff 0) across 93 raster-derived patches
including 21 MULTIPOLYGON and 2 with holes; `numeric(0)` on zero rows. **Bare `st_length()`
on polygons returns 0**, silently. Pin it with a test that `"lwgeom" %in% loadedNamespaces()`
is `FALSE` after the call (unload first; it goes red with `st_perimeter()` restored).

Same shape in `st_geod_*`, `st_minimum_bounding_circle()`, `st_split()`, `st_subdivide()`:
the function is in sf's namespace, so `sf::` reads as a declared dependency while the branch
needs one nobody declared. Read the body for `requireNamespace` before relying on it. This is
"A fixture that cannot reach the failure mode" arriving through the *environment*: no fixture
varies which packages are installed.

### terra keeps a result in memory whenever it fits, so a per-class loop over a large grid accumulates full-grid rasters

`ifel()`, `focal()`, arithmetic and `rasterize()` return in-memory SpatRasters whenever the
result fits under `memfrac` (60% of RAM by default). On a 169M-cell grid each one is 1.35 GB,
and a loop that computes two per class and never frees them holds 2.7 GB per iteration —
measured 11.3 GB peak for **one** class and killed for memory at eight on a 64 GB machine
(drift#44, 2026-09-05, the BULK floodplain at 10 m, 97.7% NA). `inMemory()` was `TRUE` on
every intermediate. Unit tests on a 40x40 fixture cannot reach this; only a run at scale did.

Pass `filename = tempfile(fileext = ".tif")` to every intermediate that is not the return
value (`app`, `focal`, `rasterize`, `segregate` all take it) so terra streams in chunks, and
`unlink()` them in `on.exit()`. Prefer one multi-layer pass over a per-class loop:
`segregate(x, classes = ks, other = 0L)` gives a 0/1 layer per class in ascending order,
`focal()` processes the stack per layer, and `zonal()` returns one column per layer — three
calls in place of `3 * n_classes`. Same run afterwards: 143 s, peak set by the upstream
stage. LZW-compressed intermediates measured ~0.2 bytes/cell/layer, so disk is not the
constraint. Do not fix it with `terraOptions(memfrac = )` from library code — that is a
global a caller did not ask you to change.

### `geom_sf(data = NULL)` draws nothing, silently

A `NULL` `data` argument does not error and does not warn — the layer inherits the plot's data,
which for `ggplot()` with no global data is empty, so it contributes a **zero-row layer**. The
figure builds, writes, and is missing whatever that layer was.

The reachable shape is a list subscript that has stopped matching: `ff[[primary]]` is `NULL` the
moment `primary` names a key the list no longer has, and a list built from config changes without
anybody editing the constant that indexes it. Measured 2026-09-04 in floodplains#77 — with the
scenario set derived from a CSV and the primary scenario left as a literal, the overview panel
wrote successfully at 373,719 bytes with its entire floodplain ribbon absent, under a subtitle
still naming the scenario. Nothing in the render said a word.

Assert membership where the index is not derived from the same source as the collection:

```r
if (!key %in% names(x)) stop("`", key, "` is not among (", paste(names(x), collapse = ", "),
                             ") — the layer would draw nothing and say nothing about it")
```

Same class as *"Zero-length, empty, and unset are three different things"* in `code-check.md`,
landing in a graphics device rather than a data frame: the wrong value is a perfectly valid one,
and the output is a plausible picture.


### terra: `app()` calls a vector-tolerant `fun` once per CELL, and reads a 5-column return on a 5-column raster as transposed

Two contracts inside `terra::app()` that read as the opposite of what they are, both measured on
terra 1.9.34 (drift#9, 2026-09-05):

- **Dispatch.** `app()` first tries `apply(chunk, 1, fun)` — one R call per cell — and falls back
  to `fun(chunk)` only when that errors. A `fun` written to accept a bare vector (the natural
  "handle both shapes" reflex: `v <- matrix(v, ncol = n)`) therefore silently runs per cell:
  measured 360,013 calls / 6.96 s against 2 calls / 0.12 s on a 600 x 600 x 7 stack, 57x, values
  identical. Chunks always arrive as matrices, single cells included, so **refuse anything else**:
  `if (!is.matrix(v)) stop("matrix chunks only")` is what forces the vectorised path. Nothing in
  a suite sees it — both paths give the same numbers — so pin the closure directly and let a
  scale run carry the timing. The same defect reappeared in the benchmark script that measured it.
- **Shape inference.** `app()` decides the output layer count from a test chunk of
  `min(ncol, 13)` cells and checks `ncol(result) == ntest` *before* `nrow(result) == ntest`.
  A `fun` returning k columns on a raster exactly k columns wide (k < 13) is read as transposed,
  and every chunk is written across layers with no warning. Silent scrambling on a legal input;
  pad such a stack by one column (`extend()` then `crop()` back), and assert the output against an
  arithmetic reference on widths 4, k, k+1.

Also from the same run: `wopt = list(steps = n)` is honoured as a **floor** on chunk count and is
the library-local way to bound the R-side matrices `fun` receives (left to its memory heuristic, a
64 GB machine takes a 192M-cell grid in one or two chunks, ~10 GB of matrices); and the default
`app()` datatype is `FLT4S`, while `INT2S` overflows at `from * 1000 + to` once a class code reaches
33 (every ESA WorldCover code) with a *warning* from `writeValues()`, not an error, that fires before
`writeStop()` — so promote it to an abort and keep the partial file on the cleanup list.

### terra: `levels<-` and `coltab<-` copy before they strip; `set.cats(NULL)` is the in-place form

Both replacement methods begin with `x@pntr <- x@pntr$deepcopy()`, so no placement of
`levels(r) <- NULL` / `coltab(r) <- NULL` can mutate a caller's raster — and a test asserting "the
caller's rasters are untouched" is decoration under every variant, because nothing the code could
do would reach them. `terra::set.cats(r, layer = i, value = NULL)` mutates in place, strips every
layer when looped, costs no copy, and is the form a caller-unmutated test can actually guard.
`coltab(stack) <- NULL` strips **layer 1 only** (`layer = 1` default, `removeColors(layer[1] - 1)`);
`levels(stack) <- NULL` strips all. `rast(list)` copies in-memory sources — seven 192M-cell
rasters cost ~10 GB again — so spill in-memory inputs to temp files before stacking. And terra
writes a RAT sidecar (`<file>.tif.aux.xml`) beside **any** factor it writes (`resample()`,
`writeRaster()`), which an `unlink(files)` of the `.tif` alone leaves behind; a palette on a
non-byte band warns on every write. Strip both on a copy before writing, and unlink the sidecar
too — guarded on `length(files)`, because `paste0(character(0), ".aux.xml")` is `".aux.xml"` and
`unlink()` resolves that in the working directory (drift#9 round 7, 2026-09-05).

### terra `metags()`: the empty case is `NULL`, and the sidecar is half the artefact

Three measured facts about raster **container** metadata, all of which fail quietly
(floodplains#83, 2026-09-05, terra 1.9.34 / GDAL 3.8.5).

**`metags()` returns `NULL` for a raster with no tags — not a 0-row frame.** So
`if (!nrow(metags(r)))` raises `invalid argument type`, and `metags(r) <- NULL` on that
same raster dies with `value[, 3] <- "" : incorrect number of subscripts on matrix`. A
strip written without that guard aborts on precisely the rasters that need no stripping,
so it works on the machine with the bug and breaks everywhere else. Nothing on disk
reaches it either — every written GeoTIFF carries `AREA_OR_POINT` — so only a
constructed zero-tag case finds it. Guard with `!is.null(tg) && NROW(tg) > 0`.

**Band category names can live ONLY in the `.aux.xml`.** `GDAL_PAM_ENABLED=NO gdalinfo`
on a terra-written factor raster shows no `Categories` block at all. So the `.tif` and its
sidecar are one artefact: a repair that rewrites the `.tif` and renames it into place
without the sidecar destroys the published RAT, and **every content check still agrees** —
a values-plus-geometry digest does not read class labels, so `is.factor()` goes FALSE with
the digest byte-identical. This is the mirror of the rule above ("unlink the sidecar too"):
on cleanup you must remove both, on repair you must **move both**, and assert
`terra::cats()` before and after rather than inferring it from a `gdalinfo` diff — that
diff reads each file with its own sidecar and so cannot see one go missing at rename time.

**A guard reading dataset tags must disable PAM.** GDAL merges a sidecar's dataset-level
`<Metadata>` block into the default domain, so a sidecar carrying `TIFFTAG_SOFTWARE=QGIS`
puts two "stray" tags on a clean raster — and GDAL writes that sidecar as a side effect of
anyone *opening* the file. Unguarded, the property depends on who has looked at the raster,
and a `.tif` rewrite cannot remove a sidecar tag, so the file is "repaired" and reports
dirty forever. Set `GDAL_PAM_ENABLED=NO` around the read and restore the prior value.
Read through GDAL (`sf::gdal_utils("info", …, "-json")`), not `terra::metags()`, whenever
terra is the library under suspicion — and select the default domain **by position**, since
its key is the empty string and `md[[""]]` silently matches nothing.

### `ggmap`: a fixed `zoom` silently crops points off the basemap, and `calc_zoom()` does not fix it

`ggmap::get_map()` fetches ONE fixed-size image at whatever `zoom` it is given. Points outside
that image are still drawn by `geom_point()`, land off the basemap, and are clipped away — the
map renders successfully, looks plausible, and is missing sites. No warning and no error, so the
loss is invisible unless you already know how many points you expected. A hardcoded `zoom = 9`
did this in safety_plan_template: 8 sites spanning 1.5 degrees of latitude showed as 2 pins, on a
map crews navigate by.

`ggmap::calc_zoom()` is not the fix — it ignores Mercator latitude compression and returns the
same too-tight zoom. A 640 px Google static image spans `900/2^z` degrees of longitude, but those
same pixels cover only `cos(latitude)` as much **latitude**, a factor of ~1.75 at 55 N. At zoom 9
near Chetwynd the image covers 1.76 lon x 1.00 lat against the 1.88 x 1.72 needed: the longitude
axis fits, the latitude axis loses three quarters of the sites, and only one of the two axes is
the one anybody checks.

Solve both axes and take the looser one:

```r
map_cos  <- cos(mean(bb[c("bottom","top")]) * pi/180)
map_zoom <- floor(min(log2(900 / diff(bb[c("left","right")])),
                      log2(900 * map_cos / diff(bb[c("bottom","top")]))))
map_zoom <- max(3L, min(as.integer(map_zoom), 13L))   # guard identical coords -> Inf
```

The clamp is load-bearing rather than cosmetic: one site, or two sites at the same coordinates,
gives `diff() == 0` and `log2(x/0) == Inf`.

**Verify rather than eyeball** — count the points falling inside `attr(basemap, "bb")` and assert
it equals `nrow()`. A visual check is precisely the check this failure defeats, since the map that
dropped six of eight sites is a clean and credible map (safety_plan_template, commit `7d25df4`,
2026-09-06).

### terra: `zonal()` outside its six-function fast path materializes the WHOLE grid in R

`terra::zonal()` dispatches to C++ only when `fun` is one of `max`, `min`, `mean`, `sum`,
`notNA`, `isNA`. Anything else — `"modal"`, a quantile, any R closure — falls through to

```r
xz <- c(x[[i]], z); v <- as.data.frame(xz, na.rm = FALSE)
stats::aggregate(v[, 1], v[, 2, drop = FALSE], fun, ...)
```

which is one data-frame row per cell, per layer. On a floodplain grid that is 169M rows (BULK)
or 204M (KOTL), ~2.7 GB as doubles before `aggregate` copies it — so the obvious answer to
"take the modal value per zone rather than the mean" is a silent OOM on a machine that handles
the mean fine. Read from the method body, terra 1.9.34.

**Use `terra::crosstab(c(zone, layer), long = TRUE, useNA = TRUE)` instead.** It is
`x@pntr$crosstab()`, pure C++ and streamed, and `long = TRUE` returns only observed
combinations with zeros dropped — cells per (zone, value), from which the modal value, the full
within-zone distribution and exact denominators all follow, with no statistic chosen in advance.
Measured on a 10x10 fixture: columns come back **numeric, not factor**, and `useNA = TRUE` keeps
the NA group, so `as.integer()` on a value column is the value and not a level index.

Two things `zonal(fun = "mean", na.rm = TRUE)` also gets wrong that the crosstab does not:
it computes over **non-NA cells rather than zone cells**, which is a different denominator than
most callers mean and is invisible in the result; and it returns `NaN`, not `NA`, for an
all-NA zone, which `merge(all.x = TRUE)` will not surface as missing.

Caught 2026-09-06 in drift#67, by a reviewer disassembling the method rather than by a test —
both paths return the same numbers on a fixture small enough to run.


### sf: close a rotated ring by copying the first vertex, never by recomputing it

Rotating a polygon by multiplying its whole vertex matrix — `xy %*% rot` — looks exact,
and for a ring built closed it is not. `%*%` computes rows **independently**, and an
optimised BLAS may block or vectorise them differently, so the fifth row (a duplicate of
the first, by construction) can come back a few ulps away from where the first landed:

```r
xy  <- matrix(c(-1000,-1000, 1000,-1000, 1000,1000, -1000,1000, -1000,-1000),
              ncol = 2, byrow = TRUE)             # closed: row 5 == row 1
rad <- 230 * pi / 180
r   <- xy %*% matrix(c(cos(rad), sin(rad), -sin(rad), cos(rad)), nrow = 2)
identical(r[1, ], r[5, ])                          # FALSE
r[1, ] - r[5, ]                                    # 0  -2.842171e-14
```

`sf::st_polygon()` requires **exact** closure and raises *"polygons not (all) closed"* —
an **error**, not a warning — so one unlucky feature aborts the whole batch rather than
losing itself. Rotate four vertices and append the first again:

```r
xy <- matrix(c(-hc,-ha, hc,-ha, hc,ha, -hc,ha), ncol = 2, byrow = TRUE)  # four
if (is.finite(b)) xy <- xy %*% rot
xy <- rbind(xy, xy[1, , drop = FALSE])             # close by COPY
```

**Whether it fires depends on the angle and the dimensions**, so a fixture that happens
not to hit it proves nothing: measured 2026-09-02 in fly#26, this had been latent on
`main` for every rotated non-square footprint since fly#32 and 1338 passing tests never
saw it. Sweep the angle — `seq(0, 359.5, by = 0.5)` — rather than sampling a handful,
and assert that the *recomputed* form still fails somewhere in that sweep, or the test
silently becomes decoration once the fix makes the property true by construction.

Generalises past rotation to any affine map applied to a closed ring, and past sf to any
library that validates closure by exact equality. The rule is the same: a closing vertex
is a **copy**, never a computation.


### terra: `plot(type = "classes", levels =, col =)` maps colours by POSITION, per layer

A `levels`/`col` pair is not a value-to-colour mapping. `terra::plot()` matches the vectors
against **that layer's own sorted unique values**, so a layer missing a class shifts every class
after it — and each panel of a multi-panel figure is mapped independently.

Measured 2026-09-06 in drift#66 on a 7-layer IO LULC stack carrying codes 1, 2, 5, 9, 11. Five of
the seven years contain no code 9 (Snow/Ice), so their four values took the first four colours and
**Rangeland drew in Snow/Ice's blue** — 705 cells, in the panel the figure existed to show,
contradicting the legend printed beneath it from the same vectors:

```r
present <- sort(unique(values(stack)))          # 1 2 5 9 11 across the STACK
ct <- ct[match(present, ct$code), ]
terra::plot(stack[[i]], type = "classes", levels = ct$class_name, col = ct$color)
#> layer i has 1 2 5 11 -> code 11 draws ct$color[4], not ct$color[5]
```

Computing the class set over the whole stack is exactly the instinct that produces it: it is the
right way to build a **legend**, and the wrong way to build a per-layer `col`.

Use a colour table, which is keyed by cell value and cannot desynchronise:

```r
for (i in seq_len(terra::nlyr(x))) terra::coltab(x, layer = i) <- data.frame(value = , col = )
terra::plot(x[[i]], legend = FALSE)
```

- **A single-layer fixture cannot reach this**, and neither can a stack whose layers happen to
  carry every class. The trigger is a *missing* class in *some* layer.
- **Reading the code will not find it** — the vectors are correct and the legend built from them
  is correct. Read the rendered image and check one cell of a known class against the legend.
- Same shape for any renderer taking parallel `breaks`/`labels`/`col` vectors and re-deriving the
  domain per facet.

### terra: `wrap()` carries the tempfile basename in `varnames`, so a committed artifact churns

`sources()` on a derived raster (above) is the well-known half. `varnames` is the quiet one:
terra keeps the **basename of whatever `filename =` produced**, and `wrap()` serialises it, so an
`app()`/`focal()` written to `tempfile()` puts a per-process random string into the saved object.

```r
r <- terra::app(x, fun = f, filename = tempfile(fileext = ".tif"))
terra::varnames(r)                       #> "file178092823716a"
saveRDS(terra::wrap(r), "committed.rds") #> different bytes on every run
```

Measured 2026-09-06 in drift#66. Values, extent and CRS all round-trip **identically** — the
diff is entirely `@attributes$varnames` — so every content check agrees while the file changes on
each regeneration and a real change becomes invisible in the noise. Pin it, with `longnames`,
before wrapping or writing:

```r
terra::varnames(y) <- rep("<a stable name>", terra::nlyr(y))
terra::longnames(y) <- rep("", terra::nlyr(y))
```

The check is a byte comparison of two consecutive regenerations, not an inspection of the object:
`cmp` on the two `.rds` files is what found it, after `identical(values(a), values(b))` had said
they matched. Note this pins only the **per-process** variation — a `date` field in the same
artifact still churns daily, which is a deliberate provenance choice rather than a defect, so say
which one the artifact is making.

### `terra::plot()` leaves the device in a state where a keyword-placed `legend()` draws nothing

`graphics::legend("topleft", …)` after a `terra::plot()` or `terra::plotRGB()` **silently draws
nothing** — no error, no warning, and the rest of the figure renders normally. So a map ships with
no legend at all, and every check that reads the source says the legend is there.

Explicit user coordinates work, because they do not depend on whatever plot region terra left
behind:

```r
terra::plot(r, legend = FALSE, axes = FALSE, mar = NA)
e <- terra::ext(r)
graphics::legend(x = e[1], y = e[4], legend = lab, fill = col, bty = "n", xpd = NA)
```

Measured 2026-09-07 in drift#73 on **two** figures in one article — the second only because the
first had been fixed and the same defect was not looked for in its sibling. The tell is a figure
whose legend is absent from the rendered PNG and present in the code; there is nothing else to see.

Three further things, all from reading the rendered image rather than the source:

- **`plotRGB()` fills letterbox bands BLACK.** A basemap whose extent ratio does not match
  `fig.width`/`fig.height` is letterboxed, and the padding is black — not the device background,
  which `par(bg = "white")` would fix. Set the figure dimensions from the raster's own extent
  (`e <- ext(r); (e[2]-e[1]) / (e[4]-e[3])`), not from its pixel dims, which change under
  `project()`.
- **A keyword position is a guess about where the data is not.** Bin the occupied cells onto a
  10x10 grid of the extent and place the legend in a block that is actually empty. Three
  placements were tried by eye in one figure and landed on data, on data, and clipped off the
  bottom of the device.
- **A categorical registry palette is not a sequential scale.** Category fills are chosen to sit
  under black outlines, so they are all light: ramping between two of them spanned 29 points of
  luminance where carrying on into a dark neutral spanned 54. And over a basemap the palest bin is
  indistinguishable from terrain, so a choropleth needs its own opaque ground drawn under it — plus
  the AOI outline, since a cell with no value draws nothing and the mapped extent then disappears.

The general rule underneath all four: **a map is verified by reading the rendered PNG**, never by
reading the code that produced it. Every one of these passes source review.

### A name is not a key: `GNIS_NAME` matches features all over BC

`filter(GNIS_NAME == "Buck Creek")` returns every Buck Creek in the province. The union of
those geometries is still a valid `sfc`, `st_distance()` still returns a number, and nothing
warns — so the wrong creek produces an answer rather than an error.

Three times in one session (2026-09, stewardship_upper_wedzin_kwa), each silent:

| queried | also matched | tell |
|---|---|---|
| Buck Creek | one on **Vancouver Island** | mouth came back at 50.35, -127.86 |
| McQuarrie Creek | one in **Alberta** | confluence at 50.24, -114.83 |
| Slate Creek | one 300 km northeast | a 7-creek bbox spanned 3 degrees of longitude |

The Buck case is the dangerous shape: distance-to-union takes the nearest, so the number
looked plausible and only the `DOWNSTREAM_ROUTE_MEASURE` reading 0.02 for two points 13 km
apart gave it away. The other two announced themselves with a coordinate in the wrong
province — which is luck, not a check.

**Resolve to a `BLUE_LINE_KEY` before using the geometry.** Pick it with a reference point
you trust, then filter:

```r
s   <- bcdc_query_geodata(fwa) |> filter(GNIS_NAME == nm) |> collect()
blk <- s$BLUE_LINE_KEY[sf::st_nearest_feature(ref_pt, s)]
s   <- s |> filter(BLUE_LINE_KEY == blk)
```

And print the result's centroid the first time. A stream that should be in the Skeena
reading 50 N is the cheapest possible assertion, and it is the one that caught two of these.

### `sf::st_read()` on a KML drops `<SchemaData>`, silently

GDAL has two KML drivers and picks `KML` by default, which does not read the `<SchemaData>`
block. A file whose placemarks carry typed fields comes back with `Name`, `Description` and
`geometry` — and `Description` **empty**, so nothing errors and nothing looks wrong.

Measured 2026-09-06 on a 17-site DFO eDNA export: all three of `coho_presence`,
`chinook_presence` and `species` were missing. `ogrinfo` opened the same file with `LIBKML`
and listed them.

`st_read(..., driver = "LIBKML")` does not force it — the argument is not honoured that way.
Convert instead, which is usually wanted anyway since KML does not delta in git:

```bash
ogr2ogr -f GeoJSON -lco RFC7946=YES -t_srs EPSG:4326 out.geojson in.kml
```

Same family as "Ask the file about its field names, not R" above: what `sf` hands back is a
statement about the reader, not about the file. Check the field list against `ogrinfo` before
concluding a source lacks an attribute.

### GDAL applies `-srcnodata` and an alpha mask together, and the mask loses

Two ways of saying "these pixels are not data" reach `gdalwarp` independently, and giving
it both is not an error — it is an instruction to do both. Measured on GDAL 3.8.5 through
`sf::gdal_utils()`, every combination runs clean and returns the expected band count:

| warp options on a 4-band source | result |
| --- | --- |
| `-srcalpha -dstalpha` | ok, 4 bands |
| `-srcalpha -srcnodata "0 0 0" -dstalpha` | ok, 4 bands |
| `-srcalpha -srcnodata "0 0 0 0" -dstalpha` | ok, 4 bands |

What the second row *does* is the problem. On a synthetic frame carrying an 11x11 block of
true black (value 0) well inside the image:

| | opaque | transparent |
| --- | --- | --- |
| `-srcalpha` alone | 6400 | 3600 |
| plus `-srcnodata "0 0 0"` | **6279** | 3721 |

The difference is 121 pixels — exactly the interior block. So an alpha mask built to
*preserve* genuinely dark ground is silently undone by a `srcnodata` left in place beside
it, and nothing is reported: no warning, no band-count change, no error. The failure is
invisible in every check that does not count pixels.

**A library that accepts a contradictory pair is where your code has to raise.** Do not
reason about which one "wins" — measure it once, then refuse the combination at your own
API boundary with a message naming both arguments and the remedy. Silently dropping one is
the wrong fix: a caller who set `srcnodata` deliberately must be told their instruction and
the mask disagree.

Two related measurements from the same work, both worth not re-deriving:

- **`-srcalpha` excludes the alpha band from the warped band list**, so a source with an
  appended alpha warps to the *same* band count as one without it — 1-band grayscale stays
  1 band with `-dstnodata`, 3-band RGB stays 4 with `-dstalpha`. That is what lets masking
  be added to an existing pipeline without moving a downstream consumer's schema.
- **`nearblack` is available through `sf::gdal_utils(util = "nearblack")`**, and its
  `-alg floodfill` (GDAL >= 3.7) is a flood fill seeded from the image border — i.e.
  connected-component removal of an edge-touching dark collar, in C++, with no new R
  dependency. Worth knowing before writing one: a `terra::patches(directions = 8)`
  implementation measured against it over 264 scanned airphotos agreed at r = 0.9877 with
  0 frames disagreeing by more than 0.02. It assumes **Byte** bands — `-near` is an
  absolute per-band distance, so a threshold calibrated on 8-bit imagery reaches almost
  nothing on a 16-bit scan and returns "no collar found" rather than failing.

Measured 2026-09-08 in fly#23.


# Code Check Conventions

Structured checklist for reviewing diffs before commit. Used by `/code-check`.

This file holds the **mechanisms** — the shapes that keep producing bugs regardless of
language — and a short set of standalone rules. Tool-specific traps live beside it,
each gated on the repo's contents: `code-check-shell.md` (bash, sed, git, `gh`; always),
`code-check-r.md` (package internals; `NAMESPACE`), `code-check-spatial.md` (terra, sf,
bcdata, GDAL; bookdown, `DESCRIPTION` or QGIS repos), `code-check-infra.md` (provisioning;
`*.tf`, cloud-init, compose).

When a bug class is discovered, add a **row** under the mechanism it instances. Add a
new mechanism only when no row fits. Add to a tool file only when the rule is about
that tool rather than about a shape.

**The remedy goes in the mechanism, not in the row.** A repo's `CLAUDE.md` carries the
mechanism paragraphs and omits the instance tables, which `/code-check` still reads in
full (soul#214). So a fix written into a row reaches a diff review and reaches no session
doing ordinary work. Put what someone must *do* in the rule, once; let the row carry the
citation — date, repo, what broke, what it cost — at around the median 95 words.

## Mechanisms

Fourteen shapes that keep producing bugs. Each is stated once; the table under it is
the evidence — every instance dated, with where it was caught and what it cost. The
rule is the thing to check a diff against. The rows are why the rule is trusted.

When a new instance turns up, add a row. Add a new mechanism only when no row fits,
which is rare: the previous version of this file carried 31 lines cross-referencing
another entry — "same family as", "sibling of", "mirror of", "refines" — and every
one was right.

### A guard that fails toward pass

A check decides whether to do something consequential — cut a tag, run a migration,
report a sweep clean. Work out which way it fails when the command *inside* it errors.
If the error path and the "nothing to do" path look the same, the guard is
indistinguishable from a working one right up until it silently eats the action.

The usual shapes: `IF=$(cmd)` tested with `[ -z "$IF" ]`, where an aborted `cmd` reads
as "nothing changed"; a loop over a computed list, where an empty list runs zero times
and exits 0; a `cmd | grep pattern` whose exit is grep's; a search whose regex the
local tool does not support, returning empty like an honest no-match; a `case`
allowlist that matches substrings rather than tokens. The mirror mistake is a guard that fails toward
**abort** on an operation where partial failure is certain — `exit 1 if errors` over
98k requests throws away completed work on a 0.002% transient rate.

**Assign first, test the exit status, then test the value. Branch on empty explicitly.
Test the guard against both known answers before shipping it** — one case that must
fire and one that must not. A guard nobody has seen fail is decoration.

**Before you believe a result.** A search that has never returned a hit has proven
nothing: run it against a known-positive first, and where the expected answer *is* zero
that control is what makes the zero mean anything. Prefer asserting the declared set is
**present** over asserting the bad set is absent — `setdiff()` the wrong way round is
empty for a subset as readily as for the full set. On a host you are diagnosing, call the
tool by absolute path from a known-good root and capture stderr separately: the diagnostic
binaries are casualties too, and their empty output reads as a finding. Count rather than
match, since `all(grepl(p, v))` is TRUE for an empty `v`.

**What the guard reads.** Treat unreadable as a third state beside pass and fail, naming
the shape you expect and asserting it. Ask what the producer writes for "missing" before
trusting a null check — `0`, `-9999`, `""` and `1900-01-01` all satisfy one — and watch
your own coercions invent one, since `as.integer("0.9")` is `0` with no warning and no
`NA`; compare against `round()` with a tolerance rather than watching for the failure
value. Ask of every assertion whether it is about **the artifact you built or the data
that happened to flow through it**, and whether it reads the artifact you write or the
frame you write it from: one direction refuses a correct release, the other passes a lost
row. Read a currency gate from the independent source it is really about, never from the
artifact it guards, and give a pin one gate per independent input. Gate on the count of
inputs that failed to **resolve** rather than on a return code, and gate it
*differentially* — a renderer reports success having loaded a degraded subset, and real
projects arrive already carrying failures, so an absolute count refuses every one of them.

**Where the guard sits.** A precondition must be evaluated where the operation cannot
influence it, and ahead of any early return: a clean-tree check placed after the run writes
its own logs fires on every run for a reason unrelated to what it guards, and a check
behind a dry-run return never runs in the mode people use to be careful. A rule stated in
a comment is not an enforced rule — where a comment says "never X", grep the file for X
before believing it.

**Which direction it fails.** Ask which costs more, and say so out loud. Toward abort:
retry in-process before an error can reach the exit code, gate on a rate against a stated
tolerance, and persist progress on the failure path (`if: always()` in CI). Toward pass:
`|| true` hides a real error, and an empty variable before `rm` or `destroy` needs
`[ -n "$VAR" ] || exit 1`. Enumerate the **complement** rather than the known-bad states —
assert every outcome is a deliberate resting place, so one nobody has thought of stops the
run. Where a new guard replaces an old one, prove they catch disjoint sets by restoring the
old. Compile flags per pattern rather than per sweep, and keep a negative control set,
because widening a guard is how it starts refusing correct content.

**The write path.** `cmd > file` truncates before `cmd` runs, so guard on `-s` and write
atomically. `file.rename()` signals failure by returning FALSE rather than erroring, and it
is usually the *last* step, after everything that could abort safely already has. Merge
rather than replace: a run that selected fewer rows than the last must not overwrite what
that one produced, and a run that selected nothing must not write at all. Where two files
must move together, move the one whose failure moves nothing first, and report a
half-completed pair as exactly that.

**Provenance, and repair.** Capture a provenance stamp — content hash, git SHA, config
digest, tool version — at the **start** of the run beside its timestamp, and write the
captured value; one read at write time describes the file as it finished, not as it ran.
And removing a loud failure can install a quiet wrong answer: when you fix an error, state
what the success path now returns and check it against a known truth. Two endpoints whose
names differ by a noun are the shape to distrust.

**Defaults that decide.** A default picking a methodology, a data scope or a deployment
target answers a question nobody asked. Make the argument required, so omission is an
**error** rather than a fallback; where a default must stay, print the resolved decision at
start-up with the alternative named.

*30 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### A fixture that cannot reach the failure mode

Hand-picked fixtures test the cases you thought of. If every one is structurally
incapable of triggering the bug class you are fixing, a green run means nothing — and
it is more dangerous than no test, because it licenses the word "validated". A fixture
that matches the code's happy path leaves whole branches not merely untested but
never executed: one raster in the data's CRS makes every reprojection an identity.

Before declaring a fix verified, ask what the fixtures have in common and whether that
shared property is the very thing the bug depends on. Vary the fixture along exactly
the axes it cannot reach. Prefer a global structural invariant — antisymmetry,
conservation, every node reaches a terminal — over more examples, because an invariant
cannot be gamed by fixture choice. And check a threshold against the **least
favourable** member of the population, computed, not the vivid one you remember.

A fixture must mirror production in **types**, not only in shape: a column that is
character in the fixture and double in production makes every sentinel and every comparison
test something production will never run.

**Assert the premise beside the property.** A negative-case fixture rots when the
positive set grows, and an environment built by *removing* something has removed nothing
still reachable by absolute path — so state the deprivation as an assertion, not as a
setup step. Before adding a transformation, ask of every existing assertion whether it is
invariant under it: area is rotation-invariant unconditionally, and a rotated **square**'s
bbox is still a square, so an area assertion and a bbox-aspect assertion both stay green
while the premise they were written for dies. On a non-square footprint the aspect does
move, which is what makes the condition worth stating rather than dropping. Ask which branch a realistic input takes before
trusting a green suite, and test the case an early return skips. Name the workload the
fix exists to restore and probe at that level — a hello-world checks that the compiler
launches, which was never the question.

A prefix of a sorted list is not a sample, and neither is a draw too small to
discriminate: compute what the sample would show *if the claim were true* before reading
a zero as evidence, and where the population is known, sample the named members rather
than blind. Take a stratified set and assert its composition before running. Make vacuity
visible — print `VACUOUS: <guard> — <arm> never ran` — so a green partial run cannot be
mistaken for evidence.

Ask what an id is unique *within*, and prefer the composite key even where today's data
makes the extra column redundant. Where a check measures variance across items, pair it
with one **absolute** assertion — a hardcoded count or key set — because an expectation
derived from the artifact goes empty alongside it, and read the schema's own `required`
and `anyOf` for the branch you actually validate rather than assuming an extension
enforces its purpose. Mocking the transport means the request is never built, so make the
wire format a pure function and assert it offline. And ask the parse tree for a symbol
rather than the file for text: a comment or a string literal satisfies a grep, and there
is always one more spelling.

*17 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### A proxy is not the property

A condition that stands in for the thing you actually want. It fixes the case in front
of you and leaves every other state with the same property wide open, because a proxy
is correlated with the property and a guard needs equivalence. The tell is a condition
naming a **mechanism** — "has no row in table X", "elapsed over 2 minutes", "block
size is 128" — where the requirement is a **capability** — "can be resolved", "is
well-supported", "costs N requests". Ask what property you were testing for, and
whether the condition is equivalent to it or merely adjacent.

Proxies compress (a 14,950x allocation difference showed as 5x in wall-clock, inside
CI jitter), and they can be **inverted** — a long GPS gap meant the subject stood
still, which is when interpolation is most accurate, so the time gate rejected the
best fixes. Assert the quantity that actually differs. Where the property is internal,
name it and observe it. Measure the sign of a correlation before trusting it.

**Ask whether your assertion could tell the property from a neighbouring value.** Measure in the unit you are
billed in: the tell is a prediction that counts one thing while the cost is itemised in
another. If two values produce identical observations, the assertion is about something
else — derive the
property exactly instead, even where that means instrumenting the thing to emit what you
actually want to count. Derive a predicate from inputs known before any route runs, never
from a field only some routes populate — that one is not fixed by measuring better. Restore the defect and watch the premise fail: a
premise satisfied by the happy path's own structure is decoration.

Where a shape test separates two things, ask whether they are distinguishable by shape at
all — a filename and a qualified name are not, and no cleverer pattern will make them so.
Where shape cannot discriminate, the check is a human naming the row, and what makes that
naming load-bearing is refusing, on the other side, the shape that would let an unnamed
value pass by accident: a file extension where a table token is wanted. Say in the comment
that shape cannot do it, rather than implying a cleverer pattern would. An identifier that can be copied,
installed, restored or synced identifies a **configuration**, not an instance, so ask
whether the thing being identified is the artifact's only possible author. Distrust an
"update the existing one" API that matches on an identifier it *derives* rather than
reads, because the derivation is what a third party will not reproduce.

Do not filter on one property to test another when the two correlate — hold the
confounder fixed and stratify, or the result restates the confound. Keep one named column
per axis and let the consumer rank: merging independent legs discards what each knew,
merging dependent ones counts one measurement twice, and both surface as a single plausible
number, so there is no measurement at which merging becomes right. Measure independence to
decide whether two legs may be **cited as corroborating**, which is a different question. Where a strength already exists as a number, publish it rather than a
boolean derived from it. And check the grain — an aggregate row is not a place. Where a proxy selects a population,
bound it on a criterion **the subject itself names** — its own identifiers, its own boundary
— not on a threshold of your choosing, and check what the evidence is framed on, because a
view built from the same selection cannot show you what the selection missed.

For "nothing else moved", a line count is a proxy and your own next commit is what
falsifies it. Compare the **remainder**: strip the subject from both the old and the new
file and check what is left is byte-identical. That holds however many lines the edit
touched. In structured text the remainder compare does not know about nesting, so it cannot
see an orphaned child: check whether the element you are deleting has children, then parse
the result and assert it is well-formed.

**A guard proving that some check has complete COVERAGE must ask a wider question than
the check does.** Asking the same question makes it structurally unable to catch the
check being wrong — it agrees by construction. So when a sweep and a checker share a
predicate, the sweep is not evidence. Widen the sweep to a deliberate superset, and let
anything it finds that the checker does not land in an explicit *unknown* bucket that
reports itself. The tell that the predicate is narrower than the property: a member of
the population the check already handles that the sweep cannot see — that member is the
control, and it costs one query to look for.

*17 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### Verification that reads its own output

A check whose reference was produced by the thing it checks cannot disagree with it.
Hash-on-write proves nothing changed *since you hashed*; a reference generated by
feeding your artifact to the consumer is your artifact with a blessing; a round-trip
through your own reader validates only self-consistency; a verifier on the writer's
library shares every blind spot the library has; a probe that reads back the value it
was handed is a round-trip through your own assignment. Every one returns identical,
forever.

Measure at the furthest downstream point you can reach — the rendered primitive, the
bytes on the wire, the row as the consumer's own client reads it. Ground truth is the
**consumer's own output**, constructed from inputs that are not your artifact. Diff
the bytes at the boundaries, not just the parsed structure. And for every field you
write that your own code never reads back, name what does read it.

A checksum you compute yourself cannot detect corruption that predates it, so check the
transfer that produced the bytes — `file.copy()` signals failure by returning FALSE rather
than erroring. Put the guard on the consumer having **read** the file, not on the write
having succeeded, and round-trip through the real consumer once. Suspect the serializer's
defaults while you are there — this one failed toward *absent*, which reads as "nothing to
find", while the sibling mechanism's defaults fail toward a plausible *value*. Establish
which direction yours takes before searching. A check's detect step and its explain step must use the same predicate, or the
explanation comes back empty for a difference the detector found.

Assert on the artifact the writer produced, never through anything that canonicalizes it.
Canonicalizing both sides of a diff is fine; asserting *through* a normalizer is not — where
a reader resolves, defaults or canonicalizes on the way in, an id back to a name or a missing
field to its default, it erases the defect you are proving, because that is its job.

A suite that validates **shape** can be complete and never read a value. Re-derive each
published number from the artifact it names, and prove the suite can see it by mutating one
value at a time.

Before building an A/B, name the input you are varying and confirm it reaches both the
cache key and the request on the wire. If it reaches neither, the two runs are one run
and the comparison cannot fail — say the property holds by construction rather than
dressing a tautology as evidence.

*11 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### A guard's scope, escape hatches, and remedies

Every guard grows the things that silently disable it. An **exemption list** that
covers every input makes the assertion unreachable — and reads as more careful than
the correct version because it is longer. A **lookup** that matches a container rather
than the artifact checks a stranger's copy. A **literal set** used as a filter covers
whatever the data happens to contain today and grows blind as it grows. A guard that
compares against a **vendored witness** is pinned to the copy, not the world. A guard
that reads a **coarser grain** than its property passes on the grain. A **remedy** in
the error message is code the caller will run, and nothing checks it.

Read the escape hatches before the assertion. Enumerate the inputs programmatically
and diff against the declared set. Require a reason on every exemption — one whose
reason says the rule *is* satisfied is an entry to delete. Pin scope against its
source of truth. For every literal a guard rests on, ask whether it is a **contract this
repo chose** — hardcode it, because a derived expectation cannot fire — or a **fact about
a third party's behaviour** — read it from the artifact, because a value reasoned from how
a producer behaves is where the accidental scope comes from. Terminate by enumeration,
not by a reviewer saying you have converged: the class recurs one axis over, and three
"this is now terminal" claims were wrong on one PR.

That literal rule is a binary and there are three cases. A **set** — which layers exist,
which columns a schema declares — has a source of truth to derive from. A **judgement** —
which column means drainage area, which basemap is opaque — has none at all, so it is
hardcoded like a contract; **deriving one is what inverts the guard**, and the derived
version is the one that reads as careful. Keying a judgement to whatever a formal or a
default holds today couples the guard to a value free to move for unrelated reasons, and
the test does not save you: its premise line reddens, reads as "the default changed, update
the expected name", and that repair leaves the suite green with the guard pointing the
wrong way.

**Write the partition down beside the guard**, because it is what the next person will
get wrong — and better, *return* it (`list(bad, other)`) so "the halves are disjoint and
together cover everything" is a property a test holds rather than a convention each call
site has to remember. Key the guard to the **outcome**, never to the flag that caused the
defect: "did what was asked for survive?" cannot be defeated by the next narrowing flag,
where a per-flag rule has to be re-derived for each one and the third one misses again.
Where a check names an artifact, check it by name *and* pair it with a catch-all
complement, since the two arms catch different things.

"Already current" and "never regenerated" are separated by **regeneration status, never by
equality** — a comparison whose two sides can share one source is blind exactly where nothing
was updated, so ask whether the producer left a record that it ran. A byte compare does not
rescue it, answering "same build?" rather than "same content?", and a tolerance on a content
measure mislabels the near misses. Walking every source and comparing against their *union*
has the same blindness: compare **per source**, or an item present in one and absent from
another passes.

Escape hatches have a second trigger, running the other way: **when you add a guarantee, grep
the bypasses.** A flag justified by "X always holds" is silently wrong the moment X stops
being the whole requirement, and nothing about the flag changed, so nothing points at it. The
hatch may also be in your own diff, written by you in the same hour for a good reason. And a
guard written against the whole artifact silently redefines every mode that passes it a
**subset** — the mirror of keying to the outcome, a wrong refusal of correct input rather
than a silent drop. The line is whether an arm names an id the subset contains.

Read the upstream that imposed a constraint before designing around it, not the guard
encoding it nor the prose describing it — a guard that refuses looks exactly as correct
on its last day as its first. Read a shipper's exclusions out of the shipper rather than
restating them, and assert that parse rather than trusting it: an empty pattern set fails
toward refusal, but one containing a bare `*` blesses everything. Before relying on an
upstream guard, pass your real arguments and confirm it still fires — grep your call
sites for every parameter its condition reads, because a default you never think about is
what disarms it. Where a guard compares against a vendored witness, add a currency check
gated on the source being present (skipped in CI, out loud) and stamp the date or upstream
version beside the copy.

For remedies: **run the remedy yourself, for every input the clause can receive**, and
check it finished the job rather than merely running — a remedy that repairs the subset it
knows about reports success and leaves the rest. Ask
what someone would *do* on reading the message, not whether the guard fired — a guard can
fire correctly and point at the wrong fix. A remedy repeated across sibling messages is
one claim written many times, so hold the sentence in a single internal constant, with a
test asserting each caller reaches it **and carries no copy of the old wording**, proven by
reverting each site; fixing instances is what keeps that class alive. When a property is
enforced by several mechanisms, name every one and verify against the artifact each
produces, with a positive control — and when two requirements conflict outright, find the
third option rather than trading one off.

Terminating means enumerating every claim a diff makes about behaviour elsewhere and
executing each. Enumerating by the *place* a claim lives — error message, roxygen, comment,
test comment, CLAUDE.md — is not enough. A restatement names its population **six** ways:
count, member list, rank or superlative, what a sibling assertion catches, behaviour of a
second function, universal quantifier. Only the first is reachable by grepping for digits.
Sweep each across **four** subjects: the thing being built, the source data, record-level
measurements, and external systems. Note which restatements carry a time qualifier —
"measured before", "then-", "when #N landed" mean *do not re-point*, while a present-tense
justification for a live guard must track. A reviewer's prescribed wording is an unexecuted
claim too, so execute it rather than adopting it. And where a claim is a **compression** of
several sources — a rule promoted out of its instances, a summary over a measurement set —
execute it against each source rather than against itself: the compression reads correct on
its own, and the condition it dropped is visible only in the thing it compressed.

*23 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### A fix lands in one of two callers that share a harness

Two entry points over one library, two workflows over one action, two scripts sourcing
one shell lib. A defect found through one caller gets fixed there, and the sibling
keeps it — silently, because the shared code is fine and nothing compares the callers
to each other. The count is the signal, not the instance: if you have fixed the same
class twice in one of a pair, the pair is the bug.

Fix in the harness where the behaviour belongs to it. Where it genuinely belongs to a
caller, grep the sibling in the same commit, and assert the shared policy is the one both
use rather than trusting an import to have been wired up. But a grep finds a symbol you
changed and cannot find one that was never there: where the fix **added** a behaviour
rather than corrected one, diff the two callers' contracts — options, guards, completeness
statements, what each does on a degenerate input — instead of searching the sibling for the
token you just wrote.

*1 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### Restore the bug and prove the guard fires

A test that stays green against the code it was written to reject is decoration, and
reading it will not tell you. Put the defect back, run the test, watch it go red. Pull
the exact prior bytes from git — a hand-rewritten "previous version" is a different
program, more likely to fail than the real defect was, so a green reconstruction proves
nothing and a red one proves almost nothing. And print a value that proves the patch
took: in R, `load_all()` creates two bindings, and patching only `asNamespace()` leaves
test code calling the original. Then run the file with `testthat::test_file()` —
`test_local()` and `devtools::test()` reload the package and discard the patch.

**Read the proof's output, not its exit status — in both directions, and the two
directions want different remedies.** On exit 1, grep for the message you expect: a suite
with N guards has N ways to exit 1 and only one of them is your evidence. On `rc=0` there is
no message to grep, because no guard fired at all — check instead which copy of a
deliberately duplicated literal the assertion reads, since mutating the builder's copy
leaves the validator's untouched and a correct pass gets reported as a broken guard. Assert
the mutation took before trusting what follows it: a plain-text replacement against serialized XML matches nothing once the
writer has escaped the character. Count `r$failed > 0 | r$error` and print both, because
a restored defect that *aborts* scores zero failures and reads as a guard that is
decoration; a failure means the assertion disagreed, an error means execution never
reached it. Read the returned object rather than the console, since reporters truncate at
ten and the knob differs per reporter.

Where the code under test might hang, wrap the assertion in a deadline and distinguish
its 124 from a real non-zero — `timeout` is GNU coreutils and absent from a stock Mac, so
reach for the portable `with_deadline()` in `code-check-shell.md` — an assertion with no deadline can only pass or hang, never
fail, so restoring the defect turns the suite silent rather than red. In R, name the
mocking target and the unwind scope separately, `local_mocked_bindings(f = stub, .package
= "pkg", .env = parent.frame())`, and `force(x)` inside a stub, or a piped inner call is
never evaluated and the spy on it stays empty. When a mock is installed and not reached,
prove the call was evaluated before blaming the mocking tool.

Where a fix changes *which* argument a caller passes, drive the **caller**, not the helper:
a test calling the helper with hardcoded literals proves the other value and stays green
through the restoration. Spy on the helper so it records the argument and delegates,
resolving the real function **before** installing the spy, or it records its own delegating
call. And two restored variants failing an identical count may be one proof rather than two,
since a fake answering either input exercises one path — treat a matching number as a tell,
not a corroboration. A guard added mid-review is itself unguarded, and de-vacuuming one
assertion moves other variants' counts, so re-measure the whole table against the final tree
rather than carrying earlier rounds' numbers forward.

**Before restoring anything, ask what would have to change for the predicate to be true.** Restoring the defect is the proof, but it costs a run; this costs a read, and it catches the case restoration was never going to reach — a guard whose two operands are *derived from each other*, so no caller can make them differ. That guard has no true branch at all, which is a different failure from one that can fire and does not. Its tell is that the comparison's inputs trace back to one source a few lines up. Relatedly, a minimum-sample floor must sit well clear of the group it protects: at the floor exactly, an order statistic still ignores the tail it was added to inspect.

*14 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### A shared working tree, and what generators leave in it

A working tree has one checked-out branch. Two sessions in it can `git checkout` out
from under each other mid-edit, and uncommitted work then sits on the other session's
branch — a later commit lands it there, a `--delete-branch` strands it. Worse: a
`git push -u origin main` pushes the local ref named `main`, not `HEAD`, so a commit on
the wrong branch prints `Everything up-to-date` and nothing was sent. Generators —
config regenerators, formatters, `csv.writer` rewriting every line's terminator — put
side effects in the tree that `git add -A` sweeps into a commit describing something
else. And running a generator is not committing what it generated: a build in a temp
dir leaves the repo's artifact stale while the author truthfully reports having
verified it.

One worktree per session (`-b <new-branch>`, chained with `&&`). **The tag and release
step needs a worktree too.** Every example here is an edit, so a reader who follows the
rule still runs `git checkout main && git tag` in the shared checkout — which was on
another session's branch with 281 lines of its uncommitted work when it happened
(soul#141, 2026-09-01; nothing broke, by luck). Release from a throwaway tree detached
at `origin/main`, push `HEAD:main` and the tag from there, and leave the shared
checkout's `main` alone; `gh-pr-merge` step 5 carries the form. Assert the branch
before any commit or flip. Stage by path. Generate from the committed tree, never the
checkout — a mid-edit source is internally inconsistent, which is worse than stale.
Verify the artifact after a push, not the push output. **And a dirty peer repo you are
only passing through is someone's in-flight work, not leftovers** — `git pull` reporting
"Already up to date" says nothing about the working tree, and staged edits are invisible
to it. Do not tidy, commit, `git checkout .` or `git add -A` in a repo you came to read.

Recovery, when it has already happened: back up the touched files, confirm the other
branch's changes do not overlap yours, and `git checkout <your-branch>` carries
uncommitted work across. If you committed onto their branch, restore their pointer with
`git branch -f`. If their branch has an open PR, cherry-pick forward through a throwaway
worktree rather than force-pushing into someone else's PR.

Read `git status --short` before every commit and expect exactly the paths you mean: a
second `M` on a file you already staged means the commit ships the pre-edit copy, so
review `git diff --cached` rather than `git diff`, and `git restore --staged` anything you
set aside. Before branching in a shared checkout, check the current branch and status
first — `git checkout -b` starts from whoever else's branch is out and carries their working
tree with it, and `git checkout -b x main` pins the base while still carrying that tree, so
only a worktree separates both.

For a generated artifact, render twice and compare digests before committing it, then fix
whatever differs — seed the id generators and pin the timestamps; a renderer that reaches
the network to inline a remote asset cannot be pinned at all, so keep remote images off the
self-contained target. When editing a file in place, edit only the lines you own and
reserve the full serialize for the create path — a config round-trip silently drops
comments, key order and equivalent spellings, which is the only record of *why* a setting
is what it is, so assert the comment lines survived. On delimited text that rule is
**conditional**: plain-text replacement only where the field is already quoted or the
inserted text carries no delimiter, and a full rewrite (with an explicit line terminator)
only where every data row is being edited anyway. Append with an explicit line terminator
rather than rewriting, and diff before staging — staging by path does not protect you when
the churned file is the one you are staging. Line-oriented readers normalise:
`readLines()` strips a carriage return and does not restore it, and so do
`readr::read_lines()`, `open(newline=None)` and `$(cat f)`. Split the raw bytes on the
newline, rebuild only the target lines, and assert the carriage-return and line counts
unchanged — the carriage-return count is the check that fires. Afterwards assert the field
count per row and the reader's column names, because a column shift produces data that
still parses.

*13 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### A wrapper's exit is not the work

A wrapper reports its own exit. `caffeinate`, `time`, `ssh … | tee`, a background
task, a per-item loop, a `;`-chained pair — all routinely surface exit 0 while the
inner job hit `Execution halted`. Merging stderr into stdout corrupts the stdout you
parse, and only on a long line; a `\r` progress bar on stderr makes interleaved log
lines vanish entirely; `system2()` quotes the command and pastes the arguments raw, so
a path with a space silently splits and the empty stdout reads as "nothing to report".

Gate on the artifact: in-band error markers (`grep -c "Execution halted\|Error:"` is 0)
**and** the output's mtime is newer than a marker touched at run start. `set -euo
pipefail`, `&&` between steps of one operation, stderr to a file whose contents you
carry onward (not its path — a temp file is gone by the time the assertion needs it).
Read the exit status, not just the output.

Never silence stderr on a mutating command, and never chain one with `;` — the failure
then surfaces a command later, describing a symptom rather than a cause. Test the
command, *then* format: **without** `pipefail` a `|| fallback` placed after a pipe is
unreachable, because the exit status belongs to the last stage, so a branch meant to always
print something prints nothing and reads as "checked". Since the same rule prescribes
`pipefail` two paragraphs up, know which shell you are in — `if cmd >/dev/null 2>&1; then …
else … fi` is right either way. For the `system2()` trap the shapes paragraph already names:
`shQuote()` every path argument, read `attr(out, "status")` rather than the output alone, and
remember it *raises* on a missing command, so a skip written after the call never runs.

*7 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### Zero-length, empty, and unset are three different things

`paste0(character(0), "x")` is `"x"` — one phantom row from an empty frame. A
zero-length value in a row-builder yields zero rows, so the whole group vanishes from
a `map_dfr()` and the output looks correct, just shorter. `x == character(0)` is
`logical(0)`, so every branch is false and the fallback runs — usually *create*,
producing an unnamed object rather than an error. `VAR="${A:-}"` sets the empty
string, which passes a presence test (`"PROJ_LIB" in os.environ`) that `unset` fails.
`names(character(0))` is NULL, which `expect_setequal()` refuses — so the guard breaks
the day you finally earn the empty state.

Guard the empty frame explicitly (`if (!nrow(x)) return(character(0))`). Fold to a
scalar at the boundary (`sum()` over `st_area()`). Test the argument, not the search
result. Build commands as arrays and add an assignment only when there is a value. Use
`stats::setNames(character(0), character(0))` and say why.

Absent, present-but-empty and present-with-a-value are three states, and most null checks
collapse the first two — `"x" %in% names(cfg)` discriminates, being TRUE for present-empty, which keeps an explicit
`x: false` legal where `is.null()` cannot,
which matters whenever a guard written to catch a *wrong* value sits on a key whose
*absence* also means something. And never write `[ -n "$X" ] && arr=(…)` as a bare
top-level list: under `set -e` a false test aborts the script. Use an explicit `if`.

*6 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### The probe is broken before the world is

When an ad-hoc probe reports that long-shipped code is broken, the prior belongs on
the probe. The tell is an obviously-correct item in the failure list: a probe reporting
13 things missing, one of which you can see with your own eyes, is wrong about all 13.
A 100% failure rate on shipped code is as implausible as 50%. A 200 with a perfect
schema can still be a placeholder image or a "trial expired" page — every cheap
assertion passes because the shape is right and only the meaning is wrong. And
constructing a sibling path from a known-good one assumes a uniform naming convention;
the 404 then reads as "does not exist" rather than "I guessed wrong".

Print a positive control. Reconcile the count against the population. Enumerate the
container rather than construct the path. Inspect the bytes you are acting on, never a
formatted rendering of them. When a claim is flagged as under-evidenced, narrow it —
widening adds a quantifier over a population you have not enumerated, and on one memo
every widening broke and every narrowing held.

**Fetch the authoritative copy of anything a claim rests on.** A synced working copy is a
replica with a version number, and reading it answers a question about your disk. Such a
store has git's `fetch` analogue and it is not always git — a Mergin status call, `head-object`, a
`SELECT max(version)`, an ETag — and the tell is simply that the thing *can* be behind.
Re-confirming a claim against the same local copy that produced it is agreement, not
verification. A differential baseline expires the same way: it is only valid against
`git merge-base HEAD origin/main`, re-derived when you use it, not when you branched.

**A component read alone is not the artifact anyone sees, and the composition usually
absolves it.** Read the producer's own definition of a value before inferring a grammar
from the values, and enumerate everything drawing at the same place before calling
anything invisible. Ask what else is in the frame.

**Before attributing a difference.** Enumerate everything else that differs between the two
sides — a copy is a treatment, so is a different directory or a warm
cache. Check the instrument is stable within one version before comparing two: run the
same input twice. Date a passing sibling's pin against the event before treating it as a
control, because one re-pinned afterwards is a photograph of the new world. Ask which
config file actually loaded, since the positive control is the same command from a
different working directory.

**Before believing a rate, or a response.** A valid response is not a correct one: services
fail in the shape of success, serving a
watermarked tile or a "trial expired" page through every cheap assertion. Prefer providers
that cannot enter the degraded state, detect only the degenerate cases you have measured as
separable, canary on a human's machine rather than in CI, and warn rather than discard.

For a rate, count both sides with independently justified filters and re-run the
denominator's filter one notch looser before believing it, then ask what the predicate is a
proxy for. Several independent subjects reporting an identical count is itself the
finding. When a rate survives one correction, ask who else knows what the number means.
**Before believing an error, or an absence.** Read an error's own words before matching it
to a remembered failure, and check the shape
matches: a hang and an immediate error are different bugs. Where a convention ranks routes,
confirm the preferred route's prerequisite is genuinely absent rather than merely having
errored once. Before concluding an
artifact's presence is unknowable, grep the **producer** for the path it writes — and
treat a self-filed "blocked on X" as a claim to re-test, since nothing downstream ever
will. **Write the numbers last**, against the final tree, and re-measure when a fix lands after
the prose — the second actor staling a figure is usually you, one commit later.

*17 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

| 2026-09-12 | rfp#328 | **Two test runs with different SKIP counts measured different populations, so their FAIL sets cannot be compared** — three full-suite baselines on one repo in six days reported FAIL 6, FAIL 0 and FAIL 8, and **no two named the same file**, which reads as a flaky suite. The SKIP column settles it: 34, 1, 1. The first run had no Docker, so every container-gated test was skipped; the run reporting 8 had one, and all 8 failures were container-gated. The two sets are disjoint by construction, not unstable. **Read SKIP before attributing any difference in FAIL** — a differential is only a differential when both sides ran the same tests, and host capability decides that as much as ordering does |

### Written data outlives the fix

Changing the writer changes nothing already written. The code is correct, the tests
pass, the issue closes — and every existing record keeps the defect, sometimes
self-perpetuating when a job reads the published artifact back and rewrites it. A
change-detection cache persisted at detection time strands every input whose
processing then fails, invisibly, forever. A cache keyed by fewer inputs than the
write depends on returns plausible wrong data. Tightening a consumer's assertion
breaks every producer that legitimately left the field empty, and the producer that
bites is the install script nobody thinks of as one. Teaching a build step to record
provenance makes it safety-critical: a wrong SHA satisfies every guard built to catch
its absence.

Reconcile existing records — rewrite in place, do not rebuild through today's code
path. Write caches last, or atomically with the output. Over-key, never under-key, and
hash resolved values, normalising types first, since `10L` and `10` hash differently, and
canonicalise before you serialise, since two equal values can have unequal serialisations
for reasons the type system does not see.
Check the `force` escape hatch actually overwrites, preferring the writer's own
`overwrite = TRUE` to a bare `unlink()`. Grep the producers before tightening the
consumer, and move the check as early as the fact is knowable. Gate a provenance write on
the build's own exit status; pin only what has no other identity; resolve an identifier
once per run.

Ask what a persisted entry *claims*, and whether the thing it claims actually happened —
where that depends on a later step, gate the persistence on that step rather than on the
one that produced the entry. Before renaming an identifier, enumerate every system that
keys on it and ask what each does with a reference it no longer recognises: "ignores it"
and "garbage-collects it" are both common, and only one is safe to ship ahead of the
others. Where they cannot be changed together, name the window's real cost in the release
note: if a consumer garbage-collects the unrecognised reference, the window **deletes**
rather than delays, and writing "delays" invites a reader to wait it out. When a derived
value changes, enumerate every artifact quoting it — repo prose, release notes, PR
descriptions, issue bodies in every repo you filed into — and verify a filed body by
**parsing** it rather than reading it, because `5.08` against `5.09` survives any number of
careful re-reads. An inventory is only complete relative to a boundary, so name the boundary.

Finding the records already written is the hard half, because the bad state is internally
consistent: **diff the ledger against the artifacts it claims** — cache entries against
outputs, manifest rows against published objects — rather than trusting either alone. And
measure the defect's magnitude where it lands, since it is dataset-specific: ask what is in
the denominator before calling a proportional claim safe, because a ratio is stable only
when its denominator sits inside the affected region too.

*10 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### Serialization loses meaning silently

A serializer's default for "no value" is rarely a null: `NA_real_` becomes the string
`"NA"`, R `NULL` becomes `{}`, GDAL has no null and `str(None)` writes `'None'` — each
a valid value every schema check accepts, and `{}` passes `is not None` on the far
side. A rename emits two signals — an expected key missing, an unrecognised sibling
present — and reading only the first cannot distinguish rename from absence; the
ambiguity is different at each depth, so it recurs one level out. A system that both
records and renders drifts: the sidecar computed `finish(start(x))` on one line and
reported 0.0 s for a multi-minute build. A structure transcribed from an external form
is a snapshot: the 2026 permit portal swapped Easting and Northing columns. In-place
metadata writes move a COG's IFD to the end — still valid, still hash-verifiable, no
longer cloud-optimized. Raw XML/JSON diffs report attribute order as drift.

Set `na=` and `null=` explicitly and say why; build records with `list()`, never
`[[<-`. Reject unknown keys where the set is closed, pin the key shape where keys are
data. Prefer the record over the rendering. Assert on magnitude or format, not
position. Order the layout-aware writer last, and assert the property (`cog_validate`),
not the parse. Canonicalize before diffing, and name every field you mask. Put the same
flags on any preview path, or the preview is not what gets written. Write the character,
not the entity — then read the file back and grep for what should not be there, because
a document that parses is not a document carrying its fields. And never rebuild structure
by splitting a joined string whose separator can occur inside the parts: carry the
structure from where it was built, or the split invents members that were never there.

*9 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

### One fact derived twice

A count taken from one artifact and the things counted produced from another, with a
guard comparing the two. It fires on healthy input, and because it looks like
diligence the fix goes onto the inputs rather than the comparison — so it comes back.
Line tools disagree with each other and with the truth: `wc -l` misses an unterminated
last line, `grep -c ''` exits 1 on an empty file under `set -e`, and both count lines
rather than records. A paged API's default page is a well-formed 200 whose missing
items read as *absent from the server* rather than *not requested*, and it survives
review because the fixture was smaller than the page.

Derive the expectation from the artifact the consumer actually consumes. For each
guard, name the producer of each side; if they differ, it can fire on good input.
Count records by parsing, not with a line tool — and where a line count is unavoidable,
put it in one helper checked against all four inputs: empty, unterminated, terminated,
missing. Set the page size explicitly on every request treated as evidence, and assert it
at a size larger than any plausible default.

Those two prescriptions pull opposite ways, and the distinction is what you are deriving. A
**count** of things you will iterate must come from the same list you iterate, or the two
sides have different producers. An **expected set** a subject is checked against must come
from a producer the subject **cannot influence** — build it from the deployed artifact and
`setdiff()` comes back empty on exactly the file the check exists to flag. The iteration
must then walk that expected set rather than the subject's, or a missing member is invisible
too. Compute a
measurand, its weight and any stratum threshold on **one** population, and where a
boundary case is excluded from one table and included in another, publish the reconciling
count rather than the difference — one column name carrying different populations across
files is this same defect with nothing duplicated to notice.

Terminate by enumerating every derived column with its population and its precision, and
showing none disagrees with its name — a quiet review round cannot close this class, because
the columns are individually right.

Partition every literal a change rests on: a **contract this repo chose** is hardcoded,
because a derived expectation cannot fire, and a **fact about another artifact** is read
from that artifact or the code stops on divergence. Enumerate them mechanically. A
curated list misses the ones inside strings that get *printed* — titles, captions, alt
text — which is exactly where a wrong literal hides, because nothing consumes it.

*6 recorded instances of this are in `conventions/code-check.md`, which `/code-check` reads in full.*

## Rules that stand alone

General, and not an instance of a mechanism above.

### Do not edit files a long test run is reading

- `devtools::test()` (and most runners) load each test file **when they reach
  it**, not at launch. A 30-minute run therefore reads whatever is on disk at
  that moment, so edits made while it runs are half-applied and the result
  describes a tree that never existed.
- The tell is a **changing pass count** across runs of "the same" tree —
  3490, then 3496, then 3500. A moving denominator means the input was moving.
- Cost 2026-08 in rfp#178: two full Docker suites (~1 hour) both reported
  `FAIL 1`, and the failure was a test written *during* the run, executing
  against source from *before* the fix that made it pass. It was nearly reported
  as a regression.
- **Commit before a long run.** While it runs, do work that touches nothing it
  reads — issue bodies, PR text, planning. And when a long run fails, get the
  `file:line` before forming any theory: a mid-flight edit and a real regression
  look identical in a summary line.

### Test a persistent change through its per-process override first

A setting that is changed once and persists — `xcode-select -s`, a git config key, a
registered default, an installed symlink — usually has an environment variable or flag
that overrides it **for one process**. That override is a free experiment: it answers
"would this fix it?" without sudo, without mutating the machine, and without anything to
revert if the answer is no.

Reach for it before proposing the persistent form, not after someone doubts you.

```bash
# proposed:  sudo xcode-select -s /Library/Developer/CommandLineTools
# tested first, read-only, no sudo:
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/python3 -c "import pyexpat"
```

Caught 2026-09-07 in rtj#296. A fix was proposed from inference, doubted on a plausible
mechanism (the broken framework sat outside the directory being switched away from, so the
switch might be a no-op), and a review was spawned to settle it — when one environment
variable answered it in a single read-only command. The inference happened to be right; the
cost was a review cycle and a recommendation the user was asked to trust on reasoning rather
than evidence.

The general shape: **before recommending a change someone else has to apply, find the
cheapest thing that would falsify it.** A persistent setting with a per-process override is
the easiest case, and the one most often missed because the override is documented as an
advanced feature rather than as a test harness.

Same family as "It can only be answered by testing is a claim with an author" in
`karpathy.md`, pointed the other way: there the claim is that something *cannot* be cheaply
tested, here it is that something *must* be applied to be tested. Both are worth one probe
before being believed.

### Adopting Existing Config

When importing config from one location into a canonical one (legacy `~/.bash_profile` → dotfiles repo, old script's env → repo, another project's `settings.json` → soul):

- **Verify every referenced path/binary exists.** Dead PATH exports, missing interpreters, stale env vars should be cut, not codified.
  Shell paths: `for p in $(echo "$PATH" | tr ':' ' '); do [ -d "$p" ] || echo "DEAD: $p"; done`
- **Ask before dropping a reference** — it may be something the user forgot to reinstall on this machine, not something to delete.
- **Curated subset, not verbatim copy.** The diff should reflect what you verified, not the whole source.

### Test the cold/create path of idempotent code, not just the warm no-op
- Idempotent provisioning code (a resolver-file writer, a config installer, a "create unless present" block) has two paths: the **cold** path that actually creates/writes, and the **warm** path that detects "already present" and skips. They exercise almost-disjoint code.
- Testing only on a host where the artifact already exists hits **only the warm no-op** — which cannot catch any cold-path bug: missing-directory, a derivation that returns empty, a pipefail abort before the write, wrong permissions, a flush that never runs. The warm path's job is literally to do nothing, so a green warm test proves almost nothing about onboarding.
- Every fresh host runs the **cold** path — that's the one onboarding depends on. Test it deliberately: back up + remove the artifact, run cold, assert it was created correctly, then re-run to confirm the warm no-op. (Caught 2026-06-23 on rtj#75: the resolver-writer's first test plan only ran the warm path on a host that already had `/etc/resolver/<suffix>`; a Plan-agent review flagged that the cold path — the one every new host takes — was untested. Fixed by `sudo rm`-ing the file and running cold before close.)
- Generalizes beyond shell: any "ensure X exists / converge to desired state" operation — Terraform resources, migrations, package installs — wants the from-absent path tested, not just the already-converged re-run.
- **The warm path is not always the trivial one.** "The warm path's job is literally to do nothing" holds for a provisioning check and inverts for anything that *compares before deciding* — a signature check, a schema diff, a content hash. There the warm path runs the most code and the cold path is the one that skips. A suite whose fixtures always build into a fresh `withr::local_tempdir()` only ever runs cold, stays green, and the comparison it never reaches can be outright broken. Caught 2026-08-28 in rfp#207: the signature built its geometry names with `paste0("gpkg_geometry_columns.", character(0))`, which is length one, so `setNames()` errored on a child table with no geometry row — but only against an existing file, so `devtools::test()` passed and `build_forms.R`, the one caller rebuilding in place, failed. When the code compares rather than converges, add a rebuild-in-place test.

### Do not write to an artifact a human is testing on

- Handing someone a deployed thing to test — a synced project, a staging
  database, a preview build — and then continuing to push changes into it makes
  two writers for one artifact. The tester chases versions, and any client-side
  lock or "another process is running" error that follows is **yours**, not
  theirs to debug.
- It also corrupts the evidence. When the tester reports a problem, you no longer
  know which version they were on, so a symptom cannot be tied to a change.
- Caught 2026-08-26 in rfp#186/#196: three pushes into a live Mergin project
  during a field test, taking it from v1 to v9 while the phone was syncing. The
  app reported "another process is running" and the tester tried removing and
  re-adding the project before the cause was identified as the other writer.
- Rule: **hand over one version and stop.** If a fix is needed mid-test, say so
  and let the tester decide when to take it. Batch changes rather than pushing
  each one. When you must push, say which version you pushed and what changed, so
  a later report can be anchored to it.

### Percent-encode a URL at construction, not at consumption

- A URL built by string-concatenation from filenames inherits whatever those
  filenames contain. An unencoded space is accepted by lenient clients — browsers,
  `aws-cli` — and rejected by strict ones, so the break is deferred and then
  arrives all at once.
- Caught 2026-07 in stac_dem_bc#25: hrefs carrying literal spaces worked for
  months, then every strict `curl` fetch failed together — 90 items, 0-byte
  fetches. Nothing changed about the hrefs; the consumer changed.
- Encode where the URL is **built**. Encoding at the point of use means every
  future consumer has to remember, and the one that forgets is the one you find
  out about in production.

### A preview flag is only safe if it previews

- `--dry-run`, `DRY=1`, `--plan` conventionally mean "show me what would happen".
  **Nothing enforces that.** A flag that skips the *expensive* step while still
  performing the *destructive* one is worse than no flag, because it is exactly
  what people reach for when they are unsure.
- Symptom: you run the preview to check something unrelated, and `git status`
  afterwards shows deletions you never asked for.
- Caught 2026-08-27 in floodplains#44: `run_region.R` prints
  `[DRY] plan + configs written; no pipeline runs` — it skips the pipeline, not
  the config write. A `DRY=1` run to verify an unrelated one-line change deleted a
  watershed group's second-species scenario rows, every literature citation in two
  `flood_scenarios.csv` files, and a `break_points.csv`. 50 deletions from a
  command documented as "plan only".
- Before trusting one, read what it actually gates. If you own it, make the flag
  return **before the first write**, not before the first slow call.
- Cheap audit either way: run `git status` immediately after a dry run.

### Bare `y`, `n`, `on`, `off`, `yes`, `no` are booleans in YAML 1.1
- The YAML 1.1 core schema resolves `y`, `Y`, `n`, `N`, `yes`, `no`, `on`, `off`, `true`, `false` (and their case variants) to **booleans**. Most parsers in wide use — libyaml, PyYAML, R's `yaml` — still do this.
- So a column, key, or field literally named `y` stops being a string the moment it is written unquoted:
  ```yaml
  cols:
    - name: y        # parses as logical TRUE, not "y"
  ```
  Nothing errors. The consumer simply never matches that entry again, and whatever it was supposed to do to it silently does not happen.
- Bites hardest in **schema and config files**, where single-letter names are normal: coordinate columns (`x`, `y`, `z`), flags, short codes. Quote them: `- name: "y"`.
- Caught twice in one file 2026-08-24 (crate#9) — once in a canonical column list and once in a variant's column list. Both found by a guard that asserted every declared name `is.character()`; reading the YAML had not found either.
- Worth an assertion rather than vigilance: after parsing any config that carries user-chosen names, check they are all strings. The failure is invisible otherwise, because the wrong value is a perfectly valid one.

### Documentation Staleness
- Moving/renaming scripts: update CLAUDE.md, READMEs, usage comments
- New variables: update .tfvars.example
- New workflows: update relevant README

### An ordered dispatch makes severity ordering load-bearing, and nothing enforces it

A `CASE`, an `if/elif` chain, or any first-match dispatch that reports a *verdict*
carries an unwritten invariant: every serious arm precedes every advisory one. Adding
an arm is the natural edit; ranking it correctly is a judgement — so the invariant
breaks quietly, and the symptom is a real failure that is never printed.

It recurs one axis over, which is the tell that the class is wrong rather than the
instance. Measured across three rounds on one file (link#262):

| round | edit | result |
|---|---|---|
| 1 | added a NOTE arm under a FAIL | shadowed the FAIL two lines below it |
| 2 | partitioned FAILs above NOTEs, wrote the invariant in a comment | correct, briefly |
| 3 | added a *conditionally* sanctioned state into a FAIL slot | shadowed the same arm again |

The invariant was never "FAILs before NOTEs" but "every arm above the line is
**unconditionally** a failure" — which no comment reliably enforces.

**Accumulate instead of dispatching.** Report every condition that holds:

```sql
coalesce(nullif(concat_ws('; ',
  CASE WHEN <a> THEN 'FAIL: …' END,
  CASE WHEN <b> THEN 'FAIL: …' END,
  CASE WHEN <c> THEN 'NOTE: …' END), ''), 'OK')
```

`concat_ws` skips NULLs, so arm order changes only the order of the joined tokens.

Two checks worth making once you have one:

- **Enumerate how the accumulator itself could drop an arm** — a false condition, a
  NULL-valued condition, an empty-string arm, a NULL separator, a nested `CASE` with
  no `ELSE`. That set is small and finite, which is what makes "this class is closed"
  a measurement rather than a claim.
- **No arm labelled FAIL may exit 0.** Sweep every single-fault state and check the
  label against the exit status; a reported-but-unenforced FAIL trains people to
  ignore the word. Where a condition is deliberately advisory, label it NOTE.

### A link to a repo-hosted artifact must be *tracked*, not merely present

When the published site **is** the repository — GitHub Pages serving `docs/`, or a
`raw.githubusercontent.com` URL — the question "does this file exist" is the wrong
predicate. The right one is "is it in the repository", because that is what a reader
gets. A file written by a script and never `git add`ed exists for exactly one person:
whoever last ran the script.

The failure is invisible from the inside. The build succeeds, the page renders, the
link opens locally, and it 404s for everybody else. It surfaces only on a fresh clone
or a real visit.

```r
in_git <- repo_path %in% system2("git", "ls-files", stdout = TRUE)
```

Three instances in one project, each with a different cause and the same symptom:

- an interactive map written by a manual script, never committed — the appendix
  linking it 404'd on the published site for months
- 32 generated popup pages whose build script was in no build chain
- photo URLs built from the wrong id column, pointing at directories that had been
  renamed upstream

Note this is the *inverse* of the dirty-check case under "A guard that fails toward
pass" (the job writing into its own tracked output directory), where untracked
outputs are noise and `--untracked-files=no` is right. The distinction is whether the
repo is the input to a build or is itself the artifact being served. Both predicates
are correct for their own subject and wrong for the other.

**Corollary — the DOM is not the whole document.** Harvesting `href`/`src` with an
HTML parser misses anything a script tag reconstructs at runtime. A leaflet map
serialises its popups as JSON, so every link inside them is invisible to
`xml2::xml_find_all(doc, "//@href")`. A DOM-only pass over a report with 51 dead links
found 2. Scan the raw text as well, and be permissive about the shape: markup built by
`paste0('<a href =', x, '.html ', 'target="_blank">')` emits `href =…` with a space
and no quotes, which most href patterns skip. In PCRE, lookbehind must be fixed width,
so `(?<=href *= *)` will not compile — match the attribute name and strip it after.

Cheap enough to run on every build, and it belongs there rather than in a checklist: a
check that must be remembered has the same failure mode as the script that had to be
remembered.

### An assertion that matches an interpolated value cannot see the claim around it

`expect_error(f(x), "some_column")` looks like it pins the guard. It pins the
**field name**, which the message interpolates — so it matches whatever sentence
is built around that name, including a sentence that is false. The guard's
predicate is tested; the guard's *claim* is not, and nothing distinguishes the two
from a green suite.

The failure mode is a package asserting opposite things about one thing, in two
places, both with tests passing:

```
`sessions` is missing named_by, which is an override column.        <- guard A
`annotations` carries named_by, which is not an override.           <- guard B
```

Measured 2026-09-02 in trap#28. Guard A's predicate had been widened to cover
`named_by` and its sentence was left behind; guard B refuses `named_by`
*precisely for not being an override*, twenty lines above it. The test written
for that exact column asserted `expect_error(..., "named_by")` — a working guard
on the predicate, structurally blind to the sentence. It pointed a reader at the
remedy the other guard rejects.

**The tell is a message that says what something *is*, rather than only naming
it.** "which is an override column", "the layer was altered", "carried from the
capture source" are claims. `{.field {col}}` alone is not.

Where a guard's message makes a claim, assert the **rendered text**:

```r
render <- function(expr) tryCatch(expr, error = function(e) conditionMessage(e))

msg <- render(f(x))
expect_match(msg, "crew-supplied")                       # the claim, positively
expect_false(grepl("is an override|are override", msg))  # and the wrong one
```

Two notes on doing it well:

- **`conditionMessage()` on a `cli_abort` condition returns the bullets too**, not
  only the headline — so the `i` and `x` lines are reachable. Every assertion that
  matched only the first line was blind to them.
- **Prefer a positive `expect_match` over a negative `grepl`.** A negative catches
  the regression it was written for and is evaded by a rewording; the positive
  assertion beside it is the load-bearing one.
- **testthat makes this stable**: `local_reproducible_output()` sets
  `cli.condition_width = Inf`, so messages are emitted unwrapped and the
  assertions do not depend on console width or on how long `TMPDIR` is. Rendering
  the same message *outside* testthat wraps it and appears to fail — a false alarm
  worth recognising rather than debugging.

**Terminate by enumerating the messages, not by reading them.** Parse the file and
walk every `cli_abort` / `warning` / `stop`, dump the literals, and mark which
make a claim. That set is finite and small — six in the trap case — so "all of
them are pinned" becomes a measurement. Doing it from recollection is what left
the sixth unpinned, and the sixth was the false one.

### A pluralisation marker takes the quantity of whatever was substituted last

`cli`'s `{?a/b}` reads the most recent quantity in the string, and **any**
substitution resets it — including a length-1 one that is not what the marker is
about. So a `cli::qty()` at the head of a message is overridden by the first
`{.path {x}}` that follows it.

Worse, the two failure directions look identical when you only render one case:

```r
# n = 4 drifted columns
"{cli::qty(length(d))}{.path {p}} carr{?ies/y} {.field {d}}, which differ{?s/} ..."
#> '/x.gpkg' carries A, B, C, and D, which differ ...     <- qty reset by {.path}
"{.path {p}} {cli::qty(length(d))}carr{?ies/y} {.field {d}}, which differ{?s/} ..."
#> '/x.gpkg' carry A, B, C, and D, which differ ...       <- the FILE "carry"
```

**And markers in one sentence may legitimately have different subjects.** Above,
`carr{?ies/y}` is about the file — always one — and `differ{?s/}` is about the
columns. The original was correct and a "fix" made it wrong, because the two
halves were assumed to disagree when they were describing different nouns. The
right answer was to delete the `qty()` and write `carries` literally, letting
`{.field {d}}` supply the quantity for the markers that genuinely track it.

Caught 2026-09-02 in trap#28, and it cost two review rounds: one to introduce the
regression and one to find it. Neither was visible by reading.

- **Identify each marker's subject before touching a quantity.** If a marker is
  about something singular, no `qty()` is wanted at all.
- **Put `cli::qty(n)` immediately before the marker it governs**, never at the
  head of the string, when one is needed.
- **A quantity does not carry between bullets.** Each element of a `cli_abort()`
  vector is its own string, so a `{?it/them}` in an `i =` bullet has no quantity
  in scope even when the headline above it interpolated one — and this failure is
  loud rather than silent: `Cannot pluralize without a quantity` replaces the
  whole message, so the abort still fires and says nothing about what was wrong.
  Each bullet needs its own `qty()`. Caught 2026-09-03 in trap#32, in a refusal
  whose headline pluralised correctly two lines above.
- **Render at n = 1 and n = 2 through the real code path**, not through
  `cli::format_error()` on a hand-built string. A single-quantity test cannot see
  either direction, and a message rendered outside its function may substitute
  different values than the function does.

Also worth knowing: a length-1 **numeric** substitution sets the quantity to the
*number itself*, so `{cli::qty(length(x))}... {length(x)} item{?s}` is fine and
looks like the same defect. Do not "fix" it.

## Security

### Process Visibility
- Secrets passed as command-line args are visible in `ps aux`
- Use env files, stdin pipes, or temp files with `chmod 600` instead

### Secrets in Committed Files
- `.tfvars` must be gitignored (contains tokens, passwords)
- `.tfvars.example` should have all variables with empty/placeholder values
- Sensitive variables need `sensitive = true` in variables.tf

### Firewall Defaults
- `0.0.0.0/0` for SSH is world-open — document if intentional
- If access is gated by Tailscale, say so explicitly

### Credentials
- Passwords with special chars (`'`, `"`, `$`, `!`) break naive shell quoting
- `printf '%q'` escapes values for shell safety
- Temp files for secrets: create with `chmod 600`, delete after use

### Gitleaks pre-commit hook
Configuration patterns and false-positive handling for the `gitleaks` pre-commit hook (kdot's Brewfile ships `gitleaks` + `pre-commit`; cyclops standardizes the hook):
- **`.gitleaks.toml` schema in v8.30+**: top-level table is `[[allowlists]]` (PLURAL, array of tables). Each entry MUST include at least one of `commits` / `paths` / `regexes` / `stopwords`. The singular `[allowlist]` and `fingerprints = [...]` forms shown in older docs fail to validate. Use `paths` + `regexes` together for targeted file-and-content allowlists. Example in `soul/.gitleaks.toml`.
- **PEM marker regex spans multi-line**: gitleaks's `private-key` rule is `(?i)-----BEGIN...PRIVATE KEY-----[\s\S]*-----END...-----`. It matches across comment prefixes, blank lines, and code-fence boundaries. **Commenting out the markers does NOT neutralize the match.** Only fix in content is to omit the literal `-----BEGIN/END...-----` strings entirely and replace with prose ("Paste your private key here, preserving headers" etc.). See the `rtj` cypher `tfvars.example` precedent.
- **`curl-auth-header` rule false-positives on non-auth headers**: matches any `-H "X: Y"` shape, not just credential-bearing headers. Trips on docs with custom CORS or app-specific headers (e.g. `Zotero-Allowed-Request: true`). Fix: targeted `[[allowlists]]` with `paths` + `regexes`. Don't path-allowlist the whole file unless content is entirely safe.
- **`pre-commit install` legacy-hook handling**: running `pre-commit install` on a repo with an existing `.git/hooks/pre-commit` renames it to `.legacy` and keeps invoking it after framework hooks. No breakage, but means hook surface is split between `.pre-commit-config.yaml` and `.git/hooks/pre-commit.legacy`. For full visibility, migrate the legacy check into `.pre-commit-config.yaml` as a `local` hook so the whole hook surface is declared in one place.
- **AWS canonical example keys are allowlisted by default** (`AKIAIOSFODNN7EXAMPLE` etc.) — don't use those in test fixtures expecting a block. Use `ghp_`-shape PAT lookalikes or other non-allowlisted patterns for hook-trigger tests.

### "Public bucket" ≠ listable: GetObject vs ListBucket
- A bucket policy granting only `s3:GetObject` on `bucket/*` makes exact-key fetches public but NOT listing — and dataset discovery (`arrow::open_dataset()`, duckdb globs, STAC `/vsicurl/` directory reads) requires `s3:ListBucket` on the **bucket ARN** (no `/*`; it's a bucket-level action).
- The breakage hides: anyone with ANY ambient AWS credentials lists fine, so "anonymous access works" goes unverified for years. Caught 2026-07-18 (water-temp-bc#23 → rtj#187): anonymous `open_dataset()` had never worked on a bucket whose whole purpose was credential-less querying.
- Review checks: for an open-data bucket, the policy needs BOTH statements (GetObject on `bucket/*`, ListBucket on `bucket`); acceptance-test anonymous access from a credential-stripped environment (`env -u AWS_ACCESS_KEY_ID ... AWS_CONFIG_FILE=/dev/null`). Note ListBucket makes the full key listing publicly enumerable — intended for open data, wrong for mixed-content buckets.

## Spreadsheets and PDFs

### A stored value is not wrong just because the raw number looks wrong

Before reporting that a spreadsheet value is off by a factor, check the cell's
**number format**. A cell formatted `0.0%` multiplies by 100 for display: stored
`0.028` renders as `2.8%`. Reading raw values with `readxl` and comparing them against
what the column header implies will make correct data look 100x wrong.

- `tidyxl::xlsx_formats(path)$local$numFmt[cell$local_format_id]` gives the format.
- The header text is not the signal. A column headed `(%)` may legitimately store a
  proportion, because the format supplies the percent.

**Why:** this cost a full wrong turn in the fish data submission work — a formula
`AVERAGE(...)/100` was reported as a provincial template defect, a correction notice to
the ministry was drafted, and the "fix" would have shipped `280.0%` where `2.8%` was
meant. Caught only because a human opened the file and looked at it.

### Verify PDF links from the annotations, not the extracted text

`pdftotext` returns anchor text, not the href. A link whose anchor reads "here" leaves
no URL in the text layer, so grepping the text proves nothing either way. Extract the
annotation instead:

```bash
qpdf --qdf --object-streams=disable in.pdf - | strings | grep -oE 'https?://[^ )>]*'
```

`pdftotext` also splits ligatures — "fish" comes out as " sh" — so a grep for any term
containing `fi`, `fl` or `ffi` can report a false absence.

### Extracted PDF text carries corrupted glyphs, and a tolerant parser turns them into wrong numbers

Worse than the ligature case above, because it fails silently with a plausible value
rather than a missing match. Three shapes, all met in one set of 18 camera calibration
reports (fly#32, 2026-08-30):

| what the PDF renders | what it means | what a naive parser does |
|---|---|---|
| `2001Opixel` | 20010 | `gsub("[^0-9.]", "", x)` **deletes** the O and returns 2001 |
| `Pixel Size [<U+F06D>m]` | `[µm]` in a Symbol font | a literal `\[µm\]` misses; a human reading the extract sees `[m]` and takes **metres** |
| `Pixel Size  5.200 m` | 5.200 µm, sign dropped entirely | reads as metres — a factor of 10^6 |

The micron sign is the common one: U+F06D is a **Private Use Area** codepoint emitted by
Word-generated PDFs, so it is neither `µ` (U+00B5) nor `μ` (U+03BC) and matches neither.

Three habits:

- **Anchor on the label, not the unit.** Take the first number on the `Pixel Size` line
  rather than matching a unit that is written three different ways.
- **Never strip non-digits to "clean" a number.** That silently deletes a corrupted
  glyph instead of failing on it. Substitute deliberately (`[Oo]` preceded by a digit
  → `0`) and let an independent check prove the result.
- **Have an independent identity to check against.** These reports state pixel count,
  pixel size *and* image size in mm, so `px × pitch == mm` catches any one of the three
  being wrong — which is what made the O→0 substitution safe rather than reckless. Where
  the document states only two of the three, the check is vacuous; know which rows those
  are rather than counting them as passes.


# NGE Feature Workflow

For non-trivial issue-driven work, follow this checklist. Each step exists for a reason — skipping leads to rework, broken builds, and avoidable bugs that we've hit repeatedly.

## The Sequence

1. **Start with `/planning-init <N>`** — given an issue number, enters plan mode for codebase exploration, presents a phase breakdown for user approval, then scaffolds branch + PWF baseline with the approved phases. One command replaces the manual issue → explore → plan → branch → scaffold dance.
2. **Write robust tests first** — failing tests that reproduce the issue or document the new behavior. Tests are the contract; they fail until the work makes them pass.
3. **Name with intent** — functions, parameters, internal helpers carry the naming style of the package they live in. Look at existing exports as the guide; consistency over cleverness. For files rather than functions — shell scripts and operational R scripts under `scripts/` or `data-raw/` — the standard is the `noun_verb-detail` pattern in `newgraph.md`, noun first.
4. **Examples that run** — every exported function gets a runnable `@examples` block. Pkgdown renders them; CI executes them. An example that doesn't run is documentation rot.
5. **Code-check before each commit** — `/code-check` on staged diff. Catches what tests miss: edge cases, hard-coded paths, unguarded variables, security issues.
6. **Atomic commits** — each commit bundles code change + checkbox flip in `task_plan.md`. The diff and the progress live in the same commit; `git log -- planning/` tells the full story.
7. **`/planning-archive` when complete** — moves PWF to `archive/YYYY-MM-issue-N-slug/`, creates a fresh `active/`. Then `/gh-pr-push` opens the PR; `/gh-pr-merge` handles the release bookkeeping.

## Where the checkpoints are not

Step 1's plan approval is the authorization for every step after it. Run steps 2–7
through to the **open PR** without stopping to report between phases — the merge in
step 7 is outside the mandate unless the instruction includes it; put the decisions that
genuinely change what gets built at the plan gate, batched, with a recommendation
first; report once when the PR is open. The rule, its boundary (before a plan
exists, a question wants an answer) and its exceptions are `karpathy.md` §8.

## Re-read origin before you open the PR, not just before you cut the branch

Verifying local is current with origin (`code-check-shell.md`, "Before you *cut* a
branch") protects the branch point. It
says nothing about the build window, which is where a parallel session lands: measured
once, a second session filed, built and merged the same feature in 18 minutes, entirely
inside the first session's planning phase, and merged 15 seconds before its first
commit. Both sessions' pre-flight checks passed and both were correct when they ran; the
duplicate surfaced hours later as a version-bump conflict across eight files.

Before opening a PR, and again before merging:

```bash
git fetch -q origin
git log --oneline HEAD..origin/main          # what landed while you worked
git diff origin/main -- DESCRIPTION NEWS.md  # a version you did not bump
```

**A version bump you did not make is the tell**, and usually the only one — the tree is
clean, the branch is healthy, and nothing in git hints that someone solved your problem
an hour ago.

On a collision, do not resolve conflicts file by file. The merge conflict hides the
useful question, which is *which body of work survives*. Ask, then re-land the delta on
top of what shipped; two independent attempts at one problem are usually complementary
rather than redundant, and a mechanical resolution keeps whichever half git preferred.

## An issue number you did not file yet is somebody else's

GitHub allocates one sequence across issues **and** PRs, on creation. So a number
written down before the issue exists — a branch name, a code comment, a config header,
a commit trailer — is a reservation nobody honours, and in an active repo it will
eventually name a real issue about something else entirely.

That is the expensive direction. A number pointing at *nothing* is obvious; a number
pointing at a **stranger's issue** resolves, renders as a link, and reads as provenance.
Nothing downstream checks that the issue it names has anything to do with the code
beside it.

Measured 2026-09-08 in rtj. Work with no issue was branched as `322-sern-thompson-2026`
on a guess, and four `rtj#322` citations went into a `project.yml` header and two
shared-library comments. A parallel session then filed #322 — about a STAC registration
script. Every citation was wrong, all four looked fine, and the real issue for the work
(#319) went uncited until the merge.

- **Cite an issue only after it exists.** If the work has no issue and does not warrant
  one, write no number: a comment that explains itself is better than a wrong pointer.
- **Before merging, resolve every issue number the branch introduces** and check the
  title is about this work — one call, and it is the only thing that separates a good
  citation from a plausible one:

  ```bash
  git diff --stat origin/main...HEAD >/dev/null   # three-dot: the branch's own changes
  git diff origin/main...HEAD | grep -oE '(^\+.*)(rtj|rfp|gq|soul|link)#[0-9]+' \
    | grep -oE '[a-z_]+#[0-9]+' | sort -u
  # then, per hit:
  gh issue view <N> --repo NewGraphEnvironment/<repo> --json title -q .title
  ```

- **Name the branch for the work when there is no issue** (`sern-thompson-2026`), and
  rename it once one exists — `git branch -m` before the first push costs nothing.

Sibling of the section above: both are parallel sessions moving underneath work that
looked settled when it started.

## The version lives in one place

Do not restate the current version in `README.md` or `CLAUDE.md` prose. A version
string typed into prose drifts from the moment it is written — the release step
maintains `DESCRIPTION` and `NEWS.md`, and one report repo's
`CLAUDE.md` was found eight minor versions behind, its `README.md` one behind, with both
canonical files correct. Link to `NEWS.md` instead. Where a claim genuinely must stay in
prose, `/gh-pr-merge` step 7 greps for the previous version string outside the two
canonical files and updates the prose restatements it finds, reporting each.

## When to Skip

For one-line typo fixes, version-bump-only PRs, or trivial documentation edits, the full workflow is overhead. Use judgment. The threshold is roughly: **multi-step issue, multi-file change, or anything that requires scoping** → use the workflow.

## Skills That Slot In

- `/planning-init <N>` — start
- `/planning-update` — sync checkboxes mid-session
- `/code-check` — before every commit
- `/planning-archive` — when issue closes
- `/gh-pr-push` — open the PR
- `/gh-pr-merge` — merge with release bookkeeping

## Issue bodies get edited, not appended

When work changes what an issue should say, **edit the body**. Don't add a
comment that corrects it, and retitle when the scope moves.

**Why:** an issue is read as a spec by whoever picks it up. A body saying one
thing with a comment three screens down saying the opposite costs the reader the
reconciliation, every time.

**How to apply:** `gh issue view N --json body -q .body` into a file, revise,
`gh issue edit N --body-file`. Name what changed and why when the correction is
load-bearing — the goal is a body that reads correctly top to bottom, not an
erasure of history. Comments are for genuine commentary: a merge notice, a
cross-repo pointer, a question. Applies to PR bodies too. Commit messages are
immutable history and are never rewritten this way.

**The failure mode that keeps recurring: research findings feel like
commentary.** They are not — they are the spec. If a finding changes what
someone would *build*, it belongs in the body, with the durable version in
`research/` and the body linking to it. What `research/` holds, how a file is
named and what its header carries is `planning.md`, "`research/` — what is
known, outliving the issue that found it".

**Bodies drift at the moment work finishes, not while it is in flight.** Four
instances in a single day of rfp work, all of the same shape — the code learned
something and the issue did not:

| drift | what a reader saw |
|---|---|
| premise disproved by measurement | an issue arguing for a fix that was no longer needed |
| a conclusion asserted in the body but never landed in code | body and tree contradicting each other |
| the shape of the work moved during exploration | a spec describing a design nobody built |
| a decision made and shipped, body still listing options A–D | "decision needed" on a decision a year old |

Vigilance does not catch this, because the drift happens exactly when attention
moves to the merge. `/gh-pr-merge` reconciles at that moment — see its step 3b.

## Why This Exists

We've hit snags repeatedly when half-doing this — branches that mix concerns, tests bolted on after, code-check skipped (and then a bug ships in the diff), examples that fail in pkgdown. Each step is small; the cumulative reliability gain is real. The convention is here so it becomes the default expectation, not a thing the user has to remind every session about.


# LLM Behavioral Guidelines

<!-- Source: https://github.com/forrestchang/andrej-karpathy-skills/main/CLAUDE.md -->
<!-- Last synced: 2026-02-06 -->
<!-- These principles are hardcoded locally. We do not curl at deploy time. -->
<!-- Periodically check the source for meaningful updates. -->

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. You Have No Clock Between Tool Calls

**Every duration claim comes from `date`, never from how much waiting felt like
it happened.**

Background `sleep` returns immediately from the agent's side, and the number of
times you have polled is not evidence of elapsed time. Two consecutive tool
calls can be 15 seconds apart by the clock while feeling like ten minutes of
waiting.

The failure is stating it out loud before checking. Observed 2026-08: a CI run
was reported to the user as "pending for over an hour — unusually long, probably
a stuck runner", after roughly eight background sleeps. One `date -u` showed the
run was **three minutes old** and entirely normal. The whole diagnosis — stuck
runner, duplicate triggers, something wrong with the workflow — rested on a
duration that had been invented.

**How to apply:** before saying *any* duration — "still running after N
minutes", "this has been X a while", "longer than usual" — run `date -u` and
subtract a real start time. `gh run list --json createdAt` gives it for CI. If a
claim about slowness would change what the user does next, it needs a measured
number or it does not get made.

The same rule covers process state. `ps` and task-status listings have both been
observed wrong; check the artifact (an output file's size, its mtime, the
service's own API) rather than the wrapper.

### The same blind spot picks the wrong waiting tool

Not having a clock also makes a **chain of background sleeps** feel like
waiting when it is not. Observed 2026-08 on the same session as the above:
roughly a dozen `sleep 570; check` background tasks were spawned to wait out a
55-minute test suite and then CI. Two consecutive foreground checks printed the
*same minute* — no wall time had passed between them, because the sleeps run
detached and the polling happened around them rather than after them. Every one
of those tasks was waste, and killing them produced a batch of eleven
exit-code-144 notifications that read like failures.

Pick the instrument by how many answers you need:

| you need | use |
|---|---|
| one notification when a condition becomes true | `Bash(run_in_background)` with an `until` loop that exits |
| one per state change, ending on its own | `Monitor` with a command that emits and then exits |
| a value you must have before the next step | a **foreground** call, so the blocking is explicit |

A repeated `sleep N; grep` is right in none of them. **Tell: if you are about to
spawn a second waiter for the same thing, the first one was the wrong shape.**

A `Monitor` filter must also match the failure states, not just the success
one — silence looks identical to "still running", so a watcher that greps only
for the happy path stays quiet through a crash.

### Don't edit files a long-running suite is still reading

`devtools::test()` and its equivalents load each test file **when they reach it**,
not at launch. A 30-minute run therefore reads whatever is on disk at that moment,
so edits made mid-run are half-applied and the result describes a tree that never
existed.

Cost two full Docker suites (~1 hour) on rfp#178, both reporting `FAIL 1`. The
failure was a test written *during* the run, executing against source from *before*
the fix that made it pass — nearly reported as a regression. **The tell is a moving
denominator:** 3490 passes, then 3496, then 3500, on "the same" tree.

Before a long run, commit. While it runs, do work that touches nothing it reads —
issue bodies, PR text, reading, planning. If an edit cannot wait, kill the run
rather than let it produce a result that has to be re-litigated. And when a long run
fails, get the `file:line` before forming any theory: a mid-flight edit and a real
regression look identical in a summary line.

## 6. Subagents Are Evidence, Not Dependencies

**Spawn on your own judgment. Don't block on one. Don't trust its status. Verify its claims in both directions.**

### Spawning is your call, not the user's

Deciding to spawn a subagent is an engineering judgment, the same kind as choosing
to write a test or run a grep. **Do not ask permission for it.**

The user is usually not positioned to answer. Knowing whether a fan-out beats a
sequential read requires knowing the shape of the work — which you have and they do
not, so the question forces them to guess at a technical call. Under **Always Away**
it is worse than useless: the work stalls until they wake up, for an answer that was
yours to make. *"I wouldn't be in the know enough to know when that is"*
(airvine, 2026-08-27) is the whole problem in one line.

This does not soften §1's asks — *"if uncertain, ask"* and *"if something is unclear,
stop and ask"*. Those are about **what the user wants**: intent, scope, an ambiguous
requirement, a tradeoff only they can weigh. This is about **how you carry it out**.
Ask about intent; decide about mechanism. A question starting "should I use…" is
almost always the second kind, and almost always yours to answer.

#### Standing authorization: the harness bars the Agent tool by default on Opus 5

Sessions on Opus 5 carry a hardcoded instruction from the CLI itself —
*"Do not call the AgentTool unless the user requested it"* — alongside the same
line for workflows and deep-research. It is not a setting anyone here
misconfigured, and it cannot be turned off locally: measured 2026-08-29 in
`claude` v2.1.251, the string is a literal in the bundle, emitted when the
session is on the `opus_5_prompt_bundle` and the server-side flag
`tengu_fennel_godwit` is off. That flag and the replacement text
(`tengu_heron_brook`) are both remote config; nothing in `~/.claude/settings.json`
reaches them.

The symptom is a skill quietly doing less than it says: `/code-check` reporting
*"the subagent rounds did not run — your session instruction bars the Agent
tool"*, which is the review the command exists to perform. It reads as a
configuration problem, so the fix gets looked for in the wrong place.

**The clause is conditional, so this convention is the request.** Invoking a
skill that mandates subagents — `/code-check`'s three rounds, the Plan review in
`planning.md` — **is** the user requesting them. Spawn them. This paragraph is a
standing user instruction, written for exactly that purpose (airvine,
2026-08-29), and CLAUDE.md project instructions override default behaviour by
their own terms.

It authorizes the mandated spawns and nothing wider: the bounds in this section
still hold — two or three concurrent, about five per task, no fan-out from a
child — and a workflow or deep-research run fanning out dozens of agents remains
a spending decision that needs an explicit ask.

**Spawn without asking when:**

- A skill or convention mandates it — `/code-check`'s review rounds, the Plan review
  in `planning.md`. That decision is already made; re-asking it is friction carrying
  no information.
- You want fresh eyes on your own work. The mechanism and the measurements behind it
  are in `code-check/SKILL.md`.
- A sweep over many files will **locate** what matters faster than reading serially.
  The sweep finds candidates; it does not replace the read — `planning.md` is
  explicit that agents sometimes report existing files as absent, so read directly
  whatever you are going to act on.
- Independent items can run concurrently and nothing downstream needs them ordered.

**Do it yourself when:**

- One grep answers it.
- The work depends on conversation context a subagent will not have.
- You would sit idle waiting — spawn and keep working, or do it inline.

**Bounds and defaults you enforce yourself, rather than converting into questions:**

- **Two or three concurrent is the working default, and about five per task** is
  where spend stops being incidental. Concurrency and cumulative total are different
  quantities — `/code-check`'s three rounds plus a Plan review plus an ad-hoc sweep
  never exceeds three at once while spending well past a handful. Bound both.
- Past that total, **say so in your next message.** An escape you grant yourself
  silently is not a bound; it has to land in front of the user, after the fact.
- **Do not let a subagent fan out again.** Intent does not enforce this — the child
  decides what it calls — so use the structure: the `Explore` and `Plan` types are
  defined without the `Agent` tool and *cannot* spawn. `general-purpose` can, so when
  you use it (as `/code-check` does), put "do not spawn subagents" in the prompt. The
  one case on record — a research agent that had spawned 5 children and deadlocked
  for **~3 hours** while still reporting as running (below) — never had a root cause
  established, which is exactly why this bound is structural rather than advisory.
- Unnamed, delivering by file — `planning.md` carries the mechanics.
- **Report after, not before.** Say what you spawned, and relay what it found (per
  `code-check/SKILL.md` — a subagent's report never reaches the user on its own). A
  user can object to a spawn that already happened; they cannot usefully approve one
  that has not.

**What is genuinely the user's call is budget, not mechanism.** A workflow or
deep-research run fanning out dozens of agents is a spending decision and needs an
explicit ask. Two or three reviewers is not — that is just doing the work.

Worth being concrete about the value, because the cost is the visible half and the
benefit is not: on 2026-08-27 two reviewers over one conventions draft returned
**20 findings**, caught **six** false factual claims in it, and killed a section that
would otherwise have shipped contradicting `code-check.md`. None of that review
happens if the spawn waits on a user who is away.

### Don't block

Spawn a background subagent, then keep working on the lowest-risk part of the
task — scaffolding, data files, tests. When findings arrive, treat them as a
review of landed work rather than a precondition for starting it.

If a result genuinely must precede the next step, run it synchronously
(`run_in_background: false`) so the blocking is explicit and visible.

Three observed cases where waiting would have been the expensive choice:

- A research agent spawned 5 children and deadlocked for **~3 hours**, still
  reporting as "running". The user caught it, not the agent.
- A `Plan` agent asked to review a `task_plan.md` *before the baseline commit*
  returned after the issue was implemented, reviewed, merged and tagged.
- The same pattern on a later issue: findings arrived after all four phases had
  shipped. Because the work had not waited, this cost nothing — three findings
  were still new and landed as follow-up commits.

That last one is the shape to aim for. Concurrent review is not a degraded
version of blocking review; it is often better, because the reviewer reads real
code instead of a plan.

### Don't trust status

**Never report an agent as "still running" without evidence.** Agent status and
`TaskList` have both been observed to be wrong — `TaskList` reported "No tasks
found" for an agent that was alive and later replied. Check the output file's
mtime before claiming progress, and say what you checked.

**And never record a review as "Clean" on the strength of an idle notification.**
From the parent's side an idle ping is indistinguishable from an agent that had
nothing to say, so a lost review reads as a pass — a whole `/code-check` pass was once
reported as finding nothing while three reviews were stranded, one of which had found
a data-loss bug (measured 2026-08-25; the numbers are in `planning.md`, "Spawn review
agents UNNAMED"). Passing `name` turns a spawn into a persistent teammate that idles
instead of completing; pass it only for a collaborator you will keep messaging, and
shut it down when done. The rule that survives either spawn shape:
the reviewer **writes its findings to a file and reports only the path**, and a
missing or empty file means the round produced nothing and is re-run — never
"Clean". `planning.md` carries the mechanics; `code-check/SKILL.md` applies them.

### Verify claims, in both directions

Subagent output is evidence, not verdict. Both failure modes are real:

- **Acting on a wrong finding.** One labelled BLOCKER — "`glue()` will choke on
  the literal braces in this fragment" — was disproved by a 30-second probe,
  because glue does not re-parse interpolated values. Acting on it would have
  meant rewriting a working generator.
- **Dismissing a late review wholesale.** In that same review 2 of 9 findings
  were real, including a dead link. In a later one, a finding that a
  `path|layername=` check would delete KML/GPX layers was correct, and was
  confirmed against 207 real datasources before the fix landed.

The rule that separates them: **cheap probe first, then act.** Reproduce the
claim before you fix it, and before you dismiss it. A finding you cannot
reproduce is a finding you do not yet understand.

### Fan out inside one process

A workflow that shells out **once per item** costs one permission prompt per item,
unless the command happens to be allowlisted. The same work done **inside one
process** costs one prompt total, and nothing says so until the run is already
going. Measured 2026-09-04 (knowledge#4): a harvest script issuing two `curl` calls
per report inside each subagent meant hundreds of approvals across a run — the user
had flagged it as *"a big time suck last time"* without knowing the cause — while a
sibling script doing the same fetch-download-upload work with Python `urllib` in a
single process cost **one** prompt for the entire run. Same task, same volume, three
orders of magnitude apart in interruptions.

It breaks **Always Away** directly: an unattended run that stops for approval on item
3 of 200 has not failed loudly, it has gone idle, and the wrapper reports nothing.

- **Prefer one process doing N items over N processes doing one.** Loop inside the
  language runtime; shell out once, for the batch.
- Where a per-item subprocess is genuinely required, allowlist its command **before**
  the run, not one refusal at a time during it — the allowlist fixes the commands you
  predicted, and the one that blocks is the one you did not.
- Diagnostic: if a run keeps stopping for approval, look at whether the loop sits
  inside or outside the process boundary before adding allowlist entries.

---

## 7. Evidence, Not Impressions

**Measure before you characterise. Presence is not provenance. "Unknowable" is a
claim.**

Six principles that all fail the same way: something *feels* established — because
it is visible, because it is present, because someone said so — and gets offered
with the confidence of a measurement.

### Measure before you characterise

When a decision turns on **what something contains**, open it and count. Do not
describe it from its structure, from an issue's claim about it, or from a tag list.
A heading tells you a thing is *present*, never that it is *populated* — an empty
`<conditionalstyles/>` and one with rules look identical in a list of child names.

Four instances in one rfp session, each corrected by the user's follow-up question
rather than by review: a tradeoff described as three times its real size; an issue's
stale claim repeated as current; an installed version reported as sixteen releases
behind when a parallel session had updated it eighteen minutes earlier; and "nothing
on main addresses this" from a local `main` three commits behind — one `git fetch`
away from the truth.

**A measurement carries the time it was taken.** One made earlier in the same
session is not a current one, least of all for anything another session can change
underneath it. For anything git-backed, `git fetch` first: reading a local clone and
reporting it as the state of the world is the same error with a longer fuse.

**And before hand-rolling a parser for a probe, check whether the code already has
one.** A bespoke parser silently narrows the population it can see, and the result
looks like a measurement rather than a sample — worse than not measuring, because it
carries a number. Measured 10 of 80 with a hand-written matcher; routed through the
package's own resolver it was 14 of 117.

### Presence is not provenance

When something's **presence** is offered as evidence for **how it got there**, find
the fact that actually discriminates. A QGIS project's `3.30.1` stamp was offered as
evidence a desktop had opened it — but the template it was copied from carries that
stamp, so a never-opened project reads the same. What actually proved it was a
tracking key the template does not contain.

The tell: reaching for the *most visible* fact rather than the *discriminating* one,
because the visible fact is consistent with the conclusion. **Consistency is not
support.** Before offering "X shows Y", ask what else would produce X. If anything
would, X is not evidence.

When the user pushes back on an inference, re-derive rather than defend. The
conclusion often survives; the reasoning that reaches it is usually different.

### Documents that share an ancestor corroborate nothing

Sibling of the rule above, one level out: there a *fact* was consistent with the
conclusion, here several *documents* are. Finding the same claim in three places
feels like triangulation and is not — if one was written from another, they are one
source wearing three hats, and the agreement is a copy, not a confirmation.

**The tell is agreement with no independent derivation.** Ask of each restatement:
what did its author read? If the answer is "one of the others", the count is one.
Prose repeats; code does not, so the discriminating check is almost always to read
the thing the prose describes.

**The release note is where this costs the most, because its readers cannot check it.**
Measured 2026-09-04 in stac_floodplains_bc#26: three claims in one set of release notes were
wrong, each restated from a prior document rather than derived from the artifact — "18 items
changed" (the count of upstream *re-runs*, six of which moved nothing; 13 changed), "5-33%"
(the issue's own summary line, contradicted by its own per-item table; 1.5-33.5%), and worst,
*"the correction is visible in the checksums, so a consumer can tell replaced data from
unchanged"*. That last one measured **140 assets across 20 items, zero unchanged** — the
re-encoding touched every byte, so the checksum answers "are my bytes current" and can never
answer "did the values change". It would have sent every consumer to a signal that cannot
answer the question they have.

Two habits, both cheap:

- **Derive every number in a release note from the artifact it describes**, at the moment you
  write it. Not from the issue, not from the last release's notes, not from memory.
- **For any sentence of the form "you can tell X by looking at Y", check that Y actually
  separates X from not-X.** A discriminator that fires on everything discriminates nothing,
  and it reads as helpful right up until someone relies on it.
- **A carve-out is a number too, and reasoning one from the shape of a literal understates
  it.** A release note recording someone else's regression said a broken smoke test "could
  validate any group except the two named in `EXPECTED_DEPRECATED`" — reasoned from the
  literal being the thing the check consults. Driven over one-group trees it could validate
  **none**: the literal names two items, so a one-group tree is always missing at least one,
  including each of those two, which are missing each other. Wrong in the direction that
  understates the reach of a defect, in the document a reader uses to decide whether to
  backport. Run the check over the population before writing the exception
  (stac_floodplains_bc#61, 2026-09-05).

Measured 2026-09-02 in link. `CLAUDE.md`, `research/study_area_run.md` and
`research/recompute_parallel_2026_09_01.md` all stated that a post-consolidate
recompute "runs over every WSG in the schema, not the run's own set, so it does not
scale with scope". One line of shell disagreed — `ALL_WSGS` is the union of the host
buckets — and the run's own log said `recompute (lnk_access, 34 WSGs)` against a
95-WSG schema. Two later commits had changed the behaviour and none of the three
documents was updated.

It was quoted to the user twice in one session as a live planning input before anyone
checked, and it was load-bearing: the claim was the *premise* for concluding that
parallelising that stage beat adding machines. A false premise had produced a
plausible roadmap.

Two habits:

- **When a document states a quantity or a scope, read the code that produces it
  before repeating it.** Especially a status section — it describes a moment, and
  nothing fails when the moment passes.
- **When you find one instance stale, grep for the sentence, not the file.** The
  claim above sat in three documents; fixing the one that was quoted would have left
  two, both reading as authoritative.

### "It can only be answered by testing" is a claim with an author

An issue or a colleague saying a question needs a field season, a device or a deploy
is stating a claim, not a property of the problem. Spend the cheap probe first.

rfp#186 opened with "three questions decide whether this is viable, and none can be
answered by reading." Two fell in about twenty minutes — one to reading a call
graph, one to re-reading a file already on disk — turning "run a field season, then
decide what to build" into "build it, then confirm one thing."

The claim is usually made by someone who knows the domain, at a moment before they
looked. Not wrong so much as **unexamined**, which is what lets it survive into the
plan. Then **bound what the probe closed**: reading a desktop plugin says nothing
about the mobile app. An over-claimed probe is worse than none.

### A real bug is not necessarily the reported bug

A defect found while investigating a symptom is **evidence, not the answer**. Before
offering it as the cause, check that it produces *exactly* the symptom described,
including the details that sound incidental.

Two confident wrong causes in a row on rfp#196 — a layer missing from a map theme
(a real bug, fixed) and a sub-pixel geometry (a real measurement). Both true;
neither explained the report. The actual cause was draw order, and the user named it
himself. The discriminating fact was in his words all along: *"as soon as I stop
tracking I can't see the track"* rules out both theories in one line.

Finding a genuine defect feels like finding *the* defect — the relief of having an
explanation is what stops the check. Write the reported symptom out and ask whether
the proposed cause produces **all** of it. Say which parts are still unexplained:
"this is a real bug and it may not be your bug" is honest and cheap.

### An enumeration is not a checklist

A probe listing what exists — subkeys present, columns found, files listed — answers
"what is here", never "what do we want". Scope arriving this way looks
evidence-backed, so it survives review.

On rfp#68, "the two Mergin subkeys that exist" became "the settings to verify",
then an item on a field checklist a human had to walk outdoors to complete. Nothing
in the codebase read or wrote `PhotoNaming`. Before a probe's output becomes work,
grep for each item and ask whether anything consumes it. When it duplicates
something already done another way, name the comparison — the existing approach
usually wins for a reason worth stating.


### A relative descriptor is meaningless without its anchor

"Upstream", "downstream", "above", "below", "before", "after", "parent" — each is
relative to something named **elsewhere in the document**, often paragraphs away and
sometimes only in a table. Resolve the anchor before drawing any inference from the
term.

Getting it wrong does not produce uncertainty, it produces a confident and specific
wrong answer — and it fails in the worst direction, because you now believe you have
*evidence* against a claim rather than merely lacking evidence for it.

Measured 2026-09-02. A field report read *"downstream sampling confirmed the presence
of coho"*. Taken as downstream of the crossing under discussion, it appeared to
disprove the user's recollection that coho were present above that crossing. The
sampling site was actually at a road crossing 1.5 km further up the stream, so its
"downstream" was still **1.1 km above** the crossing in question — the claim was true
and the correction nearly removed it from an email to the infrastructure owner, on the
one point the email existed to make.

**Where a source describes a sequence — crossings on a stream, releases in a
changelog, stages in a pipeline, commits on a branch — write the order out before
interpreting a single relative term in it.** The ordering is usually one sentence in
the source and takes seconds to find; the inference built on the wrong anchor survives
every later check, because nothing downstream re-examines it.


### A safeguard whose mechanism is a human reading a diff is not a control

When a design says "the writes are uncommitted, so the diff is the review", check
whether anyone reads diffs. Here nobody does — the user says "commit" without opening
one, stated plainly and confirmed 2026-08-28 — so every per-action confirmation loop
built on that premise was latency wearing the costume of a control. Two skills had one.

Gate on **blast radius** instead, because that fires without anyone reading anything: a
write that reaches one repo just happens; a write that reaches every repo (a soul
convention) may be appended to freely but edited or removed only through an issue. Where
a real check is needed, make it mechanical — a grep for a contradicting rule, an
assertion that nothing above the `CLAUDE.md` marker moved, a guard that resolves every
heading against a base SHA. Those are the controls; a prompt is not.

The user still wants a short, honest account of what was written. That is a report, not a
review, and confusing the two is how the loops got built.

### Not finding it is not evidence it does not exist

Before building a fetcher, harvester, backup or sourcing routine, **search the sibling
packages for the verb**. One command, and it is the difference between adding a function
and adding a second copy of one.

```bash
# Enumerate the org's installed packages rather than listing them: a hardcoded list
# named four packages; thirteen other org packages were installed on the machine this
# was measured on (2026-09-05), and the gap will grow again. Match
# on any URL-ish field, case-insensitively: RemoteUsername is set only by GitHub
# installs (a package installed from a local checkout has none) and the org name is
# not always cased the same. Forks of upstream packages come along; that is fine.
# `collapse` matters: paste() over fields that are all NULL is character(0), and
# `if` on a zero-length grepl() aborts the whole enumeration (measured, soul#171).
for p in $(Rscript -e 'for (p in rownames(installed.packages())) {
  d <- packageDescription(p)
  u <- paste(c(d$URL, d$BugReports, d$RemoteUrl, d$RemoteUsername), collapse = " ")
  if (grepl("newgraphenvironment", u, ignore.case = TRUE)) cat(p, "\n") }'); do
  echo "== $p"; grep -E "^export" "$(Rscript -e "cat(system.file(package='$p'))")/NAMESPACE" \
    | grep -iE "source|fetch|harvest|backup|manifest|download|ingest|store|snapshot|read|write|conform"
done
ls ~/Projects/repo/rtj/scripts/gis/     # operational drivers live here, not in a package
```

**Then read the README ownership table and the above-marker `CLAUDE.md` of any package
plausibly adjacent — exports understate remit.** `trap`'s README states it exists "so a
report does not have to harvest its own copy", with a manifest pinning per-snapshot
sources, schema, md5 and row count; no export says that. The old hardcoded list would
not have searched it at all; the grep finds functions; the README is the load-bearing
artifact. Measured 2026-09-04: a harvest-and-manifest layer was
proposed across three issues before `trap/README.md` was opened, with `trap` checked out
and current on the machine (soul#183).

The failure is not carelessness — it is that **a decision is invisible from where the work
is happening**. The tool exists, is correct, and is three repos away in a directory you had
no reason to open. So the path of least resistance builds it again, and the duplicate is
plausible precisely because the original was never visible.

Four instances in one session (2026-08/09), all by an agent that had just read the thread
documenting the pattern:

| Built or proposed | Already existed |
|---|---|
| a Mergin form-harvest script | `rtj/scripts/gis/mergin_data-harvest.R` — dry-run by default, parquet, photo manifest, excludes `.mergin/` cache copies |
| ad-hoc project layer curation | `rtj/scripts/gis/mergin_manifest-create.R` + per-project manifests git-tracked in rtj |
| "photo functions should go to ngr" | `sred#26` assigns photo batch ops to rfp |
| "the source fetchers should go to ngr" | `spacehakr` already existed, holding all twelve `spk_*` |

**Tell:** you are about to write something whose name is a verb the ecosystem already does
somewhere. Fetch, sync, harvest, backup, source, register, publish.

Two corollaries worth holding:

- **A function existing in two places is worse than it existing in neither.** Measured on
  `ngr_spk_geoserv_dlv` versus `spacehakr::spk_geoserv_dlv`: same name, same signature, and
  by the time anyone looked the first printed an error and carried on where the second
  aborts. Two live copies drift silently, and the drift is invisible until someone has both
  installed — which nobody did.
- **Check what the *architecture* says, not just what exists.** Two of the four above were
  wrong-home *proposals*, not duplicate code. `sred#26` had already assigned the boundary;
  reading it would have cost less than arguing the case from first principles.

Sibling of *"An inventory is only complete relative to a boundary"* in `code-check.md`, one
step earlier: that one is about a search that was complete for the wrong scope, this is
about never having searched the scope where the answer lived.

#### The storage version: one store is not the world

The same error with buckets instead of packages, and it produced three wrong answers in
one session (2026-09-04). Each was a single negative check reported as a fact:

| claim made | what was checked | where it actually was |
|---|---|---|
| "not an `aws` layer" | `rfp_source_aws.txt`, 11 entries | `db_newgraph/jobs/` — that list is what rfp *pulls*, not an inventory of what is staged |
| "not staged anywhere" | one Postgres host, one S3 prefix | a **different bucket**, written by a job that drops its temp table afterwards |
| "the imagery is not backed up" | `aws s3 ls` on two AWS buckets | **DigitalOcean Spaces** — 228 GB, reachable only via `s3cmd` |

The third is the most general: **`aws s3` and `s3cmd` address different clouds and are
invisible to each other.** A repo whose backup script uses `s3cmd` has stores that no
`aws s3 ls` will ever list, so "I checked S3" is not a statement about where the data is.

Two habits, each one command:

- **Enumerate the stores before searching them.** `s3cmd ls` and `aws s3 ls` with no
  argument each list only their own provider's buckets; the backup script names the rest.
- **Prefer the definition to the artifact.** The job that stages data says what exists; a
  bucket only shows what some past run happened to leave. Checking artifacts returned
  nothing three times here; reading the job answered it immediately.

A negative result is only ever as wide as the store you looked in. Stating it without that
qualifier is how a gap in your own search becomes a fact in an issue body — which is where
all three of these ended up before they were corrected.

And the same shape once more for **checkouts**: a `grep` across `~/Projects/repo` searches
the repos this machine happens to have, not the ecosystem. Repos are cloned per-machine and
the set differs between them — `stewardship_upper_wedzin_kwa` was absent on m4 while holding
the answer to two separate questions on 2026-09-04, so a local grep returned clean twice and
was reported as absence twice. Use `gh api -X GET search/code -f q="org:NewGraphEnvironment <term>"`,
and note it indexes **default branches only**, so a file on a feature branch is invisible to it
and needs `gh api repos/<owner>/<repo>/contents/<path>?ref=<branch>`.

## 8. Decisions Up Front, Then Run

**Ask at the plan gate. After approval, run to the PR. Before a plan exists, a question wants an answer.**

The first three subsections are one rule on one axis — *when* to come back to the
user — and they are only correct as a set; each was learned separately in a different
repo and re-derived, usually by getting one of them wrong first. The rest are
handover rules that belong beside them because they decide what the user is handed
when you do come back.

### After plan approval, run every phase to the PR

Plan approval is the authorization for every mechanical step after it. Run every
phase, commit atomically per phase, archive the PWF, push, open the PR, and report
**once**, at the end. Do not stop between phases to report progress: the decisions
that needed the user were taken at the gate, and a check-in that only reports
spends attention already committed. Under **Always Away** the cautious answer is the
wrong one — the work stalls on a question the user answered by approving the plan.

The instruction arrives as one short message covering many commits, reviews and
repos: *"Go all phases to PR"* (airvine, flooded#49, 2026-08-31; flooded#47 and
floodplains#33, 2026-09-01; trap, 2026-09-01; soul#169, 2026-09-04). One of those
runs carried four phases, a plan review, four code-check rounds, two issue-body
reconciliations and two cross-repo PRs with no further input. The merge is a separate
instruction: on soul#188 the user typed `/gh-pr-merge` once the PR was open, and asked
directly (2026-09-05) confirmed that *"to PR"* ends there.

Two things are inside the mandate; these are not:

- **Correcting the plan is inside it.** A review that disproves an approved design
  decision gets fixed mid-run and reported in the summary; that is the run working,
  not a reason to stop — unless the correction is itself a fork of the kind below (a
  key, an identifier, a schema), which goes back to the user. Blockers that cannot be resolved are filed as issues and
  named in the final report rather than held open.
- **Our own repos are inside it.** Filing issues, opening PRs and editing bodies in
  NGE repos is normal work; one run produced a follow-up issue and two cross-repo PRs
  without asking, and that was right.
- **Outward-facing actions are not** — see "Never post outside our own repos" below.
  Neither is anything a convention names as its own gate: **the merge** — *to the PR*
  ends at the open PR; `/gh-pr-merge` runs when the user invokes it or the instruction
  says so (airvine, 2026-09-05; `gh-pr-push/SKILL.md`, "Ask user before merging") — a change to the machine
  (`newgraph.md`, "State the plan before changing the machine"), or a push into an
  artifact a human is testing on (`code-check.md`). A push to the feature branch is
  inside the mandate.

### Before a plan exists, a question wants an answer

The same terseness that means "go" after approval means "answer me" before it. A
turn that ends in a question mark, with no approved plan, gets an answer and a
one-line offer of the work — not the first commit toward it. Twice in one day
(floodplains, 2026-09-02) a question was read as approval and editing started — once
after *"why not fix before publish?"*, and once after a gap had been explained, stopped
with *"do not take on 70. i want to understand"*. When the ask is to understand something, keep it short and concrete; a
worked example beats a taxonomy. *"small answers here"*, *"keep it short"* (airvine).

This is the boundary condition on the rule above, which is why they are one section:
a standing mandate to run autonomously, stated alone, is exactly what reads every
terse message as "go". **The mandate starts at plan approval.**

### What still interrupts, and where it goes

A decision that permanently shapes stored data — a key, an identifier, a schema
choice, a deprecation shim versus a hard rename — is the user's, and it goes to the
**plan gate**, batched, as two or three concrete options with the recommended one
first and the consequence stated. Two such forks put at one gate (flooded#47) were
both load-bearing and neither was derivable from the issue: the rename would also
have broken a production driver in another repo, which only the sweep surfaced.
Asked at the gate a fork costs one round-trip and buys the whole run; discovered
mid-execution it costs a stall with nobody there to answer it. Found mid-run, it is
still not the agent's to decide: ask it the same way — options, recommendation first,
phone-answerable — commit, and continue on the phases that do not depend on it while
the answer is outstanding (`planning.md`, "When Something Keeps Failing" — escalating
is not stopping).

During plan-mode exploration, keep a list of "this changes what I build" forks and
ask them together before `ExitPlanMode`. Questions are welcome; status updates are
not. Mechanism — whether to spawn reviewers, which regex, how to build a fixture — is
never a question (§6, "Spawning is your call"), and anything with a conventional
default is not one either: pick it, say so, move on.

### Never post outside our own repos without approval

Never post to a venue outside NGE's own repositories without the user's explicit
approval for that specific post — upstream GitHub issues and PR comments, mailing
lists, forums, third-party trackers. **Drafting is welcome and expected**: write the
comment, show it, wait. It is the sending that needs the word. *"Never post things
upstream without my explicit approval"* (airvine, 2026-09-02, after an offer to draft
comments on two of a vendor's upstream issues).

**Why:** an upstream comment is published under the organisation's name to a venue we
do not control, is indexed immediately, and cannot be unpublished. It is a
communications act, not an engineering one, and the judgement about tone, timing and
what we are willing to say in public is the user's.

- Our own repos are unaffected; filing and editing issues there is the standing
  disposition and needs no asking.
- **Reading upstream is unrestricted and worth doing.** Checking issue state before
  filing ours has caught a wrong citation in our own roxygen and found an upstream
  issue already proposing the feature we were about to request.
- Offer the draft in the reply, not as a fait accompli, and say plainly that nothing
  has been posted when the work obviously produced something postable.

### Hand the user bare commands

When the user must run a command themselves — an interactive login, a
sudo-needs-TTY operation, anything the Bash tool is blocked from running — give the
**bare command**, in a fenced block, ready to paste. Never prefix it with `!`.
*"Give me the cmd without the ! - that never works btw"* (airvine, 2026-08-21);
*"stop giving me the ! at the start. that doesn't work. i need the raw cmd"* (`cd`, 2026-08).

**Why, twice over.** Default session guidance proposes the `!` prefix as a way to run
a command in-session, so this recurs in every repo unless written down. On this
operator's terminals it either does not run at all, or — where it does — **it ran from
`$HOME` rather than the session's working directory** (one measurement, 2026-09-02): a
handed-over `! mkdir -p pursuits/x && cp … pursuits/x/` created `~/pursuits/x` and the
file had to be found and moved. Absolute paths are right whichever directory it
resolves against. So:

- Emit the command plain. Applies to fenced blocks and inline commands alike.
- **Absolute paths** in any handed-over command that touches files
  (`~/Projects/repo/<repo>/…`), whichever form the user ends up running it in.
- Keep it paste-safe: prefer `grep`/`awk` over a nested `python3 -c "…"` inside a
  single-quoted remote command, so the quoting survives the trip.

**A file under `~/Downloads` is unreadable by the agent process, and no retry helps.**
`Read`, `cp` and `pdftotext` on `~/Downloads/*` all fail with `Operation not permitted`
(measured 2026-09-02). It is macOS folder protection (TCC) on the process, not a
Claude Code permission mode, so `/permissions` does not change it; Desktop and
Documents behave the same. Do not retry variants — ask for **one** copy into the repo,
with absolute source and destination paths, then continue from the copy. (Granting
the terminal app Full Disk Access removes it on one machine; the fallback stays for
the next machine.)

### Link every issue and PR you name to the user

When a message to the user names an issue or a PR, make the number a link the user can
click: `[soul#191](https://github.com/NewGraphEnvironment/soul/issues/191)`,
`[soul PR #192](https://github.com/NewGraphEnvironment/soul/pull/192)`. Terminal output
renders markdown, so a bare `#191` costs the user a browser, a repo, and a click through
several pages to learn what it was — for every number in a report that may carry a
dozen. *"want to be able to follow up without opening new browser and clicking through
mult pages to find"* (airvine, 2026-09-05).

- **Issues under `/issues/N`, pull requests under `/pull/N`.** They are different paths,
  and the type is not always obvious from a number. When unsure, ask `gh` rather than
  guess — it returns the canonical URL for either:
  ```bash
  gh issue view 192 --repo NewGraphEnvironment/soul --json url -q .url \
    || gh pr view 192 --repo NewGraphEnvironment/soul --json url -q .url
  ```
- **Cross-repo references carry the repo**: `rfp#268`, never a bare `#268` from inside
  soul.
- **A bare `#N` is not ambiguous — it is a working link to the wrong repo.** The host
  resolves it against the session's own repo, so a bare number in a discussion *about* a
  different repo silently retargets. Measured 2026-09-12: an rfp review written from an rtj
  session rendered `#329`, `#221`, `#203` and four others as rtj links, and rtj#329 — *"its
  group is ticked by none, so it is invisible everywhere"* — is close enough in subject to
  rfp#329 to read as correct. Naming the collision in prose afterwards does not fix it; the
  link has to be re-qualified.
- **Spot-check a subset, not every link.** Before sending a report with many numbers,
  resolve two or three through `gh` — the ones you typed from memory or whose type you
  inferred — and let the rest ride. Checking all of them would slow every message; checking
  none is how a wrong repo or an issue-path link to a PR ships. Measured 2026-09-05: three
  constructed links checked against `gh`, two matched, one was a PR filed under the issue
  path.
- **Scope is messages to the user** — terminal replies, the compact-prep report, PR and
  issue bodies where a reader lands from outside the repo. Commit messages and issue bodies
  read *on* GitHub autolink `#N` already; do not bloat those.

### Surface upstream defects; do not work around them

When a dependency or an external API misbehaves, surface it and ask rather than
coding around it. *"dont' do workarounds for things like zotero api problems. surface
and ask as there may be simple solution"* (airvine, 2026-09-03).

**Why:** a workaround hides the defect from whoever could fix it properly, and the user
often has upstream context or a simple fix the session lacks. Most of the dependencies
in question are **first-party** — an upstream bug is usually ours — so a local patch
is strictly worse than an issue: it leaves the bug in place for every other consumer
while making this repo look fine. Same instinct as `newgraph.md`'s "install missing
packages, don't workaround", applied to a *broken* dependency rather than a *missing*
one.

**How to apply:** reproduce it minimally, file an issue in the owning repo with the
repro and the exact lines, report it, and carry on if it is not blocking. The rule is
*do not hide it*, not *do not continue*: the day it was recorded, a search function
failed on a list column and broke a documented pipeline step; the local guard would
have taken minutes and hidden a bug affecting every consumer, so it was filed with a
three-line repro and the pipeline continued, since its data path did not use search.

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.


# Planning Conventions

How Claude manages structured planning for complex tasks using planning-with-files (PWF).

## When to Plan

Use PWF when a task has multiple phases, requires research, or involves more than ~5 tool calls. Triggers:
- User says "let's plan this", "plan mode", "use planning", or invokes `/planning-init`
- Complex issue work begins (multi-step, uncertain approach)
- Claude judges the task warrants structured tracking

Skip planning for single-file edits, quick fixes, or tasks with obvious next steps.

## The Workflow

1. **Explore first** — Enter plan mode (read-only). Read code, trace paths, understand the problem before proposing anything. When the work codifies a pattern that already exists in multiple places (reference implementations across repos), read **every** reference in full, not just the canonical one — variation across references surfaces patches before v0.1 instead of as churn later (soul#52: reading all 4 references preempted 5 of the 7 fixes a dry-run would have found). Don't substitute Explore-agent summaries for direct reads; agents sometimes report existing files as absent.
2. **Plan to files** — Write the plan into 3 files in `planning/active/`:
   - `task_plan.md` — Phases with checkbox tasks
   - `findings.md` — Research, discoveries, technical analysis
   - `progress.md` — Session log with timestamps and commit refs
3. **Plan-review with the Plan agent — concurrently, not as a gate** — Once `task_plan.md` is scaffolded, spawn the Plan subagent (`Agent({subagent_type: "Plan", prompt: "..."}`) and ask it to critically review the task_plan against the issue body + actual codebase. Categorize findings as Blocker / Gap / Ordering / Assumption / Scope / Acceptance. The agent reads files fresh — it catches what you miss when you've been thinking about the design too long. Real example: caught 21 issues including hardcoded literals across 4 files not listed in the plan, untested DB column mismatches, and a baseline-cache-shadow that would have produced a 6-second no-op run.

   **Do not wait for it.** Spawn, then start the lowest-risk phase. Background agents have repeatedly returned late — in one case after the entire issue had shipped — so treating the review as a precondition stalls the work for as long as the agent takes (see `karpathy.md` §6). Fold findings in whenever they land: pre-baseline they edit the plan; mid-implementation they become follow-up commits — unless the finding is a stored-data fork of the kind `karpathy.md` §8 reserves for the user. A review that arrives after the code is written is not wasted — the reviewer reads real code instead of a plan, which is how one late review still contributed three fixes that no earlier reading had found. If you genuinely cannot proceed without the result, run it with `run_in_background: false` so the blocking is explicit.

   Verify before acting, in both directions. Findings have been confidently wrong (a "BLOCKER" disproved by a 30-second probe) and confidently right about things nobody suspected. Reproduce the claim first.

   **"Both directions" includes the reviewer's conclusions, not just its findings.**
   A review is wrong in the *alarming* direction loudly — a BLOCKER you probe and
   disprove costs one round-trip. It is wrong in the *reassuring* direction
   silently, because nothing prompts you to check a sentence telling you that you
   are finished. Measured 2026-08-30 in gq#77: round 4 fixed its own finding and
   characterised the residual as "definitional". Two commands showed it was not —
   the leftover axis had exactly one member and no margin, the same shape as the
   instance that reviewer had just fixed. Treat *"this is now terminal / complete /
   definitional"* as a claim with an author, exactly like an issue asserting a
   question can only be answered by testing.

   Corollary on when to stop: **convergence is not a reviewer saying you have
   converged.** Across four rounds on that PR, five instances of one defect class
   were found, and three separate "this is terminal now" claims — two of them mine
   — were wrong. What ended it was enumerating the complete candidate set and
   showing nothing sat above its source, not another round.

   **Spawn review agents UNNAMED.** Passing `name` to the `Agent` tool changes what you get: a named spawn becomes a persistent *teammate* that goes **idle** rather than completing, so there is no final report to auto-deliver and its output must be pulled with `SendMessage`. An unnamed spawn is a fire-and-return subagent whose report arrives on its own in the completion notification. Measured 2026-08-25 on one machine, one session, unchanged settings: the unnamed spawn returned in **6.4s**; three named reviewers returned nothing at all, sending only empty idle pings. Pass `name` only for a collaborator you intend to keep messaging, and shut it down when done — it pings indefinitely otherwise.

   That mis-spawn is what produced the silent-delivery failures below, so check `name` before suspecting settings. Teammate mode (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` + `teammateMode`, merged globally from `soul/settings/defaults.json`) shapes what a *named* spawn becomes; it is not by itself why findings go missing, and an unnamed spawn delivers fine with it enabled.

   **Get the findings into a file — but check who is doing the writing.** Message delivery has silently failed twice: one review arrived as idle notifications with no content, and one was routed to a different session on the user's phone, surfacing only because the user mentioned it. From this side an idle ping is indistinguishable from an agent that had nothing to say, so the loss is invisible. A file (`planning/active/review-<N>.md`) survives routing, survives the agent exiting, and is greppable later.

   **The `Plan` and `Explore` agent types have no Write tool, so they cannot write that file.** Both plan reviews on 2026-08-26 (gq#61, gq#40) were instructed to and were structurally unable to; one said so outright — *"I have no Write/Edit tools and am explicitly barred from creating files; an agent instruction can't lift that"* — and returned the full review as reply text instead. Both arrived intact, ~26 findings each. So:

   - **Read-only agent** (`Plan`, `Explore`): ask for the findings **in the reply**, then write them to `planning/active/review-<N>.md` yourself. The file is still the deliverable; you are just the one creating it.
   - **Agent type that can write**: put the file-path instruction in the first prompt, not as a follow-up.

   Asking for a file the agent cannot produce costs a round-trip, and — worse — sets you up to read an absent file as an absent review. Check the agent type's tools before writing the instruction.

   **Review the fixes, not just the code.** The second pass is where the value concentrates, because a fix written under a wrong assumption reproduces the same defect. Measured on gq#52: pass 1 found 13 defects, pass 2 found 7 more — including a blocker sitting *inside the fix* for pass 1's blocker, the same class twice (`lty`, then `fill_alpha`) because completeness was reasoned about rather than computed. Pass 3, scoped narrowly to the file edited most, found no new instances; **convergence is the signal to stop, not a fixed number of rounds.**

   Convergence is measured, not felt — a quiet round and an exhausted reviewer look
   identical. The rule that terminated trap#28 (five rounds; each of the first four
   found its best defect *inside the previous round's fix*) was to **enumerate the
   candidate set mechanically and show nothing sits above its source of truth**: parse
   the files and walk every `cli_abort`/`warning`/`stop` rather than recalling them, so
   "all of them are pinned" is a count. `code-check.md` states it under "A guard's
   scope, escape hatches, and remedies" — terminate by enumeration, not by a reviewer
   saying you have converged. `/code-check` treats three rounds as the floor and keeps
   going while a round finds a defect inside the previous fix.

   Ask for the **mechanism**, not more instances. Pass 3's best finding was that an invariant was enforced by two lists happening to agree — which is what had produced instances two and three.

   The thing reviewers catch that self-probing does not is **interop**: 18 tests inspected a legend object and none handed it to the renderer, which rejected it outright. Ask the consumer.
4. **Lock naming before the baseline** — If naming feedback surfaces during planning (legacy filename, inconsistency with an existing file family), fold the rename into the convention + task_plan BEFORE the baseline commit, not as a follow-up. Pre-baseline it's free; retrofitting after implementation cascades (soul#52: `build_exec_pdf.R` → `run_pagedown_exec_summary.R` locked in pre-baseline meant zero downstream rework).
5. **Commit the plan** — After Plan-agent review + fixes. This is the baseline.
6. **Work in atomic commits** — Each commit bundles code changes WITH checkbox updates in the planning files. The diff shows both what was done and the checkbox marking it done.
7. **Code check before commit** — Run `/code-check` on staged diffs before committing. Don't mark a task done until the diff passes review.
8. **Archive when complete** — Move `planning/active/` to `planning/archive/` via `/planning-archive`. Write a README.md in the archive directory with a one-paragraph outcome summary and closing commit/PR ref — future sessions scan these to catch up fast. Where the work produced measurements, that README is also the evidence record; see below.

## The archive README is the measurement record

Debugging and benchmarking sessions are systematic investigation: a stated unknown, an
experiment, a number, a conclusion, and usually two or three informative dead ends. That
is SRED evidence, and it scatters — into PR bodies, issue comments, and log files whose
names encode a timestamp and nothing else. In six months the chain *we did not know X,
we measured Y, therefore Z* survives only in a chat transcript.

**The archive README is where that chain lives.** Not a separate run record: the PWF
triple already holds every part of it — the question in `task_plan.md`'s frame, the
method in `progress.md`, the numbers in `findings.md`, the dead ends in its "Errors
Encountered" table. A second document would restate all of it and be half-populated.
The README is the index over them.

So an archive README for work that produced measurements carries two more sections:

```markdown
## Measurement

m1 0.0391 vs cypher 0.0872 min/1k segments — hosts are 2.23x apart.
Moved the provincial estimate 5.0 h -> 4.3 h and changed how work packs across machines.

## Evidence

`data-raw/logs/study_area_run/20260831_19*` — four spins, one defect each.
```

Three rules on those sections:

- **Numbers carry units, and say what changed because of them.** A measurement nobody
  acted on is still worth recording if it turned an assumption into a number — say that
  too. "Confirmed the expected" is a real outcome.
- **Cite a prefix or glob, never a file list.** A list rots the moment a run is re-run;
  a prefix survives. This is why campaign subdirectories exist (`newgraph.md`, "Which
  logs to commit").
- **Keep the wrong turns.** A diagnosis made, retracted on a bad inference, then
  confirmed by measurement *is* the evidence of systematic investigation. Sanitising it
  into a tidy conclusion destroys exactly what makes the record worth keeping.

**The case this does not cover.** Measurement that predates an issue has no PWF to
attach to — `/planning-init` takes an issue number, and exploratory runs often *produce*
the issues rather than follow them. That measurement belongs in the issue or PR it
spawned, with the log directory's own README as the index. Do not build a third system
to close this gap. The *finding* it settles goes where every settled finding goes —
`research/`, next section — which is not a third record of the run but the one place its
verdict is kept current.

## `research/` — what is known, outliving the issue that found it

Three homes, one job each: **the PWF archive is the story, committed logs are the
measurements, `research/` is the durable verdict** — floodplains' `research/README.md`
had that framing before this section existed. A research file holds what is now *known*: a
settled method, a measured fact about an external system, a search that established an
absence — so that someone picking the work up months later does not re-derive it.
`planning/archive/<issue>/` holds what was *done*, in order, for one issue, and is rarely
opened by anyone who never saw that issue. The research file is the one they will look for.

What does **not** go there: a work log; a run record (Run / Hardware / Software /
Configuration blocks — that is the archive README's `Measurement` and `Evidence`, above);
the raw numbers (committed logs). Measured 2026-09-06 across the seven repos carrying a
`research/`, 40 topic files: link's `provincial_parity_2026_05_*.md` are four run records in
25 days, each dated by the run it records and carrying that run's setup and metrics, while
its living documents, `bcfishpass_methodology.md`,
`study_area_run.md` and `provincial_run_runbook.md`, are single files revised as the
knowledge moved. The second shape is the one that moves the state of knowledge; the first
duplicates the archive.

### One topic file, revised in place — git is the version record

`research/<topic>.md`, noun-first, **no date in the filename**. A new measurement that
changes what is known revises the topic file; it does not add a dated sibling.
`git log --follow research/<topic>.md` is the dated history, the archive README it cites
is the *why*, and the logs are the numbers — everything an R&D claim needs, with no second
copy of any of it.

Existing dated files — `20260711_…`, `…_2026_05_25.md` — are **not renamed**. They are
cited by path from `CLAUDE.md` files and from other conventions (`bookdown.md`,
`karpathy.md` §7), and a rename breaks the citation the way it breaks log evidence
(`newgraph.md`, "Which logs to commit"). Convergence is forward-only, and the README says
when.

### The header is the provenance, in prose

No research file in any repo carries YAML frontmatter and nothing consumes it, so
provenance is one line under the H1. floodplains' is the shape to adapt — it already carries
the date and the issues, and names its log prefix in the body:

```markdown
**Date opened:** 2026-07-11 · **Issue:** #8 · **drift:** 0.6.0 (`dft_stac_fetch(tile_size=)`,
drift#36) · **Status:** OPEN — design set, runs pending.
```

Three things the line must carry — `**Verified:** <date> · **Issues:** … · **Produced by:** …`
is the minimal form:

- **When it was last true.** The file's date, and a section-level date wherever one
  section is re-verified alone. A research file whose numbers cannot be re-derived ages
  into folklore, and one that states a scope or a quantity drifts silently when the code
  moves — three link documents, two of them research files, asserted a recompute "runs over
  every WSG in the schema" after two commits had changed it (`karpathy.md` §7, "Documents
  that share an ancestor corroborate nothing"). When code changes a behaviour a research
  file describes, grep `research/` for the sentence. Files written before 2026-09-06 gain
  the line when next revised; no fleet sweep is required.
- **What produced it.** The script path or log prefix for a measurement; the source list or
  reference-manager collection for a literature review. Never a number without its producer.
- **Which issues it came from and which it spawned.** The issue body links the research
  file (`feature-workflow.md`, "Issue bodies get edited, not appended"); the research file
  names its issues; and an archive README whose `Measurement` was distilled into a research
  file links it. Both ways, every time — one direction leaves the other end unfindable.

### The directory carries a README

An index: one row per file, what it covers — rfp's is the model. Where other repos hold
related work, a "Related work" list of links. Where two naming patterns coexist, the
cutover line in the form `newgraph.md` uses for logs:

```markdown
Naming: `<topic>.md`, revised in place, from 2026-09-06.
Files dated before that carry a `yyyymmdd_` prefix; they are not being renamed.
```

The README is the index. `CLAUDE.md` links the README once and cites an individual file
only where a rule depends on it. Twenty-three topic files with no README and a `CLAUDE.md`
citing four of them by path — link, measured 2026-09-06 — is the state this prevents.

### R packages and public repos

`research/` is top-level and excluded from the tarball: `^research$` in `.Rbuildignore`
(`code-check-r.md`, "`R CMD build` ships every top-level directory not in
`.Rbuildignore`"). Not `inst/notes/` or `inst/research/`, which ship inside the installed
package — the three packages carrying those (eight files, 2026-09-06) migrate by issue,
forward-only. In a package, `research/` is also where durable reference notes go, because
`docs/` belongs to pkgdown and `inst/` ships. And a public tool repo's `research/` is
public: report findings from internal work aggregated, never by the names of who it was for.

## Atomic Commits (Critical)

Every commit that completes a planned task MUST include:
- The code/script changes
- The checkbox update in `task_plan.md` (`- [ ]` -> `- [x]`)
- A progress entry in `progress.md` if meaningful

This creates a git audit trail where `git log -- planning/` tells the full story. Each commit is self-documenting — you can backtrack with git and understand everything that happened.

## File Formats

### task_plan.md

Phases with checkboxes. This is the core tracking file.

```markdown
# Task: <issue title> (#<N>)

<issue body — Problem section if present, otherwise first paragraph>

## Phase 1: [Name]
- [ ] Task description
- [ ] Another task

## Phase 2: [Name]
- [ ] Task description
```

Mark tasks done as they're completed: `- [x] Task description`

### findings.md

Append-only research log. Discoveries, technical analysis, things learned.

```markdown
# Findings

## [Topic]
[What was found, with source/date]

## Errors Encountered

| Error | Resolution |
|-------|------------|
```

### progress.md

Session entries with commit references.

```markdown
# Progress

## Session YYYY-MM-DD
- Completed: [items]
- Commits: [refs]
- Next: [items]
```

<!-- The Reboot Test and the error ledger below are adapted from -->
<!-- OthmanAdi/planning-with-files (MIT). Soul does not install or invoke that -->
<!-- plugin — the useful parts are carried here as text. Adapted 2026-08-26. -->
<!-- Same precedent as the attribution header in karpathy.md. -->

## The Reboot Test

The planning files exist so the work survives an interruption. Whether they
actually do is checkable: at any point mid-task, these five questions must be
answerable from the files alone, without the conversation.

| Question | Answer source |
|----------|---------------|
| Where am I? | Current phase in `task_plan.md` |
| Where am I going? | Remaining phases in `task_plan.md` |
| What's the goal? | The `# Task: <title> (#N)` frame and problem statement at the top of `task_plan.md` |
| What have I learned? | `findings.md` |
| What have I done? | `progress.md` |

If an answer lives only in the session, **write it down and commit it**. Written
is not sufficient: an uncommitted `findings.md` does not move between machines,
and a repo whose `planning/` is gitignored accepts `git add planning/` with exit
0 while tracking nothing — see Directory Structure below.

This is the operational check for the rule that every interruption should be a
resume point: a session death, sleep, or machine swap should cost a re-run at
most, never lost context. That rule states the goal; this tests it.

Run it before any long wait, before compaction, and before switching machines —
the moments that take a session without warning. `/compact-prep` and
`/planning-update` are where it gets run; this section is what it asks.

## Directory Structure

```
planning/
  active/          <- Current work (3 PWF files)
  archive/         <- Completed issues
    YYYY-MM-issue-N-slug/
```

If `planning/` doesn't exist in the repo, run `/planning-init` first.

**`planning/active/` must be tracked, not gitignored.** The atomic-commit rule
above requires each commit to carry its own checkbox flip in `task_plan.md`; an
ignored `active/` drops it silently, so `git log -- planning/` shows archives
appearing fully-formed with no history behind them. In-flight PWF also stops
surviving a move between machines.

The failure is quiet in both directions. `git add planning/` reports nothing and
exits 0 on an ignored path, and files tracked *before* the rule existed keep
being tracked — including through a `git mv` into the ignored directory. So a
repo can look like it is working right up until the first genuinely new PWF file,
which simply never appears in a commit.

Check rather than assume:

```bash
git check-ignore -v planning/active/task_plan.md   # expect no output
```

Found 2026-08-24 in gq, where the rule dated from the scaffold commit and the
#17 files had only survived because they predated their move into that
directory. gq and roli were the only 2 of 32 repos carrying it; roli still does.

## When Something Keeps Failing

Before a second attempt, name the failure class. A **deterministic** failure
returns the same result to the same inputs, so re-running unchanged only spends a
turn — change the inputs or change the approach. A **transient** failure
(network, a provider read, a rate limit, a resource still settling) is the case
where a re-run *is* the attempt: `code-check-infra.md` prescribes exactly that for a
tofu plan that falsely reports a resource deleted. The rule is not "never retry";
it is never retry unchanged while expecting a different answer.

Escalate rather than iterate once the approach itself is in question. Report what
was tried and the exact error, and hand over the commands to run — the user is
assumed to be away, so a question answerable from a phone beats a retry loop they
cannot see. Escalating is not stopping: commit the current state, then move to
the lowest-risk independent part of the plan while the question is outstanding.

Two classes escalate immediately rather than after retries, because further
attempts make them worse:

- **A clamped session.** Once a live credential has been read, later
  system-mutating commands are refused regardless of route — seven consecutive
  refusals across unrelated routes is the documented case (`newgraph.md`,
  "Reading a secret clamps the rest of the session"). Trying more phrasings is
  the failure mode, not the remedy, and `/permissions` does not clear it.
- **Rate limits.** Retrying extends the block (`ci-monitoring.md`).

### Log the errors that cost a retry

An error that took more than one attempt to get past goes in `findings.md`, so
one task does not hit the same wall twice:

```markdown
## Errors Encountered

| Error | Resolution |
|-------|------------|
| `fatal: Unimplemented pathspec magic '_'` | Long-form `:(exclude)path` |
```

That row is also what graduation looks like: it began as one task's blocker and
now lives in `code-check-shell.md` as a general rule about pathspec magic. Most rows
never make that trip and should not — the ledger's job is to stop one task
repeating itself.

When a failure does generalize, it graduates to the convention that owns its
class: the `code-check*.md` family for a bug class in a diff — `code-check.md` for a
mechanism, `-shell`, `-r`, `-spatial` or `-infra` for a tool quirk — `ci-monitoring.md` for CI
behaviour, the domain convention otherwise.

## Skills

| Skill | When to use |
|-------|-------------|
| `/planning-init` | First time in a repo — creates directory structure |
| `/planning-update` | Mid-session — sync checkboxes and progress |
| `/planning-archive` | Issue complete — archive and create fresh active/ |


# Reference Management Conventions

How references flow between Claude Code, Zotero, and technical writing at New Graph Environment.

## Tool Routing

Three tools, different purposes. Use the right one.

| Need | Tool | Why |
|------|------|-----|
| Search by keyword, read metadata/fulltext, semantic search | **MCP `zotero_*` tools** | pyzotero, works with Zotero item keys |
| Look up by citation key (e.g., `irvine2020ParsnipRiver`) | **`/zotero-lookup` skill** | Citation keys are a BBT feature — pyzotero can't resolve them |
| Create items, attach PDFs, deduplicate | **`/zotero-api` skill** | Connector API for writes, JS console for attachments |

**Citation keys vs item keys:** Citation keys (like `irvine2020ParsnipRiver`) come from Better BibTeX. Item keys (like `K7WALMSY`) are native Zotero. The MCP works with item keys. `/zotero-lookup` bridges citation keys to item data.

**BBT citation key storage:** As of Feb 2025+, BBT stores citation keys as a `citationKey` field directly in `zotero.sqlite` (via Zotero's item data system), not in a separate BBT database. The old `better-bibtex.sqlite` and `better-bibtex.migrated` files are stale and no longer updated. Query citation keys with: `SELECT idv.value FROM items i JOIN itemData id ON i.itemID = id.itemID JOIN itemDataValues idv ON id.valueID = idv.valueID JOIN fields f ON id.fieldID = f.fieldID WHERE f.fieldName = 'citationKey'`.

**BBT citekey format is locally patched to strip `&`:** the `citekeyFormat` pref (`extensions.zotero.translators.better-bibtex.citekeyFormat` in `~/Library/Application Support/Zotero/Profiles/*/prefs.js`) has a `.replace(find = "&", replace = "")` segment added by hand. Without it, institutional authors containing `&` (e.g. "BC Species & Ecosystem Explorer", "WA Dept of Fish & Wildlife") leak `&` into the citekey, and pandoc's `@key` parser stops at `&` — so cites render broken in any bookdown/quarto build even though biblatex accepts the key. Reapply via Zotero → Tools → Run JavaScript: `Zotero.Prefs.set("translators.better-bibtex.citekeyFormat", val)` (also patch `citekeyFormatEditing` to match). Survives Zotero/BBT auto-updates; reverts only on a profile reset or a manual edit via the BBT preferences UI. Detect drift: `grep citekeyFormat ~/Library/Application\ Support/Zotero/Profiles/*/prefs.js` should show the `.replace(find = "&", ...)` chain. Teammates on Skeena/Fraser/restoration machines that hit the same `@key`-breaks-at-`&` drift should run the same `Zotero.Prefs.set`.

## Which routes are live by default

Measured 2026-09-04 on a freshly provisioned machine. Four of the six routes below were
dead, and each dead end costs a session time it has no reason to expect:

| route | state on a default setup |
|---|---|
| **Web API** | **works** — the route to use for writes; targets a collection directly via `"collections": [...]` and needs Zotero neither open nor restarted for the write itself |
| **read-only SQLite** | works, and remains the best route for *searching* (`/zotero-lookup`) |
| MCP `zotero_*` | unavailable until an API key is configured — the install script registers the server but never configures a key |
| Local API | `403 Local API is not enabled`, with and without the `Zotero-Allowed-Request` header |
| Connector `saveItems` | HTTP 500 on a minimal item with exactly the documented headers — a defect, not a permission; reads on the same port (`ping`, `getSelectedCollection`) are fine, and `getSelectedCollection` returns the whole collection tree in one call |
| JS runner (`zotero_run_js.sh`) | `osascript is not allowed assistive access` until the terminal has Accessibility |

**Zotero's server takes about 30 s after launch to respond.** An early failure does not
mean it is not running, which is exactly the wrong conclusion to draw at that moment —
wait and retry once before diagnosing.

The key's location, the password-manager item that holds it and the local port are
infrastructure identity and stay in machine-local memory, not here (soul#177).

**`immutable=1` serves a stale snapshot, so it cannot confirm a write landed.** The
read-only URI the skills prescribe —
`sqlite3 "file:$HOME/Zotero/zotero.sqlite?mode=ro&immutable=1"` — is right for
*searching*, and it is exactly wrong for *verifying*: `immutable` tells SQLite the file
cannot change, so it skips the WAL and the change counter and serves whatever it first
mapped. A write made through the Web API is invisible to it for as long as the process
lives, which reads as "the write failed" rather than "this reader cannot see it". Copy
the file first when the question is whether something landed, and note that a Web API
create also needs Zotero to **sync** before it is in the local database at all.

Three skills prescribe that URI (`zotero-lookup`, `zotero-api`, `lit-search`) and none
of them says this, which is why it is here rather than in one of them.

## Citation keys are BBT-auto-derived

**Never set `Citation Key:` in the `extra` field.** BBT honours it as a manual override,
and that breaks the convention that every key follows one formula: stable, reproducible,
the same key for the same paper on every collaborator's machine. Leave `extra` empty, or
use it only for other Zotero-supported fields (`Original Date:`, `tex.shorttitle:`).
Ten items created with hand-set keys in one lit review (cd#58, 2026-05-05) had to be
PATCHed clean after the user caught it.

- **Web API-created items get no key until Zotero restarts.** Sync alone does not trigger
  BBT. On macOS:
  ```bash
  osascript -e 'tell application "Zotero" to quit'; sleep 3; open -a Zotero; sleep 30
  ```
  Thirty seconds covered seven fresh items (cd#61); scale the wait with the batch.
- **Corporate-author guard.** CrossRef sometimes returns no individual authors (a paper
  bylined to a working group), so the POST lands with empty `creators` and BBT falls back
  to a `<title-prefix><year>` key. PATCH the individual authors from the paper's roster
  into `creators` before triggering the restart.
- **BBT and Zotero version lines are paired** — BBT 8.x for Zotero 7, 9.x for Zotero 8/9.
  If Zotero auto-disables BBT after an update, keys silently stop generating for new
  items; reinstall the matching line via Plugin Manager → gear → "Install Plugin From
  File…" from the BBT releases page.

`/lit-search` and `/zotero-api` point here; this is the authority (soul#43).

## Adding References Workflow

### 1. Search and flag

When research turns up a reference:
- **DOI available:** Tell the user — Zotero's magic wand (DOI lookup) is the fastest path
- **ResearchGate link:** Flag to user for manual check — programmatic fetch is blocked (403), but full text is often there
- **BC gov report:** Search [ACAT](https://a100.gov.bc.ca/pub/acat/), for.gov.bc.ca library, EIRS viewer
- **Paywalled:** Note it, move on. Don't waste time trying to bypass.

### 2. Add to Zotero

**Preferred order:**
1. DOI magic wand in Zotero UI (fastest, most complete metadata)
2. Web API POST with `collections` array (grey literature, local PDFs — targets collection directly, no UI interaction needed)
3. `saveItems` via `/zotero-api` (batch creation from structured data — requires UI collection selection)
4. JS console script for group library (when connector can't target the right collection)

**Collection targeting:** `saveItems` drops items into whatever collection is selected in Zotero's UI. Always confirm with the user before calling it. **Web API bypasses this** — include `"collections": ["KEY"]` in the POST body. Find collection keys with `?q=name` search on the collections endpoint.

### 3. Attach PDFs

`saveItems` attachments silently fail. Don't use them. Instead:

1. **Web API S3 upload (preferred):** Create attachment item → get upload auth → build S3 body (Python: prefix + file bytes + suffix) → POST to S3 → register with uploadKey. Works without Zotero running. See `/zotero-api` skill section 4.
2. **JS console fallback:** Download with `curl`, attach via `item_attach_pdf.js` in Zotero JS console.
3. Verify attachment exists via MCP: `zotero_get_item_children`

### 4. Verify

After manual adds, confirm via MCP:
- `zotero_search_items` — find by title
- `zotero_get_item_metadata` — check fields are complete
- `zotero_get_item_children` — confirm PDF attached

### 5. Clean up

If duplicates were created (common with `saveItems` retries):
- Run `collection_dedup.js` via Zotero JS console
- It keeps the copy with the most attachments, trashes the rest

## In Reports (bookdown)

### Bibliography generation

```yaml
# index.Rmd — dynamic bib from Zotero via Better BibTeX
bibliography: "`r rbbt::bbt_write_bib('references.bib', overwrite = TRUE)`"
```

`rbbt` pulls from BBT, which syncs with Zotero. Edit references in Zotero → rebuild report → bibliography updates.

**Library targeting:** rbbt must know which Zotero library to search. This is set globally in `~/.Rprofile`:

```r
# default library — NewGraphEnvironment group (libraryID 9, group 4733734)
options(rbbt.default.library_id = 9)
```

Without this option, rbbt searches only the personal library (libraryID 1) and won't find group library references. The library IDs map to Zotero's internal numbering — use `/zotero-lookup` with `SELECT DISTINCT libraryID FROM citationkey` against the BBT database to discover available libraries.

### Citation syntax

- `[@key2020]` — parenthetical: (Author 2020)
- `@key2020` — narrative: Author (2020)
- `[@key1; @key2]` — multiple
- `nocite:` in YAML — include uncited references

### Cite primary sources

When a review paper references an older study, trace back to the original and cite it. Don't attribute findings to the review when the original exists. (See LLM Agent Conventions in `newgraph.md`.)

**When the original is unavailable** (paywalled, out of print, can't locate): use secondary citation format in the prose and include bib entries for both sources:

> Smith et al. (2003; as cited in Doctor 2022) found that...

Both `@smith2003` and `@doctor2022` go in the `.bib` file. The reader can then track down the original themselves. Flag incomplete metadata on the primary entry — it's better to have a partial reference than none at all.

## PDF Fallback Chain

When you need a PDF and the obvious URL doesn't work:

1. DOI resolver → publisher site (often has OA link)
2. Europe PMC (`europepmc.org/backend/ptpmcrender.fcgi?accid=PMC{ID}&blobtype=pdf`) — ncbi blocks curl
3. SciELO — needs `User-Agent: Mozilla/5.0` header
4. ResearchGate — flag to user for manual download
5. Semantic Scholar — sometimes has OA links
6. Ask user for institutional access

Always verify downloads: `file paper.pdf` should say "PDF document", not HTML.

## Searching Paper Content (ragnar)

### Setup (per project)
- `scripts/rag_build.R` — maps citation keys to Zotero PDF attachment keys, builds DuckDB
- `data/rag/` gitignored — store is local, not committed
- Dependencies: ragnar, Ollama with nomic-embed-text model
- See `/lit-search` skill for full recipe

### Query
`ragnar_store_connect()` then `ragnar_retrieve()` — returns chunks with source file attribution.

### Anti-patterns
- NEVER write abstracts manually — if CrossRef has no abstract, leave blank
- NEVER cite specific numbers without verifying from the source PDF via ragnar search
- NEVER paraphrase equations — copy exact notation and cite page/section
