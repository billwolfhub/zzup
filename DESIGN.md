# zzup v2 design

zzup shows which norns community catalog scripts are new to you, and which of your installed scripts have updates available.

This document is the agreed design for v2. The current release (v1.2) tracks first-seen dates locally only.

## data

There are two sources, and zzup works with either one alone.

**Central dates file.** `dates.json` lives in [billwolfhub/zzup-data](https://github.com/billwolfhub/zzup-data) and is regenerated daily by a GitHub Action:

```json
{
  "version": 1,
  "generated": "2026-10-11",
  "scripts": {
    "awake": {
      "added": "2019-10-20",
      "updated": "2025-03-02",
      "commit": "<full hash of the latest commit>"
    }
  }
}
```

- `added`: the date the entry first appeared in `community.json`, taken from monome/norns-community's git history. The 57 entries added in the 2019-10-21 bulk import really mean "2019 or earlier".
- `updated` / `commit`: the latest commit on the repo's default branch, with its date. These are missing for zip-hosted entries and unreachable repos.

**Local record.** `dust/data/zzup/` holds zzup's own state, including when it first saw each catalog entry, used when the dates file can't be reached, and your settings.

zzup downloads `dates.json` at most once per launch, and not at all if the cached copy is under a few hours old. If the download fails, it uses the cached copy, then its local record. A PARAMS setting can turn the central file off or point it at another URL (for example, a fork of zzup-data).

Nothing is uploaded. Information about your local scripts never leaves the norns.

## states

Each row has two indicator columns before the date.

**Column 1: new to you**

| mark | meaning |
|---|---|
| `+` | added to the catalog since your last visit |

- On the first run, "new" means added in the last 30 days.
- A script stops being new when you open its details, or two weeks after it was first marked, whichever comes first.
- Updates never make a script "new" again.

**Column 2: on this norns**

| mark | meaning |
|---|---|
| (blank) | not installed |
| `*` | installed, up to date |
| `!` | update available: your copy is behind the latest commit |
| `m` | modified locally: uncommitted edits, or local commits ahead of the published version |
| `!m` | both: updating would mean merging or losing your changes (exact rendering to be settled on the real screen) |
| `?` | installed but can't check: not a git install, or the repo is unreachable |
| `~` | local only: in `dust/code` but not in the catalog |

Updates are only shown for installed scripts. Updates to scripts you don't have are not flagged.

## dates

- The list shows the date the script was **added** to the catalog.
- The details screen shows both added and last-updated dates.

## sort orders (E1)

1. **status** (default): updates available and modified first, then new to you, then everything else newest first
2. **date added**: newest first
3. **A–Z**
4. **last updated**: most recent commit first
5. **author**

The header shows the current sort order and counts, such as `+4 !2`.

## controls

| control | list | details |
|---|---|---|
| E1 | change sort order | |
| E2 | scroll one row | scroll |
| E3 | scroll one page | scroll |
| K2 | hide / show installed scripts (including local-only) | back to list |
| K3 | open details | |

On the opening screen, K2 or K3 continues. The sort order and hide-installed setting are remembered between runs.

## local checks

These run on the norns in the background after the list appears, and only for installed scripts that are in the catalog. Local-only scripts need no git check.

- **Where the folder comes from.** If the folder's git `origin` isn't the catalog's repo (a fork, or your own script that happens to share a catalog name), it's treated as local only (`~`) and not compared against the catalog.
- **Behind or ahead.** If your HEAD equals the published commit, it's up to date. If the published commit exists in your local history, you're up to date or ahead, and get `m` if ahead. Otherwise you're behind (`!`). This needs no network fetch.
- **Modified.** `git status --porcelain` is non-empty means `m`.
- **Not git.** A folder without `.git` (copied by hand) gets `?`.

## edge cases to test

- An author with dozens of unpublished scripts (speed, clutter, hide installed)
- An author's working copy ahead of what's published (must show `m`, not `!`)
- Committed customizations, then a new upstream commit (`!m`)
- A fork installed under the original folder name (`~`, not `!`)
- A local script sharing a catalog name (`~`)
- A hand-copied install (`?`)
- A renamed catalog entry
- Offline, with and without a cached `dates.json`
- `dates.json` unreachable or malformed
- The clock not yet set (dates near 1970)
