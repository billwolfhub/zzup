# zzup

A norns script that shows which scripts in the community catalog are new to you, and which of your installed scripts have updates available, before you update them.

## install

With your norns connected to wifi, open maiden in a browser and type this in the REPL at the bottom:

```
;install https://github.com/billwolfhub/zzup
```

Then select **zzup** from the SELECT menu.

To install by hand instead, copy `zzup.lua` into a folder named `zzup` in `~/dust/code/` (via maiden, SMB, or `scp`).

**If `;install` doesn't work:** it won't overwrite an existing `~/dust/code/zzup` folder, for example one left by an earlier install attempt or a manual copy. Delete that folder (in maiden's file browser, or `rm -rf ~/dust/code/zzup` over ssh) and run `;install` again.

## updating

If you installed with `;install`, type this in maiden's REPL, then relaunch zzup:

```lua
os.execute("cd /home/we/dust/code/zzup && git pull")
```

This keeps your record and settings. It only works on a git install, so it won't work on a copy made by hand; for that, delete `~/dust/code/zzup` and install again with `;install`. Avoid editing zzup's own files, or `git pull` may refuse to update.

To start over completely (forget what you've seen, and reset settings), also delete `~/dust/data/zzup`.

## the list

Every script in the catalog is listed, plus any local scripts you have. Each row shows a new mark, a status indicator, how long ago the script was added to the catalog, and its name:

```
+  11d vinker
 ! 6y  mlr
 * 6y  awake
 ~     my-sketch
```

Ages are days (`11d`), then weeks (`3w`), months (`4mo`) and years (`6y`). The details screen (K3) shows full dates. A long name on the selected row scrolls so you can read all of it. Scrolling relies on the norns clock; on some norns the clock doesn't run after a fresh start until a clock-based script (awake, for example) has been opened, and until then long names just end in `..`.

**New**

- `+` new to you: added to the catalog since your last visit

**Status indicator**

- `*` installed, up to date
- `!` update available: a newer version has been published
- `m` modified locally: you've edited it, or made your own commits
- `!m` both: updating could lose your changes
- `?` installed, but can't be checked: copied by hand rather than installed with git, or its repo can't be reached
- `~` local only: in `dust/code` but not from the catalog. This covers your own scripts, forks, and scripts removed from the catalog.
- blank: not installed

The header shows the sort order (for example `sort: status, date`), the number of rows, and counts like `+3 !2` (three new to you, two updates), or `offline` when the catalog couldn't be downloaded.

## controls

- **E1:** sort order: status, date added, A–Z, update date, author. The header shows the current one, e.g. `sort: status, date`. Turn left past "status" for the **key**, a one-screen reference of the main status indicators (E1 right or K2 returns to the list). The key leaves out `?` and the header's `-*`, which are described above.
- **E2 / E3:** scroll by row / page
- **K2:** hide or show installed scripts, including your local ones. The header shows `-*` while they're hidden.
- **K3:** details: dates, author, tags, description, and what its status indicator means
- **K2 in details or the key:** back to the list

**Status** order (the default) puts updates and modified scripts first, then scripts new to you, then everything else, newest first.

**Author** order groups each author's scripts under a heading with the author's name. Scripts with no author listed come after the named authors, and your local scripts come last.

The sort order and the hide setting are remembered between runs.

## what counts as new

- **First run:** scripts added to the catalog in the last 30 days.
- **After that:** anything added since your last visit.
- A script stays new for two weeks after it was marked, even if you open its details, so you have time to get around to trying it.
- Updates never make a script new again. A script that's been updated 20 times since you last looked is still just new to you once.

## where the information comes from

- **The catalog:** monome's [community catalog](https://github.com/monome/norns-community), the same one maiden uses.
- **dates.json:** a small file in [billwolfhub/zzup-data](https://github.com/billwolfhub/zzup-data), rebuilt daily. It records when each script was added to the catalog and the latest commit on its repo. zzup downloads it at most every six hours.
- **Your norns:** installed scripts are checked with git, locally, in the background. It can take a little while on a norns with many scripts. Nothing about your scripts is ever uploaded.

Without dates.json (offline, or turned off), zzup still works. It uses dates it records itself, but can't tell whether installed scripts have updates.

## settings

In the norns PARAMS menu:

- **dates.json:** on or off
- **dates url:** where to download it from, for example your own fork of zzup-data

## notes

- **"Added" means added to the catalog,** which is usually close to when a script was first published. The 57 scripts added in the catalog's 2019 bulk import show "2019 or earlier".
- **"Updated" counts any commit,** including README edits.
- **Before "update all" in maiden:** git installs with local edits (`m`, `!m`) will most likely fail to update rather than lose changes, but non-git installs (`?`) are deleted and reinstalled, so any edits to those are lost.
- **Data location:** zzup keeps its data in `dust/data/zzup/`. `state.tsv` is your record and settings (plain text); the rest are cached downloads. Delete the folder to start over.

## license

GPL-3.0, the same license as norns itself. See [LICENSE](LICENSE).
