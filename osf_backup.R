#!/usr/bin/env Rscript
# ============================================================================
# osf_backup.R
# David Levari, August 2026
#
# Downloads a full local backup (metadata + files) of every OSF project you
# own -- including sub-components -- using the OSF public API (v2) and the
# WaterButler file-storage API.
#
# ----------------------------------------------------------------------------
# SETUP
# ----------------------------------------------------------------------------
# 1. Create a Personal Access Token at https://osf.io/settings/tokens/
#      - Click "Create token"
#      - Give it a name (e.g. "backup-script")
#      - Check EXACTLY ONE scope:  osf.full_read
#          osf.full_read           <- YES. The only one you need. Grants read
#                                     access to everything on the account,
#                                     including private projects, which is
#                                     required to list nodes and download files.
#          osf.full_write          <- NO. Grants edit/delete rights. This script
#                                     only reads, so leaving this off means a
#                                     leaked token cannot damage your projects.
#          osf.users.profile_read  <- NO. Profile bio/name only; unused here.
#          osf.users.email_read    <- NO. Email address only; unused here.
#      - Copy the token (you only see it once)
# 2. Do NOT paste the token into this file. Instead, set it as an
#    environment variable before running the script, e.g. in your OS terminal:
#
#      export OSF_PAT="paste-your-token-here"
#      Rscript osf_backup.R
#
#    (On Windows/PowerShell: $env:OSF_PAT = "paste-your-token-here")
#
# 3. Install dependencies once:
#      install.packages(c("httr", "jsonlite"))
#
#    Optional but recommended, for SHA-256 verification rather than MD5:
#      install.packages("digest")
#
# ----------------------------------------------------------------------------
# CONFIGURING WITHOUT EDITING THIS FILE
# ----------------------------------------------------------------------------
# Every setting has a sensible default below and can be overridden with an
# environment variable, so colleagues can run it as-is:
#
#   OSF_PAT              (required) your personal access token
#   OSF_OUTPUT_DIR       where to write the backup       [next to this script]
#   OSF_ACCESS_MODE      admin | collaborator            [admin]
#   OSF_VISIBILITY       all | public                    [all]
#   OSF_FORCE_REFRESH    1 to re-download existing files [0]
#   OSF_VERIFY           0 to skip checking downloads    [1]
#   OSF_VERIFY_ONLY      1 to re-check a backup offline  [0]
#   OSF_MIN_FREE_MB      stop below this free space      [2048]
#   OSF_CONTACT          your email, sent in User-Agent  [unset]
#   OSF_REQUEST_DELAY    seconds between API calls       [0.25]
#   OSF_MAX_RETRIES      retries on 429/5xx/network      [5]
#   OSF_TIMEOUT          per-API-request timeout, sec    [60]
#   OSF_DOWNLOAD_TIMEOUT per-file download timeout, sec  [3600]
#   OSF_MAX_RETRY_AFTER  cap on obeying Retry-After, sec [900]
#   OSF_RATE_LIMIT_FLOOR min wait after a bare 429, sec  [60]
#   OSF_LOG_ENTRIES      activity-log entries per node   [100]
#   OSF_ONLY             back up only these node ids     [unset]  (testing)
#   OSF_LIMIT            stop after N projects           [0]      (testing)
#
# e.g.  OSF_ACCESS_MODE=admin OSF_OUTPUT_DIR=~/archive Rscript osf_backup.R
#
# ----------------------------------------------------------------------------
# BEING A GOOD API CITIZEN
# ----------------------------------------------------------------------------
# OSF is a free, shared, non-profit service. This script tries to behave:
#   - pauses briefly between requests rather than firing them as fast as
#     possible
#   - on HTTP 429 (rate limited) it backs off and waits, honouring the
#     server's Retry-After header, instead of retrying immediately
#   - retries transient 5xx and network errors with exponential backoff and
#     jitter, then gives up rather than looping forever
#   - identifies itself in the User-Agent, so OSF can see what this traffic is
#   - skips files it already has, so re-runs are cheap for both sides
# Setting OSF_CONTACT to your email is appreciated if you are backing up a
# very large account.
#
# ----------------------------------------------------------------------------
# PRIVACY
# ----------------------------------------------------------------------------
# The backup will contain your PRIVATE projects and unpublished data. Treat
# the output directory accordingly: do not commit it to a git repository, and
# think before putting it on a shared or cloud drive.
#
# ----------------------------------------------------------------------------
# WHAT IT DOES
# ----------------------------------------------------------------------------
# For every top-level project you are the creator of (via
# GET /v2/users/me/nodes/), and recursively for every child component:
#   - Saves the project's full JSON metadata (title, description, tags,
#     contributors, category, dates, wiki/citation info if present) to
#     metadata.json
#   - Saves a flat contributors.json and logs.json (last 100 log entries)
#     for provenance
#   - Downloads every file storage add-on attached to that node (usually
#     just "osfstorage", but also github/dropbox/googledrive/etc. if
#     connected and still authorized) as a single recursive .zip archive,
#     using WaterButler's built-in folder-zip feature -- no manual file
#     tree walking required
#
# Output layout:
#   <OUTPUT_DIR>/backup_manifest.csv             index of everything captured
#   <OUTPUT_DIR>/<project title (sanitized)>__<node id>/
#     metadata.json
#     contributors.json
#     logs.json
#     wikis.json                                 wiki page metadata
#     wiki/<page name>.md                        wiki page content
#     checksums.csv                              local hashes, for offline checks
#     registrations/<title>__<id>/
#       registration.json                        incl. registered_meta
#       preregistration.md                       readable: questions + answers
#       DOI.txt
#       files/, wiki/
#     files/osfstorage.zip
#     files/<other-provider>.zip
#     components/<child title>__<child id>/...   (same structure, recursive)
#
# This is NOT the same as OSF's "make private" or "delete" -- nothing on
# OSF itself is modified. This script only reads from your account and
# writes files locally.
#
# ----------------------------------------------------------------------------
# LIMITATIONS -- PLEASE READ
# ----------------------------------------------------------------------------
# Provided as-is, with no warranty. Not affiliated with or endorsed by the
# Center for Open Science. Verify a restore yourself before deleting anything
# from OSF, and do not let this be the only copy of anything irreplaceable.
#
# NOT backed up:
#   - FILE VERSION HISTORY. The zip holds the CURRENT version of each file
#     only. Earlier revisions, which OSF keeps under a file's Revisions tab,
#     are NOT retrieved. This is a deliberate choice: fetching them would mean
#     downloading each revision of each file individually, giving up the
#     single-zip-per-project efficiency and multiplying API traffic. If you
#     rely on being able to recover a superseded version of a file, this
#     script will not do it for you.
#   - Preprints associated with a project.
#   - Comments and annotations.
#   - Activity log beyond the most recent LOG_ENTRIES entries.
#   - Storage add-ons that are disconnected or whose authorization expired
#     (reported, but skipped).
#   - View-only / anonymised links. If a manuscript under review cites one,
#     that link dies with the project.
#
# ARE backed up: wiki pages (as markdown), registrations (including
# registered_meta, i.e. your preregistration answers, plus their own files,
# wikis and DOI), and each project's DOI where one has been minted.
#
# ----------------------------------------------------------------------------
# CHECKING THE BACKUP LATER, WITH NO NETWORK
# ----------------------------------------------------------------------------
#   OSF_VERIFY_ONLY=1 OSF_OUTPUT_DIR=~/archive Rscript osf_backup.R
#
# Re-hashes every file against the checksums.csv written alongside it when the
# backup was made, and needs no token and no internet. This is the check that
# still works when OSF does not. Worth doing before you rely on an archive:
# disks rot quietly, and a backup nobody has ever checked is a hope, not a
# backup.
#
# ----------------------------------------------------------------------------
# IF YOU WORK WITH HUMAN-SUBJECTS DATA
# ----------------------------------------------------------------------------
# This copies whatever is in your projects onto whatever machine you run it on.
# If any of it is human-subjects data, check that your IRB protocol and any
# data-use agreements actually permit storing it there before you run this. A
# laptop or personal cloud drive is often not an approved location.
#
# What verification proves: that what you downloaded matches WHAT OSF'S API
# SAYS THE PROJECT CONTAINS. It catches truncation, missing files and
# corruption in transit. It cannot tell you whether a file was correctly
# uploaded to OSF in the first place -- a faithful copy of something already
# wrong on OSF will verify clean.
#
# Other caveats:
#   - Snapshot, not a sync: nothing detects files DELETED on OSF since the
#     last run.
#   - No restore path; putting a project back on OSF is a manual job.
#   - Metadata and files for a project are fetched seconds apart, so a project
#     edited mid-run can yield a slightly inconsistent snapshot.
# ============================================================================

SCRIPT_VERSION <- "1.0.0"

# The script uses startsWith(), endsWith() and strrep(), all introduced in
# R 3.3.0. Fail with a clear message rather than an obscure "could not find
# function" error on an older install.
if (getRversion() < "3.3.0") {
  stop("This script needs R 3.3.0 or newer (you have ", getRversion(), ").",
       call. = FALSE)
}

# --- dependency check -------------------------------------------------------
# Fail with an actionable message rather than a bare "there is no package
# called 'httr'" traceback.
.missing <- Filter(
  function(p) !requireNamespace(p, quietly = TRUE),
  c("httr", "jsonlite")
)
if (length(.missing) > 0) {
  stop(
    "Missing required R package(s): ", paste(.missing, collapse = ", "), "\n",
    "Install them with:\n",
    "  install.packages(c(", paste(sprintf('"%s"', .missing), collapse = ", "), "))",
    call. = FALSE
  )
}

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
})

# ---------------------------------------------------------------------------
# CONSOLE OUTPUT
# ---------------------------------------------------------------------------
# Most people running this are researchers, not people who spend their day in a
# terminal. A wall of undifferentiated text is hard to scan and harder to act
# on, so output is marked with a symbol saying what kind of thing it is, and
# problems say what to do rather than only what went wrong.
#
# Everything degrades safely: no colour when output is redirected to a file or
# when NO_COLOR is set, and plain ASCII markers where the console can't render
# UTF-8 (some Windows consoles). Never let presentation break the message.

UI_UNICODE <- tryCatch(isTRUE(l10n_info()[["UTF-8"]]), error = function(e) FALSE)
UI_COLOR   <- tryCatch(
  isatty(stderr()) && !nzchar(Sys.getenv("NO_COLOR")),
  error = function(e) FALSE
)

SYM <- if (UI_UNICODE) {
  list(ok = "✔", err = "✖", warn = "!", info = "ℹ",
       bullet = "•", skip = "·", wait = "↻", rule = "─")
} else {
  list(ok = "v", err = "x", warn = "!", info = "i",
       bullet = "*", skip = ".", wait = "~", rule = "-")
}

ui_paint <- function(txt, code) {
  if (!UI_COLOR) return(txt)
  paste0("\033[", code, "m", txt, "\033[0m")
}

# One line, marked with a symbol. `indent` keeps nested components readable.
ui_line <- function(sym, code, fmt, ..., indent = "") {
  message(indent, ui_paint(sym, code), " ", sprintf(fmt, ...))
}

ui_ok    <- function(fmt, ..., indent = "") ui_line(SYM$ok,   "32", fmt, ..., indent = indent)
ui_err   <- function(fmt, ..., indent = "") ui_line(SYM$err,  "31", fmt, ..., indent = indent)
ui_warn  <- function(fmt, ..., indent = "") ui_line(SYM$warn, "33", fmt, ..., indent = indent)
ui_info  <- function(fmt, ..., indent = "") ui_line(SYM$info, "36", fmt, ..., indent = indent)
ui_skip  <- function(fmt, ..., indent = "") ui_line(SYM$skip, "90", fmt, ..., indent = indent)
ui_wait  <- function(fmt, ..., indent = "") ui_line(SYM$wait, "33", fmt, ..., indent = indent)

# Plain text, no symbol.
ui_text <- function(fmt, ..., indent = "") message(indent, sprintf(fmt, ...))

# A titled horizontal rule, to break the run into phases you can scan for.
ui_rule <- function(title = "") {
  width <- 72
  if (!nzchar(title)) return(message(strrep(SYM$rule, width)))
  left <- paste0(strrep(SYM$rule, 2), " ", title, " ")
  message(ui_paint(paste0(left, strrep(SYM$rule, max(0, width - nchar(left)))),
                    "1"))
}

# A problem with what to do about it. The "next step" is the part people
# actually need, and it is the part usually missing from error output.
# Free space on the volume holding `path`, in bytes, or NA if we can't tell.
#
# Base R has no portable way to ask this, so shell out. Both branches are
# wrapped: an unusual environment where neither works should degrade to "we
# don't know" and let the run continue, never abort a good backup over a
# failed disk query.
disk_free_bytes <- function(path) {
  tryCatch({
    p <- normalizePath(path, mustWork = FALSE)
    if (.Platform$OS.type == "windows") {
      # Only ever interpolate a single drive letter into the command string.
      # Everything else here is shQuote'd; this one is built by sprintf, so
      # constrain it rather than rely on where the path came from.
      drive <- substr(p, 1, 1)
      if (!grepl("^[A-Za-z]$", drive)) return(NA_real_)
      out <- suppressWarnings(system2(
        "powershell",
        c("-NoProfile", "-Command",
          shQuote(sprintf("(Get-PSDrive -Name '%s').Free", drive))),
        stdout = TRUE, stderr = FALSE))
      val <- suppressWarnings(as.numeric(trimws(out[1])))
      if (length(val) == 0 || is.na(val)) NA_real_ else val
    } else {
      # POSIX `df -Pk`: column 4 of the second line is available 1024-blocks.
      out <- suppressWarnings(system2("df", c("-Pk", shQuote(p)),
                                        stdout = TRUE, stderr = FALSE))
      if (length(out) < 2) return(NA_real_)
      f <- strsplit(trimws(out[2]), "[[:space:]]+")[[1]]
      if (length(f) < 4) return(NA_real_)
      as.numeric(f[4]) * 1024
    }
  }, error = function(e) NA_real_, warning = function(w) NA_real_)
}

# Bytes as something a person can read at a glance.
format_size <- function(bytes) {
  if (is.na(bytes)) return("unknown size")
  if (bytes < 1024)        return(sprintf("%d B", as.integer(bytes)))
  if (bytes < 1024^2)      return(sprintf("%.0f KB", bytes / 1024))
  if (bytes < 1024^3)      return(sprintf("%.1f MB", bytes / 1024^2))
  sprintf("%.2f GB", bytes / 1024^3)
}

ui_problem <- function(headline, ..., next_steps = character(0)) {
  message("")
  ui_err("%s", sprintf(headline, ...))
  for (s in next_steps) message("  ", SYM$bullet, " ", s)
  message("")
}

# ---------------------------------------------------------------------------
# CONFIG
# ---------------------------------------------------------------------------

# Every setting below can be overridden with an environment variable, so users
# can run the script without editing it:
#
#   OSF_OUTPUT_DIR=~/backups OSF_ACCESS_MODE=admin Rscript osf_backup.R
#
# The in-file value is the default used when the variable is unset.
env_or <- function(varname, default) {
  val <- Sys.getenv(varname)
  if (identical(val, "")) default else val
}
env_num_or <- function(varname, default) {
  val <- suppressWarnings(as.numeric(Sys.getenv(varname)))
  if (is.na(val)) default else val
}
env_flag_or <- function(varname, default) {
  val <- toupper(Sys.getenv(varname))
  if (identical(val, "")) default else val %in% c("1", "TRUE", "YES", "Y")
}

API_BASE   <- "https://api.osf.io/v2"
FILES_BASE <- "https://files.osf.io/v1/resources"   # WaterButler

# Where the script itself lives. The default output directory is placed next to
# it rather than in the current working directory, so the backup lands in a
# predictable place no matter where the script is invoked from -- the working
# directory is often not what you would guess.
script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  hit  <- grep("^--file=", args, value = TRUE)
  if (length(hit) == 1) {
    return(dirname(normalizePath(sub("^--file=", "", hit), mustWork = FALSE)))
  }
  getwd()   # sourced interactively, or invoked in some way without --file
}

# Which projects to include, by visibility on OSF.
#
#   "all"    (default) -- everything, public and private.
#   "public" -- only nodes OSF reports as public, so the result is safe to
#               share. Applied to EVERY node, not just top-level projects: a
#               public project can contain private components, and filtering
#               only at the top would put private data into an archive someone
#               believes is shareable.
#
# This is a convenience for producing a shareable subset. It is NOT a security
# boundary: it trusts OSF's `public` flag and trusts this code to have no bugs.
# Check the `public` column of the manifest before sharing anything.
# Stop rather than fill the disk.
#
# Running a volume to zero is worse than running out of patience: downloads
# truncate, other applications start failing, and on the boot volume the whole
# machine can misbehave. So before each download, check there is still this
# much room, and stop cleanly if not. A stopped run resumes; a full disk
# leaves debris to clean up first.
#
# Set OSF_MIN_FREE_MB=0 to disable the check.
MIN_FREE_BYTES <- env_num_or("OSF_MIN_FREE_MB", 2048) * 1024^2

VISIBILITY <- tolower(env_or("OSF_VISIBILITY", "all"))
if (!VISIBILITY %in% c("all", "public")) {
  stop("OSF_VISIBILITY must be 'all' or 'public' (got '", VISIBILITY, "')",
       call. = FALSE)
}

# Public-only runs write somewhere else by default.
#
# Sharing the wrong folder is the failure that matters here, and mixing the two
# kinds of run in one directory invites it: a full backup followed by a
# public-only run into the same place would leave every private file on disk
# while the manifest described only the public ones. Separate directories mean
# "this folder is shareable" stays true of the whole folder.
DEFAULT_OUTPUT_NAME <- if (identical(VISIBILITY, "public")) {
  "osf_backup_results_public"
} else {
  "osf_backup_results"
}

OUTPUT_DIR <- env_or("OSF_OUTPUT_DIR",
                       file.path(script_dir(), DEFAULT_OUTPUT_NAME))

# NOTE: the OSF API spells this query parameter `page[size]`, not `page_size`.
# An unrecognised parameter is silently ignored rather than rejected, so
# getting this wrong does not fail loudly -- it just falls back to the default
# page size of 10 and quietly makes ~10x as many requests as necessary.
PAGE_SIZE  <- 100                                     # max allowed by OSF API

# How many activity-log entries to keep per node. One page's worth; raising
# this past PAGE_SIZE will not fetch more, since only the first page is read.
LOG_ENTRIES <- min(env_num_or("OSF_LOG_ENTRIES", 100), PAGE_SIZE)
REQUEST_DELAY_SEC <- env_num_or("OSF_REQUEST_DELAY", 0.25)  # pause between calls

# Network behaviour. The defaults are deliberately conservative: this is
# someone else's server, and a backup is not urgent.
REQUEST_TIMEOUT_SEC  <- env_num_or("OSF_TIMEOUT", 60)    # per-request cap for API calls
# An hour per archive. Only bites when something is genuinely stuck, and the
# old 30-minute default was short enough that a legitimately large project
# (roughly 4-5 GB on a home connection) would fail on time alone.
DOWNLOAD_TIMEOUT_SEC <- env_num_or("OSF_DOWNLOAD_TIMEOUT", 3600)
MAX_RETRIES          <- env_num_or("OSF_MAX_RETRIES", 5) # for 429 / 5xx / network errors
BACKOFF_BASE_SEC     <- 2                                # exponential: 2, 4, 8, 16...
BACKOFF_CAP_SEC      <- 120                              # cap on our OWN guessed backoff

# Cap on how long we will obey an explicit Retry-After from the server. This is
# deliberately much larger than BACKOFF_CAP_SEC: if OSF tells us to wait five
# minutes, the polite (and effective) thing is to actually wait five minutes.
# Truncating it would just guarantee another 429 and waste a retry.
MAX_RETRY_AFTER_SEC  <- env_num_or("OSF_MAX_RETRY_AFTER", 900)

# Minimum wait after a 429 that arrives WITHOUT a Retry-After header. OSF's
# limits are per-hour/per-day, so a few seconds of backoff is pointless.
RATE_LIMIT_FLOOR_SEC <- env_num_or("OSF_RATE_LIMIT_FLOOR", 60)

# Sent with every request so OSF's admins can see what is generating traffic
# and contact the author if it misbehaves. Set OSF_CONTACT to your email if
# you are running a large backup -- it is good manners on a shared service.
USER_AGENT_STRING <- sprintf(
  "osf_backup.R/%s (R %s.%s; +https://developer.osf.io/)%s",
  SCRIPT_VERSION, R.version$major, R.version$minor,
  if (nzchar(Sys.getenv("OSF_CONTACT")))
    paste0(" contact:", Sys.getenv("OSF_CONTACT")) else ""
)

# Which projects to back up. GET /v2/users/me/nodes/ returns every node you
# are a contributor on, so pick how broadly to cast the net:
#
#   "admin"        (default) -- projects where you hold Admin permission. This
#                               is the practical meaning of "my projects": you
#                               administer them, whoever originally clicked
#                               "create".
#   "collaborator" -- everything you are a contributor on, at any permission
#                     level, including read-only access to others' projects.
#
# NOTE ON "creator": there is deliberately no creator-based mode. The OSF node
# object exposes no creator relationship -- the API simply does not tell you
# who made a project (see the relationships list in the APIv2 schema: parent,
# root, contributors, logs, ... but no creator). An earlier version of this
# script tried to filter on it and silently matched NOTHING, reporting a clean
# run that backed up zero projects. "admin" is the closest honest equivalent.
# The value "creator" is still accepted, and mapped to "admin" with a warning,
# so old invocations do not break.
#
# This applies to top-level projects only. Once a project is selected, all of
# its components are backed up with it, whoever created them.
ACCESS_MODE <- env_or("OSF_ACCESS_MODE", "admin")

# Restrict the run to specific projects, by OSF id. Comma-separated.
#
#   OSF_ONLY=your-project-id Rscript osf_backup.R
#
# Intended for trying something out quickly: a full run re-checks every archive
# it already has, which on a large account means minutes of hashing before you
# find out whether your change worked. Pointing it at one small project turns
# that into seconds.
#
# An id that names a component rather than a top-level project works too -- it
# is backed up as if it were a project, along with anything beneath it.
ONLY_IDS <- {
  raw <- env_or("OSF_ONLY", "")
  ids <- trimws(unlist(strsplit(raw, "[,[:space:]]+")))
  ids[nzchar(ids)]
}

# Stop after this many top-level projects. 0 means no limit.
#
#   OSF_LIMIT=1 Rscript osf_backup.R
#
# Useful when you don't have a particular id in mind and just want the run to
# finish quickly.
LIMIT <- as.integer(env_num_or("OSF_LIMIT", 0))

# Re-download files that are already present locally?
#
#   FALSE (default) -- resume. Any file already on disk is left alone, so an
#                      interrupted run can simply be started again and it will
#                      pick up where it stopped instead of re-fetching
#                      everything. Downloads are written to a temporary
#                      <name>.part file and renamed into place only when
#                      complete, so a file sitting at its final name is always
#                      a finished file.
#   TRUE            -- re-fetch everything, overwriting existing files. Use
#                      this to refresh a backup made earlier.
#
# Metadata JSON is always rewritten either way -- it is small, and this keeps
# titles, tags and contributor lists current on every run.
FORCE_REFRESH <- env_flag_or("OSF_FORCE_REFRESH", FALSE)

# Verify downloaded archives against what OSF says they should contain.
#
# A successful download is not proof of a correct download: an HTTP 200
# followed by a truncated body looks like success to the code that made the
# request. When TRUE (the default), each archive is checked for structural
# integrity, compared against the API's file listing, and every osfstorage
# file's contents are hashed and compared to the MD5/SHA-256 that OSF
# computed server-side.
#
# This does NOT add download traffic -- the archives are already on disk and
# hashing is local. It adds one listing request per FOLDER (not per file).
# Set OSF_VERIFY=0 to skip it, at the cost of not knowing whether the backup
# is any good.
VERIFY <- env_flag_or("OSF_VERIFY", TRUE)

# Re-verify an existing backup offline and exit, without contacting OSF.
#
#   OSF_VERIFY_ONLY=1 OSF_OUTPUT_DIR=~/archive Rscript osf_backup.R
#
# Re-hashes every file against the checksums.csv written when the backup was
# made. This is the check that still works when OSF does not: it detects disk
# corruption, bit rot, truncation by a failed copy, and accidental edits. Worth
# doing before you rely on an archive.
VERIFY_ONLY <- env_flag_or("OSF_VERIFY_ONLY", FALSE)

# Extension used for in-progress downloads.
PART_SUFFIX <- ".part"

OSF_PAT <- Sys.getenv("OSF_PAT")
# Offline verification touches nothing on the network, so it deliberately does
# not require a token -- you can check an archive years later on a machine that
# has never been near your OSF account.
if (identical(OSF_PAT, "") && !VERIFY_ONLY) {
  stop(
    "No OSF token found, so there's no way to reach your account.\n\n",
    "  To fix this:\n",
    "    1. Sign in at https://osf.io/settings/tokens/\n",
    "    2. Create a token, ticking only the 'osf.full_read' box\n",
    "    3. Paste this into your terminal, with your token in the quotes:\n\n",
    "         export OSF_PAT=\"your-token-here\"\n",
    "         (Windows PowerShell:  $env:OSF_PAT = \"your-token-here\")\n\n",
    "    4. Run the script again, in the same terminal window.\n\n",
    "  The token is only remembered until you close that window.\n",
    "  No token is needed to re-check an existing backup (OSF_VERIFY_ONLY=1).",
    call. = FALSE
  )
}

if (identical(ACCESS_MODE, "creator")) {
  message("NOTE: ACCESS_MODE='creator' is not supported -- the OSF API does ",
           "not expose\n      who created a project. Using 'admin' instead ",
           "(projects you administer).")
  ACCESS_MODE <- "admin"
}

VALID_ACCESS_MODES <- c("admin", "collaborator")
if (!ACCESS_MODE %in% VALID_ACCESS_MODES) {
  stop(sprintf("ACCESS_MODE must be one of: %s (got '%s')",
                paste(VALID_ACCESS_MODES, collapse = ", "), ACCESS_MODE),
       call. = FALSE)
}

auth_header <- add_headers(
  Authorization = paste("Bearer", OSF_PAT),
  `User-Agent`  = USER_AGENT_STRING
)

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

# Report a problem immediately.
#
# Deliberately message() rather than warning(): under Rscript, warnings are
# queued and dumped after the script finishes, so during a long backup you
# would see no sign of trouble until the very end. message() writes to stderr
# as it happens, which is what you want when watching a long-running job.
# Remaining internal warnings route through the same styling as everything
# else, so output looks consistent regardless of which code path produced it.
notify <- function(fmt, ...) ui_warn("%s", trimws(sprintf(fmt, ...)))

# Null-coalescing helper: `a %||% b` yields b when a is NULL.
`%||%` <- function(a, b) if (is.null(a)) b else a

# Sanitize a string for safe use as a folder/file name on macOS, Linux AND
# Windows.
#
# Beyond stripping exotic characters, Windows additionally forbids a set of
# reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9) and rejects names
# with a trailing dot or space. A folder called "CON" is unwritable on Windows
# even though it is perfectly fine on a Mac -- worth handling in a script meant
# to be shared with colleagues on other platforms.
WINDOWS_RESERVED <- c("CON", "PRN", "AUX", "NUL",
                       paste0("COM", 1:9), paste0("LPT", 1:9))

sanitize <- function(x, max_len = 80) {
  x <- gsub("[^A-Za-z0-9 _.-]", "_", x)
  x <- trimws(x)
  x <- substr(x, 1, max_len)
  x <- sub("[. ]+$", "", x)               # no trailing dots or spaces (Windows)
  x <- sub("^[.]+", "", x)                # no leading dots -- would hide the
                                           # folder on macOS/Linux
  x <- trimws(x)
  if (!nzchar(x)) x <- "untitled"
  if (toupper(x) %in% WINDOWS_RESERVED) x <- paste0(x, "_")
  x
}

# How long to wait before retry number `attempt`, honouring Retry-After when
# the server supplies it. Exponential backoff with a little jitter, so that a
# script run by several people at once does not resynchronise into a thundering
# herd against the same endpoint.
retry_delay <- function(attempt, resp = NULL, is_rate_limit = FALSE) {
  server_hint <- NA_real_
  if (!is.null(resp)) {
    ra <- headers(resp)[["retry-after"]]
    if (!is.null(ra)) server_hint <- suppressWarnings(as.numeric(ra))
  }
  # The server told us exactly how long to wait -- respect it.
  if (!is.na(server_hint)) return(min(server_hint, MAX_RETRY_AFTER_SEC))

  wait <- BACKOFF_BASE_SEC^attempt

  # A 429 with no Retry-After header needs a much longer wait than an ordinary
  # transient error. OSF's limits are measured per hour and per day, so backing
  # off for a couple of seconds and trying again just burns another retry
  # against a window that has not moved. Start at a minute and climb.
  if (is_rate_limit) wait <- max(wait, RATE_LIMIT_FLOOR_SEC * (attempt + 1))

  min(wait, if (is_rate_limit) MAX_RETRY_AFTER_SEC else BACKOFF_CAP_SEC) +
    runif(1, 0, 1)
}

# ---------------------------------------------------------------------------
# CREDENTIAL SAFETY ON REDIRECTS
# ---------------------------------------------------------------------------
# WaterButler may answer a download request with a 302 redirect to a signed URL
# on the underlying storage backend (S3, Google Cloud, or a connected add-on
# like Dropbox or GitHub). That destination is a different host, and often not
# operated by OSF at all.
#
# This matters because curl re-sends explicitly-set request headers when it
# follows a redirect, including across hosts. Left on autopilot, an OSF bearer
# token with read access to every one of your private projects would be handed
# to whatever third-party host the redirect points at. Nothing is likely to go
# wrong with it, but a credential should never be sent somewhere it is not
# needed, and here it plainly is not.
#
# So: follow redirects by hand, and attach the Authorization header only while
# we are still talking to OSF.
OSF_HOST_PATTERN <- "(^|\\.)osf\\.io$"

is_osf_host <- function(host) {
  !is.null(host) && !is.na(host) && grepl(OSF_HOST_PATTERN, host)
}

# Resolve a possibly-relative Location header against the URL it came from.
# In practice OSF sends absolute URLs; the relative branches are defensive.
resolve_url <- function(location, base_url) {
  if (grepl("^https?://", location, ignore.case = TRUE)) return(location)

  if (startsWith(location, "/")) {
    modify_url(base_url, path = location, query = NULL, fragment = NULL)
  } else {
    base_path <- parse_url(base_url)$path %||% ""
    parent    <- sub("[^/]*$", "", base_path)
    modify_url(base_url, path = paste0(parent, location),
                query = NULL, fragment = NULL)
  }
}

# GET a URL, following redirects manually and dropping the Authorization
# header the moment we leave OSF. Returns the final httr response.
get_redirect_safe <- function(url, dest_path = NULL, timeout_sec = REQUEST_TIMEOUT_SEC,
                                max_redirects = 5) {
  current  <- url
  had_auth <- FALSE

  for (hop in seq_len(max_redirects + 1)) {
    host <- parse_url(current)$hostname
    use_auth <- is_osf_host(host)

    if (!use_auth && !had_auth) {
      # First hop already off-OSF: unusual, but do not send the token.
      notify("request to non-OSF host %s -- sending without credentials",
             host %||% "<unknown>")
    }
    had_auth <- had_auth || use_auth

    hdrs <- if (use_auth) auth_header else
      add_headers(`User-Agent` = USER_AGENT_STRING)

    args <- list(current, hdrs, config(followlocation = FALSE),
                  timeout(timeout_sec))
    if (!is.null(dest_path)) {
      args <- c(args, list(write_disk(dest_path, overwrite = TRUE)))
    }
    resp <- do.call(GET, args)

    code <- status_code(resp)
    if (!code %in% c(301, 302, 303, 307, 308)) return(resp)

    location <- headers(resp)[["location"]]
    if (is.null(location)) return(resp)   # redirect with no target; let caller judge

    next_url  <- resolve_url(location, current)
    next_host <- parse_url(next_url)$hostname
    if (is_osf_host(host) && !is_osf_host(next_host)) {
      notify("redirected off OSF to %s -- continuing without the token",
             next_host %||% "<unknown>")
    }
    current <- next_url
  }

  notify("too many redirects (>%d) for %s", max_redirects, url)
  NULL
}

# Should this status code be retried, or is it a permanent answer?
#   429 -- rate limited: always retry, after backing off
#   5xx -- server-side hiccup: worth retrying
#   4xx -- our fault (bad token, deleted node, no permission): do not retry
is_retryable_status <- function(code) code == 429 || code >= 500

# A 401 gets exactly ONE retry, which is a separate rule from the above.
#
# Normally retrying a rejected credential is pointless: the token is wrong and
# will still be wrong in two seconds. But OSF's auth service runs behind
# several backends, and a token created moments earlier has not necessarily
# reached all of them -- so the first request can be refused and the next one
# accepted, with nothing having changed. Observed in practice on a token
# created seconds before the run.
#
# One retry makes that disappear. More than one would just slow down the
# genuinely-expired case and bury the real message under repeated warnings,
# which is why this is not folded into MAX_RETRIES.
AUTH_RETRIES <- 1
AUTH_RETRY_WAIT_SEC <- 3

# Perform an HTTP request with retries, backoff and a timeout.
# `req_fn` does the actual call; everything around it is the retry policy.
# Status of the most recent completed request, so callers can distinguish a
# definitive 404 from a transport failure. Reset before each attempt sequence.
http_state <- new.env(parent = emptyenv())
http_state$last_status <- NA_integer_

with_retries <- function(req_fn, label) {
  attempt <- 0
  auth_attempt <- 0
  http_state$last_status <- NA_integer_
  repeat {
    Sys.sleep(REQUEST_DELAY_SEC)

    resp <- tryCatch(req_fn(), error = function(e) e)

    # get_redirect_safe() returns NULL when it hits a redirect loop -- treat
    # that as a permanent failure, not something to retry.
    if (is.null(resp)) return(NULL)

    # Network-level failure (DNS, dropped connection, timeout).
    if (inherits(resp, "error")) {
      msg <- conditionMessage(resp)

      # A timeout on a large archive is the one network failure with an obvious
      # fix, and curl's wording ("Timeout was reached: Operation timed out
      # after 1800000 milliseconds") does not suggest it. Name the setting
      # rather than leaving someone to translate milliseconds into a remedy.
      timed_out <- grepl("timed out|timeout", msg, ignore.case = TRUE)

      if (attempt >= MAX_RETRIES) {
        ui_err("%s failed after %d attempts: %s", label, attempt + 1, msg,
               indent = "  ")
        if (timed_out) {
          ui_text("    Took longer than the %d-minute limit per download.",
                  round(DOWNLOAD_TIMEOUT_SEC / 60))
          ui_text("    For a very large project, allow more time and re-run:")
          ui_text("      OSF_DOWNLOAD_TIMEOUT=7200 Rscript osf_backup.R")
        }
        return(NULL)
      }
      wait <- retry_delay(attempt)
      if (timed_out) {
        ui_wait("timed out after %d min, retrying in %.0fs (attempt %d of %d)",
                round(DOWNLOAD_TIMEOUT_SEC / 60), wait, attempt + 1,
                MAX_RETRIES, indent = "  ")
      } else {
        ui_wait("connection problem, retrying in %.0fs (attempt %d of %d)",
                wait, attempt + 1, MAX_RETRIES, indent = "  ")
      }
      Sys.sleep(wait)
      attempt <- attempt + 1
      next
    }

    code <- status_code(resp)
    if (code < 400) return(resp)

    if (is_retryable_status(code) && attempt < MAX_RETRIES) {
      wait <- retry_delay(attempt, resp, is_rate_limit = (code == 429))
      if (code == 429) {
        ui_wait("OSF asked us to slow down -- waiting %.0fs (attempt %d of %d)",
                wait, attempt + 1, MAX_RETRIES, indent = "  ")
      } else {
        ui_wait("OSF returned a temporary error (%d), retrying in %.0fs (attempt %d of %d)",
                code, wait, attempt + 1, MAX_RETRIES, indent = "  ")
      }
      Sys.sleep(wait)
      attempt <- attempt + 1
      next
    }

    # One more go at a 401, in case the credential simply had not propagated.
    # Counted separately so it cannot consume the ordinary retry budget.
    if (code == 401L && auth_attempt < AUTH_RETRIES) {
      ui_wait("not authorised -- trying once more in %ds, in case the token is new",
              AUTH_RETRY_WAIT_SEC, indent = "  ")
      Sys.sleep(AUTH_RETRY_WAIT_SEC)
      auth_attempt <- auth_attempt + 1
      next
    }

    explanation <- ""
    if (code == 401) {
      # Deliberately does NOT say "your token is invalid". A 401 from
      # WaterButler usually means a connected add-on (GitHub, Dropbox, Google
      # Drive) has lost its own authorisation on OSF -- the OSF token is fine,
      # and every other request in the run succeeds with it. Blaming the token
      # sends people off to re-issue a credential that was never the problem.
      explanation <- paste0(" -- not authorised, even after a second attempt. ",
                             "Most likely: the token has expired or was typed ",
                             "wrong, or a connected storage add-on has lost ",
                             "its own link to OSF. If you created this token ",
                             "in the last minute, wait and run it again")
    } else if (code == 403) {
      explanation <- " -- token lacks permission for this resource"
    } else if (code == 404) {
      explanation <- " -- not found (deleted, or never existed)"
    } else if (code == 410) {
      explanation <- " -- resource has been deleted or withdrawn"
    }
    # Record the status so callers can tell a definitive "this does not exist"
    # (404) from "the request failed". Optional sub-resources like wikis are
    # 404 when the add-on is switched off, which means there is nothing to back
    # up -- not that something went wrong.
    http_state$last_status <- code

    if (!identical(code, 404L)) {
      notify("%s failed with HTTP %d%s", label, code, explanation)
    }
    return(NULL)
  }
}

# GET a single OSF API URL and return parsed JSON (list), or NULL on failure.
osf_get <- function(url, query = list()) {
  full_url <- if (length(query) > 0) modify_url(url, query = query) else url
  resp <- with_retries(
    function() get_redirect_safe(full_url),
    label = sub(API_BASE, "", url, fixed = TRUE)
  )
  if (is.null(resp)) return(NULL)

  tryCatch(
    fromJSON(content(resp, as = "text", encoding = "UTF-8"),
             simplifyVector = FALSE),
    error = function(e) {
      notify("Could not parse JSON from %s: %s", url, conditionMessage(e))
      NULL
    }
  )
}

# Follow OSF's JSON-API pagination (data$links$next) and return a combined
# list of every "data" entry across all pages.
# CRITICAL: this returns the items WITH a "complete" attribute saying whether
# the listing was actually retrieved in full.
#
# Without that flag, an empty list is ambiguous: it means either "this project
# genuinely has no files" or "the request failed". Treating those the same is
# how a backup silently loses data -- a failed /children/ listing would drop
# every component while the project still looked backed up, and a failed file
# listing would make verification pass against an empty inventory. A partial
# result is just as dangerous: if page 1 succeeds and page 2 fails, the caller
# sees a plausible-looking list that is missing half the files.
#
# Callers MUST check listing_ok() before trusting an empty or short result.
# `absent_if_404`: for OPTIONAL sub-resources (wikis, registrations,
# identifiers), a 404 is a definitive answer -- the add-on is switched off or
# the collection does not exist -- so an empty result is the truth, not a
# failure. Left FALSE for anything whose absence would mean real data loss,
# where a 404 should still be treated as "could not retrieve".
osf_get_all_pages <- function(url, query = list(`page[size]` = PAGE_SIZE),
                                absent_if_404 = FALSE) {
  all_items <- list()
  next_url  <- url
  next_query <- query
  complete  <- TRUE

  while (!is.null(next_url)) {
    page <- osf_get(next_url, query = next_query)
    if (is.null(page)) {
      definitively_absent <- absent_if_404 &&
        identical(http_state$last_status, 404L)
      complete <- definitively_absent
      break
    }
    all_items <- c(all_items, page$data)
    next_url <- page$links$`next`
    next_query <- list()  # next_url already has query params baked in
  }

  attr(all_items, "complete") <- complete
  all_items
}

# Was a listing retrieved in full? Anything not produced by osf_get_all_pages
# is treated as trustworthy, so this is safe to call on plain lists.
listing_ok <- function(x) {
  is.null(attr(x, "complete")) || isTRUE(attr(x, "complete"))
}

# Record a failed listing as a first-class problem, so it lands in the
# verification report and forces a non-zero exit rather than passing silently.
record_listing_failure <- function(node_id, what, indent = "") {
  notify("%scould not retrieve %s for %s -- this backup is INCOMPLETE",
         indent, what, node_id)
  verification_problems[[length(verification_problems) + 1]] <<- data.frame(
    node_id = node_id, provider = what, file = NA_character_,
    issue = "listing_incomplete",
    detail = paste0("the ", what, " listing could not be retrieved in full; ",
                     "anything it would have contained is missing from this backup"),
    stringsAsFactors = FALSE
  )
  run_stats$listing_failures <- run_stats$listing_failures + 1
  invisible(NULL)
}

# Write JSON to disk atomically: build a .part file, then rename it into place.
# A rename within one filesystem is atomic, so the real filename never exists
# in a half-written state, even if the script is killed mid-write.
write_json_atomic <- function(x, dest_path) {
  part_path <- paste0(dest_path, PART_SUFFIX)
  # enc2utf8 + useBytes: without them, writeLines re-encodes to the machine's
  # native encoding on the way out, which mangles non-ASCII titles, author
  # names and abstracts on any system not already running a UTF-8 locale
  # (notably Windows). The JSON must be UTF-8 to be readable anywhere.
  # Returns TRUE on success. Callers must check: a disk-full or permissions
  # failure here used to be swallowed entirely, leaving a project folder that
  # looked complete but had quietly lost its metadata, contributor list or
  # registration record.
  ok <- tryCatch({
    json <- enc2utf8(toJSON(x, auto_unbox = TRUE, pretty = TRUE))
    writeLines(json, part_path, useBytes = TRUE)
    TRUE
  }, error = function(e) {
    notify("could not write %s: %s", basename(dest_path),
           conditionMessage(e))
    FALSE
  })

  if (!ok || !file.rename(part_path, dest_path)) {
    unlink(part_path)
    notify("failed to save %s (disk full, or no write permission?)",
           dest_path)
    return(invisible(FALSE))
  }
  invisible(TRUE)
}

# Download a URL to a local file, streaming to disk.
#
# Returns one of "downloaded", "skipped" (already present), or "failed".
#
# Resumability: the transfer goes to <dest>.part and is renamed into place only
# once it completes. So a file at its final name is always a complete file --
# if the script is interrupted, the debris is a .part file, which is ignored on
# the next run and overwritten. That is what makes it safe to simply re-run the
# script after an interruption and have it pick up where it left off.
#
# Note this resumes at file granularity, not byte granularity: an interrupted
# zip is re-fetched from the start, but every zip already finished is skipped.
download_file <- function(url, dest_path) {
  if (file.exists(dest_path) && !FORCE_REFRESH) {
    return("skipped")
  }

  # Room to work? Checked per download rather than once up front, because the
  # total is not knowable in advance and free space changes as we go.
  if (MIN_FREE_BYTES > 0) {
    free <- disk_free_bytes(dirname(dest_path))
    if (!is.na(free) && free < MIN_FREE_BYTES) {
      stop("Stopping: only ", format_size(free), " left on the disk holding\n",
           "  ", dirname(dest_path), "\n\n",
           "  Downloading further would risk filling the volume, which can ",
           "truncate files\n  and destabilise other software.\n\n",
           "  Free some space and run the script again -- everything already ",
           "downloaded\n  is kept and skipped, so it resumes where it stopped.\n",
           "  (To proceed anyway: OSF_MIN_FREE_MB=0)", call. = FALSE)
    }
  }

  part_path <- paste0(dest_path, PART_SUFFIX)
  unlink(part_path)  # clear debris from any previous interrupted run

  resp <- with_retries(
    function() get_redirect_safe(url, dest_path = part_path,
                                   timeout_sec = DOWNLOAD_TIMEOUT_SEC),
    label = paste("download", basename(dest_path))
  )

  if (is.null(resp) || !file.exists(part_path) ||
      !file.rename(part_path, dest_path)) {
    unlink(part_path)
    return("failed")
  }
  "downloaded"
}

# ---------------------------------------------------------------------------
# CORE LOGIC
# ---------------------------------------------------------------------------

# Is this node a top-level project (as opposed to a component)?
#
# IMPORTANT: GET /v2/users/me/nodes/ returns EVERY node you are a contributor
# on -- components included, not just root projects. If we backed up that list
# as-is, every component would be saved twice: once nested under its parent
# (via the /children/ recursion below) and again as its own top-level folder.
# So we keep only nodes that have no parent.
#
# Two independent signals, since the API has varied on whether an absent
# parent is omitted or serialized as null:
#   - relationships$parent has no data  -> no parent
#   - relationships$root points at itself -> it is its own root
is_top_level <- function(node) {
  rel <- node$relationships
  if (is.null(rel)) return(TRUE)

  parent_data <- rel$parent$data
  has_parent  <- !is.null(parent_data) && !is.null(parent_data$id)

  root_id <- rel$root$data$id
  is_own_root <- is.null(root_id) || identical(root_id, node$id)

  !has_parent && is_own_root
}

# (There was a node_creator_id() here. It read node$relationships$creator,
# which does not exist: the OSF node schema has no creator relationship, so it
# returned NA for every project and silently excluded all of them. Removed
# rather than repaired -- there is nothing to read. Ownership is determined by
# admin permission below.)

# Does the authenticated user hold Admin permission on this node?
#
# Preferred source is the node's own current_user_permissions attribute, which
# comes back with the listing and costs no extra request. If that attribute is
# ever absent (it has moved around between API versions), fall back to reading
# your own contributor record for that node, which costs one request but is
# unambiguous.
has_admin_permission <- function(node, my_user_id) {
  perms <- node$attributes$current_user_permissions
  if (!is.null(perms) && length(perms) > 0) {
    return("admin" %in% unlist(perms))
  }

  contrib <- osf_get(paste0(API_BASE, "/nodes/", node$id,
                              "/contributors/", my_user_id, "/"))
  if (is.null(contrib) || is.null(contrib$data)) return(FALSE)
  identical(contrib$data$attributes$permission, "admin")
}

# Should this top-level project be backed up, given ACCESS_MODE?
node_matches_access_mode <- function(node, my_user_id) {
  switch(
    ACCESS_MODE,
    # Everything the listing returned is something you contribute to.
    "collaborator" = TRUE,
    "admin"        = has_admin_permission(node, my_user_id),
    FALSE
  )
}

# ---------------------------------------------------------------------------
# VERIFICATION
# ---------------------------------------------------------------------------
# A backup you cannot trust is worse than no backup, because you stop worrying
# about the thing that is quietly broken. Downloading a file successfully is
# not evidence that the file is correct: an HTTP 200 followed by a truncated
# body still looks like success to the code that issued the request.
#
# So after each project's archive is fetched, it is checked three ways, from
# cheapest to strictest:
#
#   1. INTEGRITY  -- can the zip be opened and its index read? A zip stores its
#                    central directory at the END of the file, so a truncated
#                    download reliably fails this. Catches the most likely
#                    failure mode for nothing more than a local read.
#
#   2. INVENTORY  -- does the archive contain every file the OSF API says the
#                    project has, at the right size? Catches a zip that is
#                    structurally valid but incomplete.
#
#   3. CHECKSUMS  -- does each file's content hash match the MD5/SHA-256 that
#                    OSF computed server-side? Catches silent corruption that
#                    the first two checks would wave through.
#
# Only osfstorage exposes hashes. Files from connected add-ons (Dropbox,
# GitHub, Google Drive) are verified at levels 1-2 and reported as unhashable
# rather than being silently treated as verified.

# Which hashing implementation is available?
#
# Base R ships MD5 (tools::md5sum) but no SHA-256. OSF publishes both, so use
# SHA-256 when an optional package provides it and fall back to MD5 otherwise.
# MD5 is entirely adequate here -- we are detecting accidental corruption and
# truncated transfers, not defending against someone deliberately crafting a
# collision.
# NB: written as a braced block on purpose. At top level R treats
# `x <- if (cond) a` as a complete statement, so a following line starting with
# `else` is a syntax error. Keeping `else` off the start of a line avoids the
# whole class of problem.
HASH_BACKEND <- {
  if (requireNamespace("digest", quietly = TRUE)) {
    "digest"
  } else if (requireNamespace("openssl", quietly = TRUE)) {
    "openssl"
  } else {
    "base"
  }
}
CAN_SHA256 <- HASH_BACKEND %in% c("digest", "openssl")

digest_file <- function(path, algo) {
  tryCatch({
    if (identical(HASH_BACKEND, "digest")) {
      digest::digest(file = path, algo = algo)
    } else if (identical(HASH_BACKEND, "openssl")) {
      con <- file(path, "rb"); on.exit(close(con), add = TRUE)
      if (identical(algo, "sha256")) {
        as.character(openssl::sha256(con))
      } else {
        as.character(openssl::md5(con))
      }
    } else if (identical(algo, "md5")) {
      unname(tools::md5sum(path))
    } else {
      NA_character_
    }
  }, error = function(e) NA_character_)
}

# Recursively list every file in a node's storage provider.
#
# Cost note: this is one request per FOLDER (paginated at 100 entries), not one
# per file. A project with thousands of files in a handful of folders costs a
# handful of requests.
list_files_recursive <- function(node_id, provider, folder_url = NULL,
                                   prefix = "", depth = 0,
                                   resource = "nodes") {
  if (depth > 25) {
    notify("folder nesting deeper than 25 levels in %s -- stopping descent",
           node_id)
    # Must be marked incomplete. Returning a bare list() here would tell the
    # caller "this is the full inventory", and verification would then pass
    # against a truncated file list -- the same false-pass bug as a failed
    # request, just triggered by depth instead of by an error.
    out <- list()
    attr(out, "complete") <- FALSE
    return(out)
  }

  # Registrations expose their files under /registrations/<id>/, not
  # /nodes/<id>/ -- using the wrong one silently yields an empty listing, which
  # would make an unverified archive look like a verified one.
  url <- folder_url %||%
    paste0(API_BASE, "/", resource, "/", node_id, "/files/", provider, "/")

  entries <- osf_get_all_pages(url)
  if (!listing_ok(entries)) {
    # Propagate the failure rather than returning a short list that would be
    # mistaken for the project's true contents.
    out <- list()
    attr(out, "complete") <- FALSE
    return(out)
  }
  out <- list()

  for (e in entries) {
    a    <- e$attributes
    name <- a$name %||% NA_character_
    path <- paste0(prefix, name)

    if (identical(a$kind, "folder")) {
      child_url <- e$relationships$files$links$related$href
      if (!is.null(child_url)) {
        sub <- list_files_recursive(node_id, provider, child_url,
                                      paste0(path, "/"), depth + 1, resource)
        if (!listing_ok(sub)) {
          # A subfolder we could not read means the inventory is incomplete;
          # verifying against it would be verifying against a lie.
          out <- list()
          attr(out, "complete") <- FALSE
          return(out)
        }
        out <- c(out, sub)
      }
    } else {
      hashes <- a$extra$hashes
      out[[length(out) + 1]] <- list(
        path   = path,
        size   = a$size %||% NA_real_,
        md5    = hashes$md5 %||% NA_character_,
        sha256 = hashes$sha256 %||% NA_character_
      )
    }
  }
  out
}

# Is a system `unzip` binary available as a fallback reader?
#
# R's built-in unzip does not handle ZIP64, so it fails on archives over ~4 GB
# and on those with more than 65,535 members. Research projects can easily
# exceed both. Without a fallback we would report a perfectly good large
# archive as corrupt -- a false alarm that would teach you to ignore the
# verification output, which is worse than not checking at all.
SYSTEM_UNZIP <- Sys.which("unzip")
HAVE_SYSTEM_UNZIP <- nzchar(SYSTEM_UNZIP)

# Is this a VALID archive that simply contains nothing?
#
# A project with no files yields a 22-byte zip holding only the end-of-central-
# directory record. Both R's reader and `unzip` report zero entries for it,
# which is indistinguishable from a failure unless we look: `unzip -Z1` even
# exits non-zero ("Empty zipfile."). Calling that corruption would raise a
# false alarm on every empty project -- and false alarms are how a verification
# report gets ignored, which costs more than the check is worth.
#
# So parse the record directly and confirm it says zero entries.
is_empty_zip <- function(path) {
  size <- file.size(path)
  if (is.na(size) || size < 22 || size > 1024) return(FALSE)

  tryCatch({
    con <- file(path, "rb"); on.exit(close(con), add = TRUE)
    bytes <- readBin(con, "raw", n = size)
    eocd  <- bytes[(size - 21):size]
    sig_ok <- identical(as.integer(eocd[1:4]), c(0x50L, 0x4BL, 0x05L, 0x06L))
    # Bytes 11-12 of the record are the total entry count, little-endian.
    entries <- as.integer(eocd[11]) + 256L * as.integer(eocd[12])
    sig_ok && entries == 0L
  }, error = function(e) FALSE)
}

# Level 1: can the archive be opened and its index read?
#
# Returns ok, a reason when not, the member listing, and which reader was used.
verify_zip_integrity <- function(zip_path) {
  if (!file.exists(zip_path)) {
    return(list(ok = FALSE, reason = "archive missing", contents = NULL))
  }
  size <- file.size(zip_path)
  if (is.na(size) || size == 0) {
    return(list(ok = FALSE, reason = "archive is empty (0 bytes)",
                 contents = NULL))
  }

  contents <- tryCatch(
    utils::unzip(zip_path, list = TRUE),
    error   = function(e) e,
    warning = function(w) w
  )

  internal_ok <- !inherits(contents, "condition") &&
    is.data.frame(contents) && nrow(contents) > 0
  if (internal_ok) {
    return(list(ok = TRUE, reason = NA_character_, contents = contents,
                 reader = "internal"))
  }

  # A genuinely empty archive is valid, not broken.
  if (is_empty_zip(zip_path)) {
    return(list(ok = TRUE, reason = NA_character_,
                 contents = data.frame(Name = character(0),
                                        Length = numeric(0),
                                        stringsAsFactors = FALSE),
                 reader = "empty"))
  }

  internal_msg <- "reader returned an empty index"
  if (inherits(contents, "condition")) {
    internal_msg <- conditionMessage(contents)
  }

  # Fall back to the system unzip, which understands ZIP64.
  if (HAVE_SYSTEM_UNZIP) {
    names <- suppressWarnings(
      system2(SYSTEM_UNZIP, c("-Z1", shQuote(zip_path)),
               stdout = TRUE, stderr = FALSE)
    )
    failed <- !is.null(attr(names, "status")) && attr(names, "status") != 0
    if (!failed && length(names) > 0) {
      # -t re-reads every member and checks its CRC32, which is a stronger
      # integrity guarantee than merely parsing the index.
      crc <- suppressWarnings(
        system2(SYSTEM_UNZIP, c("-t", shQuote(zip_path)),
                 stdout = FALSE, stderr = FALSE)
      )
      if (!identical(as.integer(crc), 0L)) {
        return(list(ok = FALSE,
                     reason = "system unzip -t reports CRC errors (corrupt archive)",
                     contents = NULL))
      }
      names <- names[!endsWith(names, "/")]   # drop directory entries
      return(list(
        ok = TRUE, reason = NA_character_,
        contents = data.frame(Name = names, Length = NA_real_,
                               stringsAsFactors = FALSE),
        reader = "system"
      ))
    }
  }

  hint <- ""
  if (!HAVE_SYSTEM_UNZIP) {
    hint <- " (no system 'unzip' available as a fallback for large/ZIP64 archives)"
  }

  list(ok = FALSE,
       reason = paste0("unreadable archive (likely truncated): ",
                        internal_msg, hint),
       contents = NULL)
}

# Normalise a zip member path for comparison with an API path. WaterButler
# nests everything under the project/folder name, so compare on the tail.
normalise_zip_path <- function(p) {
  p <- gsub("\\\\", "/", p)
  p <- sub("^/+", "", p)
  p <- sub("/+$", "", p)
  p
}

# Levels 2 and 3: inventory and checksums.
#
# Returns a data frame of problems (zero rows means everything matched).

# Extract one member, using whichever reader managed to open the archive.
# Returns the path to the extracted file, or NULL.
extract_member <- function(zip_path, member, exdir, reader) {
  if (identical(reader, "system") && HAVE_SYSTEM_UNZIP) {
    status <- suppressWarnings(system2(
      SYSTEM_UNZIP,
      c("-o", "-q", shQuote(zip_path), shQuote(member), "-d", shQuote(exdir)),
      stdout = FALSE, stderr = FALSE
    ))
    if (!identical(as.integer(status), 0L)) return(NULL)
    p <- file.path(exdir, member)
    return(if (file.exists(p)) p else NULL)
  }

  out <- tryCatch(utils::unzip(zip_path, files = member, exdir = exdir),
                   error = function(e) NULL)
  if (is.null(out) || length(out) == 0 || !file.exists(out[1])) NULL else out[1]
}

verify_against_listing <- function(zip_path, zip_contents, expected, provider,
                                     reader = "internal") {
  problems <- list()
  add <- function(path, issue, detail = NA_character_) {
    problems[[length(problems) + 1]] <<- data.frame(
      provider = provider, file = path, issue = issue, detail = detail,
      stringsAsFactors = FALSE
    )
  }

  if (length(expected) == 0) return(do.call(rbind, problems))

  zip_names <- normalise_zip_path(zip_contents$Name)
  # NB: deliberately no name-keyed size lookup here. Sizes are read by index
  # (zip_contents$Length[idx]) so that repeated names in an archive cannot
  # cause a comparison against the wrong entry's size.

  # Match on path suffix: the archive may root everything under a folder name
  # that the API listing does not include.
  # Returns the index of the archive member for `target`, or a marker.
  #
  # Exact matches win. Suffix matching is only a fallback for the folder prefix
  # WaterButler adds, and if it is ambiguous we refuse to guess: silently
  # pairing a file with a same-named file from another folder could compare the
  # wrong bytes and report a pass while the real file is missing.
  find_member <- function(target) {
    target <- normalise_zip_path(target)

    exact <- which(zip_names == target)
    if (length(exact) == 1) return(exact)
    if (length(exact) > 1)  return(-1L)   # duplicate entries: ambiguous

    suffix <- which(endsWith(zip_names, paste0("/", target)))
    if (length(suffix) == 1) return(suffix)
    if (length(suffix) > 1)  return(-1L)  # several candidates: ambiguous
    NA_integer_
  }

  # Hash the archive's members once, only if we have hashes to compare to.
  want_hashes <- any(vapply(expected,
                              function(f) !is.na(f$md5) || !is.na(f$sha256),
                              logical(1)))

  # Always create the scratch directory: even files with no published checksum
  # get extracted, to force a CRC check on their data.
  extract_dir <- file.path(tempdir(),
                            paste0("osfverify_",
                                    basename(tempfile(pattern = ""))))
  dir.create(extract_dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(extract_dir, recursive = TRUE), add = TRUE)

  # If the scratch directory could not be made, every file would come back as
  # "extract_failed" -- reporting corruption in your archive when the actual
  # problem is a full or unwritable temp volume. Say what is really wrong.
  if (!dir.exists(extract_dir)) {
    return(data.frame(
      provider = provider, file = NA_character_, issue = "verification_error",
      detail = paste0("could not create a temporary directory (", extract_dir,
                       ") -- archive contents were NOT checked; this is a local ",
                       "problem, not evidence about the backup"),
      stringsAsFactors = FALSE
    ))
  }

  # Is there room to extract the biggest file in this archive?
  #
  # Verification writes each member to the scratch directory before hashing it,
  # so a 20 GB file needs 20 GB of scratch space. That space is on the TEMP
  # volume, which on macOS is the boot disk -- not necessarily the volume the
  # backup is going to. Someone archiving to a roomy external drive could fill
  # their startup disk here, which the destination-space check would never see.
  #
  # Report it as "could not check" rather than pressing on: filling the boot
  # volume is worse than an unverified archive, and quietly skipping the check
  # would be worse than both.
  sizes <- vapply(expected,
                   function(f) suppressWarnings(as.numeric(f$size %||% NA)),
                   numeric(1))
  biggest <- suppressWarnings(max(sizes, na.rm = TRUE))
  scratch_free <- disk_free_bytes(extract_dir)

  if (is.finite(biggest) && !is.na(scratch_free) &&
      scratch_free < biggest * 1.1) {
    return(data.frame(
      provider = provider, file = NA_character_, issue = "no_scratch_space",
      detail = sprintf(paste0("largest file is %s but only %s free on the ",
                               "temporary volume (%s), so contents were NOT ",
                               "checked. Point TMPDIR at a volume with room ",
                               "and re-run to verify this archive."),
                        format_size(biggest), format_size(scratch_free),
                        extract_dir),
      stringsAsFactors = FALSE
    ))
  }

  for (f in expected) {
    idx <- find_member(f$path)
    if (is.na(idx)) {
      add(f$path, "missing_from_archive",
          "listed by the OSF API but not present in the downloaded zip")
      next
    }
    if (idx < 0L) {
      add(f$path, "ambiguous_match",
          "several archive entries could be this file; refusing to guess which to verify")
      next
    }

    member <- zip_contents$Name[idx]

    # Look the size up BY INDEX, not by name. A name lookup on a vector with
    # repeated names silently returns the first match, which need not be the
    # entry we actually matched -- i.e. it could compare against a different
    # file's size and report a pass.
    archive_size <- zip_contents$Length[idx]
    if (!is.na(f$size) && !is.na(archive_size)) {
      if (as.numeric(f$size) != as.numeric(archive_size)) {
        add(f$path, "size_mismatch",
            sprintf("OSF says %s bytes, archive has %s",
                     format(f$size), format(archive_size)))
        next
      }
    }

    # Pick the strongest algorithm we have both a published value and a local
    # implementation for.
    algo <- NA_character_
    if (!is.na(f$sha256) && CAN_SHA256) {
      algo <- "sha256"
    } else if (!is.na(f$md5)) {
      algo <- "md5"
    }

    if (is.na(algo)) {
      # No published checksum to compare against -- but we can still force the
      # data to be read, which checks the member's CRC32. Without this, a file
      # from an add-on could be corrupt inside a structurally valid zip and
      # pass verification on the strength of its size alone.
      probe <- extract_member(zip_path, member, extract_dir, reader)
      if (is.null(probe)) {
        add(f$path, "extract_failed",
            "member could not be read from the archive (bad CRC or corrupt data)")
      } else {
        unlink(probe)
        add(f$path, "unhashable",
            sprintf("%s publishes no checksum; verified by size and CRC only",
                     provider))
      }
      next
    }

    extracted <- extract_member(zip_path, member, extract_dir, reader)
    if (is.null(extracted)) {
      add(f$path, "extract_failed",
          "member is in the archive index but could not be extracted (corrupt data or bad CRC)")
      next
    }

    expected_hash <- if (identical(algo, "sha256")) f$sha256 else f$md5
    got <- digest_file(extracted, algo)
    if (is.na(got)) {
      add(f$path, "hash_failed",
          sprintf("could not compute %s locally", algo))
    } else if (!identical(tolower(got), tolower(expected_hash))) {
      add(f$path, paste0(algo, "_mismatch"),
          sprintf("expected %s, got %s", expected_hash, got))
    }
    unlink(extracted)
  }

  do.call(rbind, problems)
}

# ---------------------------------------------------------------------------
# SELF-VERIFICATION (works with OSF gone)
# ---------------------------------------------------------------------------
# The checks above compare local files against OSF's API. That is the right
# test at download time, but it is useless in the situation this backup exists
# for: if OSF is unreachable, or your account is gone, there is nothing to
# compare against. And disks rot -- a file that was perfect in 2026 can be
# silently corrupt by 2031 with nothing having "gone wrong" in any run.
#
# So each project also gets a checksums.csv recording the SHA-256 and size of
# every file written, computed locally at the time it was saved. That makes the
# backup self-describing: OSF_VERIFY_ONLY=1 re-hashes everything on disk and
# compares against this record, with no network access at all.
CHECKSUM_FILE <- "checksums.csv"

# Files belonging to THIS node, excluding its components/ subtree.
#
# Each component is a node in its own right: it gets its own manifest row and
# its own checksums.csv. Including its files in the parent's listing double
# counts them -- and does so only on RE-RUNS, because on a first run the
# parent's totals are computed before components/ exists. That asymmetry is
# what makes it easy to miss.
#
# It matters beyond the byte count. If a parent's checksums.csv recorded its
# components' files, it would also record a hash of each component's
# checksums.csv -- which the component then rewrites moments later, leaving the
# parent's copy of that hash immediately stale. Offline verification would
# report CORRUPTED on a file that is perfectly fine.
node_own_files <- function(folder) {
  files <- list.files(folder, recursive = TRUE, full.names = TRUE)
  comp_dir <- file.path(folder, "components")
  files[!startsWith(files, paste0(comp_dir, .Platform$file.sep))]
}

# Hash every file in a project folder (except the checksum record itself) and
# write the record.
write_local_checksums <- function(folder) {
  files <- node_own_files(folder)
  files <- files[basename(files) != CHECKSUM_FILE]
  files <- files[!endsWith(files, PART_SUFFIX)]
  if (length(files) == 0) return(invisible(NULL))

  algo <- if (CAN_SHA256) "sha256" else "md5"

  # Compute paths relative to the project folder by string length, NOT by
  # regex substitution: an output directory like "~/Archive (2026)" contains
  # regex metacharacters and would silently produce wrong paths.
  base    <- tools::file_path_as_absolute(folder)
  relpath <- function(p) {
    substring(tools::file_path_as_absolute(p), nchar(base) + 2L)
  }

  # Reuse hashes from a previous run where the file is demonstrably unchanged
  # (same size AND same modification time). Without this, every re-run re-hashes
  # the entire backup -- on a 100 GB archive that is many minutes of pointless
  # CPU each time, which is how a "just re-run it" habit dies.
  #
  # This caching cannot hide corruption, and in fact protects against it. Bit
  # rot changes a file's CONTENT without touching its size or mtime, so the
  # cache keeps the original (correct) checksum rather than overwriting the
  # record with a hash of the already-rotted bytes. Offline verification then
  # reports a mismatch. Re-hashing unconditionally every run would quietly
  # launder the corruption into the record and destroy the evidence.
  prior <- NULL
  prior_path <- file.path(folder, CHECKSUM_FILE)
  if (!FORCE_REFRESH && file.exists(prior_path)) {
    prior <- tryCatch(
      read.csv(prior_path, stringsAsFactors = FALSE, fileEncoding = "UTF-8"),
      error = function(e) NULL
    )
    if (!is.null(prior) && !all(c("path", "size", "mtime", "algorithm",
                                   "checksum") %in% names(prior))) {
      prior <- NULL   # record from an older version; recompute
    }
  }

  rows <- lapply(files, function(p) {
    rel   <- relpath(p)
    size  <- file.size(p)
    mtime <- format(file.mtime(p), "%Y-%m-%dT%H:%M:%S")

    cached <- NA_character_
    if (!is.null(prior)) {
      hit <- which(prior$path == rel)
      if (length(hit) == 1 &&
          identical(as.numeric(prior$size[hit]), as.numeric(size)) &&
          identical(prior$mtime[hit], mtime) &&
          identical(prior$algorithm[hit], algo)) {
        cached <- prior$checksum[hit]
      }
    }

    data.frame(
      path      = rel,
      size      = size,
      mtime     = mtime,
      algorithm = algo,
      checksum  = if (!is.na(cached)) cached else digest_file(p, algo),
      hashed_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      stringsAsFactors = FALSE
    )
  })
  record <- do.call(rbind, rows)
  tryCatch(
    write.csv(record, file.path(folder, CHECKSUM_FILE),
              row.names = FALSE, na = "", fileEncoding = "UTF-8"),
    error = function(e)
      notify("could not write %s in %s: %s", CHECKSUM_FILE, folder,
             conditionMessage(e))
  )
  invisible(record)
}

# Re-verify a backup entirely offline, against the checksums.csv files written
# when it was made. Returns the number of problems found.
verify_offline <- function(root) {
  ui_rule("Checking an existing backup")
  ui_info("Folder: %s", normalizePath(root))
  ui_info("No internet needed -- comparing the files on disk against the")
  ui_text("  checksums recorded when this backup was made.")
  message("")

  records <- list.files(root, pattern = paste0("^", CHECKSUM_FILE, "$"),
                         recursive = TRUE, full.names = TRUE)
  if (length(records) == 0) {
    ui_problem(
      "No checksum records found in %s", root,
      next_steps = c(
        "Check you pointed OSF_OUTPUT_DIR at the right folder.",
        "If this backup was made by an older version of the script, run a normal backup once to create the records."
      ))
    return(-1L)
  }

  problems <- list()
  n_files <- 0L

  # A project folder with no checksums.csv is NOT verified -- and was
  # previously not mentioned either, so an interrupted backup could show
  # "all files match" while whole projects went unchecked. Absence of a record
  # is itself a finding.
  covered <- normalizePath(dirname(records), mustWork = FALSE)
  looks_like_project <- function(d) {
    any(file.exists(file.path(d, c("metadata.json", "registration.json")))) ||
      dir.exists(file.path(d, "files"))
  }
  all_dirs <- list.dirs(root, recursive = TRUE, full.names = TRUE)
  for (d in all_dirs) {
    dn <- normalizePath(d, mustWork = FALSE)
    if (!(dn %in% covered) && looks_like_project(d)) {
      problems[[length(problems) + 1]] <- data.frame(
        folder = d, path = NA_character_, issue = "no_checksum_record",
        detail = paste0("project folder has no ", CHECKSUM_FILE,
                         " -- its contents cannot be verified offline"),
        stringsAsFactors = FALSE)
    }
  }

  for (rec_path in records) {
    folder <- dirname(rec_path)
    rec <- tryCatch(
      read.csv(rec_path, stringsAsFactors = FALSE,
                fileEncoding = "UTF-8"),
      error = function(e) NULL
    )
    if (is.null(rec) || nrow(rec) == 0) {
      problems[[length(problems) + 1]] <- data.frame(
        folder = folder, path = NA_character_, issue = "unreadable_record",
        detail = "checksums.csv is missing or unreadable",
        stringsAsFactors = FALSE)
      next
    }

    for (i in seq_len(nrow(rec))) {
      n_files <- n_files + 1L
      p <- file.path(folder, rec$path[i])

      if (!file.exists(p)) {
        problems[[length(problems) + 1]] <- data.frame(
          folder = folder, path = rec$path[i], issue = "file_missing",
          detail = "recorded in the backup but no longer on disk",
          stringsAsFactors = FALSE)
        next
      }

      actual_size <- file.size(p)
      if (!is.na(rec$size[i]) && actual_size != rec$size[i]) {
        problems[[length(problems) + 1]] <- data.frame(
          folder = folder, path = rec$path[i], issue = "size_changed",
          detail = sprintf("was %s bytes, now %s",
                            format(rec$size[i]), format(actual_size)),
          stringsAsFactors = FALSE)
        next
      }

      # A file recorded without a baseline checksum cannot be verified. Saying
      # so is the only honest answer: comparing against NA would either raise a
      # false alarm or, worse, quietly count as a match.
      if (is.na(rec$checksum[i]) || !nzchar(rec$checksum[i])) {
        problems[[length(problems) + 1]] <- data.frame(
          folder = folder, path = rec$path[i], issue = "no_baseline_checksum",
          detail = "no checksum was recorded for this file when the backup was made",
          stringsAsFactors = FALSE)
        next
      }

      got <- digest_file(p, rec$algorithm[i])
      if (is.na(got)) {
        problems[[length(problems) + 1]] <- data.frame(
          folder = folder, path = rec$path[i], issue = "hash_unavailable",
          detail = sprintf("cannot compute %s on this machine", rec$algorithm[i]),
          stringsAsFactors = FALSE)
      } else if (!identical(tolower(got), tolower(rec$checksum[i]))) {
        problems[[length(problems) + 1]] <- data.frame(
          folder = folder, path = rec$path[i], issue = "CORRUPTED",
          detail = sprintf("%s was %s, now %s", rec$algorithm[i],
                            rec$checksum[i], got),
          stringsAsFactors = FALSE)
      }
    }
  }

  ui_info("Checked %d file(s) across %d project folder(s).",
          n_files, length(records))

  if (length(problems) == 0) {
    message("")
    ui_ok("%s", ui_paint("Every file matches. This backup is intact.", "1"))
    message("")
    return(0L)
  }

  report <- do.call(rbind, problems)
  out <- file.path(root, "problems_found_offline.csv")
  tryCatch({
    write.csv(report, out, row.names = FALSE, na = "",
              fileEncoding = "UTF-8")
    ui_info("Details written to: %s", out)
  }, error = function(e) NULL)

  message("")
  ui_err("Found %d problem(s):", nrow(report))
  for (i in seq_len(min(10, nrow(report)))) {
    ui_text("  %s %s -- %s (%s)", SYM$bullet, report$path[i],
            report$detail[i], report$issue[i])
  }
  if (nrow(report) > 10) {
    ui_text("  ... and %d more (see the report)", nrow(report) - 10)
  }
  nrow(report)
}

# Fetch a node's persistent identifier (DOI), if it has been minted.
#
# Worth capturing because the DOI is what published papers actually cite. A
# backup that cannot be matched back to the citations pointing at it is much
# less useful when you are trying to work out what a paper's "available at
# osf.io/xxxxx" reference now refers to.
fetch_doi <- function(node_id, indent = "") {
  fetch_doi_generic(paste0(API_BASE, "/nodes/", node_id, "/identifiers/"),
                     node_id, indent)
}

# ---------------------------------------------------------------------------
# RENDERING A PREREGISTRATION AS READABLE TEXT
# ---------------------------------------------------------------------------
# registration.json holds everything, but not in a form a human can read: the
# answers are keyed by opaque schema field IDs, and in older schemas the values
# are themselves JSON encoded inside strings. A preregistration you cannot read
# without writing code to decode it is only half preserved -- and the schema
# needed to decode it lives on the same servers this backup exists to hedge
# against.
#
# So we also fetch the registration's schema, map field IDs to their question
# text, and write a plain-markdown transcript.
#
# OSF has two schema layouts in circulation:
#   "blocks" -- flat list of blocks, question text in `display_text`
#   "pages"  -- pages > questions (with nested `properties`), text in `title`
# Both are handled; anything unrecognised falls back to printing the raw key so
# the answer is never lost, only less prettily labelled.

# Flatten a schema into a named character vector: field id -> question text.
schema_question_map <- function(schema) {
  out <- character(0)
  if (is.null(schema)) return(out)

  blocks <- schema$attributes$blocks
  if (!is.null(blocks) && length(blocks) > 0) {
    for (b in blocks) {
      key <- b$registration_response_key
      txt <- b$display_text
      if (!is.null(key) && nzchar(key) && !is.null(txt)) out[[key]] <- txt
    }
    if (length(out) > 0) return(out)
  }

  pages <- schema$attributes$schema$pages
  if (!is.null(pages)) {
    walk <- function(qs) {
      for (q in qs) {
        qid <- q$qid %||% q$id
        ttl <- q$title %||% q$description
        if (!is.null(qid) && !is.null(ttl)) out[[qid]] <<- ttl
        if (!is.null(q$properties)) walk(q$properties)
      }
    }
    for (p in pages) walk(p$questions %||% list())
  }
  out
}

# Turn one answer -- which may be a string, a list, or a nested value/comments
# structure -- into readable text.
render_answer <- function(v, depth = 0) {
  if (is.null(v)) return("_(no answer)_")

  if (is.list(v)) {
    if (!is.null(v$value)) return(render_answer(v$value, depth + 1))
    if (length(v) == 0) return("_(no answer)_")
    parts <- vapply(v, function(x) render_answer(x, depth + 1), character(1))
    parts <- parts[nzchar(parts) & parts != "_(no answer)_"]
    if (length(parts) == 0) return("_(no answer)_")
    return(paste(paste0("- ", parts), collapse = "\n"))
  }

  txt <- trimws(paste(as.character(v), collapse = ", "))
  if (!nzchar(txt)) "_(no answer)_" else txt
}

# Write preregistration.md for one registration.
write_preregistration_md <- function(reg, dest_dir) {
  a <- reg$attributes

  # Newer registrations expose a flat registration_responses map; older ones
  # only registered_meta. Prefer the flat one.
  answers <- a$registration_responses
  if (is.null(answers) || length(answers) == 0) answers <- a$registered_meta
  if (is.null(answers) || length(answers) == 0) return(invisible(FALSE))

  schema_url <- reg$relationships$registration_schema$links$related$href
  qmap <- character(0)
  if (!is.null(schema_url)) {
    schema <- osf_get(schema_url)
    qmap <- tryCatch(schema_question_map(schema$data),
                      error = function(e) character(0))
  }

  lines <- c(
    paste0("# ", a$title %||% reg$id),
    "",
    paste0("**Registration:** https://osf.io/", reg$id, "/"),
    paste0("**Schema:** ", a$registration_supplement %||% "unknown"),
    paste0("**Registered:** ", a$date_registered %||% "unknown"),
    if (!is.null(a$embargo_end_date))
      paste0("**Embargo ends:** ", a$embargo_end_date) else NULL,
    if (isTRUE(a$withdrawn))
      paste0("**WITHDRAWN.** ", a$withdrawal_justification %||% "") else NULL,
    "",
    paste0("> Rendered from registration.json by osf_backup.R v", SCRIPT_VERSION,
            " on ", format(Sys.Date()), "."),
    "> registration.json remains the authoritative record.",
    ""
  )

  for (key in names(answers)) {
    # NB: `qmap[[key]]` would raise "subscript out of bounds" for a key the
    # schema does not describe -- unlike a list, `[[` on a named character
    # vector errors rather than returning NULL. Check membership first.
    question <- if (key %in% names(qmap)) qmap[[key]] else key
    if (identical(question, key)) {
      # No label available -- say so rather than pretending the key is the
      # question, so nobody misreads a field id as the wording used.
      lines <- c(lines, paste0("## ", key),
                  "_(question text unavailable; showing the schema field id)_", "")
    } else {
      lines <- c(lines, paste0("## ", question), "")
    }
    lines <- c(lines, render_answer(answers[[key]]), "")
  }

  writeLines(enc2utf8(lines), file.path(dest_dir, "preregistration.md"),
             useBytes = TRUE)
  invisible(TRUE)
}

# Back up a node's registrations.
#
# For a research group these are often the most important objects on OSF: a
# registration is the frozen, citable, DOI-bearing record of what you said you
# would do before you did it. `registered_meta` holds the actual answers to the
# preregistration questions -- the scholarly content, not just a pointer to it.
# Registrations are immutable on OSF, which makes them feel safe, but immutable
# is not the same as durable.
#
# Registrations have their own files and wikis, so those are fetched too.
# Returns the number of registrations saved.
backup_registrations <- function(node_id, folder, indent = "") {
  regs <- osf_get_all_pages(paste0(API_BASE, "/nodes/", node_id,
                                     "/registrations/"),
                              absent_if_404 = TRUE)
  if (!listing_ok(regs)) {
    record_listing_failure(node_id, "registrations", indent)
    return(NA_integer_)   # NA, not 0 -- "unknown", not "none"
  }
  if (length(regs) == 0) return(0L)

  regs_dir <- file.path(folder, "registrations")
  dir.create(regs_dir, showWarnings = FALSE)

  saved <- 0L
  for (r in regs) {
    reg_id    <- r$id
    reg_title <- r$attributes$title %||% reg_id

    # Embargoed registrations report public = FALSE until the embargo lifts,
    # so this excludes them from a public-only run, which is the conservative
    # reading: not public yet means not shareable yet.
    if (identical(VISIBILITY, "public") && !isTRUE(r$attributes$public)) {
      run_stats$skipped_private <- run_stats$skipped_private + 1L
      ui_text("%s  %s Registration: %s (%s)  [not public -- skipped]",
              indent, SYM$bullet, reg_title, reg_id)
      next
    }
    reg_dir   <- file.path(regs_dir, paste0(sanitize(reg_title), "__", reg_id))
    dir.create(reg_dir, recursive = TRUE, showWarnings = FALSE)

    ui_text("%s  %s Registration: %s (%s)%s", indent, SYM$bullet,
             reg_title, reg_id,
             if (isTRUE(r$attributes$withdrawn)) "  [WITHDRAWN]" else "")

    # The full record, including registered_meta (the preregistration answers)
    # and registration_supplement (which schema it followed).
    if (!write_json_atomic(r, file.path(reg_dir, "registration.json"))) {
      record_listing_failure(reg_id, "registration.json (write failed)",
                              paste0(indent, "  "))
    }

    # ...and a readable transcript of it.
    rendered <- tryCatch(write_preregistration_md(r, reg_dir),
                          error = function(e) {
                            notify("%s  could not render preregistration.md: %s",
                                   indent, conditionMessage(e))
                            FALSE
                          })
    if (isTRUE(rendered)) {
      ui_ok("saved preregistration.md (readable questions + answers)",
            indent = paste0(indent, "    "))
    }

    doi <- fetch_doi_generic(paste0(API_BASE, "/registrations/", reg_id,
                                      "/identifiers/"), reg_id,
                              paste0(indent, "  "))
    if (!is.na(doi) && !identical(doi, "LOOKUP_FAILED")) {
      writeLines(doi, file.path(reg_dir, "DOI.txt"))
      ui_info("DOI: %s", doi, indent = paste0(indent, "    "))
    }

    # Registrations carry their own file storage and wikis.
    reg_files <- file.path(reg_dir, "files")
    dir.create(reg_files, showWarnings = FALSE)
    providers <- osf_get_all_pages(paste0(API_BASE, "/registrations/", reg_id,
                                            "/files/"))
    if (!listing_ok(providers)) {
      record_listing_failure(reg_id, "registration storage providers",
                              paste0(indent, "  "))
      providers <- list()
    }
    for (p in providers) {
      pname <- p$attributes$provider
      zip_url <- paste0(FILES_BASE, "/", reg_id, "/providers/", pname, "/?zip=")
      dest <- file.path(reg_files, paste0(sanitize(pname), ".zip"))
      res <- download_file(zip_url, dest)
      run_stats[[res]] <- run_stats[[res]] + 1
      if (identical(res, "failed")) {
        notify("%s  could not download registration storage '%s'",
               indent, pname)
        next
      }
      # Registrations are frozen, citable records -- if anything deserves
      # verifying it is these. They were previously downloaded without any
      # check, which meant the most scholarly-critical files got the least
      # scrutiny.
      verify_archive(reg_id, pname, dest, paste0(indent, "  "),
                      resource = "registrations")
    }

    backup_wikis_from(paste0(API_BASE, "/registrations/", reg_id, "/wikis/"),
                       reg_id, reg_dir, paste0(indent, "  "))
    saved <- saved + 1L
    run_stats$registrations <- run_stats$registrations + 1L
  }
  saved
}

# DOI lookup against any identifiers endpoint (nodes or registrations).
# Returns the DOI string, NA if the object genuinely has none, or the literal
# "LOOKUP_FAILED" if we could not tell.
#
# The distinction matters in an archival record: silently writing "no DOI" for
# an object that does have one is a false statement in the manifest, and a DOI
# is exactly what someone will use years later to work out which paper an
# archived project belongs to.
fetch_doi_generic <- function(url, object_id = NA_character_, indent = "") {
  # No identifiers collection simply means no DOI has been minted.
  ids <- osf_get_all_pages(url, absent_if_404 = TRUE)
  if (!listing_ok(ids)) {
    record_listing_failure(object_id, "DOI / identifiers", indent)
    return("LOOKUP_FAILED")
  }
  if (length(ids) == 0) return(NA_character_)
  for (i in ids) {
    if (identical(i$attributes$category, "doi")) {
      return(i$attributes$value %||% NA_character_)
    }
  }
  NA_character_
}

# Back up a node's wiki pages.
#
# Wikis are NOT part of file storage -- they live behind their own API
# endpoint, so a project whose methods notes or codebook live in the wiki would
# otherwise produce a backup that verifies perfectly clean while silently
# missing that content. Each page is saved as markdown (OSF stores wikis as
# text/markdown), plus a wikis.json with the page metadata.
#
# Returns the number of pages saved.
backup_wikis <- function(node_id, folder, indent = "") {
  backup_wikis_from(paste0(API_BASE, "/nodes/", node_id, "/wikis/"),
                     node_id, folder, indent)
}

# Shared implementation: works for a node's wikis or a registration's wikis,
# which live at different endpoints but have identical structure.
backup_wikis_from <- function(wikis_url, node_id, folder, indent = "") {
  # A 404 here means the wiki add-on is switched off for this project -- there
  # is no wiki to lose, so it is not a failure.
  wikis <- osf_get_all_pages(wikis_url, absent_if_404 = TRUE)
  if (!listing_ok(wikis)) {
    record_listing_failure(node_id, "wiki pages", indent)
    return(NA_integer_)   # NA, not 0 -- "unknown", not "none"
  }
  if (length(wikis) == 0) return(0L)

  wiki_dir <- file.path(folder, "wiki")
  dir.create(wiki_dir, showWarnings = FALSE)
  if (!write_json_atomic(wikis, file.path(folder, "wikis.json"))) {
    record_listing_failure(node_id, "wikis.json (write failed)", indent)
  }

  saved <- 0L
  for (w in wikis) {
    name <- w$attributes$name %||% w$id
    dl   <- w$links$download
    if (is.null(dl)) {
      notify("%swiki page '%s' has no download link -- skipped", indent, name)
      next
    }

    dest   <- file.path(wiki_dir, paste0(sanitize(name), ".md"))
    result <- download_file(dl, dest)
    if (identical(result, "failed")) {
      run_stats$failed <- run_stats$failed + 1
      verification_problems[[length(verification_problems) + 1]] <<- data.frame(
        node_id = node_id, provider = "wiki", file = name,
        issue = "wiki_download_failed",
        detail = "wiki page listed by the API but could not be downloaded",
        stringsAsFactors = FALSE
      )
      next
    }

    # An empty file where OSF reports content is the failure worth catching.
    # Deliberately not comparing exact sizes: it is unclear whether OSF's
    # `size` counts bytes or characters, and a check that cries wolf on
    # unicode would be worse than no check at all.
    expected <- suppressWarnings(as.numeric(w$attributes$size %||% NA))
    actual   <- file.size(dest)
    if (!is.na(expected) && expected > 0 && !is.na(actual) && actual == 0) {
      ui_skip("wiki page '%s' is empty on OSF -- nothing to save", name,
              indent = paste0(indent, "  "))

      # Delete the empty file rather than leaving it in place. Otherwise the
      # next run sees a file at the final name, reports "already have it", and
      # skips it forever -- a page that failed once would never be retried, and
      # the backup would keep a 0-byte placeholder where content should be.
      unlink(dest)
      verification_problems[[length(verification_problems) + 1]] <<- data.frame(
        node_id = node_id, provider = "wiki", file = name,
        issue = "wiki_empty",
        detail = sprintf(paste0("wiki page is empty: OSF returns HTTP 200 with ",
                                 "no content from both the page and version ",
                                 "endpoints, though its metadata reports %s ",
                                 "bytes. Recorded for completeness; not a fault."),
                          format(expected)),
        stringsAsFactors = FALSE
      )
      next
    }
    saved <- saved + 1L
  }

  if (saved > 0) {
    ui_ok("saved %d wiki page(s)", saved, indent = paste0(indent, "  "))
    run_stats$wiki_pages <- run_stats$wiki_pages + saved
  }
  saved
}

# Registry of node ids already written, as a belt-and-suspenders guard against
# backing up the same node twice by any route.
visited_nodes <- new.env(parent = emptyenv())

# Tally of file outcomes across the run, reported in the closing summary.
run_stats <- new.env(parent = emptyenv())
run_stats$downloaded <- 0
run_stats$skipped    <- 0
run_stats$failed     <- 0
run_stats$verified   <- 0
run_stats$unverified <- 0
run_stats$listing_failures <- 0
run_stats$registrations    <- 0
run_stats$wiki_pages       <- 0

# TRUE when OSF_ONLY or OSF_LIMIT actually narrowed the run.
#
# A partial run must not overwrite the index files of a real backup: doing so
# would leave every file in place while replacing the manifest that describes
# them with one listing a single project. The data would survive and the record
# of it would not, which is arguably worse than losing a file -- so partial runs
# write to separate ".partial" filenames.
run_stats$partial <- FALSE
run_stats$skipped_private <- 0L

# Where index files go, kept distinct for partial runs.
out_name <- function(base) {
  if (isTRUE(run_stats$partial)) {
    parts <- strsplit(base, ".", fixed = TRUE)[[1]]
    ext   <- parts[length(parts)]
    stem  <- paste(parts[-length(parts)], collapse = ".")
    return(paste0(stem, ".partial.", ext))
  }
  base
}

# Every problem verification turns up, written to problems_found.csv.
#
# Deliberately named for what it contains. A file called "verification_report"
# implies a per-project record of every check, which is what the `verification`
# column of the manifest actually is; this file holds only the exceptions, and
# only exists when there are some.
verification_problems <- list()

# Issue codes that are worth recording but are NOT failures -- they describe a
# limit of what could be checked, or a quirk of OSF's own data, rather than
# anything wrong with the backup. They appear in the report but do not force a
# non-zero exit.
#
# Keeping this list honest matters: if routine conditions raise alarms, the
# report stops being read, and then a real failure goes unnoticed too.
#
#   unhashable  -- provider publishes no checksum (add-ons); size + CRC checked
#   wiki_empty  -- OSF's wiki endpoints return HTTP 200 with an empty body while
#                  the metadata advertises a non-zero size. Confirmed against
#                  both /wikis/<id>/content/ and /wikis/<id>/versions/<n>/content/:
#                  the bytes are not retrievable by any route, the page renders
#                  as empty on osf.io, and the size field is simply stale. No
#                  content is being lost, so this is a note, not a fault.
NON_FAILURE_ISSUES <- c("unhashable", "wiki_empty")

# Run all applicable checks on one downloaded archive. Returns a short status
# string for the manifest.
verify_archive <- function(node_id, provider, zip_path, indent = "",
                             resource = "nodes") {
  if (!VERIFY) return("not_checked")

  integrity <- verify_zip_integrity(zip_path)
  if (!integrity$ok) {
    ui_err("%s failed its check: %s", basename(zip_path), integrity$reason,
           indent = paste0(indent, "  "))
    verification_problems[[length(verification_problems) + 1]] <<- data.frame(
      node_id = node_id, provider = provider, file = NA_character_,
      issue = "archive_unreadable", detail = integrity$reason,
      stringsAsFactors = FALSE
    )
    run_stats$unverified <- run_stats$unverified + 1
    return("FAILED_integrity")
  }

  expected <- list_files_recursive(node_id, provider, resource = resource)

  # THE dangerous case: if the listing request failed we have nothing to
  # compare against. Previously this looked identical to "the project has no
  # files" and was counted as verified -- a clean bill of health issued on the
  # basis of no evidence whatsoever.
  if (!listing_ok(expected)) {
    ui_err("can't check %s -- OSF wouldn't give us its file list",
           basename(zip_path), indent = paste0(indent, "  "))
    record_listing_failure(node_id, paste0(provider, " file listing"), indent)
    run_stats$unverified <- run_stats$unverified + 1
    return("FAILED_no_listing")
  }

  if (length(expected) == 0) {
    ui_ok("checked %s (it's empty -- OSF lists no files here)",
          basename(zip_path), indent = paste0(indent, "  "))
    run_stats$verified <- run_stats$verified + 1
    return("ok_empty")
  }

  problems <- verify_against_listing(zip_path, integrity$contents,
                                       expected, provider,
                                       reader = integrity$reader %||% "internal")

  n_files <- length(expected)
  if (is.null(problems) || nrow(problems) == 0) {
    ui_ok("checked %s -- all %d file(s) match OSF's checksums",
          basename(zip_path), n_files, indent = paste0(indent, "  "))
    run_stats$verified <- run_stats$verified + 1
    return(sprintf("ok_%d_files", n_files))
  }

  # Some issue codes are caveats rather than faults (see NON_FAILURE_ISSUES):
  # the file is present and correct as far as it can be checked, and the note
  # records a limit of the check, not a problem with the backup.
  real <- problems[!problems$issue %in% NON_FAILURE_ISSUES, , drop = FALSE]
  problems$node_id <- node_id
  verification_problems[[length(verification_problems) + 1]] <<-
    problems[, c("node_id", "provider", "file", "issue", "detail")]

  if (nrow(real) == 0) {
    ui_ok("checked %s -- %d file(s) present (%d have no checksum published by OSF)",
          basename(zip_path), n_files, nrow(problems),
          indent = paste0(indent, "  "))
    run_stats$verified <- run_stats$verified + 1
    return(sprintf("ok_%d_files_%d_unhashable", n_files, nrow(problems)))
  }

  ui_err("%s has %d problem(s) -- first: %s (%s)",
         basename(zip_path), nrow(real), real$file[1], real$issue[1],
         indent = paste0(indent, "  "))
  run_stats$unverified <- run_stats$unverified + 1
  sprintf("FAILED_%d_problems", nrow(real))
}

# One row per node backed up, written out as backup_manifest.csv at the end.
# This is the human-readable index of the backup: which project each folder
# corresponds to, its OSF URL, when it was captured. Useful years later when
# the folder names alone no longer mean anything, and handy for citing or
# re-locating an archived project.
manifest_rows <- list()

# Write the manifest to disk. Returns the assembled data frame, or NULL if
# nothing was captured. Called at the end of a normal run, and also via on.exit
# so that a run stopped partway through still leaves an index of what it did
# manage to fetch.
write_manifest <- function() {
  if (length(manifest_rows) == 0) return(NULL)
  manifest <- do.call(rbind, manifest_rows)
  manifest_path <- file.path(OUTPUT_DIR, out_name("backup_manifest.csv"))
  ok <- tryCatch({
    write.csv(manifest, manifest_path, row.names = FALSE, na = "",
               fileEncoding = "UTF-8")
    TRUE
  }, error = function(e) {
    notify("Could not write manifest: %s", conditionMessage(e))
    FALSE
  })
  if (ok) ui_info("Index written to %s", basename(manifest_path))
  manifest
}

record_manifest <- function(node, folder, is_component, bytes,
                              verification = NA_character_,
                              wiki_pages = NA_integer_,
                              registrations = NA_integer_,
                              doi = NA_character_) {
  attrs <- node$attributes
  manifest_rows[[length(manifest_rows) + 1]] <<- data.frame(
    node_id       = node$id,
    title         = if (!is.null(attrs$title)) attrs$title else NA_character_,
    type          = if (is_component) "component" else "project",
    category      = if (!is.null(attrs$category)) attrs$category else NA_character_,
    public        = if (!is.null(attrs$public)) attrs$public else NA,
    date_created  = if (!is.null(attrs$date_created)) attrs$date_created else NA_character_,
    date_modified = if (!is.null(attrs$date_modified)) attrs$date_modified else NA_character_,
    osf_url       = paste0("https://osf.io/", node$id, "/"),
    doi           = doi,
    local_path    = folder,
    bytes_on_disk = bytes,
    wiki_pages    = wiki_pages,
    registrations = registrations,
    verification  = verification,
    backed_up_at  = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    stringsAsFactors = FALSE
  )
}

# Write problems_found.csv, listing only what went wrong. Returns the number
# of genuine failures (excluding the caveat rows in NON_FAILURE_ISSUES).
write_problems_found <- function() {
  if (length(verification_problems) == 0) return(0)
  report <- do.call(rbind, verification_problems)
  path <- file.path(OUTPUT_DIR, out_name("problems_found.csv"))
  tryCatch({
    write.csv(report, path, row.names = FALSE, na = "",
               fileEncoding = "UTF-8")
    ui_info("Problem details written to %s", basename(path))
  }, error = function(e) {
    notify("Could not write verification report: %s", conditionMessage(e))
  })
  sum(!report$issue %in% NON_FAILURE_ISSUES)
}

# Recursively back up a single node (project or component) into `dir_path`.
backup_node <- function(node, dir_path, is_component = FALSE, depth = 0) {
  node_id    <- node$id

  # A malformed entry with no id would otherwise crash on the visited-nodes
  # lookup partway through the run. Report and move on.
  if (is.null(node_id) || !nzchar(node_id)) {
    notify("skipping an entry with no node id -- OSF returned something unexpected")
    record_listing_failure("<unknown>", "node with missing id")
    return(invisible(NULL))
  }

  attrs      <- node$attributes
  title      <- if (!is.null(attrs$title)) attrs$title else node_id
  indent     <- strrep("  ", depth)

  if (!is.null(visited_nodes[[node_id]])) {
    message(sprintf("%sSkipping %s (%s) -- already backed up at %s",
                     indent, title, node_id, visited_nodes[[node_id]]))
    return(invisible(NULL))
  }

  folder     <- file.path(dir_path, paste0(sanitize(title), "__", node_id))
  dir.create(folder, recursive = TRUE, showWarnings = FALSE)
  if (!dir.exists(folder)) {
    notify("could not create folder for %s (%s) -- skipping this project",
           title, node_id)
    record_listing_failure(node_id, "project folder (could not be created)",
                            indent)
    return(invisible(NULL))
  }
  visited_nodes[[node_id]] <- folder

  # Visibility filter. A private node is not saved, but we still descend into
  # it: OSF lets a component be public while its parent is not, and skipping
  # the whole subtree would silently drop public content the user asked for.
  keep_node <- identical(VISIBILITY, "all") || isTRUE(attrs$public)

  if (is_component) {
    ui_text("%s%s %s (%s)%s", indent, SYM$bullet, title, node_id,
            if (!keep_node) "  [private -- skipped]" else "")
  } else {
    message(indent, ui_paint(title, "1"), " (", node_id, ")",
             if (!keep_node) "  [private -- skipped]" else "")
  }

  if (!keep_node) {
    run_stats$skipped_private <- run_stats$skipped_private + 1L

    # Descend anyway, in case something beneath this is public.
    kids <- osf_get_all_pages(paste0(API_BASE, "/nodes/", node_id, "/children/"))
    if (!listing_ok(kids)) {
      record_listing_failure(node_id, "child components", indent)
      kids <- list()
    }
    if (length(kids) > 0) {
      components_dir <- file.path(folder, "components")
      dir.create(components_dir, showWarnings = FALSE)
      for (child in kids) {
        backup_node(child, components_dir, is_component = TRUE,
                     depth = depth + 1)
      }
    }

    # Leave nothing behind if nothing public turned up underneath.
    if (length(list.files(folder, recursive = TRUE)) == 0) {
      unlink(folder, recursive = TRUE)
    }
    return(invisible(NULL))
  }

  # --- metadata.json --------------------------------------------------
  full_node <- osf_get(paste0(API_BASE, "/nodes/", node_id, "/"))
  if (!is.null(full_node)) {
    if (!write_json_atomic(full_node$data, file.path(folder, "metadata.json"))) {
      record_listing_failure(node_id, "metadata.json (write failed)", indent)
    }
  } else {
    # Previously this just skipped writing metadata.json with no complaint,
    # leaving a project folder that looked fine but had lost its description,
    # tags, licence and dates.
    record_listing_failure(node_id, "project metadata", indent)
  }

  # --- contributors.json ------------------------------------------------
  contributors <- osf_get_all_pages(
    paste0(API_BASE, "/nodes/", node_id, "/contributors/")
  )
  if (!listing_ok(contributors)) {
    record_listing_failure(node_id, "contributors", indent)
  } else if (!write_json_atomic(contributors,
                                  file.path(folder, "contributors.json"))) {
    record_listing_failure(node_id, "contributors.json (write failed)", indent)
  }

  # --- logs.json (most recent 100 entries) -------------------------------
  logs_page <- osf_get(paste0(API_BASE, "/nodes/", node_id, "/logs/"),
                        query = list(`page[size]` = LOG_ENTRIES))
  if (!is.null(logs_page)) {
    if (!write_json_atomic(logs_page$data, file.path(folder, "logs.json"))) {
      record_listing_failure(node_id, "logs.json (write failed)", indent)
    }
  }

  # --- wiki pages ---------------------------------------------------------
  n_wikis <- backup_wikis(node_id, folder, indent)

  # --- files: one zip per storage provider -------------------------------
  files_dir <- file.path(folder, "files")
  dir.create(files_dir, showWarnings = FALSE)

  providers <- osf_get_all_pages(paste0(API_BASE, "/nodes/", node_id, "/files/"))
  verify_notes <- character(0)

  # If we could not list the storage providers, we do not know what this
  # project has. Without this check the project would be recorded with
  # "no_files" -- indistinguishable from a genuinely empty project.
  if (!listing_ok(providers)) {
    record_listing_failure(node_id, "storage providers", indent)
    verify_notes <- c(verify_notes, "FAILED_provider_listing")
    providers <- list()
  }

  for (provider in providers) {
    provider_name <- provider$attributes$provider
    zip_url <- paste0(FILES_BASE, "/", node_id, "/providers/",
                       provider_name, "/?zip=")
    dest <- file.path(files_dir, paste0(sanitize(provider_name), ".zip"))

    result <- download_file(zip_url, dest)
    run_stats[[result]] <- run_stats[[result]] + 1

    if (identical(result, "downloaded")) {
      ui_ok("downloaded %s (%s)", basename(dest),
            format_size(file.size(dest)), indent = paste0(indent, "  "))
    } else if (identical(result, "skipped")) {
      ui_skip("already have %s, skipping", basename(dest),
              indent = paste0(indent, "  "))
    } else {
      ui_err("couldn't download %s from '%s'", basename(dest), provider_name,
             indent = paste0(indent, "  "))

      # Add-on storage fails differently from OSF's own. When GitHub, Dropbox
      # or Drive is connected to a project, OSF stores a credential for it; if
      # that lapses, WaterButler answers 401 even though your OSF token is
      # perfectly good. Name the real remedy instead of leaving the generic
      # message to imply the token is at fault.
      if (!identical(provider_name, "osfstorage")) {
        ui_text("%s    This is an add-on, not OSF's own storage. Its link to",
                indent)
        ui_text("%s    OSF may have lapsed -- reconnect '%s' under the",
                indent, provider_name)
        ui_text("%s    project's Add-ons settings on osf.io, then re-run.",
                indent)
        ui_text("%s    Files stored on OSF itself are unaffected.", indent)
      }
      next  # nothing on disk to verify
    }

    # Verify whether it was just downloaded or was already present: a zip left
    # by an earlier run deserves the same scrutiny as a fresh one.
    status <- verify_archive(node_id, provider_name, dest, indent)
    verify_notes <- c(verify_notes, paste0(provider_name, "=", status))
  }

  # --- registrations ------------------------------------------------------
  n_regs <- backup_registrations(node_id, folder, indent)

  # --- DOI / persistent identifiers ---------------------------------------
  doi <- fetch_doi(node_id, indent)

  # --- local checksum record (for offline re-verification later) ----------
  # Written before the manifest so the byte total includes it.
  write_local_checksums(folder)

  # --- record in the manifest ---------------------------------------------
  # This node's own bytes only -- components are counted in their own rows.
  bytes <- sum(file.size(node_own_files(folder)), na.rm = TRUE)
  verification_summary <- "no_files"
  if (length(verify_notes) > 0) {
    verification_summary <- paste(verify_notes, collapse = "; ")
  }

  record_manifest(node, folder, is_component, bytes,
                   verification = verification_summary,
                   wiki_pages = n_wikis, registrations = n_regs, doi = doi)

  # --- recurse into child components --------------------------------------
  children <- osf_get_all_pages(paste0(API_BASE, "/nodes/", node_id, "/children/"))

  # Worst silent failure in the script if left unchecked: a failed children
  # listing would drop EVERY component of this project while the project itself
  # still looked cleanly backed up and verified.
  if (!listing_ok(children)) {
    record_listing_failure(node_id, "child components", indent)
    children <- list()
  }

  if (length(children) > 0) {
    components_dir <- file.path(folder, "components")
    dir.create(components_dir, showWarnings = FALSE)
    for (child in children) {
      backup_node(child, components_dir, is_component = TRUE, depth = depth + 1)
    }
  }
}

# ---------------------------------------------------------------------------
# SCOPE REPORT
# ---------------------------------------------------------------------------
# Printed before anything downloads, and saved as scope_report.txt.
#
# ACCESS_MODE quietly decides how much of an account gets captured, and "backup
# completed successfully" says nothing about what was left out. Without this,
# the only way to learn that six projects and seven registrations were out of
# scope is to go and count them on OSF by hand -- which nobody does, least of
# all the person who inherits the archive years later.
#
# So state plainly: what exists, what was eligible, what was taken, and what was
# not. A backup should be honest about its own boundaries.
# `mode_selected` is what ACCESS_MODE chose; `selected_nodes` is what will
# actually be fetched after any OSF_ONLY / OSF_LIMIT narrowing. Keeping them
# apart matters: reporting a debug filter's exclusions as ACCESS_MODE's would
# tell you projects you administer are out of scope, which is false and would
# undermine the one report meant to be trustworthy about coverage.
build_scope_report <- function(all_nodes, top_level_nodes, mode_selected,
                                 selected_nodes, my_user_id) {
  n_all  <- length(all_nodes)
  n_top  <- length(top_level_nodes)
  n_comp <- n_all - n_top

  is_admin <- vapply(top_level_nodes,
                      function(nd) isTRUE(has_admin_permission(nd, my_user_id)),
                      logical(1))
  n_admin <- sum(is_admin)

  sel_ids  <- vapply(selected_nodes, function(nd) nd$id, character(1))
  mode_ids <- vapply(mode_selected,  function(nd) nd$id, character(1))

  # Excluded BY ACCESS_MODE -- the durable fact about your account.
  excluded <- Filter(function(nd) !(nd$id %in% mode_ids), top_level_nodes)

  # Dropped by a debug filter on top of that -- a property of this run only.
  filtered_out <- Filter(function(nd) nd$id %in% mode_ids &&
                                        !(nd$id %in% sel_ids), top_level_nodes)

  # Everything that will actually be captured -- the selected projects AND all
  # of their components, since components come along with their parent.
  #
  # Matching only against top-level ids undercounts: a registration attached to
  # a COMPONENT (an "Ethics Approval" or "Materials" component, say) would be
  # reported as out of scope while in fact being backed up. Each node carries a
  # `root` relationship, so membership is decidable from the listing alone.
  captured_ids <- unique(c(sel_ids, vapply(all_nodes, function(nd) {
    root_id <- nd$relationships$root$data$id
    if (!is.null(root_id) && root_id %in% sel_ids) nd$id else NA_character_
  }, character(1))))
  captured_ids <- captured_ids[!is.na(captured_ids)]

  # Registrations are counted account-wide, not per project: they are separately
  # citable objects, and one attached to a project you merely contribute to is
  # still part of your scholarly record.
  regs <- osf_get_all_pages(paste0(API_BASE, "/users/me/registrations/"),
                              absent_if_404 = TRUE)
  reg_known <- listing_ok(regs)
  reg_in <- 0L; reg_out <- 0L
  for (r in regs) {
    rf <- r$relationships$registered_from$data$id
    if (!is.null(rf) && rf %in% captured_ids) {
      reg_in <- reg_in + 1L
    } else {
      reg_out <- reg_out + 1L
    }
  }

  L <- c(
    "SCOPE OF THIS BACKUP",
    strrep("-", 70),
    sprintf("Account:                    OSF user %s", my_user_id),
    sprintf("Run at:                     %s",
             format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    sprintf("Access mode:                %s", ACCESS_MODE),
    if (identical(VISIBILITY, "public")) {
      "Visibility filter:          PUBLIC ONLY -- private nodes are skipped"
    } else {
      "Visibility filter:          none (public and private)"
    },
    {
      free <- disk_free_bytes(OUTPUT_DIR)
      if (is.na(free)) {
        "Free disk space:            could not be determined"
      } else {
        sprintf("Free disk space:            %s available where this is saving",
                 format_size(free))
      }
    },
    "",
    "On your account",
    sprintf("  Nodes you contribute to:  %d  (%d top-level project(s), %d component(s))",
             n_all, n_top, n_comp),
    sprintf("  Projects you administer:  %d of %d", n_admin, n_top),
    sprintf("  Projects, contributor:    %d of %d", n_top - n_admin, n_top),
    if (reg_known) {
      # Lower bound: /users/me/registrations/ does not appear to list
      # registrations made from COMPONENTS, so a run can legitimately capture
      # more than this. The closing summary reports the number actually saved.
      sprintf("  Registrations (at least): %d", reg_in + reg_out)
    } else {
      "  Registrations:            could not be counted (listing failed)"
    },
    "",
    "Being captured",
    sprintf("  Top-level projects:       %d of %d", length(selected_nodes), n_top),
    sprintf("  Their components:         included, nested in each project"),
    if (reg_known) {
      sprintf("  Registrations:            %d of %d (those on captured projects)",
               reg_in, reg_in + reg_out)
    } else {
      "  Registrations:            unknown"
    }
  )

  if (length(filtered_out) > 0) {
    L <- c(L, "",
            sprintf("THIS RUN ONLY -- %d project(s) you administer, held back by OSF_ONLY/OSF_LIMIT:",
                     length(filtered_out)))
    for (nd in filtered_out) {
      t <- nd$attributes$title %||% nd$id
      L <- c(L, sprintf("  - %s (%s)", substr(t, 1, 58), nd$id))
    }
    L <- c(L, "  (a normal run without those settings would include these)")
  }

  if (length(excluded) > 0) {
    L <- c(L, "",
            sprintf("NOT captured -- %d project(s) outside ACCESS_MODE = '%s':",
                     length(excluded), ACCESS_MODE))
    for (nd in excluded) {
      t <- nd$attributes$title %||% nd$id
      L <- c(L, sprintf("  - %s (%s)", substr(t, 1, 58), nd$id))
    }
    if (reg_known && reg_out > 0) {
      L <- c(L, sprintf("  ...along with %d registration(s) attached to them.",
                         reg_out))
    }
    L <- c(L, "",
            "  These are projects you contribute to but do not administer.",
            "  To include them:  OSF_ACCESS_MODE=collaborator")
  } else {
    L <- c(L, "", "Nothing on your account is excluded by the current mode.")
  }

  c(L, strrep("-", 70))
}

# End the run with an exit status.
#
# quit() would terminate the whole R session, which is fine under Rscript but
# hostile in RStudio: someone who clicks "Source" on this file would lose their
# session and everything in it. Researchers overwhelmingly run R through
# RStudio, so treat that as a normal way to invoke this, not a misuse.
finish_run <- function(status) {
  if (interactive()) {
    if (status != 0L) {
      message("\n(Finished with problems. Run from a terminal to get a ",
               "non-zero exit status for scripting.)")
    }
    return(invisible(status))
  }
  quit(status = status, save = "no")
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main <- function() {
  # Offline mode: check the existing backup and exit without touching OSF.
  if (VERIFY_ONLY) {
    if (!dir.exists(OUTPUT_DIR)) {
      stop("No backup directory at: ", OUTPUT_DIR,
           "\nSet OSF_OUTPUT_DIR to the backup you want to verify.",
           call. = FALSE)
    }
    n <- verify_offline(OUTPUT_DIR)
    return(finish_run(if (n == 0L) 0L else 1L))
  }

  dir.create(OUTPUT_DIR, recursive = TRUE, showWarnings = FALSE)

  # showWarnings = FALSE keeps the "already exists" noise down, but it also
  # hides a genuine failure (no permission, read-only volume, bad path). Check
  # explicitly, or the run proceeds to fail at every single write instead of
  # saying the one useful thing.
  if (!dir.exists(OUTPUT_DIR)) {
    stop("Could not create the output directory: ", OUTPUT_DIR,
         "\nCheck the path is valid and you have permission to write there.",
         call. = FALSE)
  }
  if (file.access(OUTPUT_DIR, mode = 2) != 0) {
    stop("No write permission for the output directory: ", OUTPUT_DIR,
         call. = FALSE)
  }

  # Refuse to write a public-only run into a folder that already holds private
  # data from a full backup.
  #
  # The files from the earlier run would stay exactly where they are while the
  # manifest was replaced by one listing only public projects -- producing a
  # folder that reads as shareable and is not. Someone would then share it.
  # This is the one mistake in the whole script with no recovery, so it stops
  # rather than warns.
  if (identical(VISIBILITY, "public")) {
    existing <- file.path(OUTPUT_DIR, "backup_manifest.csv")
    if (file.exists(existing)) {
      prev <- tryCatch(
        read.csv(existing, stringsAsFactors = FALSE, fileEncoding = "UTF-8"),
        error = function(e) NULL
      )
      has_private <- !is.null(prev) && "public" %in% names(prev) &&
        any(tolower(as.character(prev$public)) %in% c("false", "f", "0"))
      if (has_private) {
        stop("Refusing to write a public-only backup into a folder that ",
             "already contains private projects.\n\n",
             "  Folder: ", OUTPUT_DIR, "\n\n",
             "  Those private files would stay on disk while the index was ",
             "replaced with a\n  public-only one -- leaving a folder that ",
             "looks shareable but isn't.\n\n",
             "  Use a different folder, e.g.:\n",
             "    OSF_VISIBILITY=public OSF_OUTPUT_DIR=~/osf_public ",
             "Rscript osf_backup.R\n",
             "  (Leaving OSF_OUTPUT_DIR unset already picks a separate ",
             "folder for you.)", call. = FALSE)
      }
    }
  }

  # If the run is interrupted or errors out partway, still leave behind an
  # index of whatever was captured before it stopped. `add = TRUE` so this
  # does not clobber other exit handlers.
  interrupted <- TRUE
  on.exit({
    if (interrupted && length(manifest_rows) > 0) {
      message("\nRun did not finish -- writing manifest for what was captured.")
      write_manifest()
    }
  }, add = TRUE)

  # Who am I? Needed to tell my projects from collaborators'.
  me <- osf_get(paste0(API_BASE, "/users/me/"))
  my_user_id <- me$data$id
  if (is.null(my_user_id)) {
    stop("Couldn't sign in to OSF.\n\n",
         "  The reason is in the line above this one. The usual causes:\n\n",
         "    - The token was created seconds ago and hasn't propagated yet.\n",
         "      Wait a few seconds and run it again -- this is common and\n",
         "      resolves on its own.\n",
         "    - The token was copied incompletely, or has expired.\n",
         "    - The token lacks the 'osf.full_read' scope.\n\n",
         "  Tokens are at https://osf.io/settings/tokens/ (sign in first).",
         call. = FALSE)
  }
  ui_ok("Signed in to OSF as user %s", my_user_id)
  ui_info("Looking up your projects...")
  all_nodes <- osf_get_all_pages(paste0(API_BASE, "/users/me/nodes/"))

  # Refuse to continue on a partial account listing. Carrying on would produce
  # a backup and a manifest that look complete while silently omitting whole
  # projects -- the single most dangerous outcome this script can produce.
  # Better to fail loudly and be re-run than to hand back a confident lie.
  if (!listing_ok(all_nodes)) {
    stop("Could not retrieve the full list of your projects from OSF.\n",
         "Refusing to continue: a partial run would produce a backup that ",
         "looks complete\nbut silently omits projects. Check your connection ",
         "and token, then re-run\n(already-downloaded files are skipped, so a ",
         "re-run is cheap).", call. = FALSE)
  }

  # Drop components -- they get backed up in place, nested under their parent.
  # Keep the full top-level list under its own name: the scope report needs to
  # say what EXISTS, not just what survived the filter.
  all_roots <- Filter(is_top_level, all_nodes)
  n_components <- length(all_nodes) - length(all_roots)

  # Apply the ACCESS_MODE filter.
  selected <- Filter(function(nd) node_matches_access_mode(nd, my_user_id),
                      all_roots)
  n_excluded <- length(all_roots) - length(selected)
  root_nodes <- selected

  # --- debugging filters --------------------------------------------------
  # Applied after ACCESS_MODE so they narrow whatever that selected. Both are
  # announced loudly: a partial run that looked like a full one would be the
  # very failure this script works hardest to avoid.
  if (length(ONLY_IDS) > 0) {
    picked <- Filter(function(nd) nd$id %in% ONLY_IDS, all_nodes)
    found  <- vapply(picked, function(nd) nd$id, character(1))
    missing <- setdiff(ONLY_IDS, found)

    if (length(missing) > 0) {
      ui_warn("OSF_ONLY listed %d id(s) not found on your account: %s",
              length(missing), paste(missing, collapse = ", "))
    }
    if (length(picked) == 0) {
      stop("OSF_ONLY matched none of your projects, so there is nothing to do.\n",
           "  Ids come from the 'node_id' column of backup_manifest.csv, or\n",
           "  from an OSF url: https://osf.io/<id>/ -> the <id> part", call. = FALSE)
    }
    root_nodes <- picked
    run_stats$partial <- TRUE
    ui_warn("PARTIAL RUN: limited to %d project(s) by OSF_ONLY -- this is not a full backup",
            length(root_nodes))
  }

  if (LIMIT > 0 && length(root_nodes) > LIMIT) {
    root_nodes <- root_nodes[seq_len(LIMIT)]
    run_stats$partial <- TRUE
    ui_warn("PARTIAL RUN: stopping after %d project(s) by OSF_LIMIT -- this is not a full backup",
            LIMIT)
  }

  # Scope first, before a single byte is downloaded: you should be able to see
  # what you are about to get -- and what you are not -- and stop here if the
  # mode is wrong.
  scope <- build_scope_report(all_nodes, all_roots, selected, root_nodes,
                                my_user_id)
  message("")
  ui_rule("What will be backed up")
  message(paste(scope, collapse = "\n"))
  ui_rule()

  scope_path <- file.path(OUTPUT_DIR, out_name("scope_report.txt"))
  tryCatch({
    writeLines(enc2utf8(scope), scope_path, useBytes = TRUE)
    ui_info("Saved a copy of this summary to %s", basename(scope_path))
  }, error = function(e) {
    ui_warn("Couldn't save the summary to a file: %s", conditionMessage(e))
  })
  message("")

  # A run that selects nothing out of a non-empty account is almost certainly a
  # filter bug, not a correct answer -- and "Done. 0 nodes backed up" with exit
  # status 0 is precisely the kind of confident-but-wrong result this script is
  # supposed to never produce. (This guard exists because an earlier version
  # filtered on a field the API does not provide and cheerfully backed up
  # nothing.)
  if (length(root_nodes) == 0 && length(all_roots) > 0) {
    stop("Found ", length(all_nodes), " node(s) on your account but selected ",
         "NONE to back up.\n",
         "ACCESS_MODE='", ACCESS_MODE, "' matched no top-level project.\n\n",
         "This is being treated as an error rather than an empty backup, ",
         "because a\nrun that quietly saves nothing is worse than one that ",
         "stops and says so.\n\n",
         "Try:  OSF_ACCESS_MODE=collaborator Rscript osf_backup.R\n",
         "to see everything you are a contributor on.", call. = FALSE)
  }

  ui_rule("Backing up")
  for (i in seq_along(root_nodes)) {
    message("")
    message(ui_paint(sprintf("[%d/%d]", i, length(root_nodes)), "90"), " ",
             appendLF = FALSE)
    backup_node(root_nodes[[i]], OUTPUT_DIR)
  }

  # --- manifest -----------------------------------------------------------
  manifest <- write_manifest()
  total_bytes <- if (is.null(manifest)) 0 else
    sum(manifest$bytes_on_disk, na.rm = TRUE)

  n_problems <- write_problems_found()

  # Selecting projects and actually saving them are different things, and only
  # the second one matters. ACCESS_MODE filters up front (guarded above), but
  # OSF_VISIBILITY filters per node at save time -- so an account with nothing
  # public passes the earlier guard, writes nothing, and would otherwise print
  # "complete and verified" over an empty folder. Check the real outcome.
  if (length(ls(visited_nodes)) == 0) {
    reason <- if (identical(VISIBILITY, "public")) {
      paste0("OSF_VISIBILITY=public matched no public projects or components ",
              "in the selected set.")
    } else {
      "Nothing was saved, though projects were selected."
    }
    hint <- ""
    if (identical(VISIBILITY, "public")) {
      hint <- "  Run without OSF_VISIBILITY=public to include private work.\n"
    }
    stop("Nothing was backed up.\n\n  ", reason, "\n\n",
         "  Treating this as an error rather than an empty backup: a run that ",
         "quietly\n  saves nothing is worse than one that stops and says so.\n\n",
         hint, call. = FALSE)
  }

  message("")
  ui_rule("Finished")

  ui_ok("Backed up %d project(s) and component(s), %s",
        length(ls(visited_nodes)), format_size(total_bytes))
  ui_info("Saved in: %s", normalizePath(OUTPUT_DIR))

  message("")
  ui_text("  %s %d file archive(s) downloaded, %d already had, %d failed",
          SYM$bullet, run_stats$downloaded, run_stats$skipped,
          run_stats$failed)
  ui_text("  %s %d registration(s), %d wiki page(s)",
          SYM$bullet, run_stats$registrations, run_stats$wiki_pages)

  if (identical(VISIBILITY, "public")) {
    ui_text("  %s %d private node(s) skipped by OSF_VISIBILITY=public",
            SYM$bullet, run_stats$skipped_private)
  }

  if (run_stats$listing_failures > 0) {
    ui_err("%d listing(s) couldn't be retrieved -- some content is MISSING",
           run_stats$listing_failures)
  }

  if (VERIFY) {
    if (run_stats$unverified > 0) {
      ui_err("%d archive(s) failed their check", run_stats$unverified)
      ui_ok("%d archive(s) match OSF's checksums", run_stats$verified)
    } else {
      ui_ok("All %d archive(s) match OSF's checksums", run_stats$verified)
    }
  } else {
    ui_warn("Checking was turned off (OSF_VERIFY=0), so nothing in these archives has been verified")
  }

  message("")
  ui_warn("This backup contains your private project data. Keep it off shared")
  ui_text("  drives and out of any public repository.")

  interrupted <- FALSE  # reached the end cleanly; on.exit has nothing to do

  # Exit non-zero if anything is wrong, so a caller can tell a clean run from a
  # problematic one rather than having to read the output.
  if (run_stats$unverified > 0 || n_problems > 0 || run_stats$failed > 0 ||
      run_stats$listing_failures > 0) {
    steps <- c(
      "Run the script again -- finished files are skipped, so it's quick.",
      sprintf("If problems persist, open %s to see exactly what failed.",
               file.path(basename(OUTPUT_DIR), "problems_found.csv"))
    )
    ui_problem(
      "This backup is NOT complete. Don't treat it as a full archive yet.",
      next_steps = steps
    )
    return(finish_run(1L))
  }

  message("")
  if (isTRUE(run_stats$partial)) {
    ui_warn("%s", ui_paint("Partial run finished. This is NOT a full backup.", "1"))
    ui_text("  Only the projects you asked for were fetched. Run without")
    ui_text("  OSF_ONLY / OSF_LIMIT for a complete one.")
  } else if (identical(VISIBILITY, "public")) {
    ui_ok("%s", ui_paint("Public-only backup complete and verified.", "1"))
    ui_text("  Intended to be shareable -- but check the 'public' column of")
    ui_text("  backup_manifest.csv yourself before you share it.")
  } else {
    ui_ok("%s", ui_paint("This backup is complete and verified.", "1"))
  }
  message("")

  invisible(0L)
}

main()
