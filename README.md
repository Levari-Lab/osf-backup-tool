# OSF Project Backup Tool

*David Levari*


This script attempts to make a complete local copy of everything (public and private) in your OSF account — files, project descriptions, wiki pages, and registrations including your preregistration answers — and checks that the copy is correct.

> ⚠️ **The backup contains your private projects and unpublished data.** Keep it off shared drives, don't put it in a public repository, and if your work involves human-subjects data, check that your IRB protocol and any data-use agreements allow storing it wherever you're about to put it — permission to keep data on OSF doesn't automatically extend to your laptop.

> **Provided as-is, no warranty.** Not affiliated with the Center for Open Science. Some things are *not* captured — most importantly **file version history: you get the current version of each file only.** See [Limitations](#limitations) before relying on this as an archive.

## Contents

- [What you'll need](#what-youll-need)
- [Setup](#setup) — terminal, R, token, first run
- [What happens when you run it](#what-happens-when-you-run-it)
- [Settings](#settings) — including which projects get backed up
- [Privacy](#privacy) — how your token is handled
- [What you get](#what-you-get) — the folder layout
- [How it checks the copy is correct](#how-it-checks-the-copy-is-correct)
- [Limitations](#limitations) — **read this before relying on it**
- [FAQ](#faq) — *"do I need to know R?"*, *"does my OS matter?"*, and other first questions
- [Problems and changes](#problems-and-changes)
- [Being a good API citizen](#being-a-good-api-citizen)
- [License](#license)

## What you'll need

- **R installed.** Free, from [r-project.org](https://cloud.r-project.org/). You don't need to know R or read any code — you just run the script.
- **The Terminal.** Also free, already on your computer. Instructions below.
- **Disk space** roughly equal to your OSF storage. The scope summary shows how much you have free before downloading starts, and the run stops rather than filling the disk.
- **Time.** Setting up takes 10–20 minutes once, most of it installing R. The backup itself is mostly download time, so it depends on how much you have on OSF and how fast your connection is — minutes for a small account, potentially hours for tens of gigabytes. After the first run it's a single command, and re-runs only fetch what's changed.

Windows, macOS, and Linux should all work (in theory).

## Setup

### 1. Open a terminal

- **macOS** — press `Cmd + Space`, type `Terminal`, press Enter.
- **Windows** — press the Start button, type `PowerShell`, press Enter.
- **Linux** — `Ctrl + Alt + T` on most systems.

A window appears where you type commands and press Enter. That's all you'll be doing.

### 2. Install R, then the packages it needs

Install R from [cloud.r-project.org](https://cloud.r-project.org/) if you don't have it — any version from 3.3.0 (2016) onwards works. Then paste this into the terminal and press Enter:

```bash
Rscript -e 'install.packages(c("httr","jsonlite","digest"), repos="https://cloud.r-project.org")'
```

If that says `Rscript: command not found`, R isn't on your system path — see the [FAQ](#faq).

### 3. Get an OSF token

A token is a password that only lets a program read your OSF account.

Sign in to OSF in your browser, then go to **https://osf.io/settings/tokens/** → *Create token* → give it any name → tick **`osf.full_read`** and nothing else → *Create*. (If you're not signed in, that link just takes you to the login page.)

Copy the token now. OSF shows it once.

`osf.full_read` is read-only. Even if the token leaked, nobody could change or delete anything in your OSF account with it.

### 4. Tell the script your token

Paste this into the same terminal window, with your token between the quotes:

**macOS / Linux:**
```bash
export OSF_PAT="paste-your-token-here"
```

**Windows PowerShell:**
```powershell
$env:OSF_PAT = "paste-your-token-here"
```

This lasts until you close the window. That's deliberate — it keeps the token out of any file.

### 5. Run it

Move to the folder containing `osf_backup.R`, then run it:

```bash
cd "/path/to/the/folder"
Rscript osf_backup.R
```

Tip: type `cd ` (with a space), then drag the folder from Finder or Explorer onto the terminal window — it fills in the path for you.

## What happens when you run it

First it prints a summary of what it's about to do, before downloading anything:

```
Access mode:                admin
Visibility filter:          none (public and private)
Free disk space:            120.00 GB available where this is saving

On your account
  Nodes you contribute to:  30  (10 top-level project(s), 20 component(s))
  Projects you administer:  7 of 10
  Projects, contributor:    3 of 10
  Registrations (at least): 4

Being captured
  Top-level projects:       7 of 10
  Their components:         included, nested in each project
  Registrations:            3 of 4 (those on captured projects)

NOT captured -- 3 project(s) outside ACCESS_MODE = 'admin':
  - <title> (<id>)
```

**Read this part.** It's the difference between "the backup finished" and knowing what's actually in it. By default the script only takes projects you're an **admin** on; the list shows what that leaves out. Press `Ctrl + C` to stop if it isn't what you want.

Then it downloads each project, verifies it, and prints a summary. Everything goes into an `osf_backup_results` folder next to the script. A copy of the scope summary is saved there as `scope_report.txt`.

If it's interrupted — you close the laptop, the wifi drops — just run it again. It skips what it already has.

## Settings

You don't have to change anything. To change something, put it in front of the command:

```bash
OSF_ACCESS_MODE=collaborator Rscript osf_backup.R
```

| Setting | Default | What it does |
|---|---|---|
| `OSF_PAT` | *(required)* | Your token. |
| `OSF_ACCESS_MODE` | `admin` | `admin` = projects you administer. `collaborator` = everything you're on, including other people's projects. |
| `OSF_VISIBILITY` | `all` | `public` backs up only projects and components that are public on OSF — see below. |
| `OSF_OUTPUT_DIR` | `osf_backup_results` | Where to save. Defaults to next to the script. |
| `OSF_FORCE_REFRESH` | `0` | `1` re-downloads everything instead of skipping what's there. |
| `OSF_VERIFY` | `1` | `0` skips checking downloads. Not recommended. |
| `OSF_VERIFY_ONLY` | `0` | `1` checks an existing backup and exits. No token or internet needed. |
| `OSF_CONTACT` | *(unset)* | Your email, sent to OSF with each request. Courteous for big accounts. |
| `OSF_REQUEST_DELAY` | `0.25` | Seconds between requests. |
| `OSF_MAX_RETRIES` | `5` | Retries after a failed request. |
| `OSF_TIMEOUT` | `60` | Seconds before giving up on a request. |
| `OSF_DOWNLOAD_TIMEOUT` | `3600` | Seconds before giving up on a download. Raise for very large projects. |
| `OSF_MAX_RETRY_AFTER` | `900` | Longest wait when OSF asks us to slow down. |
| `OSF_RATE_LIMIT_FLOOR` | `60` | Minimum wait after being rate-limited. |
| `OSF_LOG_ENTRIES` | `100` | Activity-log entries saved per project (max 100). |
| `OSF_MIN_FREE_MB` | `2048` | Stop if free disk space falls below this. `0` disables the check. |
| `OSF_ONLY` | *(unset)* | Back up only these project IDs, comma-separated. For testing — see below. |
| `OSF_LIMIT` | `0` | Stop after this many projects. `0` means no limit. For testing. |

**Worth doing once:** run with `OSF_ACCESS_MODE=collaborator` even if you don't keep the result, just to see what `admin` leaves out. A PI added as a plain contributor to a student's thesis project gets none of it by default — and that's often exactly what's at risk when someone leaves. (There's no "creator" mode; OSF's API doesn't reveal who created a project.)

If a run would capture *nothing* while your account has projects, it stops with an error instead of reporting a successful empty backup.

### Making a shareable copy

Everything else in this README warns you not to share the backup, because it contains private work. If you want a copy you *can* share:

```bash
OSF_VISIBILITY=public Rscript osf_backup.R
```

This keeps only nodes that OSF reports as public, and applies that test to **every** project, component, and registration — not just top-level projects. A public project can contain private components, so filtering only at the top would put private data into an archive you believed was shareable. A public component of a private project is still captured; the private parent is walked through but not saved.

Embargoed registrations count as not public until the embargo lifts, so they're excluded.

Output goes to a separate `osf_backup_results_public/` folder by default, and the script **refuses to run** if you point it at a folder that already contains private projects from a full backup. Those files would remain on disk while the index was replaced with a public-only one — a folder that reads as shareable but isn't. That's the one mistake here with no undo, so it stops rather than warns.

**This is a convenience, not a security guarantee.** It trusts OSF's public/private flag and trusts this code to be correct. Before you share anything, open `backup_manifest.csv` and check the `public` column yourself.

## Privacy

The backup contains everything from your private projects — see the warning at the top of this page for where not to put it.

Your token is read-only, is never saved to disk or printed in any output, and is never sent anywhere except OSF. It lives only in the terminal window you set it in, so closing that window forgets it.

## What you get

```
osf_backup_results/backup_manifest.csv      # index of everything captured
osf_backup_results/scope_report.txt         # what was in scope vs what exists
osf_backup_results/problems_found.csv       # only written if something is wrong
osf_backup_results/<Project Title>__<node id>/
  metadata.json          # title, tags, category, dates, license, ...
  contributors.json
  logs.json              # recent activity log
  wikis.json             # wiki page metadata
  wiki/<Page Name>.md    # wiki content, as markdown
  checksums.csv          # local hashes, for offline re-checks
  registrations/<Title>__<id>/
    registration.json    # full record (authoritative)
    preregistration.md   # readable: questions + your answers
    DOI.txt              # the DOI papers cite, if one was minted
    files/, wiki/
  files/osfstorage.zip   # project files, zipped
  files/<other>.zip      # other connected storage (GitHub, Dropbox, ...)
  components/<Child Title>__<child id>/...   # same structure, recursive
```

Open `backup_manifest.csv` in Excel or R to see everything at a glance: one row per project and component, with titles, OSF links, DOIs, sizes, and whether each verified correctly. It's what makes the backup legible years later, when the folder names alone no longer mean much.

## How it checks the copy is correct

**A download that "succeeded" isn't proof it arrived intact** — a connection can drop mid-file and still look like success. So each archive is checked after it lands:

| Check | Catches |
|---|---|
| **Integrity** | Truncated or unopenable archives |
| **Inventory** | Archives missing files, or with the wrong sizes |
| **Checksums** | Silent corruption the first two would pass |

OSF publishes a checksum — a fingerprint — for every file, computed on their servers. The script compares your copy against those fingerprints, so it's verifying against OSF's own record rather than just re-reading what it wrote.

Every project's result appears in the `verification` column of `backup_manifest.csv`. Anything that went wrong is also written to `problems_found.csv` — a file that only exists when there's something in it — and the run ends with an error status. Things that are limits of the check rather than faults (a storage provider that publishes no checksum, an empty wiki page) are noted but don't count as failures.

### Checking it again years later, with no internet

Each project folder also stores its own checksums, so the backup can verify itself with no token and no network — the check that still works when OSF doesn't:

```bash
OSF_VERIFY_ONLY=1 Rscript osf_backup.R
```

**Worth doing before you rely on an archive, and again any time you want to confirm it's still intact.** Hard drives degrade silently, and a backup nobody has ever checked is a hope rather than a backup.

## Limitations

Not affiliated with or endorsed by the Center for Open Science. **Test a restore yourself before you delete anything from OSF**, and don't make this your only copy of anything irreplaceable.

**Not captured:**

| | |
|---|---|
| **File version history** | **Current version of each file only.** Earlier revisions, under a file's Revisions tab, are not retrieved. **A clean verification result does not mean older versions are recoverable.** |
| Preprints | Not included. |
| View-only / anonymized links | Not captured. If a manuscript under review cites one, that link dies with the project. |
| Comments and annotations | Not retrieved. |
| Activity log | Most recent 100 entries per project only. |
| Disconnected add-ons | Skipped if the connection to Dropbox/GitHub/etc. has expired. Reported, not silent. |

**What verification proves:** that your copy matches what OSF says the project contains. It catches truncation, missing files, and corruption in transit. It can't tell you whether something was uploaded to OSF correctly in the first place — a faithful copy of something already wrong will verify clean.

**Also worth knowing:**

- **It's a snapshot, not a sync.** Re-running fetches anything missing, but nothing reports a file *deleted* on OSF since last time.
- **No restore path.** Putting a project back onto OSF is a manual job.
- **Component nesting is capped at 25 levels**; deeper trees stop and say so.
- **Rate limits are shared** across everything using your token.

## FAQ

**Do I need to know R?**
No. You install R and run one command. You never open, read, or edit the code.

**Does my operating system matter?**
No — Windows, macOS, and Linux all work. The only difference is how you set the token in step 4.

**`Rscript: command not found` — what now?**
R is installed but your terminal can't find it. On macOS, reinstalling from [cloud.r-project.org](https://cloud.r-project.org/) usually fixes it. On Windows, use the full path, e.g. `& "C:\Program Files\R\R-4.4.1\bin\Rscript.exe" osf_backup.R` — adjust the version number to match yours.

**Can I run it from RStudio instead?**
Yes. Use the **Terminal** tab (next to Console) and follow the instructions exactly as written. You can also run it in the Console with `Sys.setenv(OSF_PAT="your-token")` then `source("osf_backup.R")` — it won't close your session.

**How long does it take?**
Almost entirely download time, so it scales with how much data you have and how fast your connection is — not with the number of projects. A couple of gigabytes takes a few minutes on home broadband. Re-runs are much faster because they only fetch what's missing. The scope summary at the start tells you how many projects are coming before the downloading begins.

**How much disk space?**
About the same as your OSF storage. The scope summary shows how much free space you have before anything downloads, and the final summary reports what was used.

The script can't tell you the total in advance — OSF doesn't report a project's size without walking every folder first, which would be slow. Instead it checks before each download and **stops cleanly if free space drops below 2 GB**, rather than filling your disk. Nothing is lost: run it again after freeing space and it resumes. Change the threshold with `OSF_MIN_FREE_MB`, or set it to `0` to disable.

**Will this change anything on OSF?**
No. The token is read-only and the script only ever downloads. Nothing on OSF is modified, moved, or deleted.

**Do I have to keep the terminal open?**
Yes, until it finishes. Closing the window stops the run — but that's safe, and re-running picks up where it stopped.

**It stopped partway. Did I lose anything?**
No. Files are only put into place once fully downloaded, so a partial file never masquerades as a complete one. Run it again.

**When should I run it?**
Whenever you want a current copy — and particularly before a change that could cost you access, like leaving an institution, closing a lab, or handing a project over.

**What if my projects are huge?**
Mostly fine — a 1.6 GB archive with 250 files inside it has been tested — but a few things to know above roughly that size:

- **Raise the download timeout** if an archive takes over an hour: `OSF_DOWNLOAD_TIMEOUT=7200 Rscript osf_backup.R`. The run tells you when a timeout is what failed, and names this setting.
- **Downloads restart from the beginning if the connection drops.** Resume works per file, not per byte, so a very large archive on an unreliable connection may not finish. Nothing is corrupted — it just retries.
- **Checking needs scratch space.** Verification extracts each file before hashing it, so a 20 GB file needs 20 GB free on your *temporary* volume — which on macOS is the startup disk, even if the backup is going to an external drive. If there isn't room, the archive is reported as `no_scratch_space` rather than checked; set `TMPDIR` to somewhere roomier and run again.
- **Checking takes time.** Every run re-checks archives it already has, which for tens of gigabytes means substantial disk work. `OSF_VERIFY=0` skips it when you just want the files.

**I got a message with a `!` in it.**
That's a real problem worth reading. Check `problems_found.csv` in the backup folder. Lines starting with `.` or `~` are notes and retries, not failures.

**Can I share the backup with a collaborator?**
Careful — it contains everything from your private projects, not just the parts you'd normally share.

## Problems and changes

**This is shared as-is and isn't actively maintained.** Issues are turned off, and there's no support. You're welcome to fork it and change whatever you need.

**If something goes wrong,** the run tells you more than it might first appear. Lines starting with `!` are real problems; `.` and `~` are notes and retries. `problems_found.csv` names each failing file and why. `scope_report.txt` shows what the run was trying to capture, which is usually where a surprise turns out to have started.

When a check fires and it isn't obvious whether the script or OSF is at fault, this settles it in one step — the response headers distinguish a redirect, an empty body, and a real error:

```bash
curl -sD - -o /dev/null -H "Authorization: Bearer $OSF_PAT" "<the url from the message>"
```

**Modifying the script?** `OSF_ONLY` and `OSF_LIMIT` narrow a run to a single project, so you aren't waiting on a full re-check to see whether a change worked. `Rscript -e 'parse("osf_backup.R")'` catches syntax errors without running anything — though it won't catch a wrong API field, which parses fine and then silently does nothing. A short real run is the test that matters.

**Forking it?** The default output folder sits inside the repo. `.gitignore` excludes it, but check rather than trust: `git add -A && git status` should list only the script, README, LICENSE and `.gitignore`. Git keeps deleted files in its history, so a private file committed once is hard to take back.

## Being a good API citizen

OSF is a free, shared, non-profit service. The script paces its requests, waits when asked to slow down, retries transient failures with increasing delays, times out rather than hanging, identifies itself, and skips what it already has. Set `OSF_CONTACT` to your email if you're backing up a large account.

## License

MIT — see [LICENSE](LICENSE). No warranty, which for backup tooling is worth reading literally: test a restore before you rely on it.
