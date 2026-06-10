<#
.SYNOPSIS
    Finds out who's hogging your disk. The squirrel snitches, never touches.

.DESCRIPTION
    Shows free space on every fixed drive, then scans a path (default: the
    system drive) and reports the biggest folders and the largest files.
    Strictly read-only — no admin needed, nothing gets deleted, there is
    nothing to -WhatIf. Junction/symlink-aware, and OneDrive-aware: cloud-only
    placeholder files take ~0 bytes on disk, so they're tallied separately
    instead of inflating the report.

.EXAMPLE
    .\Get-SquirrelHogs.ps1
    Scan the system drive; show the top 10 folders and top 10 files.

.EXAMPLE
    .\Get-SquirrelHogs.ps1 -Path D:\ -Top 20 -Depth 2
    Scan D:, roll folder sizes up 2 levels deep, show 20 of each.

.EXAMPLE
    (.\Get-SquirrelHogs.ps1 -PassThru).TopFiles | Export-Csv hogs.csv -NoTypeInformation
    Pretty report on screen, raw data to CSV.
#>
[CmdletBinding()]
param(
    [string]$Path = "$env:SystemDrive\",
    [ValidateRange(1, 100)]
    [int]$Top = 10,
    [ValidateRange(1, 10)]
    [int]$Depth = 3,
    [switch]$PassThru
)

# ---------------------------------------------------------------- helpers ----
function Format-Bytes {
    param([double]$Bytes)
    if     ($Bytes -ge 1TB) { '{0:N2} TB' -f ($Bytes / 1TB) }
    elseif ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { '{0:N0} KB' -f ($Bytes / 1KB) }
    else                    { "$([int]$Bytes) B" }
}

function Get-HogNote {
    <# Tag paths the squirrel recognizes — turns "here's bad news" into
       "here's bad news and the fix". #>
    param([string]$p)
    if     ($p -match '(?i)\\(hiberfil|pagefile|swapfile)\.sys$')       { 'system file — Windows manages this' }
    elseif ($p -match '(?i)\\Windows\.old(\\|$)')                       { 'old Windows install — Disk Cleanup removes it' }
    elseif ($p -match '(?i)\\\$Recycle\.Bin(\\|$)')                     { 'recycle bin — SquirrelCleaner -EmptyRecycleBin' }
    elseif ($p -match '(?i)\\SoftwareDistribution\\Download(\\|$)')     { 'update cache — SquirrelCleaner -IncludeWindowsUpdate' }
    elseif ($p -match '(?i)\\WinSxS(\\|$)')                             { 'mostly hardlinks — smaller than it looks' }
    elseif ($p -match '(?i)\\(Temp|INetCache)(\\|$)')                   { 'temp/cache — SquirrelCleaner territory' }
    elseif ($p -match '(?i)\\(Cache|Code Cache|GPUCache|cache2)(\\|$)') { 'browser cache — SquirrelCleaner territory' }
}

# attribute bits we care about
$REPARSE = [int][IO.FileAttributes]::ReparsePoint
# OneDrive Files On-Demand placeholders: RecallOnDataAccess | RecallOnOpen | Offline.
# These report full .Length but occupy ~0 bytes of actual disk.
$CLOUD   = 0x00400000 -bor 0x00040000 -bor 0x00001000

# ------------------------------------------------------------------ banner ----
# 🐿️ only struts on PS 7+ — Windows PowerShell 5.1's conhost renders him as tofu
$ShowMascot = $PSVersionTable.PSVersion.Major -ge 7
$Mascot     = if ($ShowMascot) { '🐿️  ' } else { '' }
$MascotEnd  = if ($ShowMascot) { '  🐿️' } else { '' }

Write-Host ""
Write-Host "  ${Mascot}SquirrelScripts — Disk-Hog Finder" -ForegroundColor DarkYellow
Write-Host "  ---------------------------------" -ForegroundColor DarkGray
Write-Host ""

# --------------------------------------------------------- drive free space ----
foreach ($drv in [IO.DriveInfo]::GetDrives()) {
    if ($drv.DriveType -ne 'Fixed' -or -not $drv.IsReady) { continue }
    $usedFrac = if ($drv.TotalSize) { ($drv.TotalSize - $drv.TotalFreeSpace) / $drv.TotalSize } else { 0 }
    $freePct  = [int](100 - $usedFrac * 100)
    $bar      = ('█' * [int]($usedFrac * 24)).PadRight(24, '░')
    $barColor = if ($freePct -lt 10) { 'Red' } elseif ($freePct -lt 20) { 'Yellow' } else { 'Green' }
    $lowNote  = if ($freePct -lt 10) { '  — getting full!' } else { '' }
    Write-Host ("  {0}  {1} total — {2} free ({3}%){4}" -f `
        $drv.Name.TrimEnd('\'), (Format-Bytes $drv.TotalSize), (Format-Bytes $drv.TotalFreeSpace), $freePct, $lowNote)
    Write-Host "  [$bar]" -ForegroundColor $barColor
}

# ------------------------------------------------------------------- scan ----
$rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
if (-not $rootItem -or -not $rootItem.PSIsContainer) {
    Write-Error "Path not found (or not a folder): $Path"
    return
}
$root = $rootItem.FullName

Write-Host ""
Write-Host "  Sniffing $root for hogs (read-only — a full drive can take a few minutes)..." -ForegroundColor DarkGray

$folders    = @{}    # rollup key -> bytes; each file counts toward exactly one key
$topFiles   = New-Object System.Collections.Generic.List[psobject]
$topMin     = 0
$fileCount  = 0
$diskBytes  = 0L
$cloudBytes = 0L
$cloudCount = 0
$denied     = 0
$sw         = [Diagnostics.Stopwatch]::StartNew()

# Iterative walk (no recursion, junction-safe), same skeleton as SquirrelCleaner.
# Each stack entry: directory path, the rollup key its files credit, its depth.
# Dirs at depth <= $Depth get their own key; anything deeper inherits its
# ancestor's — that's the "rolled up N deep" folder table, with no overlap.
$stack = [System.Collections.Generic.Stack[object[]]]::new()
$stack.Push(@($root, $root, 0))

while ($stack.Count -gt 0) {
    $dir, $key, $depthNow = $stack.Pop()

    try   { $items = ([IO.DirectoryInfo]$dir).GetFileSystemInfos() }
    catch { $denied++; continue }   # access denied / path too long — count it, move on

    foreach ($item in $items) {
        $attr = [int]$item.Attributes

        if ($item -is [IO.DirectoryInfo]) {
            # Junction/symlink — don't follow (loops, double counts), don't count.
            # Can't skip on the ReparsePoint attribute alone: OneDrive sync dirs
            # are reparse points too (cloud tag) but contain real local data.
            # LinkType is non-empty only for actual junctions/symlinks.
            if (($attr -band $REPARSE) -and $item.LinkType) { continue }
            # ($depthNow + 1) must be computed before the array build — PS comma
            # binds tighter than +, so inlining it appends 1 as a 4th element
            $childDepth = $depthNow + 1
            $childKey   = if ($childDepth -le $Depth) { $item.FullName } else { $key }
            $stack.Push(@($item.FullName, $childKey, $childDepth))
            continue
        }

        # Cloud-only placeholder: full .Length reported, ~0 bytes on disk — tally
        # separately. Locally-available OneDrive files keep the ReparsePoint bit
        # (minus the recall bits) but hold real data, so for the symlink skip we
        # again need LinkType, not just the attribute.
        if ($attr -band $CLOUD) { $cloudCount++; $cloudBytes += $item.Length; continue }
        if (($attr -band $REPARSE) -and $item.LinkType) { continue }   # file symlink — target counted where it lives

        $len = $item.Length
        $fileCount++
        $diskBytes += $len
        $folders[$key] = $folders[$key] + $len

        # running top-N: only ever hold $Top file objects, evict the smallest
        if ($topFiles.Count -lt $Top -or $len -gt $topMin) {
            $topFiles.Add([pscustomobject]@{
                Path          = $item.FullName
                Length        = $len
                LastWriteTime = $item.LastWriteTime
            })
            if ($topFiles.Count -gt $Top) {
                $minIdx = 0
                for ($i = 1; $i -lt $topFiles.Count; $i++) {
                    if ($topFiles[$i].Length -lt $topFiles[$minIdx].Length) { $minIdx = $i }
                }
                $topFiles.RemoveAt($minIdx)
            }
            $topMin = ($topFiles | Measure-Object -Property Length -Minimum).Minimum
        }

        # progress every 2000 files to avoid per-file overhead
        if ($fileCount % 2000 -eq 0) {
            Write-Progress -Id 0 -Activity 'Sniffing for hogs' `
                -Status ("{0:N0} files · {1} so far" -f $fileCount, (Format-Bytes $diskBytes)) `
                -CurrentOperation $dir
        }
    }
}
$sw.Stop()
Write-Progress -Id 0 -Activity 'Sniffing for hogs' -Completed

# ----------------------------------------------------------------- report ----
$folderRows = @($folders.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $Top)
$fileRows   = @($topFiles | Sort-Object Length -Descending)

Write-Host ""
Write-Host "  Top folders  (size on disk, rolled up $Depth deep — rows don't overlap)" -ForegroundColor DarkYellow
Write-Host "  ----------------------------------------------------------------------" -ForegroundColor DarkGray
foreach ($row in $folderRows) {
    $label = if ($row.Key -eq $root) { "$root  (files directly at root)" } else { $row.Key }
    Write-Host ("  {0,10}  {1}" -f (Format-Bytes $row.Value), $label) -NoNewline
    $note = Get-HogNote $row.Key
    if ($note) { Write-Host "   ← $note" -ForegroundColor DarkCyan } else { Write-Host "" }
}

Write-Host ""
Write-Host "  Top files" -ForegroundColor DarkYellow
Write-Host "  ----------------------------------------------------------------------" -ForegroundColor DarkGray
foreach ($f in $fileRows) {
    Write-Host ("  {0,10}  {1:yyyy-MM-dd}  {2}" -f (Format-Bytes $f.Length), $f.LastWriteTime, $f.Path) -NoNewline
    $note = Get-HogNote $f.Path
    if ($note) { Write-Host "   ← $note" -ForegroundColor DarkCyan } else { Write-Host "" }
}

# ------------------------------------------------------------------- flush ----
$elapsed = if ($sw.Elapsed.TotalHours -ge 1) { $sw.Elapsed.ToString('h\:mm\:ss') } else { $sw.Elapsed.ToString('m\:ss') }
$topFolderSum = ($folderRows | Measure-Object -Property Value -Sum).Sum

Write-Host ""
Write-Host "  ----------------------------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("  Scanned {0:N0} files ({1} on disk) in {2}{3}" -f `
    $fileCount, (Format-Bytes $diskBytes), $elapsed, $MascotEnd) -ForegroundColor Green
if ($topFolderSum) {
    Write-Host ("  The {0} folder{1} above hold{2} {3} of it." -f `
        $folderRows.Count,
        $(if ($folderRows.Count -eq 1) { '' } else { 's' }),
        $(if ($folderRows.Count -eq 1) { 's' } else { '' }),
        (Format-Bytes $topFolderSum))
}
if ($cloudCount) {
    Write-Host ("  Skipped {0:N0} cloud-only file{1} ({2} in OneDrive, ~0 on disk)" -f `
        $cloudCount, $(if ($cloudCount -eq 1) { '' } else { 's' }), (Format-Bytes $cloudBytes)) -ForegroundColor DarkGray
}
if ($denied) {
    Write-Host ("  {0:N0} folder{1} unreadable — re-run elevated for the full picture" -f `
        $denied, $(if ($denied -eq 1) { '' } else { 's' })) -ForegroundColor DarkGray
}
Write-Host "  Cache-shaped hog? SquirrelCleaner can flush it." -ForegroundColor DarkGray
Write-Host ""

if ($PassThru) {
    [pscustomobject]@{
        Root           = $root
        FilesScanned   = $fileCount
        BytesOnDisk    = $diskBytes
        CloudOnlyFiles = $cloudCount
        CloudOnlyBytes = $cloudBytes
        DeniedFolders  = $denied
        Elapsed        = $sw.Elapsed
        TopFolders     = @($folderRows | ForEach-Object { [pscustomobject]@{ Path = $_.Key; Bytes = $_.Value } })
        TopFiles       = $fileRows
    }
}
