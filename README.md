# zzup

A norns script that shows which scripts in the community catalog are new to your norns, and the date your norns first saw each one.

The catalog has no dates, so zzup keeps its own record: every time it runs, it downloads the current catalog, compares it with the scripts it has already seen, and stamps anything new with today's date.

## install

With your norns connected to wifi, open maiden in a browser and type this in the REPL at the bottom:

```
;install https://github.com/billwolfhub/zzup
```

Then select **zzup** from the SELECT menu.

To install by hand instead, copy `zzup.lua` into a folder named `zzup` in `~/dust/code/` (via maiden, SMB, or `scp`).

**If `;install` doesn't work:** it won't overwrite an existing `~/dust/code/zzup` folder, for example one left by an earlier install attempt or a manual copy. Delete that folder (in maiden's file browser, or `rm -rf ~/dust/code/zzup` over ssh) and run `;install` again.

## first run

The first run has no history to compare against, so it scans `dust/code` instead. Scripts you already have installed become the baseline: they have no date (shown as `--`) and only appear in the **all** view. Everything you don't have is marked new as of that day and labeled "first scan" in its details.

From then on, anything that appears in the catalog gets the date zzup first saw it. These always sort above the first-scan batch, and the most recent batch is drawn brightest, so genuinely new scripts stay at the top.

## opening screen

zzup opens with a short description while the catalog downloads in the background. Press K3 (or K2) to continue to the list.

## controls

- **E2**: scroll
- **E3**: scroll a page at a time
- **K3**: details (author, tags, description, date seen)
- **K2**: back from details; in the list, toggle between **new** (dated entries only) and **all**
- **hold K2** (half a second): hide or show installed scripts. The setting is remembered between runs.

In the list, a `*` after a name means it's installed. While installed scripts are hidden, the header shows `-*` after the count.

## notes

- New scripts are only noticed when zzup runs. If you go a few months between runs, everything added in that time gets the same date.
- Offline, it shows the last downloaded catalog. On a fresh norns with no network, it falls back to the catalogs maiden has saved in `dust/data/catalogs/`.
- Its data lives in `dust/data/zzup/`: `seen.tsv` is the first-seen record (plain text, one script per line; first-scan entries end in `first`) and `catalog.json` is the cached catalog. Delete `seen.tsv` to rescan and start a new baseline.
