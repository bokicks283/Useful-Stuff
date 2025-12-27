<#
.SYNOPSIS
  Audit and (optionally) interactively resolve Git config duplicates/overrides across scopes.

.DESCRIPTION
  Reads Git config from SYSTEM, GLOBAL, and LOCAL scopes using byte-safe parsing of:
    git config --<scope> --list --show-origin -z

  -z FORMAT (critical):
    Records are NUL-terminated.
    Key and value are separated by a NEWLINE within a record:
      <origin>\0<key>\n<value>\0<origin>\0<key>\n<value>\0...

  We MUST parse values this way to preserve multi-line values correctly.

  Why bytes:
    PowerShell text capture is not reliable for NUL-delimited output on Windows.
    We capture stdout as bytes, split on 0x00, then parse.

  OUTPUT FORMAT:
    <key>
    [System]: <value(s) or (not set)>
    [Global]: <value(s) or (not set)>
    [Local ]: <value(s) or (not set)>
    Value being used: <value> (from <scope>)

  MULTI-LINE VALUE DISPLAY (Option B + A):
    - Single-line values print inline
    - Multi-line values print as an indented block (first MaxValueLines lines),
      plus "(+N more line(s) hidden)".
    - Each displayed line is truncated to PreviewChars for readability.

.PARAMETER Fix
  Interactive mode. Prompts per key with actions.

.PARAMETER DryRun
  Show what would change without changing anything.

.PARAMETER IncludeSystemWrite
  Allow modifying SYSTEM config (usually requires admin). Default: read-only.

.PARAMETER IncludeRedundantAcross
  Also include keys that have the same single value in multiple scopes.

.PARAMETER ShowInfoKeys
  Include normally noisy keys (remote.*, branch.*, alias.*, etc.) even if they are not conflicts.

.PARAMETER ShowAll
  Include all keys, even those that are not conflicts or normally noisy.

.PARAMETER DebugRead
  Print parsing diagnostics (bytes/fields per scope).

.PARAMETER Prefer
  Default selection preference in -Fix: effective/local/global.

.PARAMETER PreviewChars
  Max characters per displayed line.

.PARAMETER MaxValueLines
  Max lines shown for multi-line values in the main report.

.NOTES
  Run from PowerShell 7:
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\Scripts\git-tools\Fix-GitConfigConflicts.ps1
#>

[CmdletBinding()]
param(
  [switch]$Fix,
  [switch]$DryRun,
  [switch]$IncludeSystemWrite,
  [switch]$IncludeRedundantAcross,
  [switch]$ShowInfoKeys,
  [switch]$ShowAll,
  [switch]$DebugRead,
  [ValidateSet("effective", "local", "global")]
  [string]$Prefer = "effective",
  [int]$PreviewChars = 140,
  [int]$MaxValueLines = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Team policy knobs (adjustable)
# -----------------------------
$MustBeGlobalKeys = @(
  "user.name",
  "user.email",
  "user.signingkey",
  "commit.gpgsign",
  "tag.gpgsign",
  "gpg.program",
  "gpg.format"
)

$WatchedOverrideKeys = @(
  "core.autocrlf",
  "core.eol",
  "core.editor",
  "init.defaultbranch",
  "pull.rebase",
  "merge.conflictstyle",
  "core.hookspath"
)

$InfoOnlyKeyPatterns = @(
  '^remote\.',
  '^branch\.',
  '^alias\.',
  '^submodule\.',
  '^include\.',
  '^includeIf\.',
  '^http\.',
  '^credential\.',
  '^lfs\.'
)

# -----------------------------
# Console helpers
# -----------------------------
function Write-Info {
  param([string]$Message)
  Write-Host $Message -ForegroundColor Cyan
}

function Write-Warn {
  param([string]$Message)
  Write-Host $Message -ForegroundColor Yellow
}

function Write-Dim {
  param([string]$Message)
  Write-Host $Message -ForegroundColor DarkGray
}

function Test-InsideGitRepository {
  try { return ((& git rev-parse --is-inside-work-tree 2>$null) -match 'true') }
  catch { return $false }
}

function Test-SystemConfigWritable {
  return [bool]$IncludeSystemWrite
}

function Test-InfoOnlyKey {
  param([string]$Key)
  foreach ($pattern in $InfoOnlyKeyPatterns) {
    if ($Key -match $pattern) { return $true }
  }
  return $false
}

function Format-ScopeTag {
  param([ValidateSet("system", "global", "local")] [string]$Scope)
  switch ($Scope) {
    "system" { "[System]" }
    "global" { "[Global]" }
    "local" { "[Local ]" }
  }
}

function Format-ScopeTitle {
  param([ValidateSet("system", "global", "local")] [string]$Scope)
  switch ($Scope) {
    "system" { "System" }
    "global" { "Global" }
    "local" { "Local" }
  }
}

# -----------------------------
# Multi-line display helpers (Option B + A)
# -----------------------------
function ConvertTo-DisplayLines {
  param([string]$Value)

  if ($null -eq $Value) { return @() }

  $normalized = ($Value -replace "`r", "")
  $lines = $normalized -split "`n"

  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    $l = $line
    if ($PreviewChars -gt 0 -and $l.Length -gt $PreviewChars) {
      $l = $l.Substring(0, $PreviewChars) + "…"
    }
    $out.Add($l) | Out-Null
  }

  return $out.ToArray()
}

function Format-PreviewInline {
  param([string]$Value)

  if ($null -eq $Value) { return "(not set)" }

  $lines = @(ConvertTo-DisplayLines -Value $Value)
  if ($lines.Count -eq 0) { return "" }
  if ($lines.Count -eq 1) { return $lines[0] }

  return ("{0}  (+{1} more line(s))" -f $lines[0], ($lines.Count - 1))
}

function Write-ValueBlock {
  param(
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory)][string]$Value,
    [string]$Indent = "  "
  )

  $lines = @(ConvertTo-DisplayLines -Value $Value)

  if ($lines.Count -le 1) {
    Write-Host ("{0} {1}" -f $Prefix, (Format-PreviewInline -Value $Value))
    return
  }

  Write-Host $Prefix
  $showCount = [Math]::Min($MaxValueLines, $lines.Count)

  for ($i = 0; $i -lt $showCount; $i++) {
    Write-Host ("{0}{1}" -f $Indent, $lines[$i])
  }

  $hidden = $lines.Count - $showCount
  if ($hidden -gt 0) {
    Write-Dim ("{0}(+{1} more line(s) hidden)" -f $Indent, $hidden)
  }
}

# -----------------------------
# Git invocation (byte-safe)
# -----------------------------
function ConvertTo-QuotedArgument {
  param([string]$Argument)
  if ($Argument -match '[\s"`]') {
    return '"' + ($Argument -replace '"', '\"') + '"'
  }
  return $Argument
}

function Get-GitStdoutBytes {
  param([string[]]$GitArguments)

  $gitPath = (Get-Command git -ErrorAction Stop).Source

  $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $startInfo.FileName = $gitPath
  $startInfo.Arguments = ($GitArguments | ForEach-Object { ConvertTo-QuotedArgument $_ }) -join ' '
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true

  $proc = [System.Diagnostics.Process]::new()
  $proc.StartInfo = $startInfo

  if (-not $proc.Start()) { throw "Failed to start git process." }

  $ms = [System.IO.MemoryStream]::new()
  $proc.StandardOutput.BaseStream.CopyTo($ms)
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($proc.ExitCode -ne 0) {
    if ($stderr) { Write-Warn "git exited with code $($proc.ExitCode): $stderr" }
    return [byte[]]@()
  }

  return $ms.ToArray()
}

function Convert-BytesToNullFields {
  param([byte[]]$Bytes)

  if (-not $Bytes -or $Bytes.Length -eq 0) { return @() }

  $fields = New-Object System.Collections.Generic.List[string]
  $start = 0

  for ($i = 0; $i -lt $Bytes.Length; $i++) {
    if ($Bytes[$i] -eq 0) {
      $len = $i - $start
      if ($len -gt 0) {
        $chunk = New-Object byte[] $len
        [Array]::Copy($Bytes, $start, $chunk, 0, $len)
        $fields.Add([System.Text.Encoding]::UTF8.GetString($chunk)) | Out-Null
      }
      $start = $i + 1
    }
  }

  if ($start -lt $Bytes.Length) {
    $len = $Bytes.Length - $start
    if ($len -gt 0) {
      $chunk = New-Object byte[] $len
      [Array]::Copy($Bytes, $start, $chunk, 0, $len)
      $fields.Add([System.Text.Encoding]::UTF8.GetString($chunk)) | Out-Null
    }
  }

  return $fields.ToArray()
}

function Convert-ZFieldsToConfigEntries {
  <#
    Correct -z parsing:

      origin\0key\nvalue\0origin\0key\nvalue\0...

    We split by NUL => fields[].
    We then walk:
      if fields[i] looks like an origin and i+1 exists:
         origin = fields[i]
         payload = fields[i+1]
         i += 2
      else:
         origin = ""
         payload = fields[i]
         i += 1

    payload is "key\nvalue" where value may contain additional newlines.
    Split on FIRST newline only.
  #>
  param(
    [ValidateSet("system", "global", "local")] [string]$Scope,
    [string[]]$Fields
  )

  $entries = New-Object System.Collections.Generic.List[object]
  if (-not $Fields -or $Fields.Count -eq 0) { return @() }

  $i = 0
  while ($i -lt $Fields.Count) {
    $origin = ""
    $payload = $Fields[$i]

    if ($payload -match '^(file|command line|blob|standard input):' -and ($i + 1) -lt $Fields.Count) {
      $origin = $payload
      $payload = $Fields[$i + 1]
      $i += 2
    }
    else {
      $i += 1
    }

    if ([string]::IsNullOrEmpty($payload)) { continue }

    $nlIdx = $payload.IndexOf("`n")
    $key = $null
    $val = ""

    if ($nlIdx -ge 0) {
      $key = $payload.Substring(0, $nlIdx).Trim()
      $val = $payload.Substring($nlIdx + 1)  # may contain more newlines
    }
    else {
      # Extremely rare fallback if newline delimiter isn't present.
      $eqIdx = $payload.IndexOf("=")
      if ($eqIdx -ge 0) {
        $key = $payload.Substring(0, $eqIdx).Trim()
        $val = $payload.Substring($eqIdx + 1)
      }
      else {
        $key = $payload.Trim()
        $val = ""
      }
    }

    if ([string]::IsNullOrWhiteSpace($key)) { continue }

    $entries.Add([pscustomobject]@{
        Scope  = $Scope
        Origin = $origin
        Key    = $key
        Value  = $val
      }) | Out-Null
  }

  return $entries.ToArray()
}

function Get-GitConfigEntries {
  param([ValidateSet("system", "global", "local")] [string]$Scope)

  if ($Scope -eq "local" -and -not (Test-InsideGitRepository)) { return @() }

  $stdoutBytes = Get-GitStdoutBytes -GitArguments @("config", "--$Scope", "--list", "--show-origin", "-z")
  $fields = @(Convert-BytesToNullFields -Bytes $stdoutBytes)

  if ($DebugRead) {
    Write-Dim ("  [debug] {0}: bytes={1}, fields={2}" -f $Scope, $stdoutBytes.Length, $fields.Count)
    if ($fields.Count -gt 0) { Write-Dim ("  [debug] {0}: first field preview: {1}" -f $Scope, (Format-PreviewInline -Value $fields[0])) }
  }

  return @(Convert-ZFieldsToConfigEntries -Scope $Scope -Fields $fields)
}

# -----------------------------
# Effective value helper
# -----------------------------
function Get-EffectiveConfigValue {
  param([object[]]$Items)

  $local = $Items | Where-Object Scope -eq "local"
  if ($local) {
    $x = $local | Select-Object -Last 1
    return [pscustomobject]@{ Scope = "local"; Value = $x.Value }
  }

  $global = $Items | Where-Object Scope -eq "global"
  if ($global) {
    $x = $global | Select-Object -Last 1
    return [pscustomobject]@{ Scope = "global"; Value = $x.Value }
  }

  $system = $Items | Where-Object Scope -eq "system"
  if ($system) {
    $x = $system | Select-Object -Last 1
    return [pscustomobject]@{ Scope = "system"; Value = $x.Value }
  }

  return [pscustomobject]@{ Scope = ""; Value = $null }
}

# -----------------------------
# Output helpers (values only; no origin paths)
# -----------------------------
function Write-ConfigScopeValues {
  param(
    [ValidateSet("system", "global", "local")] [string]$Scope,
    [string[]]$Values
  )

  $tag = Format-ScopeTag -Scope $Scope

  if (-not $Values -or $Values.Count -eq 0) {
    Write-Host ("{0}: (not set)" -f $tag)
    return
  }

  $distinct = @($Values | Sort-Object -Unique)

  if ($distinct.Count -eq 1) {
    Write-ValueBlock -Prefix ("{0}:" -f $tag) -Value $distinct[0]
    return
  }

  Write-Host ("{0}:" -f $tag)
  foreach ($val in $distinct) {
    $valLines = @(ConvertTo-DisplayLines -Value $val)
    if ($valLines.Count -le 1) {
      Write-Host ("  - {0}" -f (Format-PreviewInline -Value $val))
    }
    else {
      Write-Host "  -"
      Write-ValueBlock -Prefix "    " -Value $val -Indent "      "
    }
  }
}

function Write-ConfigIssueBlock {
  param([Parameter(Mandatory)] $Issue)

  Write-Host ""
  Write-Host $Issue.Key -ForegroundColor Cyan

  Write-ConfigScopeValues -Scope system -Values @($Issue.ByScope.system)
  Write-ConfigScopeValues -Scope global -Values @($Issue.ByScope.global)
  Write-ConfigScopeValues -Scope local  -Values @($Issue.ByScope.local)

  $eff = $Issue.Effective
  if ($eff -and $eff.Scope) {
    $scopeTitle = Format-ScopeTitle -Scope $eff.Scope
    Write-Host ("Value being used: {0}  (from {1})" -f (Format-PreviewInline -Value $eff.Value), $scopeTitle) -ForegroundColor Green
  }
  else {
    Write-Host "Value being used: (none)" -ForegroundColor Green
  }

  $flags = @()
  if ($Issue.MustGlobalViolation) { $flags += "MUST-GLOBAL" }
  if ($Issue.HasOverrideAcross) { $flags += "OVERRIDE" }
  if ($Issue.HasMultiDistinctWithin) { $flags += "MULTI" }
  if ($Issue.HasDupWithin) { $flags += "DUPES" }
  if ($Issue.IsRedundantAcross) { $flags += "REDUNDANT" }

  if ($flags.Count -gt 0) {
    Write-Dim ("Flags: {0}" -f ($flags -join ", "))
  }
}

# -----------------------------
# Fix actions
# -----------------------------
function Invoke-GitConfigCommand {
  param([string[]]$GitArguments)

  if ($DryRun) {
    Write-Dim ("DRY-RUN: git " + ($GitArguments -join " "))
    return ""
  }
  return & git @GitArguments
}

function Remove-GitConfigExactDuplicates {
  param(
    [string]$Key,
    [ValidateSet("system", "global", "local")] [string]$Scope,
    [string[]]$Values
  )

  $dupes = $Values | Group-Object | Where-Object Count -gt 1
  if (-not $dupes) { return }

  if ($Scope -eq "system" -and -not (Test-SystemConfigWritable)) {
    Write-Warn "SYSTEM is read-only. Re-run with -IncludeSystemWrite to modify system config."
    return
  }

  foreach ($d in $dupes) {
    $val = $d.Name
    Write-Info ("Cleaning DUPES: {0} in {1} (count {2} -> 1)" -f $Key, $Scope, $d.Count)
    Invoke-GitConfigCommand -GitArguments @("config", "--$Scope", "--unset-all", $Key, $val) | Out-Null
    Invoke-GitConfigCommand -GitArguments @("config", "--$Scope", "--add", $Key, $val) | Out-Null
  }
}

function Set-GitConfigSingleValue {
  param(
    [string]$Key,
    [ValidateSet("system", "global", "local")] [string]$Scope,
    [string]$Value
  )

  if ($Scope -eq "system" -and -not (Test-SystemConfigWritable)) {
    Write-Warn "SYSTEM is read-only. Re-run with -IncludeSystemWrite to modify system config."
    return
  }

  Write-Info ("Setting {0} in {1} to a single value." -f $Key, $Scope)
  Invoke-GitConfigCommand -GitArguments @("config", "--$Scope", "--unset-all", $Key) | Out-Null
  Invoke-GitConfigCommand -GitArguments @("config", "--$Scope", "--add", $Key, $Value) | Out-Null
}

function Remove-GitConfigKeyFromScope {
  param(
    [string]$Key,
    [ValidateSet("system", "global", "local")] [string]$Scope
  )

  if ($Scope -eq "system" -and -not (Test-SystemConfigWritable)) {
    Write-Warn "SYSTEM is read-only. Re-run with -IncludeSystemWrite to modify system config."
    return
  }

  Write-Info ("Removing {0} from {1}." -f $Key, $Scope)
  Invoke-GitConfigCommand -GitArguments @("config", "--$Scope", "--unset-all", $Key) | Out-Null
}

function Read-MenuChoice {
  param(
    [string]$Title,
    [string]$Message,
    [string[]]$Options,
    [int]$DefaultIndex = 0
  )
  $choiceItems = foreach ($opt in $Options) { New-Object System.Management.Automation.Host.ChoiceDescription "&$opt" }
  return $Host.UI.PromptForChoice($Title, $Message, $choiceItems, $DefaultIndex)
}

# -----------------------------
# Main
# -----------------------------
$insideRepo = Test-InsideGitRepository

$systemEntries = @(Get-GitConfigEntries -Scope system)
$globalEntries = @(Get-GitConfigEntries -Scope global)
$localEntries = @()
if ($insideRepo) { $localEntries = @(Get-GitConfigEntries -Scope local) }

Write-Info "`nLoaded git config entries:"
Write-Host ("  SYSTEM: {0}" -f $systemEntries.Count)
Write-Host ("  GLOBAL: {0}" -f $globalEntries.Count)
Write-Host ("  LOCAL : {0}" -f $localEntries.Count)

$allEntries = @($systemEntries + $globalEntries + $localEntries)
if ($allEntries.Count -eq 0) {
  Write-Warn "No config entries read. Ensure git is on PATH and run under pwsh."
  exit 0
}

$issues = @()

foreach ($group in ($allEntries | Group-Object Key)) {
  $key = $group.Name
  $items = @($group.Group)

  $isInfoOnly = Test-InfoOnlyKey -Key $key
  $isWatched = ($WatchedOverrideKeys -contains $key)
  $isMustGlobal = ($MustBeGlobalKeys -contains $key)

  $byScope = @{
    system = @($items | Where-Object Scope -eq "system" | Select-Object -ExpandProperty Value)
    global = @($items | Where-Object Scope -eq "global" | Select-Object -ExpandProperty Value)
    local  = @($items | Where-Object Scope -eq "local"  | Select-Object -ExpandProperty Value)
  }

  $distinctSystem = @($byScope.system | Sort-Object -Unique)
  $distinctGlobal = @($byScope.global | Sort-Object -Unique)
  $distinctLocal = @($byScope.local  | Sort-Object -Unique)
  $distinctAll = @($distinctSystem + $distinctGlobal + $distinctLocal | Sort-Object -Unique)

  $hasDupWithin = $false
  foreach ($scopeName in @("system", "global", "local")) {
    $vals = $byScope[$scopeName]
    if ($vals.Count -gt 1 -and (($vals | Group-Object | Where-Object Count -gt 1).Count -gt 0)) { $hasDupWithin = $true }
  }

  $hasMultiDistinctWithin = ($distinctSystem.Count -gt 1 -or $distinctGlobal.Count -gt 1 -or $distinctLocal.Count -gt 1)

  $hasOverrideAcrossRaw = ($distinctAll.Count -gt 1)
  $hasOverrideAcross = ($hasOverrideAcrossRaw -and ($isWatched -or $isMustGlobal))

  $mustGlobalViolation = ($isMustGlobal -and $byScope.local.Count -gt 0)

  $scopesPresent = 0
  foreach ($scopeName in @("system", "global", "local")) { if ($byScope[$scopeName].Count -gt 0) { $scopesPresent++ } }
  $isRedundantAcross = ($distinctAll.Count -eq 1 -and $scopesPresent -ge 2)

  $effective = Get-EffectiveConfigValue -Items $items

  $isRealIssue =
  $hasDupWithin -or
  $hasMultiDistinctWithin -or
  $hasOverrideAcross -or
  $mustGlobalViolation -or
  ($IncludeRedundantAcross -and $isRedundantAcross)

  if ($ShowAll) {
    # Show every key, even if "info-only" and not an issue
    $shouldShow = $true
  }
  else {
    $shouldShow = $ShowInfoKeys -or $isRealIssue
    if (-not $ShowInfoKeys -and $isInfoOnly -and -not $isRealIssue) { $shouldShow = $false }
  }

  if (-not $shouldShow) { continue }


  $issues += [pscustomobject]@{
    Key                    = $key
    Items                  = $items
    ByScope                = $byScope
    DistinctAll            = $distinctAll
    Effective              = $effective
    HasDupWithin           = $hasDupWithin
    HasMultiDistinctWithin = $hasMultiDistinctWithin
    HasOverrideAcross      = $hasOverrideAcross
    HasOverrideAcrossRaw   = $hasOverrideAcrossRaw
    IsRedundantAcross      = $isRedundantAcross
    MustGlobalViolation    = $mustGlobalViolation
  }
}

if ($issues.Count -eq 0) {
  Write-Host "`nNo keys worth reviewing detected (under current filters)." -ForegroundColor Green
  exit 0
}

if ($ShowAll) { Write-Info "`nAll keys:" }
else          { Write-Info "`nKeys to review:" }
foreach ($issue in ($issues | Sort-Object Key)) {
  Write-ConfigIssueBlock -Issue $issue
}

if (-not $Fix) {
  Write-Warn "`nRun again with -Fix to interactively resolve."
  exit 0
}

foreach ($issue in ($issues | Sort-Object Key)) {
  Write-ConfigIssueBlock -Issue $issue

  $menu = @(
    "Skip",
    "Clean exact duplicates (DUPES) within scopes",
    "Pick ONE value to keep (write to a scope)",
    "Remove this key from a scope (unset-all)",
    "View FULL values for this key"
  )

  $default = 0
  if ($issue.MustGlobalViolation -or $issue.HasOverrideAcross -or $issue.HasMultiDistinctWithin) { $default = 2 }
  elseif ($issue.HasDupWithin) { $default = 1 }

  $choice = Read-MenuChoice -Title "Resolve config" -Message "Action for '$($issue.Key)':" -Options $menu -DefaultIndex $default

  switch ($choice) {
    0 { continue }

    1 {
      foreach ($scopeName in @("local", "global", "system")) {
        if ($scopeName -eq "system" -and -not (Test-SystemConfigWritable)) { continue }
        $vals = @($issue.ByScope[$scopeName])
        if ($vals.Count -gt 1) {
          Remove-GitConfigExactDuplicates -Key $issue.Key -Scope $scopeName -Values $vals
        }
      }
      continue
    }

    2 {
      $uniqueValues = @($issue.DistinctAll)
      if ($uniqueValues.Count -eq 0) { Write-Warn "No values to choose."; continue }

      $defaultValueIndex = 0
      if ($Prefer -eq "effective" -and $issue.Effective.Value) {
        $idx = [Array]::IndexOf($uniqueValues, $issue.Effective.Value)
        if ($idx -ge 0) { $defaultValueIndex = $idx }
      }

      $valueOptions = $uniqueValues | ForEach-Object { Format-PreviewInline -Value $_ }
      $valuePick = Read-MenuChoice -Title "Pick value" -Message "Choose value for '$($issue.Key)':" -Options $valueOptions -DefaultIndex $defaultValueIndex
      $selectedValue = $uniqueValues[$valuePick]

      $scopeOptions = New-Object System.Collections.Generic.List[string]
      $scopeMap = New-Object System.Collections.Generic.List[string]
      if ($insideRepo) { $scopeOptions.Add("Local (.git/config)"); $scopeMap.Add("local") | Out-Null }
      $scopeOptions.Add("Global (~/.gitconfig)"); $scopeMap.Add("global") | Out-Null
      if (Test-SystemConfigWritable) { $scopeOptions.Add("System (Git install)"); $scopeMap.Add("system") | Out-Null }

      $defaultScopeIndex = 0
      if ($MustBeGlobalKeys -contains $issue.Key) {
        $defaultScopeIndex = [Math]::Max(0, $scopeMap.IndexOf("global"))
      }
      elseif ($Prefer -eq "global") {
        $defaultScopeIndex = [Math]::Max(0, $scopeMap.IndexOf("global"))
      }
      elseif ($Prefer -eq "local") {
        $defaultScopeIndex = [Math]::Max(0, $scopeMap.IndexOf("local"))
      }
      else {
        $defaultScopeIndex = [Math]::Max(0, $scopeMap.IndexOf($issue.Effective.Scope))
      }

      $scopePick = Read-MenuChoice -Title "Pick scope" -Message "Write to which scope?" -Options $scopeOptions.ToArray() -DefaultIndex $defaultScopeIndex
      $targetScope = $scopeMap[$scopePick]

      Set-GitConfigSingleValue -Key $issue.Key -Scope $targetScope -Value $selectedValue
      continue
    }

    3 {
      $scopeOptions = New-Object System.Collections.Generic.List[string]
      $scopeMap = New-Object System.Collections.Generic.List[string]
      if ($insideRepo) { $scopeOptions.Add("Local (.git/config)"); $scopeMap.Add("local") | Out-Null }
      $scopeOptions.Add("Global (~/.gitconfig)"); $scopeMap.Add("global") | Out-Null
      if (Test-SystemConfigWritable) { $scopeOptions.Add("System (Git install)"); $scopeMap.Add("system") | Out-Null }

      $scopePick = Read-MenuChoice -Title "Pick scope" -Message "Remove '$($issue.Key)' from which scope?" -Options $scopeOptions.ToArray() -DefaultIndex 0
      $targetScope = $scopeMap[$scopePick]

      Remove-GitConfigKeyFromScope -Key $issue.Key -Scope $targetScope
      continue
    }

    4 {
      Write-Host ""
      Write-Info "FULL values for '$($issue.Key)':"
      foreach ($scopeName in @("system", "global", "local")) {
        $vals = @($issue.ByScope[$scopeName])
        Write-Host ("{0}:" -f (Format-ScopeTag -Scope $scopeName)) -ForegroundColor Gray
        if ($vals.Count -eq 0) {
          Write-Host "  (not set)"
          continue
        }

        $distinctVals = @($vals | Sort-Object -Unique)
        for ($vi = 0; $vi -lt $distinctVals.Count; $vi++) {
          if ($distinctVals.Count -gt 1) { Write-Dim ("  ---- value #{0} ----" -f ($vi + 1)) }
          else { Write-Dim "  ---- value ----" }

          $full = ($distinctVals[$vi] -replace "`r", "")
          foreach ($line in ($full -split "`n")) {
            Write-Host ("  {0}" -f $line)
          }
        }
      }
      continue
    }
  }
}

Write-Host "`nDone. Verify with:" -ForegroundColor Green
Write-Host "  git config --list --show-origin" -ForegroundColor Gray
