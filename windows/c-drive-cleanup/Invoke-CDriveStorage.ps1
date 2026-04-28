[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Cleanup', 'PlanMove', 'ProfilePaging')]
    [string]$Phase = 'Analyze',

    [string]$IndexPath,

    [switch]$ReuseIndex,

    [switch]$ForceRescan,

    [int]$TopCount = 20,

    [int]$MinAgeDays = 7,

    [switch]$Execute,

    [switch]$AssessMoveToD,

    [switch]$AssessPagingFile,

    [switch]$AutoSetupPagingOnD,

    [int]$PagingFileInitialMB = 0,

    [int]$PagingFileMaximumMB = 0,

    [double]$PagingDDriveMinFreeGB = 20,

    [double]$MinMoveFolderGB = 2,

    [double]$MinMoveFileGB = 1,

    [double]$DDriveRecommendedFreeGB = 50,

    [string]$PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptBasePath = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}
else {
    (Get-Location).Path
}

if ([string]::IsNullOrWhiteSpace($IndexPath)) {
    $IndexPath = Join-Path -Path $scriptBasePath -ChildPath 'cdrive-index.json'
}

if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    $PlanPath = Join-Path -Path $scriptBasePath -ChildPath 'cdrive-move-plan.md'
}

function Format-Bytes {
    param([double]$Bytes)

    if ($Bytes -lt 1KB) { return ('{0:N0} B' -f $Bytes) }
    if ($Bytes -lt 1MB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -lt 1TB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    return ('{0:N2} TB' -f ($Bytes / 1TB))
}

function Get-DirectorySizeBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $sum = (Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [double]$sum
    }
    catch {
        return 0
    }
}

function Ensure-Array {
    param($Value)

    if ($null -eq $Value) {
        Write-Output -NoEnumerate @()
        return
    }

    $arr = @($Value)
    Write-Output -NoEnumerate $arr
}

function Get-SumProperty {
    param(
        $Items,
        [Parameter(Mandatory = $true)][string]$Property
    )

    $arr = Ensure-Array -Value $Items
    if ($arr.Count -eq 0) {
        return 0
    }

    $measure = $arr | Measure-Object -Property $Property -Sum
    if ($null -eq $measure -or -not ($measure.PSObject.Properties.Name -contains 'Sum') -or $null -eq $measure.Sum) {
        return 0
    }

    return [double]$measure.Sum
}

function Test-ObjectProperty {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$PropertyName
    )

    if ($null -eq $Object) {
        return $false
    }

    return ($Object.PSObject.Properties.Name -contains $PropertyName)
}

function Read-Index {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-Warning "Index file is empty. A new index will be created: $Path"
            return $null
        }

        return $content | ConvertFrom-Json
    }
    catch {
        try {
            $backupPath = "$Path.bad-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -LiteralPath $Path -Destination $backupPath -Force -ErrorAction SilentlyContinue
            Write-Warning "Index file exists but could not be parsed: $Path"
            Write-Warning "Malformed index was backed up to: $backupPath"
        }
        catch {
            Write-Warning "Index file exists but could not be parsed: $Path"
        }
        return $null
    }
}

function Write-Index {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $Data | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Show-History {
    param($Index)

    $history = @()
    if ($null -ne $Index -and $null -ne $Index.history) {
        $history = Ensure-Array -Value $Index.history
    }

    if ($history.Count -eq 0) {
        Write-Host "No scan history found yet."
        return
    }

    Write-Host "Recent scan history (latest first):"
    $history |
        Sort-Object -Property timestamp -Descending |
        Select-Object -First 10 |
        Select-Object timestamp,
            @{ Name = 'DurationSec'; Expression = { [math]::Round($_.durationSeconds, 2) } },
            @{ Name = 'FreeGB'; Expression = { [math]::Round($_.freeGB, 2) } },
            @{ Name = 'LargestWin'; Expression = { if ($_.largestCandidatePath) { $_.largestCandidatePath } else { '-' } } },
            @{ Name = 'LargestWinSize'; Expression = { if ($_.largestCandidateBytes) { Format-Bytes $_.largestCandidateBytes } else { '-' } } } |
        Format-Table -AutoSize
}

function Get-CleanupCandidatePaths {
    $paths = @()

    if ($env:TEMP) {
        $paths += $env:TEMP
    }

    $userTemp = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Temp'
    $paths += $userTemp
    $paths += 'C:\Windows\Temp'
    $paths += 'C:\Windows\SoftwareDistribution\Download'

    $resolved = foreach ($p in $paths) {
        if ([string]::IsNullOrWhiteSpace($p)) {
            continue
        }

        try {
            if (Test-Path -LiteralPath $p) {
                (Get-Item -LiteralPath $p -Force).FullName
            }
            else {
                $p
            }
        }
        catch {
            $p
        }
    }

    return $resolved | Sort-Object -Unique
}

function Get-HibernationInfo {
    $hiberPath = 'C:\hiberfil.sys'
    $exists = Test-Path -LiteralPath $hiberPath
    $sizeBytes = 0

    if ($exists) {
        try {
            $sizeBytes = [double](Get-Item -LiteralPath $hiberPath -Force).Length
        }
        catch {
            $sizeBytes = 0
        }
    }

    return [pscustomobject]@{
        exists     = $exists
        path       = $hiberPath
        sizeBytes  = [double]$sizeBytes
        suggestion = if ($exists -and $sizeBytes -gt 0) { 'Hibernation appears active. If you do not use hibernate, reclaim space with: powercfg /h off' } else { 'Hibernation file not detected.' }
    }
}

function Get-WindowsRecoveryInfo {
    $recoveryPath = 'C:\Windows\System32\Recovery\Winre.wim'
    $recoverySize = 0
    if (Test-Path -LiteralPath $recoveryPath) {
        try {
            $recoverySize = [double](Get-Item -LiteralPath $recoveryPath -Force).Length
        }
        catch {
            $recoverySize = 0
        }
    }

    $status = 'Unknown'
    try {
        $info = & reagentc /info 2>$null
        if ($LASTEXITCODE -eq 0 -and $info) {
            $text = ($info | Out-String)
            if ($text -match 'Windows RE status:\s*Enabled') {
                $status = 'Enabled'
            }
            elseif ($text -match 'Windows RE status:\s*Disabled') {
                $status = 'Disabled'
            }
        }
    }
    catch {
        $status = 'Unknown'
    }

    return [pscustomobject]@{
        status     = $status
        path       = $recoveryPath
        sizeBytes  = [double]$recoverySize
        suggestion = if ($status -eq 'Enabled') { 'Windows Recovery is enabled. Only disable if you have other recovery media; command: reagentc /disable' } else { 'Windows Recovery is not enabled or could not be detected.' }
    }
}

function Get-UserProfileHeavyUsage {
    param([int]$Top = 15)

    $profilePath = $env:USERPROFILE
    if (-not $profilePath -or -not (Test-Path -LiteralPath $profilePath)) {
        return [pscustomobject]@{
            profilePath = $profilePath
            topFolders  = @()
            topFiles    = @()
        }
    }

    $folderStats = foreach ($dir in (Get-ChildItem -LiteralPath $profilePath -Directory -Force -ErrorAction SilentlyContinue)) {
        [pscustomobject]@{
            path      = $dir.FullName
            sizeBytes = [double](Get-DirectorySizeBytes -Path $dir.FullName)
        }
    }

    $topFolders = Ensure-Array -Value ($folderStats | Sort-Object -Property sizeBytes -Descending | Select-Object -First $Top)

    $largeFiles = Get-ChildItem -LiteralPath $profilePath -File -Recurse -Force -ErrorAction SilentlyContinue |
        Sort-Object -Property Length -Descending |
        Select-Object -First $Top |
        ForEach-Object {
            [pscustomobject]@{
                path      = $_.FullName
                sizeBytes = [double]$_.Length
            }
        }

    return [pscustomobject]@{
        profilePath = $profilePath
        topFolders  = Ensure-Array -Value $topFolders
        topFiles    = Ensure-Array -Value $largeFiles
    }
}

function Get-DriveSummary {
    $drive = Get-PSDrive -Name C
    [pscustomobject]@{
        freeBytes  = [double]$drive.Free
        usedBytes  = [double]($drive.Used)
        totalBytes = [double]($drive.Free + $drive.Used)
        freeGB     = [math]::Round($drive.Free / 1GB, 2)
        usedGB     = [math]::Round($drive.Used / 1GB, 2)
        totalGB    = [math]::Round(($drive.Free + $drive.Used) / 1GB, 2)
    }
}

function Get-DriveInfo {
    param([Parameter(Mandatory = $true)][string]$DriveName)

    try {
        $drive = Get-PSDrive -Name $DriveName -ErrorAction Stop
        return [pscustomobject]@{
            exists     = $true
            name       = $DriveName
            root       = "${DriveName}:\"
            freeBytes  = [double]$drive.Free
            usedBytes  = [double]$drive.Used
            totalBytes = [double]($drive.Free + $drive.Used)
            freeGB     = [math]::Round($drive.Free / 1GB, 2)
            usedGB     = [math]::Round($drive.Used / 1GB, 2)
            totalGB    = [math]::Round(($drive.Free + $drive.Used) / 1GB, 2)
        }
    }
    catch {
        return [pscustomobject]@{
            exists     = $false
            name       = $DriveName
            root       = "${DriveName}:\"
            freeBytes  = 0
            usedBytes  = 0
            totalBytes = 0
            freeGB     = 0
            usedGB     = 0
            totalGB    = 0
        }
    }
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-PagingFileAssessment {
    param([double]$DMinFreeGB = 20)

    $dInfo = Get-DriveInfo -DriveName 'D'

    $ramMB = 0
    try {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computer.TotalPhysicalMemory) {
            $ramMB = [int][math]::Round(([double]$computer.TotalPhysicalMemory / 1MB), 0)
        }
    }
    catch {
        $ramMB = 0
    }

    $recommendedInitialMB = if ($ramMB -gt 0) { [int][math]::Max(1024, $ramMB) } else { 4096 }
    $recommendedMaximumMB = if ($ramMB -gt 0) { [int][math]::Max($recommendedInitialMB, [math]::Round($ramMB * 1.5, 0)) } else { 6144 }

    $autoManaged = $true
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $autoManaged = [bool]$cs.AutomaticManagedPagefile
    }
    catch {
        $autoManaged = $true
    }

    $settings = Ensure-Array -Value (Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue |
        Select-Object Name, InitialSize, MaximumSize)

    $usage = Ensure-Array -Value (Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction SilentlyContinue |
        Select-Object Name, AllocatedBaseSize, CurrentUsage, PeakUsage, TempPageFile)

    $configuredOnD = $false
    foreach ($s in $settings) {
        if ($s.Name -like 'D:*') {
            $configuredOnD = $true
            break
        }
    }

    $status = 'Undetermined'
    $recommendation = 'Paging file configuration appears valid. Keep current settings unless troubleshooting specific memory issues.'

    if (-not $dInfo.exists) {
        $status = 'D drive not found'
        $recommendation = 'D: is not available. Keep paging file on C: or attach/create D: first.'
    }
    elseif ($dInfo.freeGB -lt $DMinFreeGB) {
        $status = 'D free space below threshold'
        $recommendation = ('D: has only {0} GB free, below recommended {1} GB for moving pagefile. Keep current config for now.' -f $dInfo.freeGB, $DMinFreeGB)
    }
    elseif ($configuredOnD) {
        $status = 'Paging file already configured on D'
        $recommendation = 'Pagefile already includes D:. No move needed.'
    }
    else {
        $status = 'Eligible to move paging file to D'
        $recommendation = ('Recommend setting D:\pagefile.sys (Initial {0} MB, Max {1} MB). Reboot required after change.' -f $recommendedInitialMB, $recommendedMaximumMB)
    }

    return [pscustomobject]@{
        assessedAt            = (Get-Date).ToString('o')
        autoManaged           = [bool]$autoManaged
        ramMB                 = [int]$ramMB
        recommendedInitialMB  = [int]$recommendedInitialMB
        recommendedMaximumMB  = [int]$recommendedMaximumMB
        dDrive                = $dInfo
        dMinFreeGBThreshold   = [double]$DMinFreeGB
        settings              = $settings
        usage                 = $usage
        status                = $status
        recommendation        = $recommendation
        configuredOnD         = [bool]$configuredOnD
    }
}

function Set-PagingFileOnD {
    param(
        [int]$InitialMB = 0,
        [int]$MaximumMB = 0,
        [double]$DMinFreeGB = 20
    )

    if (-not (Test-IsAdministrator)) {
        throw 'Auto paging-file setup requires elevated PowerShell (Run as Administrator).'
    }

    $assessment = Get-PagingFileAssessment -DMinFreeGB $DMinFreeGB
    if (-not $assessment.dDrive.exists) {
        throw 'D: drive not found. Cannot configure pagefile on D:.'
    }
    if ($assessment.dDrive.freeGB -lt $DMinFreeGB) {
        throw ('D: free space {0} GB is below threshold {1} GB. Aborting auto setup.' -f $assessment.dDrive.freeGB, $DMinFreeGB)
    }

    if ($InitialMB -le 0) {
        $InitialMB = [int]$assessment.recommendedInitialMB
    }
    if ($MaximumMB -le 0) {
        $MaximumMB = [int]$assessment.recommendedMaximumMB
    }
    if ($MaximumMB -lt $InitialMB) {
        $MaximumMB = $InitialMB
    }

    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ([bool]$cs.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } | Out-Null
    }

    Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue | ForEach-Object {
        $_ | Remove-WmiObject -ErrorAction SilentlyContinue
    }

    $createResult = ([WMIClass]'Win32_PageFileSetting').Create('D:\\pagefile.sys', [uint32]$InitialMB, [uint32]$MaximumMB)
    if ($null -eq $createResult -or $createResult.ReturnValue -ne 0) {
        $returnCode = if ($null -ne $createResult) { $createResult.ReturnValue } else { -1 }
        throw ('Failed to create D:\pagefile.sys setting. WMI return code: {0}' -f $returnCode)
    }

    return [pscustomobject]@{
        changed           = $true
        target            = 'D:\pagefile.sys'
        initialMB         = [int]$InitialMB
        maximumMB         = [int]$MaximumMB
        rebootRequired    = $true
        message           = 'Paging file was configured for D:. Reboot is required for full effect.'
        appliedAt         = (Get-Date).ToString('o')
    }
}

function Get-MoveToDProposal {
    param(
        [Parameter(Mandatory = $true)]$UserProfileUsage,
        [double]$MinFolderGB = 2,
        [double]$MinFileGB = 1,
        [double]$MinRecommendedFreeGB = 50
    )

    $dInfo = Get-DriveInfo -DriveName 'D'
    $folderThresholdBytes = [double]([math]::Abs($MinFolderGB) * 1GB)
    $fileThresholdBytes = [double]([math]::Abs($MinFileGB) * 1GB)

    $folderCandidates = @()
    $fileCandidates = @()

    if ($dInfo.exists) {
        $folderCandidates = Ensure-Array -Value (
            Ensure-Array -Value $UserProfileUsage.topFolders |
                Where-Object { [double]$_.sizeBytes -ge $folderThresholdBytes } |
                Select-Object -First 15 |
                ForEach-Object {
                    $baseName = Split-Path -Path $_.path -Leaf
                    [pscustomobject]@{
                        path          = $_.path
                        sizeBytes     = [double]$_.sizeBytes
                        suggestedDest = (Join-Path -Path 'D:\MovedFromC' -ChildPath $baseName)
                        linkType      = 'junction'
                        rationale     = 'Large user folder; junction usually preserves app paths.'
                    }
                }
        )

        $fileCandidates = Ensure-Array -Value (
            Ensure-Array -Value $UserProfileUsage.topFiles |
                Where-Object { [double]$_.sizeBytes -ge $fileThresholdBytes } |
                Select-Object -First 15 |
                ForEach-Object {
                    $baseName = Split-Path -Path $_.path -Leaf
                    [pscustomobject]@{
                        path          = $_.path
                        sizeBytes     = [double]$_.sizeBytes
                        suggestedDest = (Join-Path -Path 'D:\MovedFromC\Files' -ChildPath $baseName)
                        linkType      = 'symlink-file'
                        rationale     = 'Large file; symlink can preserve original path.'
                    }
                }
        )
    }

    $totalProposedBytes = (Get-SumProperty -Items $folderCandidates -Property 'sizeBytes') + (Get-SumProperty -Items $fileCandidates -Property 'sizeBytes')

    $status = if (-not $dInfo.exists) {
        'D drive not found'
    }
    elseif ($dInfo.freeGB -lt $MinRecommendedFreeGB) {
        'D drive exists but free space is lower than recommended'
    }
    else {
        'D drive is suitable for migration proposals'
    }

    return [pscustomobject]@{
        assessedAt                   = (Get-Date).ToString('o')
        dDrive                       = $dInfo
        minFolderGB                  = [double]$MinFolderGB
        minFileGB                    = [double]$MinFileGB
        recommendedFreeGBThreshold   = [double]$MinRecommendedFreeGB
        dDriveStatus                 = $status
        folderCandidates             = Ensure-Array -Value $folderCandidates
        fileCandidates               = Ensure-Array -Value $fileCandidates
        totalProposedBytes           = [double]$totalProposedBytes
        notes                        = @(
            'Proposal only: no files are moved by this script.',
            'For folders, use junctions where possible: New-Item -ItemType Junction.',
            'For files, symlink may require Developer Mode or elevation: New-Item -ItemType SymbolicLink.'
        )
    }
}

function Write-MovePlan {
    param(
        [Parameter(Mandatory = $true)]$Proposal,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $folderCandidates = Ensure-Array -Value $Proposal.folderCandidates
    $fileCandidates = Ensure-Array -Value $Proposal.fileCandidates

    $lines = @()
    $lines += '# C Drive to D Drive Migration Plan'
    $lines += ''
    $lines += ('Generated: {0}' -f (Get-Date).ToString('o'))
    $lines += ('Assessment timestamp: {0}' -f $Proposal.assessedAt)
    $lines += ('D drive status: {0}' -f $Proposal.dDriveStatus)
    $lines += ('D free space: {0} of {1}' -f (Format-Bytes ([double]$Proposal.dDrive.freeBytes)), (Format-Bytes ([double]$Proposal.dDrive.totalBytes)))
    $lines += ('Total potential movable size: {0}' -f (Format-Bytes ([double]$Proposal.totalProposedBytes)))
    $lines += ''
    $lines += 'Important: This plan is proposal-only. Review each item before moving.'
    $lines += ''

    if (-not $Proposal.dDrive.exists) {
        $lines += 'No D drive detected. Migration steps cannot be planned.'
    }
    elseif ($folderCandidates.Count -eq 0 -and $fileCandidates.Count -eq 0) {
        $lines += 'No significant candidates found with current thresholds.'
    }
    else {
        if ($folderCandidates.Count -gt 0) {
            $lines += '## Folder Candidates'
            $lines += ''

            $orderedFolders = $folderCandidates | Sort-Object -Property sizeBytes -Descending
            $idx = 1
            foreach ($item in $orderedFolders) {
                $lines += ('### {0}. {1}' -f $idx, $item.path)
                $lines += ('- Size: {0}' -f (Format-Bytes ([double]$item.sizeBytes)))
                $lines += ('- Destination: {0}' -f $item.suggestedDest)
                $lines += '- Suggested link type: junction'
                $lines += '- Steps:'
                $lines += ('  1. Move-Item -LiteralPath "{0}" -Destination "{1}"' -f $item.path, $item.suggestedDest)
                $lines += ('  2. New-Item -ItemType Junction -Path "{0}" -Target "{1}"' -f $item.path, $item.suggestedDest)
                $lines += '- Rollback:'
                $lines += ('  1. Remove-Item -LiteralPath "{0}" -Force' -f $item.path)
                $lines += ('  2. Move-Item -LiteralPath "{0}" -Destination "{1}"' -f $item.suggestedDest, $item.path)
                $lines += ''
                $idx += 1
            }
        }

        if ($fileCandidates.Count -gt 0) {
            $lines += '## File Candidates'
            $lines += ''

            $orderedFiles = $fileCandidates | Sort-Object -Property sizeBytes -Descending
            $idx = 1
            foreach ($item in $orderedFiles) {
                $lines += ('### {0}. {1}' -f $idx, $item.path)
                $lines += ('- Size: {0}' -f (Format-Bytes ([double]$item.sizeBytes)))
                $lines += ('- Destination: {0}' -f $item.suggestedDest)
                $lines += '- Suggested link type: symbolic link (file)'
                $lines += '- Steps:'
                $lines += ('  1. Move-Item -LiteralPath "{0}" -Destination "{1}"' -f $item.path, $item.suggestedDest)
                $lines += ('  2. New-Item -ItemType SymbolicLink -Path "{0}" -Target "{1}"' -f $item.path, $item.suggestedDest)
                $lines += '- Rollback:'
                $lines += ('  1. Remove-Item -LiteralPath "{0}" -Force' -f $item.path)
                $lines += ('  2. Move-Item -LiteralPath "{0}" -Destination "{1}"' -f $item.suggestedDest, $item.path)
                $lines += ''
                $idx += 1
            }
        }
    }

    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Build-AnalyzeResult {
    param(
        [int]$Top = 20,
        [switch]$IncludeMoveToD,
        [switch]$IncludePagingAssessment,
        [switch]$AutoSetupPagingToD,
        [int]$PagingInitialMB = 0,
        [int]$PagingMaximumMB = 0,
        [double]$PagingDMinFreeGB = 20,
        [double]$MoveFolderGB = 2,
        [double]$MoveFileGB = 1,
        [double]$DRecommendedFreeGB = 50
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $drive = Get-DriveSummary

    Write-Host "Scanning top-level folders on C:\ ..."
    $rootFolders = Get-ChildItem -LiteralPath 'C:\' -Directory -Force -ErrorAction SilentlyContinue

    $rootStats = foreach ($folder in $rootFolders) {
        $size = Get-DirectorySizeBytes -Path $folder.FullName
        [pscustomobject]@{
            path      = $folder.FullName
            sizeBytes = [double]$size
        }
    }

    $topRootFolders = $rootStats |
        Sort-Object -Property sizeBytes -Descending |
        Select-Object -First $Top

    Write-Host "Measuring cleanup candidate locations ..."
    $candidateStats = foreach ($candidatePath in (Get-CleanupCandidatePaths)) {
        if (Test-Path -LiteralPath $candidatePath) {
            $size = Get-DirectorySizeBytes -Path $candidatePath
            [pscustomobject]@{
                path              = $candidatePath
                sizeBytes         = [double]$size
                recommendedAction = 'Temp cleanup'
            }
        }
    }

    $cleanupCandidates = $candidateStats |
        Sort-Object -Property sizeBytes -Descending |
        Select-Object -First $Top

    Write-Host "Collecting Windows recovery and hibernation information ..."
    $winRecovery = Get-WindowsRecoveryInfo
    $hibernation = Get-HibernationInfo

    Write-Host "Scanning user profile for significant folders/files ..."
    $userProfileUsage = Get-UserProfileHeavyUsage -Top $Top

    $moveToDProposal = $null
    if ($IncludeMoveToD) {
        Write-Host "Assessing potential move-to-D opportunities with links ..."
        $moveToDProposal = Get-MoveToDProposal -UserProfileUsage $userProfileUsage -MinFolderGB $MoveFolderGB -MinFileGB $MoveFileGB -MinRecommendedFreeGB $DRecommendedFreeGB
    }

    $pagingAssessment = $null
    $pagingSetup = $null
    if ($IncludePagingAssessment -or $AutoSetupPagingToD) {
        Write-Host "Assessing paging file configuration ..."
        $pagingAssessment = Get-PagingFileAssessment -DMinFreeGB $PagingDMinFreeGB

        if ($AutoSetupPagingToD) {
            Write-Host "Attempting automatic paging file setup on D: ..."
            try {
                $pagingSetup = Set-PagingFileOnD -InitialMB $PagingInitialMB -MaximumMB $PagingMaximumMB -DMinFreeGB $PagingDMinFreeGB
                $pagingAssessment = Get-PagingFileAssessment -DMinFreeGB $PagingDMinFreeGB
            }
            catch {
                $pagingSetup = [pscustomobject]@{
                    changed        = $false
                    rebootRequired = $false
                    message        = $_.Exception.Message
                    appliedAt      = (Get-Date).ToString('o')
                }
            }
        }
    }

    $watch.Stop()

    return [pscustomobject]@{
        timestamp         = (Get-Date).ToString('o')
        durationSeconds   = [double]$watch.Elapsed.TotalSeconds
        drive             = $drive
        topRootFolders    = $topRootFolders
        cleanupCandidates = $cleanupCandidates
        windowsRecovery   = $winRecovery
        hibernation       = $hibernation
        userProfileUsage  = $userProfileUsage
        moveToDProposal   = $moveToDProposal
        pagingAssessment  = $pagingAssessment
        pagingSetup       = $pagingSetup
    }
}

function Build-ProfilePagingResult {
    param(
        [int]$Top = 20,
        [switch]$IncludePagingAssessment,
        [switch]$AutoSetupPagingToD,
        [int]$PagingInitialMB = 0,
        [int]$PagingMaximumMB = 0,
        [double]$PagingDMinFreeGB = 20
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "Scanning user profile for top folders/files ..."
    $userProfileUsage = Get-UserProfileHeavyUsage -Top $Top

    $pagingAssessment = $null
    $pagingSetup = $null

    if ($IncludePagingAssessment -or $AutoSetupPagingToD) {
        Write-Host "Assessing paging file configuration ..."
        $pagingAssessment = Get-PagingFileAssessment -DMinFreeGB $PagingDMinFreeGB

        if ($AutoSetupPagingToD) {
            Write-Host "Attempting automatic paging file setup on D: ..."
            try {
                $pagingSetup = Set-PagingFileOnD -InitialMB $PagingInitialMB -MaximumMB $PagingMaximumMB -DMinFreeGB $PagingDMinFreeGB
                $pagingAssessment = Get-PagingFileAssessment -DMinFreeGB $PagingDMinFreeGB
            }
            catch {
                $pagingSetup = [pscustomobject]@{
                    changed        = $false
                    rebootRequired = $false
                    message        = $_.Exception.Message
                    appliedAt      = (Get-Date).ToString('o')
                }
            }
        }
    }

    $watch.Stop()

    return [pscustomobject]@{
        timestamp        = (Get-Date).ToString('o')
        durationSeconds  = [double]$watch.Elapsed.TotalSeconds
        userProfileUsage = $userProfileUsage
        pagingAssessment = $pagingAssessment
        pagingSetup      = $pagingSetup
    }
}

function Merge-History {
    param(
        $ExistingIndex,
        $AnalyzeResult
    )

    $history = @()
    if ($null -ne $ExistingIndex -and $null -ne $ExistingIndex.history) {
        $history = Ensure-Array -Value $ExistingIndex.history
    }

    $largest = $null
    if ($AnalyzeResult.cleanupCandidates -and $AnalyzeResult.cleanupCandidates.Count -gt 0) {
        $largest = $AnalyzeResult.cleanupCandidates | Sort-Object sizeBytes -Descending | Select-Object -First 1
    }

    $historyEntry = [pscustomobject]@{
        timestamp            = $AnalyzeResult.timestamp
        durationSeconds      = [double]$AnalyzeResult.durationSeconds
        freeGB               = [double]$AnalyzeResult.drive.freeGB
        usedGB               = [double]$AnalyzeResult.drive.usedGB
        largestCandidatePath = if ($largest) { $largest.path } else { $null }
        largestCandidateBytes = if ($largest) { [double]$largest.sizeBytes } else { 0 }
        bigWins              = @($AnalyzeResult.cleanupCandidates | Select-Object -First 3)
    }

    $history += $historyEntry

    $history = $history | Sort-Object -Property timestamp -Descending | Select-Object -First 50
    return $history
}

function Get-BigWinsDelta {
    param(
        $CurrentCandidates,
        $PreviousCandidates
    )

    if ($null -eq $PreviousCandidates -or $PreviousCandidates.Count -eq 0) {
        return @()
    }

    $prevMap = @{}
    foreach ($item in $PreviousCandidates) {
        $prevMap[$item.path] = [double]$item.sizeBytes
    }

    $wins = @()
    foreach ($item in $CurrentCandidates) {
        if ($prevMap.ContainsKey($item.path)) {
            $saved = $prevMap[$item.path] - [double]$item.sizeBytes
            if ($saved -gt 0) {
                $wins += [pscustomobject]@{
                    path       = $item.path
                    savedBytes = [double]$saved
                }
            }
        }
    }

    return $wins | Sort-Object -Property savedBytes -Descending
}

function Show-AnalyzeSummary {
    param($AnalyzeResult, $BigWins)

    Write-Host ""
    Write-Host "=== C: Drive Summary ==="
    Write-Host ("Used: {0} / {1} | Free: {2}" -f (Format-Bytes $AnalyzeResult.drive.usedBytes), (Format-Bytes $AnalyzeResult.drive.totalBytes), (Format-Bytes $AnalyzeResult.drive.freeBytes))
    Write-Host ("Scan took: {0:N2}s" -f $AnalyzeResult.durationSeconds)

    Write-Host ""
    Write-Host "Top root folders by size:"
    $AnalyzeResult.topRootFolders |
        Select-Object @{ Name = 'Path'; Expression = { $_.path } },
            @{ Name = 'Size'; Expression = { Format-Bytes $_.sizeBytes } } |
        Format-Table -AutoSize

    Write-Host ""
    Write-Host "Cleanup candidates (potential wins):"
    $AnalyzeResult.cleanupCandidates |
        Select-Object @{ Name = 'Path'; Expression = { $_.path } },
            @{ Name = 'Size'; Expression = { Format-Bytes $_.sizeBytes } },
            recommendedAction |
        Format-Table -AutoSize

    Write-Host ""
    Write-Host "System feature space checks:"
    if ($AnalyzeResult.windowsRecovery) {
        Write-Host ("Windows Recovery: {0}, estimated file size: {1}" -f $AnalyzeResult.windowsRecovery.status, (Format-Bytes ([double]$AnalyzeResult.windowsRecovery.sizeBytes)))
        Write-Host ("Recommendation: {0}" -f $AnalyzeResult.windowsRecovery.suggestion)
    }
    if ($AnalyzeResult.hibernation) {
        Write-Host ("Hibernation file: {0}, size: {1}" -f $AnalyzeResult.hibernation.path, (Format-Bytes ([double]$AnalyzeResult.hibernation.sizeBytes)))
        Write-Host ("Recommendation: {0}" -f $AnalyzeResult.hibernation.suggestion)
    }

    if ($AnalyzeResult.userProfileUsage) {
        $topFolders = Ensure-Array -Value $AnalyzeResult.userProfileUsage.topFolders
        $significantFiles = Ensure-Array -Value ($AnalyzeResult.userProfileUsage.topFiles | Where-Object { [double]$_.sizeBytes -ge 500MB } | Select-Object -First 10)

        Write-Host ""
        Write-Host ("Top user profile folders by size under {0}:" -f $AnalyzeResult.userProfileUsage.profilePath)
        if ($topFolders.Count -gt 0) {
            $topFolders |
                Select-Object @{ Name = 'Path'; Expression = { $_.path } },
                    @{ Name = 'Size'; Expression = { Format-Bytes ([double]$_.sizeBytes) } } |
                Format-Table -AutoSize
        }
        else {
            Write-Host "None found above threshold."
        }

        Write-Host ""
        Write-Host "Significant user profile files (>= 500 MB):"
        if ($significantFiles.Count -gt 0) {
            $significantFiles |
                Select-Object @{ Name = 'Path'; Expression = { $_.path } },
                    @{ Name = 'Size'; Expression = { Format-Bytes ([double]$_.sizeBytes) } } |
                Format-Table -AutoSize
        }
        else {
            Write-Host "None found above threshold."
        }
    }

    if ($AnalyzeResult.pagingAssessment) {
        $paging = $AnalyzeResult.pagingAssessment
        Write-Host ""
        Write-Host "Paging file assessment:"
        Write-Host ("Status: {0}" -f $paging.status)
        Write-Host ("Automatic management enabled: {0}" -f $paging.autoManaged)
        Write-Host ("Detected RAM: {0} MB" -f $paging.ramMB)
        Write-Host ("Recommendation: {0}" -f $paging.recommendation)

        $settings = Ensure-Array -Value $paging.settings
        $usage = Ensure-Array -Value $paging.usage

        Write-Host ""
        Write-Host "Current paging file settings:"
        if ($settings.Count -gt 0) {
            $settings | Format-Table -AutoSize
        }
        else {
            Write-Host "No explicit Win32_PageFileSetting entries found (system-managed may be active)."
        }

        Write-Host ""
        Write-Host "Current paging file allocation/usage:"
        if ($usage.Count -gt 0) {
            $usage |
                Select-Object Name,
                    @{ Name = 'AllocatedMB'; Expression = { $_.AllocatedBaseSize } },
                    @{ Name = 'CurrentUsageMB'; Expression = { $_.CurrentUsage } },
                    @{ Name = 'PeakUsageMB'; Expression = { $_.PeakUsage } },
                    TempPageFile |
                Format-Table -AutoSize
        }
        else {
            Write-Host "No paging usage information returned by Win32_PageFileUsage."
        }
    }

    if ($AnalyzeResult.pagingSetup) {
        Write-Host ""
        Write-Host "Paging file auto-setup result:"
        Write-Host ("Changed: {0}" -f $AnalyzeResult.pagingSetup.changed)
        Write-Host ("Message: {0}" -f $AnalyzeResult.pagingSetup.message)
        if ($AnalyzeResult.pagingSetup.rebootRequired) {
            Write-Host "Reboot required: True"
        }
    }

    if ($AnalyzeResult.moveToDProposal) {
        $proposal = $AnalyzeResult.moveToDProposal
        Write-Host ""
        Write-Host "Move-to-D assessment (proposal):"
        if (-not $proposal.dDrive.exists) {
            Write-Host "D: drive was not detected. No migration proposals generated."
        }
        else {
            Write-Host ("D: free space: {0} of {1}" -f (Format-Bytes ([double]$proposal.dDrive.freeBytes)), (Format-Bytes ([double]$proposal.dDrive.totalBytes)))
            Write-Host ("Assessment: {0}" -f $proposal.dDriveStatus)
            Write-Host ("Potential movable size: {0}" -f (Format-Bytes ([double]$proposal.totalProposedBytes)))

            $folderCandidates = Ensure-Array -Value $proposal.folderCandidates
            $fileCandidates = Ensure-Array -Value $proposal.fileCandidates

            Write-Host ""
            Write-Host "Recommended large folders to move then junction-link:" 
            if ($folderCandidates.Count -gt 0) {
                $folderCandidates |
                    Select-Object @{ Name = 'CurrentPath'; Expression = { $_.path } },
                        @{ Name = 'Size'; Expression = { Format-Bytes ([double]$_.sizeBytes) } },
                        @{ Name = 'SuggestedDPath'; Expression = { $_.suggestedDest } },
                        linkType |
                    Format-Table -AutoSize
            }
            else {
                Write-Host "No folder candidates above threshold."
            }

            Write-Host ""
            Write-Host "Recommended large files to move then file-symlink:" 
            if ($fileCandidates.Count -gt 0) {
                $fileCandidates |
                    Select-Object @{ Name = 'CurrentPath'; Expression = { $_.path } },
                        @{ Name = 'Size'; Expression = { Format-Bytes ([double]$_.sizeBytes) } },
                        @{ Name = 'SuggestedDPath'; Expression = { $_.suggestedDest } },
                        linkType |
                    Format-Table -AutoSize
            }
            else {
                Write-Host "No file candidates above threshold."
            }

            Write-Host ""
            Write-Host "Example (folder) manual migration steps:"
            Write-Host '1) Move-Item -LiteralPath "C:\path\big-folder" -Destination "D:\MovedFromC\big-folder"'
            Write-Host '2) New-Item -ItemType Junction -Path "C:\path\big-folder" -Target "D:\MovedFromC\big-folder"'
            Write-Host "Example (file) manual migration steps:"
            Write-Host '1) Move-Item -LiteralPath "C:\path\big-file.bin" -Destination "D:\MovedFromC\Files\big-file.bin"'
            Write-Host '2) New-Item -ItemType SymbolicLink -Path "C:\path\big-file.bin" -Target "D:\MovedFromC\Files\big-file.bin"'
        }
    }

    if ($BigWins -and $BigWins.Count -gt 0) {
        Write-Host ""
        Write-Host "Big wins since previous scan:"
        $BigWins |
            Select-Object @{ Name = 'Path'; Expression = { $_.path } },
                @{ Name = 'Saved'; Expression = { Format-Bytes $_.savedBytes } } |
            Format-Table -AutoSize
    }
}

function Invoke-Cleanup {
    param(
        [int]$OlderThanDays,
        [switch]$ApplyChanges
    )

    $targets = Get-CleanupCandidatePaths
    $now = Get-Date
    $cutoff = $now.AddDays(-1 * [math]::Abs($OlderThanDays))

    $results = @()

    foreach ($target in $targets) {
        if (-not (Test-Path -LiteralPath $target)) {
            continue
        }

        Write-Host "Evaluating cleanup target: $target"

        $items = Ensure-Array -Value (
            Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt $cutoff }
        )

        $bytes = Get-SumProperty -Items $items -Property 'Length'

        $deleted = 0
        if ($ApplyChanges -and $items.Count -gt 0) {
            foreach ($item in $items) {
                try {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Stop
                    $deleted += [double]$item.Length
                }
                catch {
                    continue
                }
            }
        }

        $results += [pscustomobject]@{
            path             = $target
            candidateBytes   = [double]$bytes
            deletedBytes     = [double]$deleted
            olderThanDays    = [int]$OlderThanDays
            mode             = if ($ApplyChanges) { 'execute' } else { 'dry-run' }
            evaluatedAt      = (Get-Date).ToString('o')
        }
    }

    return $results
}

$existingIndex = Read-Index -Path $IndexPath

if ($Phase -eq 'Analyze') {
    if ($ReuseIndex -and -not $ForceRescan) {
        if ($null -eq $existingIndex -or $null -eq $existingIndex.lastScan) {
            Write-Warning "No existing index found to reuse. Running full analyze scan now."
        }
        else {
            Write-Host "Reusing existing index (fast mode): $IndexPath"
            Write-Host ""
            Write-Host "Last scan timestamp: $($existingIndex.lastScan.timestamp)"
            Write-Host ("Last scan duration: {0:N2}s" -f [double]$existingIndex.lastScan.durationSeconds)

            if ($existingIndex.lastScan.cleanupCandidates) {
                Write-Host ""
                Write-Host "Last known cleanup candidates:"
                $existingIndex.lastScan.cleanupCandidates |
                    Select-Object @{ Name = 'Path'; Expression = { $_.path } },
                        @{ Name = 'Size'; Expression = { Format-Bytes ([double]$_.sizeBytes) } },
                        recommendedAction |
                    Format-Table -AutoSize
            }

            Write-Host ""
            Show-History -Index $existingIndex
            return
        }
    }

    $previousCandidates = $null
    if ($null -ne $existingIndex -and $null -ne $existingIndex.lastScan) {
        $previousCandidates = $existingIndex.lastScan.cleanupCandidates
    }

    $analyzeResult = Build-AnalyzeResult -Top $TopCount -IncludeMoveToD:$AssessMoveToD -IncludePagingAssessment:$AssessPagingFile -AutoSetupPagingToD:$AutoSetupPagingOnD -PagingInitialMB $PagingFileInitialMB -PagingMaximumMB $PagingFileMaximumMB -PagingDMinFreeGB $PagingDDriveMinFreeGB -MoveFolderGB $MinMoveFolderGB -MoveFileGB $MinMoveFileGB -DRecommendedFreeGB $DDriveRecommendedFreeGB
    $wins = Get-BigWinsDelta -CurrentCandidates $analyzeResult.cleanupCandidates -PreviousCandidates $previousCandidates
    $history = Merge-History -ExistingIndex $existingIndex -AnalyzeResult $analyzeResult

    $indexData = [pscustomobject]@{
        version          = 1
        generatedAt      = (Get-Date).ToString('o')
        indexPath        = $IndexPath
        schema           = 'cdrive-storage-index-v1'
        lastScan         = $analyzeResult
        bigWinsSinceLast = $wins
        history          = $history
    }

    Write-Index -Data $indexData -Path $IndexPath
    Show-AnalyzeSummary -AnalyzeResult $analyzeResult -BigWins $wins

    Write-Host ""
    Write-Host "Index updated: $IndexPath"
    Write-Host "Tip: rerun with -ReuseIndex for instant results and history review."
    return
}

if ($Phase -eq 'Cleanup') {
    Write-Host "Cleanup phase started. Default is dry-run; use -Execute to delete files."
    Write-Host ("Policy: remove files older than {0} days from known temp locations." -f $MinAgeDays)

    $cleanupResults = Invoke-Cleanup -OlderThanDays $MinAgeDays -ApplyChanges:$Execute

    $cleanupResults = Ensure-Array -Value $cleanupResults
    if ($cleanupResults.Count -eq 0) {
        Write-Host "No cleanup targets found."
        return
    }

    Write-Host ""
    Write-Host "Cleanup report:"
    $cleanupResults |
        Select-Object path,
            @{ Name = 'Candidate'; Expression = { Format-Bytes $_.candidateBytes } },
            @{ Name = 'Deleted'; Expression = { Format-Bytes $_.deletedBytes } },
            mode,
            olderThanDays |
        Format-Table -AutoSize

    $totalCandidate = Get-SumProperty -Items $cleanupResults -Property 'candidateBytes'
    $totalDeleted = Get-SumProperty -Items $cleanupResults -Property 'deletedBytes'

    Write-Host ""
    Write-Host ("Total candidate space: {0}" -f (Format-Bytes $totalCandidate))
    if ($Execute) {
        Write-Host ("Total reclaimed space: {0}" -f (Format-Bytes $totalDeleted))
    }
    else {
        Write-Host "No files deleted (dry-run mode)."
    }

    # Store cleanup run in history as well.
    if ($null -eq $existingIndex) {
        $existingIndex = [pscustomobject]@{
            version          = 1
            generatedAt      = (Get-Date).ToString('o')
            indexPath        = $IndexPath
            schema           = 'cdrive-storage-index-v1'
            lastScan         = $null
            bigWinsSinceLast = @()
            history          = @()
        }
    }

    $cleanupEntry = [pscustomobject]@{
        timestamp            = (Get-Date).ToString('o')
        durationSeconds      = 0
        freeGB               = (Get-DriveSummary).freeGB
        usedGB               = (Get-DriveSummary).usedGB
        largestCandidatePath = 'cleanup-run'
        largestCandidateBytes = [double]$totalCandidate
        bigWins              = @($cleanupResults)
        cleanupMode          = if ($Execute) { 'execute' } else { 'dry-run' }
    }

    $combinedHistory = @()
    if ($existingIndex.history) {
        $combinedHistory += Ensure-Array -Value $existingIndex.history
    }
    $combinedHistory += $cleanupEntry
    $combinedHistory = $combinedHistory | Sort-Object -Property timestamp -Descending | Select-Object -First 50

    $existingIndex.generatedAt = (Get-Date).ToString('o')
    $existingIndex.history = $combinedHistory

    Write-Index -Data $existingIndex -Path $IndexPath
    Write-Host "Cleanup history appended to index."
}

if ($Phase -eq 'PlanMove') {
    Write-Host "PlanMove phase started. Building migration plan artifact."

    $proposal = $null
    $source = 'new-scan'

    if ($ReuseIndex -and -not $ForceRescan -and $existingIndex -and $existingIndex.lastScan -and (Test-ObjectProperty -Object $existingIndex.lastScan -PropertyName 'moveToDProposal') -and $existingIndex.lastScan.moveToDProposal) {
        $proposal = $existingIndex.lastScan.moveToDProposal
        $source = 'reused-index'
    }
    else {
        $analyzeResult = Build-AnalyzeResult -Top $TopCount -IncludeMoveToD -IncludePagingAssessment:$AssessPagingFile -AutoSetupPagingToD:$AutoSetupPagingOnD -PagingInitialMB $PagingFileInitialMB -PagingMaximumMB $PagingFileMaximumMB -PagingDMinFreeGB $PagingDDriveMinFreeGB -MoveFolderGB $MinMoveFolderGB -MoveFileGB $MinMoveFileGB -DRecommendedFreeGB $DDriveRecommendedFreeGB
        $previousCandidates = $null
        if ($existingIndex -and $existingIndex.lastScan) {
            $previousCandidates = $existingIndex.lastScan.cleanupCandidates
        }

        $wins = Get-BigWinsDelta -CurrentCandidates $analyzeResult.cleanupCandidates -PreviousCandidates $previousCandidates
        $history = Merge-History -ExistingIndex $existingIndex -AnalyzeResult $analyzeResult

        $indexData = [pscustomobject]@{
            version          = 1
            generatedAt      = (Get-Date).ToString('o')
            indexPath        = $IndexPath
            schema           = 'cdrive-storage-index-v1'
            lastScan         = $analyzeResult
            bigWinsSinceLast = $wins
            history          = $history
        }

        Write-Index -Data $indexData -Path $IndexPath
        $proposal = $analyzeResult.moveToDProposal
    }

    if (-not $proposal) {
        Write-Warning "Move-to-D proposal data is not available. Run Analyze with -AssessMoveToD first."
        return
    }

    Write-MovePlan -Proposal $proposal -Path $PlanPath

    Write-Host ""
    Write-Host ("Plan source: {0}" -f $source)
    Write-Host ("Plan artifact written: {0}" -f $PlanPath)
    Write-Host ("Potential movable size in plan: {0}" -f (Format-Bytes ([double]$proposal.totalProposedBytes)))
    return
}

if ($Phase -eq 'ProfilePaging') {
    Write-Host "ProfilePaging phase started."

    $profilePagingResult = Build-ProfilePagingResult -Top $TopCount -IncludePagingAssessment:$AssessPagingFile -AutoSetupPagingToD:$AutoSetupPagingOnD -PagingInitialMB $PagingFileInitialMB -PagingMaximumMB $PagingFileMaximumMB -PagingDMinFreeGB $PagingDDriveMinFreeGB

    Write-Host ""
    Write-Host ("ProfilePaging scan took: {0:N2}s" -f $profilePagingResult.durationSeconds)

    if ($profilePagingResult.userProfileUsage) {
        $topFolders = Ensure-Array -Value $profilePagingResult.userProfileUsage.topFolders
        $topFiles = Ensure-Array -Value $profilePagingResult.userProfileUsage.topFiles

        Write-Host ""
        Write-Host ("Top {0} user profile folders by size under {1}:" -f $TopCount, $profilePagingResult.userProfileUsage.profilePath)
        if ($topFolders.Count -gt 0) {
            $topFolders |
                Select-Object @{ Name = 'Path'; Expression = { $_.path } },
                    @{ Name = 'Size'; Expression = { Format-Bytes ([double]$_.sizeBytes) } } |
                Format-Table -AutoSize
        }
        else {
            Write-Host "No profile folders found."
        }

        Write-Host ""
        Write-Host ("Top {0} user profile files by size:" -f $TopCount)
        if ($topFiles.Count -gt 0) {
            $topFiles |
                Select-Object @{ Name = 'Path'; Expression = { $_.path } },
                    @{ Name = 'Size'; Expression = { Format-Bytes ([double]$_.sizeBytes) } } |
                Format-Table -AutoSize
        }
        else {
            Write-Host "No profile files found."
        }
    }

    if ($profilePagingResult.pagingAssessment) {
        $paging = $profilePagingResult.pagingAssessment

        Write-Host ""
        Write-Host "Paging file assessment:"
        Write-Host ("Status: {0}" -f $paging.status)
        Write-Host ("Automatic management enabled: {0}" -f $paging.autoManaged)
        Write-Host ("Detected RAM: {0} MB" -f $paging.ramMB)
        Write-Host ("Recommendation: {0}" -f $paging.recommendation)

        $settings = Ensure-Array -Value $paging.settings
        $usage = Ensure-Array -Value $paging.usage

        Write-Host ""
        Write-Host "Current paging file settings:"
        if ($settings.Count -gt 0) {
            $settings | Format-Table -AutoSize
        }
        else {
            Write-Host "No explicit Win32_PageFileSetting entries found (system-managed may be active)."
        }

        Write-Host ""
        Write-Host "Current paging file allocation/usage:"
        if ($usage.Count -gt 0) {
            $usage |
                Select-Object Name,
                    @{ Name = 'AllocatedMB'; Expression = { $_.AllocatedBaseSize } },
                    @{ Name = 'CurrentUsageMB'; Expression = { $_.CurrentUsage } },
                    @{ Name = 'PeakUsageMB'; Expression = { $_.PeakUsage } },
                    TempPageFile |
                Format-Table -AutoSize
        }
        else {
            Write-Host "No paging usage information returned by Win32_PageFileUsage."
        }
    }

    if ($profilePagingResult.pagingSetup) {
        Write-Host ""
        Write-Host "Paging file auto-setup result:"
        Write-Host ("Changed: {0}" -f $profilePagingResult.pagingSetup.changed)
        Write-Host ("Message: {0}" -f $profilePagingResult.pagingSetup.message)
        if ($profilePagingResult.pagingSetup.rebootRequired) {
            Write-Host "Reboot required: True"
        }
    }

    return
}
