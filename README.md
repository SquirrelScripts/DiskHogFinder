# DiskHogFinder 🐿️

> Finds out who's hogging your stash. Read-only — the squirrel snitches, never touches.

The answer to "disk full, where'd it all go?" in one command. Free space on every drive, the folders eating the most, the biggest files — in pure PowerShell. No install, no dependencies, one file, no admin needed.

```
  🐿️  SquirrelScripts — Disk-Hog Finder
  ---------------------------------

  C:  952.86 GB total — 81.65 GB free (9%)  — getting full!
  [██████████████████████░░]

  Top folders  (size on disk, rolled up 3 deep — rows don't overlap)
  ----------------------------------------------------------------------
    41.20 GB  C:\Users\JohnDoe\AppData\Local
    18.70 GB  C:\Windows\Installer
    15.10 GB  C:\Users\JohnDoe\Videos

  Top files
  ----------------------------------------------------------------------
     8.90 GB  2023-04-11  C:\Users\JohnDoe\Videos\raw-capture.mkv
     6.40 GB  2026-06-01  C:\hiberfil.sys   ← system file — Windows manages this
   204.0 MB  2025-11-08  C:\...\EBWebView\Default\Cache\Cache_Data\data_3   ← browser cache — SquirrelCleaner territory

  ----------------------------------------------------------------------
  Scanned 1,204,388 files (689.2 GB on disk) in 2:14  🐿️
  Cache-shaped hog? SquirrelCleaner can flush it.
```

When the squirrel recognizes a hog — browser cache, update cache, `Windows.old`, the recycle bin — it tells you what it is *and* how to deal with it.

## Run it

Downloaded `.ps1` files come into Windows **blocked** (Mark-of-the-Web), so unblock it first, then run. From the folder you saved it in:

```powershell
# 1. unblock the downloaded file
Unblock-File .\Get-SquirrelHogs.ps1

# 2. sniff the system drive
powershell -ExecutionPolicy Bypass -File .\Get-SquirrelHogs.ps1
```

No `-WhatIf` step this time — there's nothing to preview. This tool has no write path at all.

## Switches

| Switch | What it does | Default |
|--------|--------------|---------|
| `-Path` | Folder or drive to scan | the system drive |
| `-Top` | How many folders / files to show | 10 |
| `-Depth` | How many levels deep to roll folder sizes up | 3 |
| `-PassThru` | Also emit a result object for piping | – |

```powershell
# dig into one folder, wider net
powershell -ExecutionPolicy Bypass -File .\Get-SquirrelHogs.ps1 -Path D:\Projects -Top 20 -Depth 2

# pretty report on screen, raw data to CSV
(.\Get-SquirrelHogs.ps1 -PassThru).TopFiles | Export-Csv hogs.csv -NoTypeInformation
```

Each file counts toward exactly **one** folder row — the rows don't overlap, so "these 10 folders hold 35 GB" means exactly that.

## Is it safe?

The whole point:

- **Read-only by design.** It enumerates and measures. There is no delete, no move, no write anywhere in the script — read the code, it's ~250 lines and not minified.
- **No admin needed.** Folders it can't open get counted and reported ("14 folders unreadable — re-run elevated for the full picture"), not error-sprayed.
- **Junction/symlink-aware.** It won't follow reparse-point links, so no infinite loops and no double-counting.
- **OneDrive-aware.** Files On-Demand placeholders claim their full size but take ~0 bytes of actual disk. Most scripts get this wrong and tell you OneDrive is your biggest hog when it's costing you nothing. The squirrel tallies cloud-only files separately and keeps them out of the report.

## Honest caveats

- **WinSxS looks bigger than it is.** Most of it is hardlinks into `System32`, and a per-file hardlink check isn't worth the speed cost. The squirrel tags it so you don't go hunting a phantom hog.
- A full drive takes a while — a packed 1 TB drive with 1.3 million files clocks in around 7–8 minutes. The progress bar keeps you posted.

## Pairs with

[**SquirrelCleaner**](https://github.com/SquirrelScripts/SquirrelCleaner) — find the hogs here, flush the cache-shaped ones there.

## Requirements

Windows, PowerShell 5.1 or newer (works on PowerShell 7 too).

---

Part of **[SquirrelScripts](https://squirrelscripts.github.io)** — a stash of small, sharp tools for sysadmins.

If it saved you a headache: ☕ **[Buy me a coffee](https://buymeacoffee.com/eblank)**

<sub>Built in a tree.</sub>
