@echo off
setlocal EnableExtensions

set "WFW_GUI_SCRIPT=%~f0"
set "WFW_GUI_SCRIPT_DIR=%~dp0"
set "WFW_GUI_ARGS=%*"
set "WFW_GUI_NEEDS_ADMIN=0"
if /I "%~1"=="block" set "WFW_GUI_NEEDS_ADMIN=1"
if /I "%~1"=="unblock" set "WFW_GUI_NEEDS_ADMIN=1"
if /I "%~1"=="deleteall" set "WFW_GUI_NEEDS_ADMIN=1"
set "WFW_GUI_ACTION=%~1"
set "WFW_GUI_PATH="
if not "%~1"=="" shift
:collectArgs
if "%~1"=="" goto argsCollected
if defined WFW_GUI_PATH (
    set "WFW_GUI_PATH=%WFW_GUI_PATH% %~1"
) else (
    set "WFW_GUI_PATH=%~1"
)
shift
goto collectArgs
:argsCollected

rem =========================================================
rem Elevate only for direct block/unblock operations.
rem =========================================================
net session >nul 2>&1
if %errorlevel% neq 0 if "%WFW_GUI_NEEDS_ADMIN%"=="1" (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:ComSpec -ArgumentList ('/c ""' + $env:WFW_GUI_SCRIPT + '"" ' + $env:WFW_GUI_ARGS) -Verb RunAs -WorkingDirectory $env:WFW_GUI_SCRIPT_DIR"
    exit /b
)

cd /d "%~dp0"

powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $path=$env:WFW_GUI_SCRIPT; $lines=Get-Content -LiteralPath $path; $marker=Select-String -LiteralPath $path -Pattern '^:POWERSHELL:$' | Select-Object -First 1; if(-not $marker){ throw 'PowerShell section not found.' }; $code=$lines[$marker.LineNumber..($lines.Count - 1)] -join [Environment]::NewLine; $scriptArgs=@(); if(-not [string]::IsNullOrWhiteSpace($env:WFW_GUI_ACTION)){ $scriptArgs += $env:WFW_GUI_ACTION }; if(-not [string]::IsNullOrWhiteSpace($env:WFW_GUI_PATH)){ $scriptArgs += $env:WFW_GUI_PATH }; & ([scriptblock]::Create($code)) @scriptArgs"
exit /b %errorlevel%

:POWERSHELL:
param(
    [string]$Action,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$PathParts
)

$ErrorActionPreference = 'Stop'

$ToolName = 'WinFirewalk'
$ToolVersion = '1.0'
$ProjectUrl = 'https://github.com/jgdf42/winfirewalk'
$StateFileName = 'WinFirewalk.rules.json'
$UndoFileName = 'WinFirewalk-Unblock.cmd'
$ScriptPath = $env:WFW_GUI_SCRIPT
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = $MyInvocation.MyCommand.Path
}
$ScriptFolder = Split-Path -Parent $ScriptPath

function Normalize-Path {
    param([Parameter(Mandatory)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $full = [System.IO.Path]::GetFullPath($expanded)
    $root = [System.IO.Path]::GetPathRoot($full)

    while ($full.EndsWith('\') -and $full.Length -gt $root.Length) {
        $full = $full.Substring(0, $full.Length - 1)
    }

    return $full
}

function ConvertTo-TargetPath {
    param([string]$InputPath)

    $text = ''
    if ($null -ne $InputPath) {
        $text = $InputPath.Trim()
    }

    if ($text.Length -ge 2) {
        $first = $text.Substring(0, 1)
        $last = $text.Substring($text.Length - 1, 1)
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $text = $text.Substring(1, $text.Length - 2).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'Enter or choose a target folder.'
    }

    return Resolve-WinFirewalkTargetPath -InputPath $text
}

function Test-WinFirewalkNonFileTarget {
    param([string]$TargetPath)

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return $false
    }

    $text = $TargetPath.Trim()
    if ($text -match '^[A-Za-z]:[\\/]') {
        return $false
    }
    if ($text.StartsWith('\\')) {
        return $false
    }

    return ($text -match '^[A-Za-z][A-Za-z0-9+.-]*:')
}

function Get-WinFirewalkShortcutRejectReason {
    param(
        [string]$TargetPath,
        [string]$Arguments
    )

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return 'This shortcut does not point directly to a local file or folder.'
    }

    if (Test-WinFirewalkNonFileTarget -TargetPath $TargetPath) {
        return "This shortcut uses a protocol or shell target instead of a local file: $TargetPath"
    }

    if ($Arguments -match '(?i)shell:AppsFolder') {
        return 'This looks like a Microsoft Store app shortcut. Choose the game install folder manually instead.'
    }

    if ($Arguments -match '(?i)[A-Za-z][A-Za-z0-9+.-]*://') {
        return "This shortcut uses a launcher or URL protocol instead of a direct game path: $Arguments"
    }

    $targetName = Split-Path -Leaf $TargetPath
    if ($targetName -ieq 'steam.exe' -and $Arguments -match '(?i)(steam://|-applaunch|\brungameid\b)') {
        return 'This looks like a Steam launcher shortcut. Choose the game install folder manually instead.'
    }

    if ($targetName -ieq 'explorer.exe' -and $Arguments -match '(?i)shell:AppsFolder') {
        return 'This looks like a Microsoft Store app shortcut. Choose the game install folder manually instead.'
    }

    return $null
}

function Resolve-WinFirewalkShortcutTarget {
    param([Parameter(Mandatory)][string]$ShortcutPath)

    $shell = $null
    $shortcut = $null
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $targetPath = $shortcut.TargetPath
        $arguments = $shortcut.Arguments

        $rejectReason = Get-WinFirewalkShortcutRejectReason -TargetPath $targetPath -Arguments $arguments
        if ($rejectReason) {
            throw $rejectReason
        }

        return Resolve-WinFirewalkTargetPath -InputPath $targetPath -FromShortcut
    }
    finally {
        foreach ($comObject in @($shortcut, $shell)) {
            if ($comObject) {
                try {
                    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($comObject) | Out-Null
                }
                catch {
                    # Best effort cleanup only.
                }
            }
        }
    }
}

function Resolve-WinFirewalkTargetPath {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [switch]$FromShortcut
    )

    if (Test-WinFirewalkNonFileTarget -TargetPath $InputPath) {
        throw "This target is not a local file or folder: $InputPath"
    }

    $full = Normalize-Path $InputPath
    if (Test-Path -LiteralPath $full -PathType Container) {
        return $full
    }

    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $item = Get-Item -LiteralPath $full
        if ($item.Extension -ieq '.lnk') {
            return Resolve-WinFirewalkShortcutTarget -ShortcutPath $item.FullName
        }

        if ($item.Extension -ieq '.exe' -or $FromShortcut) {
            return Normalize-Path (Split-Path -Parent $item.FullName)
        }

        throw "Unsupported file target: $full. Choose a folder, .exe file, or .lnk shortcut."
    }

    throw "Folder or supported file not found: $full"
}

function Get-PathHash {
    param([Parameter(Mandatory)][string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())
        $hashBytes = $sha.ComputeHash($bytes)
        return (($hashBytes[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function New-TargetContext {
    param([Parameter(Mandatory)][string]$InputPath)

    $rootPath = ConvertTo-TargetPath $InputPath
    $folderName = Split-Path -Leaf $rootPath
    if ([string]::IsNullOrWhiteSpace($folderName)) {
        $folderName = (Get-Item -LiteralPath $rootPath).Name
    }

    $pathHash = Get-PathHash $rootPath
    $safeFolderName = ($folderName -replace '[\x00-\x1F]', '_').Trim()
    if ([string]::IsNullOrWhiteSpace($safeFolderName)) {
        $safeFolderName = 'Folder'
    }
    if ($safeFolderName.Length -gt 120) {
        $safeFolderName = $safeFolderName.Substring(0, 120)
    }

    [pscustomobject]@{
        Root = $rootPath
        FolderName = $safeFolderName
        PathHash = $pathHash
        BaseDisplayName = "$ToolName - $safeFolderName"
        HashedDisplayName = "$ToolName - $safeFolderName [$pathHash]"
        StatePath = Join-Path $rootPath $StateFileName
        UndoPath = Join-Path $rootPath $UndoFileName
    }
}

function Test-IsUnderRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -eq 'Any') {
        return $false
    }

    try {
        $full = Normalize-Path $Path
    }
    catch {
        return $false
    }

    if ($Root.EndsWith('\')) {
        return $full.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)
    }

    return $full.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith("$Root\", [System.StringComparison]::OrdinalIgnoreCase)
}

function Read-State {
    param([Parameter(Mandatory)]$Context)

    if (-not (Test-Path -LiteralPath $Context.StatePath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Context.StatePath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Could not read $StateFileName. Falling back to firewall scan."
        return $null
    }
}

function Get-RulesByDisplayName {
    param([Parameter(Mandatory)][string]$DisplayName)

    $pattern = [System.Management.Automation.WildcardPattern]::Escape($DisplayName)
    @(Get-NetFirewallRule -DisplayName $pattern -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName.Equals($DisplayName, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Get-RulesByDisplayPrefix {
    param([Parameter(Mandatory)][string]$DisplayPrefix)

    $pattern = [System.Management.Automation.WildcardPattern]::Escape($DisplayPrefix) + '*'
    @(Get-NetFirewallRule -DisplayName $pattern -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName.StartsWith($DisplayPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
}

function Get-AllWinFirewalkRules {
    $displayPattern = [System.Management.Automation.WildcardPattern]::Escape($ToolName) + '*'
    $descriptionPrefix = "$ToolName block for "
    $displayRules = @(Get-NetFirewallRule -DisplayName $displayPattern -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and $_.DisplayName.StartsWith($ToolName, [System.StringComparison]::OrdinalIgnoreCase) })
    $internalRules = @(Get-NetFirewallRule -Name 'WFW-*' -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -and $_.Name.StartsWith('WFW-', [System.StringComparison]::OrdinalIgnoreCase) -and
            (
                ($_.DisplayName -and $_.DisplayName.StartsWith($ToolName, [System.StringComparison]::OrdinalIgnoreCase)) -or
                ($_.Description -and $_.Description.StartsWith($descriptionPrefix, [System.StringComparison]::OrdinalIgnoreCase))
            )
        })

    @($displayRules + $internalRules) |
        Where-Object { $_ } |
        Sort-Object -Property Name -Unique
}

function Get-WinFirewalkRootsFromRules {
    param([array]$Rules)

    $prefix = "$ToolName block for "
    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($rule in @($Rules)) {
        if ([string]::IsNullOrWhiteSpace($rule.Description)) {
            continue
        }

        if (-not $rule.Description.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $rawRoot = $rule.Description.Substring($prefix.Length).Trim()
        if ([string]::IsNullOrWhiteSpace($rawRoot)) {
            continue
        }

        try {
            $root = Normalize-Path $rawRoot
            if (Test-Path -LiteralPath $root -PathType Container) {
                $roots.Add($root)
            }
        }
        catch {
            # Ignore stale or malformed rule descriptions.
        }
    }

    @($roots | Sort-Object -Unique)
}

function Remove-AllWinFirewalkRules {
    param([scriptblock]$Log)

    Write-OperationLine $Log 'Scanning for WinFirewalk firewall rules...'
    $rules = @(Get-AllWinFirewalkRules)
    if ($rules.Count -eq 0) {
        Write-OperationLine $Log 'No WinFirewalk firewall rules were found.'
        return [pscustomobject]@{
            RulesRemoved = 0
            FilesDeleted = 0
            RootsChecked = 0
        }
    }

    Write-OperationLine $Log "Found $($rules.Count) WinFirewalk firewall rule(s)."

    $roots = @(Get-WinFirewalkRootsFromRules -Rules $rules)
    $deletedFiles = 0
    $failedFiles = 0
    if ($roots.Count -gt 0) {
        Write-OperationLine $Log "Checking $($roots.Count) folder(s) for WinFirewalk manifest and helper files..."
        foreach ($root in $roots) {
            foreach ($fileName in @($StateFileName, $UndoFileName)) {
                $cleanupPath = Join-Path $root $fileName
                if (Test-Path -LiteralPath $cleanupPath -PathType Leaf) {
                    try {
                        Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction Stop
                        $deletedFiles++
                        Write-OperationLine $Log "Deleted: $cleanupPath"
                    }
                    catch {
                        $failedFiles++
                        Write-OperationLine $Log "Could not delete: $cleanupPath"
                    }
                }
            }
        }
    }
    else {
        Write-OperationLine $Log 'No rule descriptions contained folder paths for manifest/helper cleanup.'
    }

    $removedRules = 0
    $failedRules = 0
    foreach ($rule in $rules) {
        try {
            Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop
            $removedRules++
            Write-OperationLine $Log "Removed firewall rule: $($rule.DisplayName) [$($rule.Direction)]"
        }
        catch {
            $failedRules++
            Write-OperationLine $Log "Could not remove firewall rule: $($rule.DisplayName)"
        }
    }

    Write-OperationLine $Log "Removed $removedRules firewall rule(s)."
    Write-OperationLine $Log "Deleted $deletedFiles manifest/helper file(s)."
    if ($failedRules -gt 0 -or $failedFiles -gt 0) {
        Write-OperationLine $Log "Skipped $failedRules firewall rule(s) and $failedFiles file(s) because Windows returned an error."
    }

    [pscustomobject]@{
        RulesRemoved = $removedRules
        FilesDeleted = $deletedFiles
        RootsChecked = $roots.Count
        RuleFailures = $failedRules
        FileFailures = $failedFiles
    }
}

function Get-RuleRecords {
    param([Parameter(Mandatory)][string]$DisplayName)

    $rules = @(Get-RulesByDisplayName -DisplayName $DisplayName)
    foreach ($rule in $rules) {
        $filters = @($rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)
        if ($filters.Count -eq 0) {
            [pscustomobject]@{
                Name = $rule.Name
                DisplayName = $rule.DisplayName
                Direction = $rule.Direction
                Program = $null
            }
            continue
        }

        foreach ($filter in $filters) {
            [pscustomobject]@{
                Name = $rule.Name
                DisplayName = $rule.DisplayName
                Direction = $rule.Direction
                Program = $filter.Program
            }
        }
    }
}

function Resolve-DisplayName {
    param([Parameter(Mandatory)]$Context)

    $state = Read-State -Context $Context
    if ($state -and $state.TargetRoot -and $state.DisplayName) {
        try {
            $stateRoot = Normalize-Path $state.TargetRoot
            if ($stateRoot.Equals($Context.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [string]$state.DisplayName
            }
        }
        catch {
            # Ignore stale or malformed state and re-resolve below.
        }
    }

    $baseRecords = @(Get-RuleRecords -DisplayName $Context.BaseDisplayName)
    $foreignBaseRules = @($baseRecords | Where-Object {
        $_.Program -and -not (Test-IsUnderRoot -Path $_.Program -Root $Context.Root)
    })

    if ($foreignBaseRules.Count -gt 0) {
        return $Context.HashedDisplayName
    }

    return $Context.BaseDisplayName
}

function Get-CandidateDisplayNames {
    param([Parameter(Mandatory)]$Context)

    $names = New-Object System.Collections.Generic.List[string]
    $names.Add($Context.BaseDisplayName)
    $names.Add($Context.HashedDisplayName)

    $state = Read-State -Context $Context
    if ($state -and $state.DisplayName) {
        $names.Add([string]$state.DisplayName)
    }

    @(Get-RulesByDisplayPrefix -DisplayPrefix $Context.BaseDisplayName) |
        Select-Object -ExpandProperty DisplayName -Unique |
        ForEach-Object { $names.Add([string]$_) }

    return $names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
}

function Remove-StateRules {
    param(
        $State,
        [scriptblock]$Log
    )

    if (-not $State -or -not $State.Rules) {
        return 0
    }

    $removed = 0
    foreach ($entry in @($State.Rules)) {
        if ([string]::IsNullOrWhiteSpace($entry.Name)) {
            continue
        }

        $rule = Get-NetFirewallRule -Name $entry.Name -ErrorAction SilentlyContinue
        if ($rule) {
            if ($Log) {
                $program = [string]$entry.Program
                if ([string]::IsNullOrWhiteSpace($program)) {
                    $filter = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($filter) {
                        $program = [string]$filter.Program
                    }
                }

                $direction = [string]$entry.Direction
                if ([string]::IsNullOrWhiteSpace($direction)) {
                    $direction = [string]$rule.Direction
                }

                if ([string]::IsNullOrWhiteSpace($program)) {
                    Write-OperationLine $Log "Removed firewall rule: $($rule.DisplayName) [$direction]"
                }
                else {
                    Write-OperationLine $Log "Unblocked: $program [$direction]"
                }
            }
            $rule | Remove-NetFirewallRule
            $removed++
        }
    }

    return $removed
}

function Remove-FolderRules {
    param(
        [Parameter(Mandatory)]$Context,
        [scriptblock]$Log
    )

    $removed = 0
    $candidateNames = @(Get-CandidateDisplayNames -Context $Context)

    foreach ($displayName in $candidateNames) {
        $rules = @(Get-RulesByDisplayName -DisplayName $displayName)
        foreach ($rule in $rules) {
            $filters = @($rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue)
            $matchesRoot = $false

            foreach ($filter in $filters) {
                if (Test-IsUnderRoot -Path $filter.Program -Root $Context.Root) {
                    $matchesRoot = $true
                    break
                }
            }

            if ($matchesRoot) {
                if ($Log) {
                    foreach ($filter in $filters) {
                        if (Test-IsUnderRoot -Path $filter.Program -Root $Context.Root) {
                            Write-OperationLine $Log "Unblocked: $($filter.Program) [$($rule.Direction)]"
                        }
                    }
                }
                Remove-NetFirewallRule -Name $rule.Name
                $removed++
            }
        }
    }

    return $removed
}

function Get-TargetFiles {
    param([Parameter(Mandatory)]$Context)

    @(Get-ChildItem -LiteralPath $Context.Root -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.exe', '.dll' } |
        Sort-Object FullName)
}

function Write-UndoScript {
    param([Parameter(Mandatory)]$Context)

    $scriptLiteral = $ScriptPath.Replace('"', '""')
    $content = @"
@echo off
setlocal EnableExtensions
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'"
    exit /b
)
echo Running WinFirewalk unblock for:
echo %~dp0
echo.
call "$scriptLiteral" unblock "%~dp0."
set "WFW_EXIT=%errorlevel%"
echo.
if "%WFW_EXIT%"=="0" (
    echo WinFirewalk unblock complete.
) else (
    echo WinFirewalk unblock failed with exit code %WFW_EXIT%.
)
echo.
pause
exit /b %WFW_EXIT%
"@

    Set-Content -LiteralPath $Context.UndoPath -Value $content -Encoding ASCII
}

function Write-State {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$DisplayName,
        [AllowEmptyCollection()][array]$Rules = @()
    )

    $state = [pscustomobject]@{
        Tool = $ToolName
        AppVersion = $ToolVersion
        Version = 1
        TargetRoot = $Context.Root
        DisplayName = $DisplayName
        Created = (Get-Date).ToString('o')
        Rules = $Rules
    }

    $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Context.StatePath -Encoding UTF8
}

function Add-BlockRule {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.IO.FileInfo]$File,
        [Parameter(Mandatory)][string]$Direction,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $internalName = 'WFW-{0}-{1}-{2}' -f $Context.PathHash, $Direction.ToUpperInvariant(), [guid]::NewGuid().ToString('N')
    $description = "$ToolName block for $($Context.Root)"

    New-NetFirewallRule `
        -Name $internalName `
        -DisplayName $DisplayName `
        -Description $description `
        -Direction $Direction `
        -Action Block `
        -Program $File.FullName `
        -Profile Any `
        -Enabled True `
        -ErrorAction Stop
}

function Write-OperationLine {
    param(
        [scriptblock]$Log,
        [string]$Message
    )

    if ($Log) {
        & $Log $Message
    }
    else {
        Write-Host $Message
    }
}

function Block-Folder {
    param(
        [Parameter(Mandatory)]$Context,
        [scriptblock]$Log
    )

    $displayName = Resolve-DisplayName -Context $Context
    $state = Read-State -Context $Context

    Write-OperationLine $Log ''
    Write-OperationLine $Log "Target folder: $($Context.Root)"
    Write-OperationLine $Log "Firewall rule name: $displayName"
    Write-OperationLine $Log ''
    Write-OperationLine $Log 'Removing existing rules for this folder...'

    $removedFromState = Remove-StateRules -State $state -Log $Log
    $removedByScan = Remove-FolderRules -Context $Context -Log $Log
    $removedTotal = $removedFromState + $removedByScan
    Write-OperationLine $Log "Removed $removedTotal existing rule(s)."

    $files = @(Get-TargetFiles -Context $Context)
    if ($files.Count -eq 0) {
        Write-OperationLine $Log ''
        Write-OperationLine $Log 'No blockable files were found.'
        Write-OperationLine $Log 'WinFirewalk only creates firewall rules for .exe and .dll files.'
        Write-OperationLine $Log 'Nothing was blocked because this folder and its subfolders do not contain either file type.'
        Write-State -Context $Context -DisplayName $displayName -Rules @()
        Write-UndoScript -Context $Context
        return
    }

    Write-OperationLine $Log ''
    Write-OperationLine $Log "Adding firewall blocks for $($files.Count) file(s)..."

    $createdRules = New-Object System.Collections.Generic.List[object]
    $failures = New-Object System.Collections.Generic.List[object]

    foreach ($file in $files) {
        foreach ($direction in @('Inbound', 'Outbound')) {
            try {
                $rule = Add-BlockRule -Context $Context -File $file -Direction $direction -DisplayName $displayName
                $createdRules.Add([pscustomobject]@{
                    Name = $rule.Name
                    DisplayName = $rule.DisplayName
                    Direction = $direction
                    Program = $file.FullName
                })
            }
            catch {
                $failures.Add([pscustomobject]@{
                    Direction = $direction
                    Program = $file.FullName
                    Error = $_.Exception.Message
                })
            }
        }

        Write-OperationLine $Log "Blocked: $($file.FullName)"
    }

    Write-State -Context $Context -DisplayName $displayName -Rules $createdRules.ToArray()
    Write-UndoScript -Context $Context

    Write-OperationLine $Log ''
    Write-OperationLine $Log "Created $($createdRules.Count) firewall rule(s)."
    Write-OperationLine $Log "Undo helper: $($Context.UndoPath)"
    Write-OperationLine $Log "Rule manifest: $($Context.StatePath)"

    if ($failures.Count -gt 0) {
        Write-OperationLine $Log ''
        Write-OperationLine $Log "$($failures.Count) rule(s) could not be created:"
        foreach ($failure in $failures) {
            Write-OperationLine $Log "$($failure.Direction): $($failure.Program) - $($failure.Error)"
        }
    }
}

function Unblock-Folder {
    param(
        [Parameter(Mandatory)]$Context,
        [scriptblock]$Log
    )

    $state = Read-State -Context $Context

    Write-OperationLine $Log ''
    Write-OperationLine $Log "Target folder: $($Context.Root)"
    Write-OperationLine $Log 'Removing firewall rules for this folder...'

    $removedFromState = Remove-StateRules -State $state -Log $Log
    $removedByScan = Remove-FolderRules -Context $Context -Log $Log
    $removedTotal = $removedFromState + $removedByScan

    if (Test-Path -LiteralPath $Context.StatePath) {
        Remove-Item -LiteralPath $Context.StatePath -Force
    }

    Write-OperationLine $Log "Removed $removedTotal firewall rule(s)."
}

function Show-FolderStatus {
    param(
        [Parameter(Mandatory)]$Context,
        [scriptblock]$Log
    )

    $files = @(Get-TargetFiles -Context $Context)
    $matches = New-Object System.Collections.Generic.List[object]
    $coverage = @{}

    foreach ($displayName in @(Get-CandidateDisplayNames -Context $Context)) {
        foreach ($record in @(Get-RuleRecords -DisplayName $displayName)) {
            if ($record.Program -and (Test-IsUnderRoot -Path $record.Program -Root $Context.Root)) {
                $matches.Add($record)

                try {
                    $program = Normalize-Path $record.Program
                    $direction = ([string]$record.Direction).ToLowerInvariant()
                    if ($direction -eq 'inbound' -or $direction -eq 'outbound') {
                        $coverage["$($program.ToLowerInvariant())|$direction"] = $true
                    }
                }
                catch {
                    # Ignore rule records whose program path cannot be normalized.
                }
            }
        }
    }

    $fullyBlockedFiles = 0
    $missingFiles = New-Object System.Collections.Generic.List[object]
    $coveredExpectedRules = 0

    foreach ($file in $files) {
        $filePath = Normalize-Path $file.FullName
        $baseKey = $filePath.ToLowerInvariant()
        $missingDirections = New-Object System.Collections.Generic.List[string]

        foreach ($direction in @('inbound', 'outbound')) {
            if ($coverage.ContainsKey("$baseKey|$direction")) {
                $coveredExpectedRules++
            }
            else {
                $missingDirections.Add($direction)
            }
        }

        if ($missingDirections.Count -eq 0) {
            $fullyBlockedFiles++
        }
        else {
            $missingFiles.Add([pscustomobject]@{
                Path = $filePath
                Missing = ($missingDirections -join ', ')
            })
        }
    }

    $expectedRules = $files.Count * 2
    $missingRuleCount = $expectedRules - $coveredExpectedRules

    Write-OperationLine $Log ''
    Write-OperationLine $Log "Target folder: $($Context.Root)"
    Write-OperationLine $Log "Candidate files: $($files.Count)"
    Write-OperationLine $Log "Current firewall rules for this folder: $($matches.Count)"
    Write-OperationLine $Log "Firewall coverage: $fullyBlockedFiles / $($files.Count) file(s) fully blocked"
    Write-OperationLine $Log "Missing expected block rules: $missingRuleCount"

    $state = Read-State -Context $Context
    if ($state -and $state.DisplayName) {
        Write-OperationLine $Log "Manifest rule name: $($state.DisplayName)"
    }
    else {
        Write-OperationLine $Log 'Manifest rule name: none'
    }

    if ($missingFiles.Count -gt 0) {
        Write-OperationLine $Log ''
        Write-OperationLine $Log 'Files needing refreshed block rules:'
        foreach ($missing in @($missingFiles | Select-Object -First 20)) {
            Write-OperationLine $Log "$($missing.Path) [$($missing.Missing)]"
        }
        if ($missingFiles.Count -gt 20) {
            Write-OperationLine $Log "...and $($missingFiles.Count - 20) more."
        }
        Write-OperationLine $Log ''
        Write-OperationLine $Log 'Press Block to rescan this folder and recreate rules for the current contents.'
    }
}

function New-FirewalkIcon {
    if (-not ('WinFirewalkIconNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinFirewalkIconNative
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}
'@
    }

    $bitmap = New-Object System.Drawing.Bitmap 32, 32, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $flameOuterBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 229, 78, 34))
        $flameMidBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 157, 43))
        $flameInnerBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 235, 122))
        $symbolFillBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 255, 255))
        $symbolBackPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(225, 255, 255, 255)), 5
        $symbolPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 0, 0, 0)), 4

        $outer = New-Object System.Drawing.Drawing2D.GraphicsPath
        $outer.AddBezier(16, 0, 31, 7, 32, 19, 23, 31)
        $outer.AddBezier(23, 31, 21, 25, 19, 20, 16, 16)
        $outer.AddBezier(16, 16, 12, 23, 8, 29, 4, 32)
        $outer.AddBezier(4, 32, -2, 20, 2, 9, 13, 3)
        $outer.CloseFigure()
        $graphics.FillPath($flameOuterBrush, $outer)

        $mid = New-Object System.Drawing.Drawing2D.GraphicsPath
        $mid.AddBezier(17, 4, 28, 12, 27, 22, 19, 30)
        $mid.AddBezier(19, 30, 18, 23, 16, 18, 13, 14)
        $mid.AddBezier(13, 14, 11, 22, 8, 27, 5, 30)
        $mid.AddBezier(5, 30, 3, 18, 7, 9, 15, 6)
        $mid.CloseFigure()
        $graphics.FillPath($flameMidBrush, $mid)

        $inner = New-Object System.Drawing.Drawing2D.GraphicsPath
        $inner.AddBezier(16, 10, 22, 16, 22, 24, 16, 29)
        $inner.AddBezier(16, 29, 12, 24, 13, 17, 16, 10)
        $inner.CloseFigure()
        $graphics.FillPath($flameInnerBrush, $inner)

        foreach ($pen in @($symbolBackPen, $symbolPen)) {
            $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Miter
            $pen.MiterLimit = 3
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Square
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Square
            $graphics.DrawLines($pen, @(
                (New-Object System.Drawing.Point 1, 20),
                (New-Object System.Drawing.Point 8, 10),
                (New-Object System.Drawing.Point 12, 13)
            ))
            $graphics.DrawLines($pen, @(
                (New-Object System.Drawing.Point 20, 13),
                (New-Object System.Drawing.Point 24, 10),
                (New-Object System.Drawing.Point 31, 20)
            ))
        }

        $diamondPoints = @(
            (New-Object System.Drawing.Point 7, 16),
            (New-Object System.Drawing.Point 16, 6),
            (New-Object System.Drawing.Point 25, 16),
            (New-Object System.Drawing.Point 16, 29)
        )
        $graphics.FillPolygon($symbolFillBrush, $diamondPoints)
        $symbolPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Miter
        $symbolPen.MiterLimit = 3
        $graphics.DrawPolygon($symbolPen, $diamondPoints)

        $hIcon = $bitmap.GetHicon()
        try {
            $icon = [System.Drawing.Icon]::FromHandle($hIcon)
            return [System.Drawing.Icon]$icon.Clone()
        }
        finally {
            [WinFirewalkIconNative]::DestroyIcon($hIcon) | Out-Null
        }
    }
    finally {
        if ($graphics) {
            $graphics.Dispose()
        }
        if ($bitmap) {
            $bitmap.Dispose()
        }
        foreach ($resource in @($flameOuterBrush, $flameMidBrush, $flameInnerBrush, $symbolFillBrush, $symbolBackPen, $symbolPen, $outer, $mid, $inner)) {
            if ($resource) {
                $resource.Dispose()
            }
        }
    }
}

function Open-ProjectPage {
    Start-Process $ProjectUrl
}

function Open-WindowsFirewallSettings {
    $wfMsc = Join-Path $env:windir 'System32\wf.msc'
    $mmc = Join-Path $env:windir 'System32\mmc.exe'

    try {
        if ((Test-Path -LiteralPath $wfMsc) -and (Test-Path -LiteralPath $mmc)) {
            Start-Process -FilePath $mmc -ArgumentList "`"$wfMsc`""
        }
        else {
            Start-Process -FilePath 'wf.msc'
        }
    }
    catch {
        Start-Process -FilePath 'control.exe' -ArgumentList 'firewall.cpl'
    }
}

function Test-WinFirewalkAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-BatchQuotedString {
    param([Parameter(Mandatory)][string]$Value)

    return '"' + ($Value -replace '%', '%%') + '"'
}

function Invoke-ElevatedWinFirewalkOperation {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [string]$TargetPath,
        [scriptblock]$Log
    )

    $operationLower = $Operation.ToLowerInvariant()
    $tempRoot = Join-Path $env:TEMP ('WinFirewalk-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null

    $runnerPath = Join-Path $tempRoot 'run-elevated.cmd'
    $logPath = Join-Path $tempRoot 'operation.log'
    $scriptArg = ConvertTo-BatchQuotedString $ScriptPath
    $logArg = ConvertTo-BatchQuotedString $logPath
    $commandLine = "call $scriptArg $operationLower"
    if (-not [string]::IsNullOrWhiteSpace($TargetPath)) {
        $targetArg = ConvertTo-BatchQuotedString $TargetPath
        $commandLine = "$commandLine $targetArg"
    }

    $runner = @"
@echo off
setlocal EnableExtensions
$commandLine > $logArg 2>&1
set "WFW_EXIT=%errorlevel%"
>> $logArg echo __WFW_EXIT__:%WFW_EXIT%
exit /b %WFW_EXIT%
"@

    Set-Content -LiteralPath $runnerPath -Value $runner -Encoding ASCII

    try {
        if ($Log) {
            & $Log "Administrator approval is required for $Operation."
        }

        $runnerCmd = '/d /c "' + $runnerPath + '"'
        $process = Start-Process -FilePath $env:ComSpec -ArgumentList $runnerCmd -Verb RunAs -WindowStyle Hidden -PassThru
        $seenLines = 0

        while (-not $process.HasExited) {
            if (Test-Path -LiteralPath $logPath) {
                $lines = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
                foreach ($line in @($lines | Select-Object -Skip $seenLines)) {
                    if ($line -notlike '__WFW_EXIT__:*' -and $Log) {
                        & $Log $line
                    }
                }
                $seenLines = $lines.Count
            }

            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 250
        }

        if (Test-Path -LiteralPath $logPath) {
            $lines = @(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue)
            foreach ($line in @($lines | Select-Object -Skip $seenLines)) {
                if ($line -notlike '__WFW_EXIT__:*' -and $Log) {
                    & $Log $line
                }
            }

            $exitLine = @($lines | Where-Object { $_ -like '__WFW_EXIT__:*' } | Select-Object -Last 1)
            if ($exitLine.Count -gt 0) {
                $exitCode = [int]($exitLine[0] -replace '^__WFW_EXIT__:', '')
                if ($exitCode -ne 0) {
                    throw "$Operation failed with exit code $exitCode."
                }
            }
            elseif ($process.ExitCode -ne 0) {
                throw "$Operation failed with exit code $($process.ExitCode)."
            }
        }
        elseif ($process.ExitCode -ne 0) {
            throw "$Operation failed with exit code $($process.ExitCode)."
        }
    }
    finally {
        try {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch {
            # Temporary log cleanup is best-effort.
        }
    }
}

function New-WinFirewalkTheme {
    [pscustomobject]@{
        Background = [System.Drawing.Color]::FromArgb(17, 17, 17)
        Panel = [System.Drawing.Color]::FromArgb(0, 0, 0)
        PanelAlt = [System.Drawing.Color]::FromArgb(28, 28, 28)
        Input = [System.Drawing.Color]::FromArgb(4, 4, 4)
        InputText = [System.Drawing.Color]::FromArgb(245, 245, 245)
        Text = [System.Drawing.Color]::FromArgb(245, 245, 245)
        MutedText = [System.Drawing.Color]::FromArgb(184, 184, 184)
        LetterFill = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Accent = [System.Drawing.Color]::FromArgb(230, 0, 0)
        AccentSoft = [System.Drawing.Color]::FromArgb(255, 255, 255)
        Border = [System.Drawing.Color]::FromArgb(0, 210, 46)
        Button = [System.Drawing.Color]::FromArgb(54, 28, 21)
        ButtonHover = [System.Drawing.Color]::FromArgb(74, 39, 29)
        ButtonDown = [System.Drawing.Color]::FromArgb(24, 14, 11)
        Error = [System.Drawing.Color]::FromArgb(255, 60, 60)
    }
}

function Set-WinFirewalkButtonStyle {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Button]$Button,
        [Parameter(Mandatory)]$Theme,
        [switch]$Accent
    )

    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.UseVisualStyleBackColor = $false
    $Button.BackColor = $Theme.Button
    $Button.ForeColor = $Theme.Text
    $Button.FlatAppearance.BorderColor = $Theme.Border
    $Button.FlatAppearance.BorderSize = $(if ($Accent) { 2 } else { 1 })
    $Button.FlatAppearance.MouseOverBackColor = $Theme.ButtonHover
    $Button.FlatAppearance.MouseDownBackColor = $Theme.ButtonDown
}

function Set-WinFirewalkTextBoxStyle {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.TextBox]$TextBox,
        [Parameter(Mandatory)]$Theme
    )

    $TextBox.BackColor = $Theme.Input
    $TextBox.ForeColor = $Theme.InputText
    $TextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
}

function Set-WinFirewalkLinkStyle {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.LinkLabel]$LinkLabel,
        [Parameter(Mandatory)]$Theme
    )

    $LinkLabel.BackColor = $Theme.Background
    $LinkLabel.ForeColor = $Theme.Text
    $LinkLabel.LinkColor = $Theme.Text
    $LinkLabel.ActiveLinkColor = $Theme.Accent
    $LinkLabel.VisitedLinkColor = $Theme.MutedText
}

function Draw-WinFirewalkBackground {
    param(
        [Parameter(Mandatory)][System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory)][System.Drawing.Rectangle]$Bounds,
        [Parameter(Mandatory)]$Theme
    )

    $Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $Graphics.Clear($Theme.Panel)

    $zigzagPen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 10
    $redBrush = New-Object System.Drawing.SolidBrush $Theme.Accent
    $blackBrush = New-Object System.Drawing.SolidBrush $Theme.Panel

    try {
        $redHeight = [Math]::Max(145, [int]($Bounds.Height * 0.24))
        $Graphics.FillRectangle($redBrush, 0, 0, $Bounds.Width, $redHeight)
        $Graphics.FillRectangle($blackBrush, 0, $redHeight, $Bounds.Width, $Bounds.Height - $redHeight)

        for ($rowY = $redHeight + 10; $rowY -lt $Bounds.Height + 24; $rowY += 20) {
            $points = New-Object System.Collections.Generic.List[System.Drawing.Point]
            $x = -48
            $toggle = $false
            while ($x -le $Bounds.Width + 48) {
                $y = if ($toggle) { $rowY + 13 } else { $rowY }
                $points.Add((New-Object System.Drawing.Point $x, $y))
                $x += 32
                $toggle = -not $toggle
            }
            if ($points.Count -gt 1) {
                $Graphics.DrawLines($zigzagPen, $points.ToArray())
            }
        }
    }
    finally {
        foreach ($resource in @($zigzagPen, $redBrush, $blackBrush)) {
            if ($resource) {
                $resource.Dispose()
            }
        }
    }
}

function Show-WinFirewalkFolderPicker {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.IWin32Window]$Owner,
        [string]$CurrentPath
    )

    $description = 'Choose a folder to block or unblock'
    $current = $ScriptFolder
    try {
        $current = ConvertTo-TargetPath $CurrentPath
    }
    catch {
        # Keep the script folder as the fallback selected path.
    }

    $shell = $null
    $useFallbackPicker = $false
    try {
        $shell = New-Object -ComObject Shell.Application
        $ownerHandle = 0
        if ($Owner -and $Owner.Handle) {
            $ownerHandle = $Owner.Handle.ToInt64()
        }

        $returnOnlyFileSystemFolders = 0x0001
        $showEditBox = 0x0010
        $useNewDialogStyle = 0x0040
        $options = $returnOnlyFileSystemFolders -bor $showEditBox -bor $useNewDialogStyle
        $thisPc = 17

        $folder = $shell.BrowseForFolder($ownerHandle, $description, $options, $thisPc)
        if ($folder -and $folder.Self -and -not [string]::IsNullOrWhiteSpace($folder.Self.Path)) {
            return $folder.Self.Path
        }
    }
    catch {
        $useFallbackPicker = $true
    }
    finally {
        if ($shell) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
        }
    }

    if (-not $useFallbackPicker) {
        return $null
    }

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = $description
        $dialog.RootFolder = [System.Environment+SpecialFolder]::MyComputer
        $dialog.SelectedPath = $current
        $dialog.ShowNewFolderButton = $false

        if ($dialog.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
    }
    finally {
        $dialog.Dispose()
    }

    return $null
}

function Show-WinFirewalkCleanupProgress {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.IWin32Window]$Owner,
        [Parameter(Mandatory)]$Theme
    )

    $cleanupState = [pscustomobject]@{
        Done = $false
    }
    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = "$ToolName Cleanup"
    $progressForm.StartPosition = 'CenterParent'
    $progressForm.FormBorderStyle = 'FixedDialog'
    $progressForm.MaximizeBox = $false
    $progressForm.MinimizeBox = $false
    $progressForm.ControlBox = $false
    $progressForm.ClientSize = New-Object System.Drawing.Size(620, 430)
    $progressForm.Icon = New-FirewalkIcon
    $progressForm.BackColor = $Theme.Background
    $progressForm.ForeColor = $Theme.Text
    $progressForm.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $statusText = New-Object System.Windows.Forms.Label
    $statusText.Text = 'Removing WinFirewalk firewall rules...'
    $statusText.Location = New-Object System.Drawing.Point(16, 16)
    $statusText.Size = New-Object System.Drawing.Size(588, 24)
    $statusText.ForeColor = $Theme.Text
    $statusText.BackColor = $Theme.Background
    $progressForm.Controls.Add($statusText)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = New-Object System.Drawing.Point(16, 48)
    $progressBar.Size = New-Object System.Drawing.Size(588, 18)
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 35
    $progressForm.Controls.Add($progressBar)

    $cleanupLogBox = New-Object System.Windows.Forms.TextBox
    $cleanupLogBox.Location = New-Object System.Drawing.Point(16, 80)
    $cleanupLogBox.Size = New-Object System.Drawing.Size(588, 288)
    $cleanupLogBox.Multiline = $true
    $cleanupLogBox.ScrollBars = 'Vertical'
    $cleanupLogBox.ReadOnly = $true
    $cleanupLogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    Set-WinFirewalkTextBoxStyle -TextBox $cleanupLogBox -Theme $Theme
    $progressForm.Controls.Add($cleanupLogBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = 'OK'
    $okButton.Location = New-Object System.Drawing.Point(508, 384)
    $okButton.Size = New-Object System.Drawing.Size(96, 30)
    $okButton.Enabled = $false
    Set-WinFirewalkButtonStyle -Button $okButton -Theme $Theme -Accent
    $okButton.Add_Click({ $progressForm.Close() })
    $progressForm.Controls.Add($okButton)

    $appendCleanupLog = {
        param([string]$Message)

        if ($null -ne $Message) {
            $cleanupLogBox.AppendText($Message + [Environment]::NewLine)
            $cleanupLogBox.SelectionStart = $cleanupLogBox.TextLength
            $cleanupLogBox.ScrollToCaret()
        }
        $progressForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }

    $progressForm.Add_FormClosing({
        if (-not $cleanupState.Done) {
            $_.Cancel = $true
        }
    })

    $progressForm.Add_Shown({
        try {
            & $appendCleanupLog 'Cleanup started.'
            if (Test-WinFirewalkAdministrator) {
                Remove-AllWinFirewalkRules -Log $appendCleanupLog | Out-Null
            }
            else {
                Invoke-ElevatedWinFirewalkOperation -Operation 'deleteall' -Log $appendCleanupLog
            }

            & $appendCleanupLog ''
            & $appendCleanupLog 'WinFirewalk cleanup complete.'
            $statusText.Text = 'Cleanup complete.'
            $statusText.ForeColor = $Theme.Text
            $progressBar.MarqueeAnimationSpeed = 0
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $progressBar.Value = 100
        }
        catch {
            & $appendCleanupLog ''
            & $appendCleanupLog "ERROR: $($_.Exception.Message)"
            $statusText.Text = 'Cleanup failed.'
            $statusText.ForeColor = $Theme.Error
            $progressBar.MarqueeAnimationSpeed = 0
            $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $progressBar.Value = 0
        }
        finally {
            $cleanupState.Done = $true
            $okButton.Enabled = $true
            $progressForm.AcceptButton = $okButton
            $progressForm.CancelButton = $okButton
            $okButton.Focus()
        }
    })

    try {
        [void]$progressForm.ShowDialog($Owner)
    }
    finally {
        if ($progressForm.Icon) {
            $progressForm.Icon.Dispose()
        }
        $progressForm.Dispose()
    }
}

function Show-AboutDialog {
    param([Parameter(Mandatory)][System.Windows.Forms.IWin32Window]$Owner)

    $theme = New-WinFirewalkTheme

    $about = New-Object System.Windows.Forms.Form
    $about.Text = "Help and About - $ToolName"
    $about.StartPosition = 'CenterParent'
    $about.FormBorderStyle = 'FixedDialog'
    $about.MaximizeBox = $false
    $about.MinimizeBox = $false
    $about.ClientSize = New-Object System.Drawing.Size(470, 330)
    $about.Icon = New-FirewalkIcon
    $about.BackColor = $theme.Background
    $about.ForeColor = $theme.Text
    $about.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = "$ToolName v$ToolVersion"
    $titleLabel.Font = New-Object System.Drawing.Font($about.Font.FontFamily, 13, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Location = New-Object System.Drawing.Point(16, 16)
    $titleLabel.Size = New-Object System.Drawing.Size(430, 28)
    $titleLabel.ForeColor = $theme.AccentSoft
    $titleLabel.BackColor = $theme.Background
    $about.Controls.Add($titleLabel)

    $linkLabel = New-Object System.Windows.Forms.LinkLabel
    $linkLabel.Text = $ProjectUrl
    $linkLabel.Location = New-Object System.Drawing.Point(16, 48)
    $linkLabel.Size = New-Object System.Drawing.Size(430, 24)
    Set-WinFirewalkLinkStyle -LinkLabel $linkLabel -Theme $theme
    $linkLabel.Add_LinkClicked({ Open-ProjectPage })
    $about.Controls.Add($linkLabel)

    $quoteBox = New-Object System.Windows.Forms.TextBox
    $quoteBox.Location = New-Object System.Drawing.Point(16, 86)
    $quoteBox.Size = New-Object System.Drawing.Size(438, 140)
    $quoteBox.Multiline = $true
    $quoteBox.ReadOnly = $true
    $quoteBox.BorderStyle = 'FixedSingle'
    $quoteBox.Font = New-Object System.Drawing.Font('Georgia', 10, [System.Drawing.FontStyle]::Italic)
    Set-WinFirewalkTextBoxStyle -TextBox $quoteBox -Theme $theme
    $quoteBox.Text = @'
Through the darkness of future's past,

The magician longs to see.

One chants out between two worlds...

"Fire... walk with me."
'@
    $about.Controls.Add($quoteBox)

    $cleanupButton = New-Object System.Windows.Forms.Button
    $cleanupButton.Text = 'Delete All WinFirewalk Rules'
    $cleanupButton.Location = New-Object System.Drawing.Point(16, 238)
    $cleanupButton.Size = New-Object System.Drawing.Size(220, 30)
    Set-WinFirewalkButtonStyle -Button $cleanupButton -Theme $theme
    $cleanupButton.Add_Click({
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $about,
            'This will remove all rules created by WinFirewalk. Proceed?',
            $ToolName,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        )

        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            return
        }

        $cleanupButton.Enabled = $false
        try {
            Show-WinFirewalkCleanupProgress -Owner $about -Theme $theme
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show(
                $about,
                $_.Exception.Message,
                "$ToolName Cleanup Failed",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
        finally {
            $cleanupButton.Enabled = $true
        }
    })
    $about.Controls.Add($cleanupButton)

    $firewallButton = New-Object System.Windows.Forms.Button
    $firewallButton.Text = 'Windows Firewall Settings'
    $firewallButton.Location = New-Object System.Drawing.Point(16, 282)
    $firewallButton.Size = New-Object System.Drawing.Size(190, 30)
    Set-WinFirewalkButtonStyle -Button $firewallButton -Theme $theme
    $firewallButton.Add_Click({ Open-WindowsFirewallSettings })
    $about.Controls.Add($firewallButton)

    $githubButton = New-Object System.Windows.Forms.Button
    $githubButton.Text = 'GitHub'
    $githubButton.Location = New-Object System.Drawing.Point(242, 282)
    $githubButton.Size = New-Object System.Drawing.Size(96, 30)
    Set-WinFirewalkButtonStyle -Button $githubButton -Theme $theme -Accent
    $githubButton.Add_Click({ Open-ProjectPage })
    $about.Controls.Add($githubButton)

    $closeAboutButton = New-Object System.Windows.Forms.Button
    $closeAboutButton.Text = 'Close'
    $closeAboutButton.Location = New-Object System.Drawing.Point(348, 282)
    $closeAboutButton.Size = New-Object System.Drawing.Size(96, 30)
    Set-WinFirewalkButtonStyle -Button $closeAboutButton -Theme $theme
    $closeAboutButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $about.AcceptButton = $closeAboutButton
    $about.CancelButton = $closeAboutButton
    $about.Controls.Add($closeAboutButton)

    try {
        [void]$about.ShowDialog($Owner)
    }
    finally {
        if ($about.Icon) {
            $about.Icon.Dispose()
        }
        $about.Dispose()
    }
}

function Show-Gui {
    param([string]$InitialPath)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    [System.Windows.Forms.Application]::EnableVisualStyles()

    $theme = New-WinFirewalkTheme

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$ToolName v$ToolVersion"
    $form.StartPosition = 'CenterScreen'
    $form.Size = New-Object System.Drawing.Size(820, 620)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 540)
    $form.Icon = New-FirewalkIcon
    $form.BackColor = $theme.Background
    $form.ForeColor = $theme.Text
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.Add_Paint({
        Draw-WinFirewalkBackground -Graphics $_.Graphics -Bounds $form.ClientRectangle -Theme $theme
    })

    $label = New-Object System.Windows.Forms.Label
    $label.Text = 'Step 1.) Choose Target Folder'
    $label.Location = New-Object System.Drawing.Point(12, 15)
    $label.Size = New-Object System.Drawing.Size(240, 20)
    $label.ForeColor = $theme.Text
    $label.BackColor = $theme.Accent
    $form.Controls.Add($label)

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Location = New-Object System.Drawing.Point(12, 38)
    $pathBox.Size = New-Object System.Drawing.Size(650, 24)
    $pathBox.Anchor = 'Top, Left, Right'
    $pathBox.Text = $InitialPath
    $pathBox.AllowDrop = $true
    Set-WinFirewalkTextBoxStyle -TextBox $pathBox -Theme $theme
    $form.Controls.Add($pathBox)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = 'Browse...'
    $browseButton.Location = New-Object System.Drawing.Point(672, 36)
    $browseButton.Size = New-Object System.Drawing.Size(115, 28)
    $browseButton.Anchor = 'Top, Right'
    Set-WinFirewalkButtonStyle -Button $browseButton -Theme $theme
    $form.Controls.Add($browseButton)

    $actionLabel = New-Object System.Windows.Forms.Label
    $actionLabel.Text = 'Step 2.) Block, Unblock, or View Folder Status'
    $actionLabel.Location = New-Object System.Drawing.Point(12, 76)
    $actionLabel.Size = New-Object System.Drawing.Size(330, 20)
    $actionLabel.ForeColor = $theme.Text
    $actionLabel.BackColor = $theme.Accent
    $form.Controls.Add($actionLabel)

    $blockButton = New-Object System.Windows.Forms.Button
    $blockButton.Text = 'Block'
    $blockButton.Location = New-Object System.Drawing.Point(12, 99)
    $blockButton.Size = New-Object System.Drawing.Size(115, 32)
    Set-WinFirewalkButtonStyle -Button $blockButton -Theme $theme -Accent
    $form.Controls.Add($blockButton)

    $unblockButton = New-Object System.Windows.Forms.Button
    $unblockButton.Text = 'Unblock'
    $unblockButton.Location = New-Object System.Drawing.Point(136, 99)
    $unblockButton.Size = New-Object System.Drawing.Size(115, 32)
    Set-WinFirewalkButtonStyle -Button $unblockButton -Theme $theme
    $form.Controls.Add($unblockButton)

    $statusButton = New-Object System.Windows.Forms.Button
    $statusButton.Text = 'View Folder Status'
    $statusButton.Location = New-Object System.Drawing.Point(260, 99)
    $statusButton.Size = New-Object System.Drawing.Size(160, 32)
    Set-WinFirewalkButtonStyle -Button $statusButton -Theme $theme
    $form.Controls.Add($statusButton)

    $logBox = New-Object System.Windows.Forms.TextBox
    $logBox.Location = New-Object System.Drawing.Point(12, 147)
    $logBox.Size = New-Object System.Drawing.Size(775, 392)
    $logBox.Anchor = 'Top, Bottom, Left, Right'
    $logBox.Multiline = $true
    $logBox.ScrollBars = 'Vertical'
    $logBox.ReadOnly = $true
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    Set-WinFirewalkTextBoxStyle -TextBox $logBox -Theme $theme
    $form.Controls.Add($logBox)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusStrip.SizingGrip = $true
    $statusStrip.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $statusStrip.BackColor = $theme.Panel
    $statusStrip.ForeColor = $theme.MutedText
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Spring = $true
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $statusLabel.ForeColor = $theme.MutedText
    $statusLabel.Text = "Ready - $ToolName v$ToolVersion"
    $aboutStatusButton = New-Object System.Windows.Forms.ToolStripStatusLabel
    $aboutStatusButton.Text = 'Help and About'
    $aboutStatusButton.IsLink = $true
    $aboutStatusButton.LinkColor = $theme.Text
    $aboutStatusButton.ActiveLinkColor = $theme.Border
    $aboutStatusButton.VisitedLinkColor = $theme.Text
    $aboutStatusButton.ForeColor = $theme.Text
    $aboutStatusButton.ToolTipText = "Help and About $ToolName"
    $aboutStatusButton.Margin = New-Object System.Windows.Forms.Padding 8, 3, 6, 2
    [void]$statusStrip.Items.Add($statusLabel)
    [void]$statusStrip.Items.Add($aboutStatusButton)
    $form.Controls.Add($statusStrip)

    $guiState = [pscustomobject]@{
        CurrentOperation = ''
        Busy = $false
        SuppressPathRefresh = $false
    }

    $statusRefreshTimer = New-Object System.Windows.Forms.Timer
    $statusRefreshTimer.Interval = 500

    function Resize-GuiLogBox {
        $logBox.Width = [Math]::Max(200, $form.ClientSize.Width - 29)
        $logBox.Height = [Math]::Max(120, $form.ClientSize.Height - $logBox.Top - $statusStrip.Height - 12)
        $form.Invalidate()
    }

    function Set-GuiStatus {
        param([string]$Message)

        if ($Message.StartsWith('Error:', [System.StringComparison]::OrdinalIgnoreCase)) {
            $statusLabel.ForeColor = $theme.Error
        }
        else {
            $statusLabel.ForeColor = $theme.MutedText
        }
        $statusLabel.Text = $Message
        $statusStrip.Refresh()
    }

    function Add-GuiLogLine {
        param([string]$Message)

        $logBox.AppendText($Message + [Environment]::NewLine)
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }

    function Set-GuiBusy {
        param([bool]$Busy)

        $guiState.Busy = $Busy
        $blockButton.Enabled = -not $Busy
        $unblockButton.Enabled = -not $Busy
        $statusButton.Enabled = -not $Busy
        $browseButton.Enabled = -not $Busy
        $aboutStatusButton.Enabled = -not $Busy
        if ($Busy) {
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        }
        else {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }

    function Test-DroppedWinFirewalkTarget {
        param($DataObject)

        if (-not $DataObject.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            return $false
        }

        $paths = @($DataObject.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        foreach ($path in $paths) {
            if (Test-Path -LiteralPath $path -PathType Container) {
                return $true
            }

            $extension = [System.IO.Path]::GetExtension($path)
            if ($extension -ieq '.exe' -or $extension -ieq '.lnk') {
                return $true
            }
        }

        return $false
    }

    function Get-DroppedTargetPath {
        param($DataObject)

        if (-not $DataObject.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
            return $null
        }

        $lastError = $null
        $paths = @($DataObject.GetData([System.Windows.Forms.DataFormats]::FileDrop))
        foreach ($path in $paths) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                $extension = [System.IO.Path]::GetExtension($path)
                if ($extension -ine '.exe' -and $extension -ine '.lnk') {
                    continue
                }
            }

            try {
                return ConvertTo-TargetPath $path
            }
            catch {
                $lastError = $_.Exception.Message
            }
        }

        if ($lastError) {
            throw $lastError
        }

        return $null
    }

    function Set-WinFirewalkDropTarget {
        param([Parameter(Mandatory)][System.Windows.Forms.Control]$Control)

        $Control.AllowDrop = $true
        $Control.Add_DragEnter({
            if ($guiState.Busy) {
                $_.Effect = [System.Windows.Forms.DragDropEffects]::None
                return
            }

            if (Test-DroppedWinFirewalkTarget -DataObject $_.Data) {
                $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
            }
            else {
                $_.Effect = [System.Windows.Forms.DragDropEffects]::None
            }
        })

        $Control.Add_DragOver({
            if ($guiState.Busy) {
                $_.Effect = [System.Windows.Forms.DragDropEffects]::None
                return
            }

            if (Test-DroppedWinFirewalkTarget -DataObject $_.Data) {
                $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
            }
            else {
                $_.Effect = [System.Windows.Forms.DragDropEffects]::None
            }
        })

        $Control.Add_DragDrop({
            if ($guiState.Busy) {
                return
            }

            try {
                $targetPath = Get-DroppedTargetPath -DataObject $_.Data
                if ($targetPath) {
                    $pathBox.Text = $targetPath
                    Set-GuiStatus "Selected folder: $($pathBox.Text)"
                }
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null
            }
        })
    }

    function Invoke-GuiOperation {
        param([Parameter(Mandatory)][string]$Operation)

        $logBox.Clear()
        Set-GuiBusy $true
        Set-GuiStatus "Running $Operation..."
        try {
            $context = New-TargetContext -InputPath $pathBox.Text
            $guiState.SuppressPathRefresh = $true
            try {
                $pathBox.Text = $context.Root
            }
            finally {
                $guiState.SuppressPathRefresh = $false
            }
            $log = { param([string]$Message) Add-GuiLogLine $Message }

            if (($Operation -eq 'Block' -or $Operation -eq 'Unblock') -and -not (Test-WinFirewalkAdministrator)) {
                Invoke-ElevatedWinFirewalkOperation -Operation $Operation -TargetPath $context.Root -Log $log
            }
            else {
                switch ($Operation) {
                    'Block' {
                        Block-Folder -Context $context -Log $log
                    }
                    'Unblock' {
                        Unblock-Folder -Context $context -Log $log
                    }
                    'Status' {
                        Show-FolderStatus -Context $context -Log $log
                    }
                }
            }

            $guiState.CurrentOperation = $Operation
            if ($Operation -eq 'Status') {
                Set-GuiStatus "Status updated for $($context.Root)"
            }
            else {
                Set-GuiStatus "$Operation complete for $($context.Root)"
            }
        }
        catch {
            $message = $_.Exception.Message
            Add-GuiLogLine "ERROR: $message"
            Set-GuiStatus "Error: $message"
            [System.Windows.Forms.MessageBox]::Show($form, $message, $ToolName, 'OK', 'Error') | Out-Null
        }
        finally {
            Set-GuiBusy $false
        }
    }

    $statusRefreshTimer.Add_Tick({
        $statusRefreshTimer.Stop()
        if ($guiState.CurrentOperation -eq 'Status' -and -not $guiState.Busy) {
            Invoke-GuiOperation 'Status'
        }
    })

    $browseButton.Add_Click({
        $selectedPath = Show-WinFirewalkFolderPicker -Owner $form -CurrentPath $pathBox.Text
        if (-not [string]::IsNullOrWhiteSpace($selectedPath)) {
            try {
                $pathBox.Text = ConvertTo-TargetPath $selectedPath
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, $ToolName, 'OK', 'Error') | Out-Null
            }
        }
    })

    $pathBox.Add_TextChanged({
        if ($guiState.SuppressPathRefresh -or $guiState.Busy) {
            return
        }

        if ($guiState.CurrentOperation -eq 'Status') {
            $statusRefreshTimer.Stop()
            $statusRefreshTimer.Start()
        }
    })

    $blockButton.Add_Click({ Invoke-GuiOperation 'Block' })
    $unblockButton.Add_Click({ Invoke-GuiOperation 'Unblock' })
    $statusButton.Add_Click({ Invoke-GuiOperation 'Status' })
    $aboutStatusButton.Add_Click({
        Set-GuiStatus 'Showing Help and About'
        Show-AboutDialog -Owner $form
        Set-GuiStatus "Ready - $ToolName v$ToolVersion"
    })

    foreach ($dropTarget in @($form, $label, $actionLabel, $pathBox, $browseButton, $blockButton, $unblockButton, $statusButton, $logBox, $statusStrip)) {
        Set-WinFirewalkDropTarget -Control $dropTarget
    }

    $form.Add_Resize({ Resize-GuiLogBox })
    $form.Add_FormClosed({
        $statusRefreshTimer.Stop()
        $statusRefreshTimer.Dispose()
        if ($form.Icon) {
            $form.Icon.Dispose()
        }
    })

    Resize-GuiLogBox
    Add-GuiLogLine 'WinFirewalk blocks .exe and .dll files in a selected folder and all subfolders using Windows Firewall rules.'
    Add-GuiLogLine ''
    Add-GuiLogLine 'Type a folder path, click Browse, or drag a folder, shortcut, or .exe into this window, then choose Block, Unblock, or View Folder Status.'

    [void]$form.ShowDialog()
}

function Invoke-ConsoleOperation {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$TargetPath
    )

    $context = New-TargetContext -InputPath $TargetPath
    $consoleLog = { param([string]$Message) Write-Host $Message }
    switch ($Operation) {
        'block' {
            Block-Folder -Context $context -Log $consoleLog
        }
        'unblock' {
            Unblock-Folder -Context $context -Log $consoleLog
        }
        'status' {
            Show-FolderStatus -Context $context -Log $consoleLog
        }
    }
}

function Invoke-ConsoleDeleteAll {
    $consoleLog = { param([string]$Message) Write-Host $Message }
    Remove-AllWinFirewalkRules -Log $consoleLog | Out-Null
}

$normalizedAction = ''
if (-not [string]::IsNullOrWhiteSpace($Action)) {
    $normalizedAction = $Action.ToLowerInvariant()
}

$targetPath = ''
if ($PathParts -and $PathParts.Count -gt 0) {
    $targetPath = ($PathParts -join ' ')
}

switch ($normalizedAction) {
    'block' {
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            $targetPath = $ScriptFolder
        }
        Invoke-ConsoleOperation -Operation 'block' -TargetPath $targetPath
    }
    'unblock' {
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            $targetPath = $ScriptFolder
        }
        Invoke-ConsoleOperation -Operation 'unblock' -TargetPath $targetPath
    }
    'status' {
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            $targetPath = $ScriptFolder
        }
        Invoke-ConsoleOperation -Operation 'status' -TargetPath $targetPath
    }
    'deleteall' {
        Invoke-ConsoleDeleteAll
    }
    default {
        $initialPath = $ScriptFolder
        if (-not [string]::IsNullOrWhiteSpace($Action)) {
            $initialPath = (($Action, $targetPath) -join ' ').Trim()
        }
        Show-Gui -InitialPath $initialPath
    }
}
