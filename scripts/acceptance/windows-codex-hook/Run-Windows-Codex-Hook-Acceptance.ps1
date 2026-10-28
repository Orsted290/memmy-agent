[CmdletBinding()]
param(
  [string] $InstallerPath,
  [string] $CodexExecutable,
  [int] $StartupTimeoutSeconds = 240,
  [int] $TurnTimeoutSeconds = 240
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function ConvertTo-NativeArgument([string] $Value) {
  if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
  $builder = New-Object System.Text.StringBuilder
  [void] $builder.Append('"')
  $slashes = 0
  foreach ($character in $Value.ToCharArray()) {
    if ($character -eq '\') { $slashes++; continue }
    if ($character -eq '"') {
      [void] $builder.Append(('\' * (2 * $slashes + 1)))
      [void] $builder.Append('"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) { [void] $builder.Append(('\' * $slashes)); $slashes = 0 }
    [void] $builder.Append($character)
  }
  if ($slashes -gt 0) { [void] $builder.Append(('\' * (2 * $slashes))) }
  [void] $builder.Append('"')
  return $builder.ToString()
}

function New-ProcessInfo([string] $FilePath, [string[]] $Arguments, [string] $WorkingDirectory, [hashtable] $Environment) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $FilePath
  $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument ([string] $_) }) -join ' ')
  $info.WorkingDirectory = $WorkingDirectory
  $info.UseShellExecute = $false
  foreach ($name in $Environment.Keys) {
    if ($null -eq $Environment[$name]) { [void] $info.EnvironmentVariables.Remove($name) }
    else { $info.EnvironmentVariables[$name] = [string] $Environment[$name] }
  }
  return $info
}

function Invoke-NativeCapture(
  [string] $FilePath,
  [string[]] $Arguments,
  [string] $WorkingDirectory,
  [hashtable] $Environment,
  [int] $TimeoutSeconds = 60
) {
  $info = New-ProcessInfo $FilePath $Arguments $WorkingDirectory $Environment
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.CreateNoWindow = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $info
  if (-not $process.Start()) { throw "Failed to start: $FilePath" }
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    try { $process.Kill() } catch { }
    throw "Timed out after $TimeoutSeconds seconds: $([IO.Path]::GetFileName($FilePath))"
  }
  $stdout = $stdoutTask.GetAwaiter().GetResult()
  $stderr = $stderrTask.GetAwaiter().GetResult()
  return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

function Invoke-NativeInteractive([string] $FilePath, [string[]] $Arguments, [string] $WorkingDirectory, [hashtable] $Environment, [int] $TimeoutSeconds = 600) {
  $info = New-ProcessInfo $FilePath $Arguments $WorkingDirectory $Environment
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $info
  if (-not $process.Start()) { throw "Failed to start: $FilePath" }
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    try { $process.Kill() } catch { }
    throw "Timed out after $TimeoutSeconds seconds: $([IO.Path]::GetFileName($FilePath))"
  }
  return $process.ExitCode
}

function Resolve-CodexExecutable([string] $RequestedPath) {
  $candidates = New-Object System.Collections.Generic.List[string]
  if ($RequestedPath) { $candidates.Add($RequestedPath) }
  $local = [Environment]::GetFolderPath('LocalApplicationData')
  $programFiles = [Environment]::GetFolderPath('ProgramFiles')
  $cache = Join-Path $local 'OpenAI\Codex\bin'
  if (Test-Path -LiteralPath $cache -PathType Container) {
    $candidates.Add((Join-Path $cache 'codex.exe'))
    Get-ChildItem -LiteralPath $cache -Directory -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      ForEach-Object { $candidates.Add((Join-Path $_.FullName 'codex.exe')) }
  }
  foreach ($base in @((Join-Path $local 'Programs'), $programFiles)) {
    foreach ($app in @('Codex', 'ChatGPT')) {
      foreach ($resources in @('resources', 'app\resources')) {
        $candidates.Add((Join-Path (Join-Path (Join-Path $base $app) $resources) 'codex.exe'))
      }
    }
  }
  $command = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command -and $command.Source) { $candidates.Add($command.Source) }
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      $resolved = [IO.Path]::GetFullPath($candidate)
      if ([IO.Path]::GetFileName($resolved) -ine 'codex.exe') {
        throw 'The selected file is not the native Codex CLI codex.exe. Do not select the Codex desktop application.'
      }
      return $resolved
    }
  }
  throw 'Codex CLI codex.exe was not found. Re-run with -CodexExecutable "C:\path\to\codex.exe".'
}

function Resolve-NodeExecutable {
  $command = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $command -or -not $command.Source -or -not (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
    throw 'Node.js node.exe is required to execute Memmy hooks. Install Node.js 22 or newer, then re-run this script.'
  }
  return [IO.Path]::GetFullPath($command.Source)
}

function Get-CodexCommandsInText([string] $FilePath) {
  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { return 0 }
  $text = [IO.File]::ReadAllText($FilePath)
  return [regex]::Matches($text, 'memmy-resume-hook\.mjs', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
}

function Get-EpisodeSnapshot([string] $MemoryUrl) {
  $uri = $MemoryUrl.TrimEnd('/') + '/api/v1/episodes'
  return Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
}

function Get-HkcuValueSnapshot([string] $SubKeyPath, [string] $ValueName) {
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKeyPath, $false)
  if (-not $key) {
    return [pscustomobject]@{ keyExists = $false; valueExists = $false; kind = $null; value = $null }
  }
  try {
    $valueExists = @($key.GetValueNames()) -contains $ValueName
    if (-not $valueExists) {
      return [pscustomobject]@{ keyExists = $true; valueExists = $false; kind = $null; value = $null }
    }
    return [pscustomobject]@{
      keyExists = $true
      valueExists = $true
      kind = [string] $key.GetValueKind($ValueName)
      value = [string] $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
  } finally {
    $key.Dispose()
  }
}

function Test-HkcuValueSnapshotEqual($Before, $After) {
  return [bool](
    $Before.keyExists -eq $After.keyExists -and
    $Before.valueExists -eq $After.valueExists -and
    $Before.kind -eq $After.kind -and
    [string]::Equals([string] $Before.value, [string] $After.value, [StringComparison]::Ordinal)
  )
}

function Get-UninstallEntriesForInstallPath([string] $InstallPath) {
  $matches = New-Object System.Collections.Generic.List[string]
  $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall', $false)
  if (-not $root) { return @() }
  $expectedPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\', '/')
  try {
    foreach ($name in $root.GetSubKeyNames()) {
      $entry = $root.OpenSubKey($name, $false)
      if (-not $entry) { continue }
      try {
        $registeredPath = [string] $entry.GetValue('InstallLocation', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (-not $registeredPath) { continue }
        $normalizedPath = [IO.Path]::GetFullPath($registeredPath).TrimEnd('\', '/')
        if ($normalizedPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) { $matches.Add($name) }
      } catch { }
      finally { $entry.Dispose() }
    }
  } finally {
    $root.Dispose()
  }
  return @($matches.ToArray())
}

function Find-TestTurn($Snapshot, [string] $Marker) {
  foreach ($task in @($Snapshot.tasks)) {
    foreach ($turn in @($task.turns)) {
      if ([string] $turn.userText -like "*$Marker*") { return $turn }
    }
  }
  return $null
}

function Add-Check([string] $Id, [string] $Status, [string] $Evidence) {
  $script:Checks.Add([pscustomobject]@{ id = $Id; status = $Status; evidence = $Evidence })
}

function Stop-MemmyProcess($Process) {
  if (-not $Process) { return }
  try {
    $Process.Refresh()
    if ($Process.HasExited) { return }
    [void] $Process.CloseMainWindow()
    if (-not $Process.WaitForExit(15000)) { $Process.Kill(); [void] $Process.WaitForExit(10000) }
  } catch { }
}

function Get-SafeError([string] $Message, [string] $ProfileRoot) {
  $safe = $Message -replace [regex]::Escape($ProfileRoot), '%MEMMY_ACCEPTANCE_TEMP%'
  $realUserProfile = [Environment]::GetFolderPath('UserProfile').TrimEnd('\', '/')
  if ($realUserProfile) {
    $profilePattern = [regex]::Escape($realUserProfile) + '(?=$|[\\/])'
    $safe = [regex]::Replace($safe, $profilePattern, '%USERPROFILE%', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
  }
  $safe = $safe -replace '(?i)(Bearer\s+)[^\s"'']+', '$1<redacted>'
  $safe = $safe -replace '(?i)(token|authorization)(\s*[:=]\s*)[^\s,"'']+', '$1$2<redacted>'
  return $safe
}

function Format-SafePath([string] $Path) {
  if (-not $Path) { return $null }
  $realUserProfile = [IO.Path]::GetFullPath([Environment]::GetFolderPath('UserProfile')).TrimEnd('\', '/')
  $fullPath = [IO.Path]::GetFullPath($Path)
  if ($fullPath.Equals($realUserProfile, [StringComparison]::OrdinalIgnoreCase)) { return '%USERPROFILE%' }
  foreach ($separator in @('\', '/')) {
    $profilePrefix = $realUserProfile + $separator
    if ($fullPath.StartsWith($profilePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      return '%USERPROFILE%' + $fullPath.Substring($realUserProfile.Length)
    }
  }
  return $fullPath
}

$script:Checks = New-Object 'System.Collections.Generic.List[object]'
$runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$profileRoot = Join-Path $tempBase "Memmy Codex Hook Acceptance $runId"
$profileHome = Join-Path $profileRoot 'home'
$codexHome = Join-Path $profileHome '.codex'
$installDirectory = Join-Path $profileRoot 'Memmy Install'
$workspace = Join-Path $profileRoot 'workspace'
$evidenceDirectory = Join-Path $PSScriptRoot 'output'
$reportPath = Join-Path $evidenceDirectory "windows-codex-hook-$runId.json"
$memmyProcess = $null
$installerPathResolved = $null
$installerAttempted = $false
$codexPath = $null
$nodePath = $null
$codexEnvironment = $null
$codexCache = $null
$profileCreated = $false
$appInstalled = $false
$codexLoginAttempted = $false
$safeToRemoveProfile = $true
$registrySnapshots = $null
$startedAt = [DateTime]::UtcNow
$errorText = $null
$codexPathWasRemovedFromMemmyPath = $false
$codexExecutableOverrideWasUnset = $false

try {
  if ($env:OS -ne 'Windows_NT' -or [Environment]::Is64BitOperatingSystem -ne $true) {
    throw 'This acceptance package requires 64-bit Windows.'
  }
  New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
  if (-not $InstallerPath) {
    $installer = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Memmy-*-codex-acceptance.exe' -File | Select-Object -First 1
    if (-not $installer) { throw 'The Codex acceptance Memmy installer must be beside this script or supplied through -InstallerPath.' }
    $InstallerPath = $installer.FullName
  }
  $installerPathResolved = [IO.Path]::GetFullPath($InstallerPath)
  if (-not (Test-Path -LiteralPath $installerPathResolved -PathType Leaf)) { throw "Installer not found: $installerPathResolved" }
  if ([IO.Path]::GetFileName($installerPathResolved) -notmatch '(?i)-unsigned-codex-acceptance\.exe$') {
    throw 'Use the unsigned -codex-acceptance.exe installer produced for this script.'
  }
  $codexPath = Resolve-CodexExecutable $CodexExecutable
  $nodePath = Resolve-NodeExecutable
  $codexVersion = Invoke-NativeCapture $codexPath @('--version') (Split-Path -Parent $codexPath) @{} 30
  if ($codexVersion.ExitCode -ne 0) { throw "Codex CLI --version failed: $($codexVersion.Stderr.Trim())" }
  $nodeVersion = Invoke-NativeCapture $nodePath @('--version') (Split-Path -Parent $nodePath) @{} 30
  $nodeVersionText = $nodeVersion.Stdout.Trim() -replace '^v', ''
  $nodeMajorVersion = 0
  if ($nodeVersionText -match '^(\d+)\.') { $nodeMajorVersion = [int] $Matches[1] }
  if ($nodeVersion.ExitCode -ne 0 -or $nodeMajorVersion -lt 22) {
    throw 'Node.js 22 or newer is required for the installed Memmy hook.'
  }

  New-Item -ItemType Directory -Path $profileRoot | Out-Null
  $profileCreated = $true
  if ((Get-Item -LiteralPath $profileRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'The temporary acceptance root must not be a symbolic link or junction.'
  }
  foreach ($directory in @($profileHome, $codexHome, $workspace, $installDirectory,
      (Join-Path $profileRoot 'app-data'), (Join-Path $profileRoot 'local-app-data'),
      (Join-Path $profileRoot 'temp'))) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $sessionsDirectory = Join-Path $codexHome 'sessions'
  New-Item -ItemType Directory -Path $sessionsDirectory -Force | Out-Null

  # Stage the real Codex CLI under the isolated LocalAppData cache fallback. The
  # Memmy process receives no Codex executable in PATH and no explicit override.
  $codexCacheParent = Join-Path (Join-Path (Join-Path $profileRoot 'local-app-data') 'OpenAI') 'Codex'
  New-Item -ItemType Directory -Path $codexCacheParent -Force | Out-Null
  $codexCache = Join-Path $codexCacheParent 'bin'
  New-Item -ItemType Junction -Path $codexCache -Target (Split-Path -Parent $codexPath) | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $codexCache 'codex.exe') -PathType Leaf)) {
    throw 'Failed to stage Codex CLI in the isolated LocalAppData fallback path.'
  }

  $systemRoot = $env:SystemRoot
  $safePathEntries = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @($env:PATH -split ';')) {
    $trimmed = $entry.Trim().Trim('"')
    if (-not $trimmed -or -not (Test-Path -LiteralPath $trimmed -PathType Container)) { continue }
    if ((Test-Path -LiteralPath (Join-Path $trimmed 'codex.exe')) -or
        (Test-Path -LiteralPath (Join-Path $trimmed 'codex.cmd')) -or
        (Test-Path -LiteralPath (Join-Path $trimmed 'codex.bat'))) { continue }
    if ($safePathEntries -notcontains $trimmed) { $safePathEntries.Add($trimmed) }
  }
  $isolatedPath = $safePathEntries -join ';'
  if (-not $isolatedPath) { $isolatedPath = Join-Path $systemRoot 'System32' }
  if ($isolatedPath -match '(?i)codex') { throw 'The isolated PATH still contains a Codex installation directory.' }
  $codexPathWasRemovedFromMemmyPath = $true

  $testEnvironment = @{
    USERPROFILE = $profileHome
    HOME = $profileHome
    APPDATA = Join-Path $profileRoot 'app-data'
    LOCALAPPDATA = Join-Path $profileRoot 'local-app-data'
    TEMP = Join-Path $profileRoot 'temp'
    TMP = Join-Path $profileRoot 'temp'
    TMPDIR = Join-Path $profileRoot 'temp'
    CODEX_HOME = $codexHome
    PATH = $isolatedPath
    MEMMY_HOOK_NODE = $nodePath
    MEMMY_TEST_PROFILE_ROOT = $profileRoot
    MEMMY_CODEX_EXECUTABLE = $null
    CODEX_CLI_PATH = $null
    OPENAI_API_KEY = $null
    CODEX_API_KEY = $null
    OPENAI_BASE_URL = $null
  }
  $codexExecutableOverrideWasUnset = $true
  $codexEnvironment = @{
    USERPROFILE = $profileHome
    HOME = $profileHome
    APPDATA = Join-Path $profileRoot 'app-data'
    LOCALAPPDATA = Join-Path $profileRoot 'local-app-data'
    TEMP = Join-Path $profileRoot 'temp'
    TMP = Join-Path $profileRoot 'temp'
    TMPDIR = Join-Path $profileRoot 'temp'
    CODEX_HOME = $codexHome
    PATH = $isolatedPath
    OPENAI_API_KEY = $null
    CODEX_API_KEY = $null
    OPENAI_BASE_URL = $null
    MEMMY_HOOK_NODE = $nodePath
  }
  $memmyEnvironment = @{} + $testEnvironment
  # The packaged app validates that its isolation root is directly under the
  # original OS temp directory before redirecting temp paths into the profile.
  $memmyEnvironment.TEMP = $tempBase
  $memmyEnvironment.TMP = $tempBase
  $memmyEnvironment.TMPDIR = $tempBase

  Write-Host 'Codex CLI executable: ' -NoNewline
  Write-Host ([IO.Path]::GetFileName((Split-Path -Parent $codexPath)) + '\codex.exe')
  Write-Host 'Codex resolution mode: isolated LocalAppData fallback; Codex removed from Memmy PATH; no executable override'
  Write-Host 'The next sign-in uses a temporary Codex home and is removed when this run ends.'
  $codexLoginAttempted = $true
  $loginCode = Invoke-NativeInteractive $codexPath @('login') $workspace $codexEnvironment 900
  if ($loginCode -ne 0) { throw "Codex login did not complete (exit $loginCode)." }
  Add-Check 'WIN-CODEX-01' 'pass' 'Native Codex CLI launched and authenticated under the disposable CODEX_HOME.'

  # Snapshot user-level registry values because process environment variables do not isolate HKCU.
  $registrySnapshots = [ordered]@{
    userPath = Get-HkcuValueSnapshot 'Environment' 'Path'
    regularMemmyRun = Get-HkcuValueSnapshot 'Software\Microsoft\Windows\CurrentVersion\Run' 'cn.memtensor.memmy'
    acceptanceMemmyRun = Get-HkcuValueSnapshot 'Software\Microsoft\Windows\CurrentVersion\Run' 'cn.memtensor.memmy.codex-acceptance'
  }

  # Install to a per-run directory; the acceptance NSIS build has a separate app identity
  # and skips host PATH, login-item, shortcut, upgrade detection, and data migration changes.
  $installerAttempted = $true
  $installerRun = Invoke-NativeCapture $installerPathResolved @('/S', "/D=$installDirectory") $profileRoot $testEnvironment 180
  if ($installerRun.ExitCode -ne 0) { throw "The Memmy NSIS installer failed with exit code $($installerRun.ExitCode)." }
  $appInstalled = $true
  $installEntries = @(Get-UninstallEntriesForInstallPath $installDirectory)
  if ($installEntries.Count -eq 0) { throw 'The acceptance install did not create an uninstall registration for its temporary install path.' }
  Add-Check 'WIN-MEMMY-REGISTRY-01' 'pass' 'The installer registered its temporary install path under its distinct acceptance identity.'
  $memmyExecutable = Join-Path $installDirectory 'Memmy.exe'
  if (-not (Test-Path -LiteralPath $memmyExecutable -PathType Leaf)) { throw 'Memmy.exe is missing from the isolated installation directory.' }
  Add-Check 'WIN-MEMMY-01' 'pass' 'Unsigned x64 NSIS installer completed in a disposable directory containing spaces.'

  $memmyInfo = New-ProcessInfo $memmyExecutable @() $installDirectory $memmyEnvironment
  $memmyProcess = New-Object System.Diagnostics.Process
  $memmyProcess.StartInfo = $memmyInfo
  if (-not $memmyProcess.Start()) { throw 'Failed to start the packaged Memmy acceptance build.' }
  $runtimeConfigPath = Join-Path (Join-Path $profileHome '.memmy') 'runtime.json'
  $startupDeadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
  while (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf) -and [DateTime]::UtcNow -lt $startupDeadline) {
    $memmyProcess.Refresh()
    if ($memmyProcess.HasExited) { throw "Memmy exited before writing the isolated runtime config (exit $($memmyProcess.ExitCode))." }
    Start-Sleep -Seconds 2
  }
  if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) { throw 'Memmy did not become ready before the startup timeout.' }
  $runtimeConfig = Get-Content -LiteralPath $runtimeConfigPath -Raw | ConvertFrom-Json
  $localApiUrl = [string] $runtimeConfig.baseUrl
  $localApiToken = [string] $runtimeConfig.localToken
  $memoryUrl = [string] $runtimeConfig.memory.baseUrl
  if (-not $localApiUrl -or -not $localApiToken -or -not $memoryUrl) { throw 'The isolated Memmy runtime config is incomplete.' }

  $memoryReady = $false
  $memoryDeadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
  while (-not $memoryReady -and [DateTime]::UtcNow -lt $memoryDeadline) {
    try {
      $baseline = Get-EpisodeSnapshot $memoryUrl
      $memoryReady = $true
    } catch { Start-Sleep -Seconds 2 }
  }
  if (-not $memoryReady) { throw 'The isolated Memmy Memory API did not become ready.' }
  $baselineCount = [int] $baseline.total

  $headers = @{ Authorization = "Bearer $localApiToken" }
  $installBody = @{ installType = 'manual' } | ConvertTo-Json -Compress
  Invoke-RestMethod -Uri ($localApiUrl.TrimEnd('/') + '/api/agent-sources/codex/plugin') `
    -Method Post -Headers $headers -ContentType 'application/json' -Body $installBody -TimeoutSec 60 | Out-Null
  $hookConfigPath = Join-Path $codexHome 'hooks.json'
  $hookCommandCount = Get-CodexCommandsInText $hookConfigPath
  if ($hookCommandCount -ne 5) { throw "Codex hooks.json contains $hookCommandCount Memmy hook commands; expected 5." }
  Add-Check 'WIN-HOOK-INSTALL-01' 'pass' 'The packaged app-server discovered and trusted all five Memmy hooks; hooks.json contains five hook commands.'

  $promptMarker = "MEMMY-WIN-HOOK-$runId"
  $expectedAnswer = "MEMMY-WIN-HOOK-ANSWER-$runId"
  $prompt = "This is a software integration acceptance. Do not use tools or inspect files. Reply with exactly this string and nothing else: $expectedAnswer"
  $firstTurn = Invoke-NativeCapture $codexPath @('exec', '--sandbox', 'read-only', '--skip-git-repo-check', "$promptMarker $prompt") `
    $workspace $codexEnvironment $TurnTimeoutSeconds
  if ($firstTurn.ExitCode -ne 0) {
    throw "Codex first turn failed with exit $($firstTurn.ExitCode): $($firstTurn.Stderr.Trim())"
  }
  $captureDeadline = [DateTime]::UtcNow.AddSeconds($TurnTimeoutSeconds)
  $capturedTurn = $null
  $afterCapture = $null
  while (-not $capturedTurn -and [DateTime]::UtcNow -lt $captureDeadline) {
    try {
      $afterCapture = Get-EpisodeSnapshot $memoryUrl
      $capturedTurn = Find-TestTurn $afterCapture $promptMarker
    } catch { }
    if (-not $capturedTurn) { Start-Sleep -Seconds 3 }
  }
  if (-not $capturedTurn) { throw 'The real Windows Codex turn did not appear in Memmy episodes; Hook execution or persistence failed.' }
  if ([string] $capturedTurn.assistantText -notlike "*$expectedAnswer*") {
    throw 'The persisted Codex turn does not contain the expected assistant response.'
  }
  if ([int] $afterCapture.total -le $baselineCount) { throw 'The persisted episode count did not increase after the Codex turn.' }
  Add-Check 'WIN-HOOK-CAPTURE-01' 'pass' 'A fresh Codex turn with a unique marker and its answer were read back from the isolated Memmy episode store.'

  # Exercise removal when Codex no longer has a sessions directory.
  if (Test-Path -LiteralPath $sessionsDirectory) {
    Remove-Item -LiteralPath $sessionsDirectory -Recurse -Force
  }
  if (Test-Path -LiteralPath $sessionsDirectory) { throw 'Could not remove the isolated Codex sessions directory before uninstall.' }
  $uninstallBody = @{ installType = 'manual' } | ConvertTo-Json -Compress
  Invoke-RestMethod -Uri ($localApiUrl.TrimEnd('/') + '/api/agent-sources/codex/plugin') `
    -Method Delete -Headers $headers -ContentType 'application/json' -Body $uninstallBody -TimeoutSec 60 | Out-Null
  $remainingHookCommands = Get-CodexCommandsInText $hookConfigPath
  $hookScript = Join-Path (Join-Path $codexHome 'hooks') 'memmy-resume-hook.mjs'
  $hookConfig = Join-Path (Join-Path $codexHome 'hooks') 'memmy-memory-config.json'
  $agentsFile = Join-Path $codexHome 'AGENTS.md'
  $agentsText = if (Test-Path -LiteralPath $agentsFile) { [IO.File]::ReadAllText($agentsFile) } else { '' }
  if ($remainingHookCommands -ne 0 -or (Test-Path -LiteralPath $hookScript) -or
      (Test-Path -LiteralPath $hookConfig) -or $agentsText -match 'memmy:start') {
    throw 'Hook uninstall left a Memmy hook, hook config, or AGENTS marker after the sessions directory disappeared.'
  }
  $beforeNoHookTurn = Get-EpisodeSnapshot $memoryUrl
  Add-Check 'WIN-HOOK-UNINSTALL-01' 'pass' 'Uninstall succeeded after the sessions directory was removed; hooks.json, hook runtime files, and Memmy AGENTS marker were cleaned.'

  $postPromptMarker = "MEMMY-WIN-AFTER-UNINSTALL-$runId"
  $postExpectedAnswer = "MEMMY-WIN-AFTER-UNINSTALL-ANSWER-$runId"
  $postPrompt = "This is a software integration acceptance. Do not use tools or inspect files. Reply with exactly this string and nothing else: $postExpectedAnswer"
  $secondTurn = Invoke-NativeCapture $codexPath @('exec', '--sandbox', 'read-only', '--skip-git-repo-check', "$postPromptMarker $postPrompt") `
    $workspace $codexEnvironment $TurnTimeoutSeconds
  if ($secondTurn.ExitCode -ne 0) {
    throw "Codex post-uninstall turn failed with exit $($secondTurn.ExitCode): $($secondTurn.Stderr.Trim())"
  }
  Start-Sleep -Seconds 5
  $afterNoHookTurn = Get-EpisodeSnapshot $memoryUrl
  if ($null -ne (Find-TestTurn $afterNoHookTurn $postPromptMarker)) {
    throw 'A new Codex turn was captured by Memmy after Hook uninstall.'
  }
  $postUninstallDeadline = [DateTime]::UtcNow.AddSeconds(20)
  while ([DateTime]::UtcNow -lt $postUninstallDeadline) {
    Start-Sleep -Seconds 2
    $afterNoHookTurn = Get-EpisodeSnapshot $memoryUrl
    if ([int] $afterNoHookTurn.total -ne [int] $beforeNoHookTurn.total -or
        $null -ne (Find-TestTurn $afterNoHookTurn $postPromptMarker)) {
      break
    }
  }
  if ([int] $afterNoHookTurn.total -ne [int] $beforeNoHookTurn.total) {
    throw "Memmy episode count changed after uninstall ($($beforeNoHookTurn.total) -> $($afterNoHookTurn.total))."
  }
  Add-Check 'WIN-HOOK-UNINSTALL-02' 'pass' 'A fresh Codex process completed a second real turn after uninstall; no new Memmy episode or turn was captured.'
  Add-Check 'WIN-ISOLATION-01' 'pass' 'Codex auth, sessions, Memmy databases, logs, temp files, and install location were confined to the disposable profile.'
} catch {
  $errorText = Get-SafeError $_.Exception.Message $profileRoot
  Add-Check 'WIN-ACCEPTANCE-ERROR' 'fail' $errorText
} finally {
  Stop-MemmyProcess $memmyProcess
  if ($codexLoginAttempted -and $codexPath -and $codexEnvironment) {
    try {
      $logoutRun = Invoke-NativeCapture $codexPath @('logout') $workspace $codexEnvironment 60
      if ($logoutRun.ExitCode -ne 0) {
        $safeToRemoveProfile = $false
        $logoutError = Get-SafeError ("Temporary Codex logout failed with exit code {0}: {1}" -f $logoutRun.ExitCode, $logoutRun.Stderr.Trim()) $profileRoot
        Add-Check 'WIN-CODEX-LOGOUT-01' 'fail' "$logoutError The isolated profile was retained; set CODEX_HOME to %TEMP%\Memmy Codex Hook Acceptance $runId\home\.codex and run codex logout."
      } else {
        Add-Check 'WIN-CODEX-LOGOUT-01' 'pass' 'Temporary Codex credentials were logged out before the disposable profile was removed.'
      }
    } catch {
      $safeToRemoveProfile = $false
      Add-Check 'WIN-CODEX-LOGOUT-01' 'fail' (Get-SafeError $_.Exception.Message $profileRoot)
    }
  }
  if ($profileCreated) {
    try {
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($profileRoot) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    } catch { }
  }
  $uninstaller = Join-Path $installDirectory 'Uninstall Memmy.exe'
  if ($installerAttempted -and (Test-Path -LiteralPath $uninstaller -PathType Leaf)) {
    try {
      $uninstallRun = Invoke-NativeCapture $uninstaller @('/S') $installDirectory @{ USERPROFILE = $profileHome; APPDATA = (Join-Path $profileRoot 'app-data'); LOCALAPPDATA = (Join-Path $profileRoot 'local-app-data'); TEMP = (Join-Path $profileRoot 'temp'); TMP = (Join-Path $profileRoot 'temp') } 120
      if ($uninstallRun.ExitCode -ne 0) { Add-Check 'WIN-MEMMY-UNINSTALL-01' 'fail' "Memmy NSIS cleanup returned exit code $($uninstallRun.ExitCode)." }
      else { Add-Check 'WIN-MEMMY-UNINSTALL-01' 'pass' 'The temporary Memmy app installation was removed with its NSIS uninstaller.' }
    } catch { Add-Check 'WIN-MEMMY-UNINSTALL-01' 'fail' (Get-SafeError $_.Exception.Message $profileRoot) }
  } elseif ($appInstalled) {
    Add-Check 'WIN-MEMMY-UNINSTALL-01' 'fail' 'The installed acceptance app has no NSIS uninstaller; inspect the temporary install directory.'
  }
  if ($installerAttempted -and $registrySnapshots) {
    try {
      $remainingEntries = @(Get-UninstallEntriesForInstallPath $installDirectory)
      if ($remainingEntries.Count -eq 0) {
        Add-Check 'WIN-MEMMY-REGISTRY-02' 'pass' 'The acceptance uninstall registration was removed after uninstall.'
      } else {
        Add-Check 'WIN-MEMMY-REGISTRY-02' 'fail' ("Uninstall registrations remain for the temporary path: " + ($remainingEntries -join ', '))
      }
      $registryUnchanged = $true
      foreach ($registryValue in @(
        @{ name = 'HKCU Environment Path'; path = 'Environment'; value = 'Path'; before = $registrySnapshots.userPath },
        @{ name = 'regular Memmy login item'; path = 'Software\Microsoft\Windows\CurrentVersion\Run'; value = 'cn.memtensor.memmy'; before = $registrySnapshots.regularMemmyRun },
        @{ name = 'acceptance Memmy login item'; path = 'Software\Microsoft\Windows\CurrentVersion\Run'; value = 'cn.memtensor.memmy.codex-acceptance'; before = $registrySnapshots.acceptanceMemmyRun }
      )) {
        $after = Get-HkcuValueSnapshot $registryValue.path $registryValue.value
        if (-not (Test-HkcuValueSnapshotEqual $registryValue.before $after)) {
          $registryUnchanged = $false
          Add-Check 'WIN-HKCU-ISOLATION-01' 'fail' ("HKCU value changed during acceptance: " + $registryValue.name + '. Inspect and restore it if this was not an expected concurrent user change.')
        }
      }
      if ($registryUnchanged) {
        Add-Check 'WIN-HKCU-ISOLATION-01' 'pass' 'HKCU user PATH and both regular/acceptance Memmy login-item values match their pre-install snapshots.'
      }
    } catch {
      Add-Check 'WIN-HKCU-ISOLATION-01' 'fail' (Get-SafeError $_.Exception.Message $profileRoot)
    }
  }
  if ($codexCache) {
    try {
      $cacheItem = Get-Item -LiteralPath $codexCache -Force -ErrorAction SilentlyContinue
      if ($cacheItem -and ($cacheItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        # Delete the junction itself, never recurse through it into the installed Codex directory.
        [IO.Directory]::Delete($codexCache, $false)
        if (Test-Path -LiteralPath $codexCache) { $safeToRemoveProfile = $false }
      }
    } catch { $safeToRemoveProfile = $false }
  }
  if ($profileCreated -and $safeToRemoveProfile -and (Test-Path -LiteralPath $profileRoot)) {
    try { Remove-Item -LiteralPath $profileRoot -Recurse -Force -ErrorAction Stop }
    catch { Add-Check 'WIN-ISOLATION-CLEANUP' 'fail' 'The disposable profile could not be fully removed; inspect the temp directory before retrying.' }
  } elseif ($profileCreated -and -not $safeToRemoveProfile) {
    Add-Check 'WIN-ISOLATION-CLEANUP' 'fail' 'The isolated Codex junction could not be safely removed; the temporary profile was left intact to protect the real Codex installation.'
  }
  $failed = @($script:Checks | Where-Object { $_.status -eq 'fail' }).Count -gt 0
  $report = [ordered]@{
    schemaVersion = 1
    acceptance = 'Windows Codex Hook install / capture / uninstall'
    runId = $runId
    status = if ($failed) { 'FAIL' } else { 'PASS' }
    startedAt = $startedAt.ToString('o')
    finishedAt = [DateTime]::UtcNow.ToString('o')
    host = [ordered]@{ os = [Environment]::OSVersion.VersionString; architecture = 'x64' }
    inputs = [ordered]@{
      installer = if ($installerPathResolved) { [IO.Path]::GetFileName($installerPathResolved) } else { $null }
      installerSha256 = if ($installerPathResolved -and (Test-Path -LiteralPath $installerPathResolved)) { (Get-FileHash -Algorithm SHA256 -LiteralPath $installerPathResolved).Hash } else { $null }
      codexExecutable = if ($codexPath) { Format-SafePath $codexPath } else { $null }
      nodeVersion = if ($nodeVersion) { $nodeVersion.Stdout.Trim() } else { $null }
      codexVersion = if ($codexVersion) { $codexVersion.Stdout.Trim() } else { $null }
      codexPathWasRemovedFromMemmyPath = $codexPathWasRemovedFromMemmyPath
      codexExecutableOverrideWasUnset = $codexExecutableOverrideWasUnset
    }
    checks = @($script:Checks)
    failure = $errorText
    temporaryProfileRemoved = -not (Test-Path -LiteralPath $profileRoot)
  }
  New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
  $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}

Write-Host ''
if (@($script:Checks | Where-Object { $_.status -eq 'fail' }).Count -gt 0) {
  Write-Host "验收失败。证据报告：$reportPath" -ForegroundColor Red
  if ($errorText) { Write-Host $errorText -ForegroundColor Red }
  exit 1
}
Write-Host "Windows Codex Hook 验收通过。证据报告：$reportPath" -ForegroundColor Green
