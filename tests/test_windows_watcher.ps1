# Windows watcher integration tests. No installer, scheduled-task or registry
# writes, proxy package or real CLI are involved. Run in Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Watcher integration tests require Windows' }

function Assert-True($condition, [string]$message) { if (-not $condition) { throw $message } }
function Assert-Equal($actual, $expected, [string]$message) {
  if ($actual -cne $expected) { throw "$message; expected '$expected', got '$actual'" }
}
function Read-EmbeddedSource($ast, [string]$name) {
  $assignments = @($ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -eq $name
  }, $true))
  $literal = @($assignments[0].Right.FindAll({ param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
      $node.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString
  }, $true))
  Assert-Equal $literal.Count 1 "Expected one embedded source: $name"
  return $literal[0].Value
}
function Write-Utf8([string]$path, [string]$value) { [IO.File]::WriteAllText($path, $value, [Text.UTF8Encoding]::new($true)) }
function Get-Digest([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
function Copy-Update([string]$destination, [long]$length = 13MB) {
  [IO.File]::Copy((Join-Path $env:SystemRoot 'System32\where.exe'), $destination, $true)
  $stream = [IO.File]::OpenWrite($destination)
  try { $stream.SetLength($length) } finally { $stream.Dispose() }
}
function Wait-Until([scriptblock]$condition, [string]$message, [int]$timeout = 15000) {
  $clock = [Diagnostics.Stopwatch]::StartNew()
  do {
    if (& $condition) { return }
    if ($null -ne $script:watcher -and $script:watcher.HasExited) { throw "Watcher exited ($($script:watcher.ExitCode)): $message" }
    Start-Sleep -Milliseconds 100
  } while ($clock.ElapsedMilliseconds -lt $timeout)
  throw "Deadline exceeded: $message"
}
function Move-DirectoryWhenReleased([string]$source, [string]$destination) {
  # Observing the shim precedes transaction cleanup and child exit. Allow only
  # transient native sharing/access errors; a persistent watcher lock still fails.
  $deadline = [Diagnostics.Stopwatch]::StartNew()
  $attempts = 0
  do {
    $attempts++
    try {
      [IO.Directory]::Move($source, $destination)
      Write-Host "Application parent rename succeeded after $attempts attempt(s)"
      return
    } catch {
      $errorCode = $_.Exception.InnerException.HResult -band 0xffff
      if (@(5, 32, 33) -notcontains $errorCode -or $deadline.ElapsedMilliseconds -ge 5000) { throw }
    }
    Start-Sleep -Milliseconds 50
  } while ($true)
}
function Invoke-Control([string]$mode, [int]$timeout = 5000) {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $script:executable
  $start.Arguments = $mode + ' "' + $script:prefix + '"'
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $process = [Diagnostics.Process]::Start($start)
  try {
    if (-not $process.WaitForExit($timeout)) { throw "Watcher control timed out: $mode" }
    return $process.ExitCode
  } finally {
    if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(1000) }
    $process.Dispose()
  }
}
function Start-TestWatcher {
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $script:executable
  $start.Arguments = '--run "' + $script:prefix + '" "' + $script:state.shimPath + '" "' + $script:state.target + '"'
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $script:watcher = [Diagnostics.Process]::Start($start)
  Wait-Until { (Invoke-Control '--status') -eq 0 } 'Watcher readiness event was not set'
}
function Stop-TestWatcher {
  if ($null -eq $script:watcher) { return }
  Assert-Equal (Invoke-Control '--stop' 50000) 0 'Owned watcher did not accept stop'
  Assert-True ($script:watcher.WaitForExit(5000)) 'Owned watcher did not exit after stop'
  Assert-Equal $script:watcher.ExitCode 0 'Owned watcher failed during graceful stop'
  $script:watcher.Dispose()
  $script:watcher = $null
}

$savedPath = $env:PATH
$script:watcher = $null
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('agy-watcher-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  $tokens = $null; $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path $PSScriptRoot -Parent) 'install.ps1'), [ref]$tokens, [ref]$parseErrors)
  Assert-True (-not $parseErrors) 'Installer has PowerShell parse errors'
  $script:prefix = Join-Path $scratch 'profile Unicode Ж ! & (watcher)\installation'
  $cliParent = Join-Path $scratch 'logical parent'
  $cli = Join-Path $cliParent 'bin'
  New-Item -ItemType Directory -Path $prefix, $cli -Force | Out-Null
  $support = Join-Path $prefix 'windows-support.ps1'
  Write-Utf8 $support (Read-EmbeddedSource $ast 'windowsSupportSource')
  . $support
  # All filesystem, compilation, watcher and repair logic remains real.
  function Get-AgyUserPath { return $script:mockUserPath }
  function Set-AgyUserPath([string]$Value) { $script:mockUserPath = $Value }
  function Send-AgyEnvironmentChange {}
  function Get-ScheduledTask { param($TaskName, $ErrorAction) return $null }
  $script:mockUserPath = ''
  $env:PATH = $cli + ';' + (Join-Path $env:SystemRoot 'System32')
  $source = Join-Path $prefix 'windows-launcher.cs'
  Write-Utf8 $source (Read-EmbeddedSource $ast 'windowsLauncherSource')
  $watcherSource = Read-EmbeddedSource $ast 'windowsWatcherSource'
  $watcherSourcePath = Join-Path $prefix 'windows-watcher.cs'
  Write-Utf8 $watcherSourcePath $watcherSource
  $script:executable = Get-AgyWatcherExecutable $prefix $watcherSourcePath
  $certificate = Join-Path $prefix 'certificate.pem'
  Write-Utf8 $certificate 'synthetic certificate'
  $shim = Join-Path $cli 'agy.exe'
  Copy-Update $shim 12MB
  $script:state = Install-AgyWindowsShim -Prefix $prefix -Port 65530 -Certificate $certificate -SourcePath $source
  $heal = (Read-EmbeddedSource $ast 'healPs1').Replace('@PREFIX@', $prefix.Replace("'", "''"))
  $healPath = Join-Path $prefix 'heal.ps1'
  Write-Utf8 $healPath $heal

  # Unit proof for the actual overflow callback: it only marks a new generation
  # and wakes the worker. There is no queued work or filesystem access here.
  $watcherType = @(Add-Type -TypeDefinition $watcherSource -PassThru | Where-Object { $_.Name -eq 'AgyWatcher' })[0]
  $flags = [Reflection.BindingFlags]'NonPublic,Static'
  $counter = $watcherType.GetField('generation', $flags)
  $signal = $watcherType.GetField('Changed', $flags).GetValue($null)
  $before = $counter.GetValue($null)
  $watcherType.GetMethod('Overflow', $flags).Invoke($null, @($null, [IO.ErrorEventArgs]::new([IO.InternalBufferOverflowException]::new('synthetic overflow'))))
  Assert-Equal ($counter.GetValue($null) - $before) 1 'Overflow did not invalidate the worker generation'
  Assert-True ($signal.WaitOne(0)) 'Overflow did not signal reconciliation'

  # Windows allows renaming the watched anchor itself, but an open watcher
  # below it pins that ancestor. Prove the native primitive before our full flow.
  $primitiveAnchor = Join-Path $scratch 'native-rename-anchor'
  $primitiveInner = Join-Path $primitiveAnchor 'bin'
  $primitiveMoved = $primitiveAnchor + '.moved'
  [void][IO.Directory]::CreateDirectory($primitiveInner)
  $descendantWatcher = [IO.FileSystemWatcher]::new($primitiveInner)
  try {
    $descendantWatcher.EnableRaisingEvents = $true
    $blocked = $false
    try { [IO.Directory]::Move($primitiveAnchor, $primitiveMoved) }
    catch { $blocked = ($_.Exception.InnerException.HResult -band 0xffff) -eq 5 }
    Assert-True $blocked 'Descendant watcher negative control did not reproduce native ancestor AccessDenied'
  } finally { $descendantWatcher.Dispose() }
  $anchorWatcher = [IO.FileSystemWatcher]::new($primitiveAnchor)
  try {
    $anchorWatcher.IncludeSubdirectories = $true
    $anchorWatcher.EnableRaisingEvents = $true
    Move-DirectoryWhenReleased $primitiveAnchor $primitiveMoved
    Assert-True ([IO.Directory]::Exists($primitiveMoved)) 'Recursive anchor-only watcher blocked its own rename'
    Write-Host 'Native directory watcher A/B passed: descendant blocked, recursive anchor allowed rename'
  } finally { $anchorWatcher.Dispose() }

  # Metadata watches must not add a handle below the application anchor or turn
  # the profile into a recursive watch. Overlay watches coalesce into the prefix.
  $watcherType.GetField('prefix', $flags).SetValue($null, $prefix)
  $plan = $watcherType.GetField('desired', $flags).GetValue($null)
  $configure = $watcherType.GetMethod('ConfigureSubscriptions', $flags)
  [void]$configure.Invoke($null, @($shim))
  Assert-True ($plan.ContainsKey($cliParent) -and $plan[$cliParent]) 'Application anchor was not recursive'
  Assert-True (-not $plan.ContainsKey($cli)) 'Subscription layout still held a descendant directory handle'
  Assert-True ($plan.ContainsKey($prefix) -and -not $plan[$prefix]) 'State metadata expanded to a recursive profile watch'
  Assert-Equal @($plan.GetEnumerator() | Where-Object { $_.Value }).Count 1 'Unexpected recursive watch outside application subtree'
  $plan.Clear()
  $overlayShim = Join-Path $prefix 'bin\agy.exe'
  [void]$configure.Invoke($null, @($overlayShim))
  Assert-True ($plan[$prefix]) 'Overlay prefix was not a recursive owned anchor'
  Assert-True (-not $plan.ContainsKey((Join-Path $prefix 'bin'))) 'Overlay configuration recreated a descendant handle'
  Assert-True (-not $plan.ContainsKey($cli)) 'Overlay watch retained a handle on the external managed launcher directory'
  $plan.Clear()
  $driveRoot = [IO.Path]::GetPathRoot($shim)
  $normalizedRoot = $watcherType.GetMethod('FullPath', $flags).Invoke($null, @($driveRoot))
  Assert-Equal $normalizedRoot $driveRoot 'Drive root became a drive-relative current directory'
  [void]$configure.Invoke($null, @((Join-Path $driveRoot 'agy.exe')))
  Assert-True ($plan.ContainsKey($driveRoot) -and -not $plan[$driveRoot]) 'Shallow root path lost its nonrecursive root watch'
  Assert-Equal @($plan.GetEnumerator() | Where-Object { $_.Value }).Count 0 'Shallow path created a broad recursive watch'
  $plan.Clear()

  # An update preceding startup must be reconciled after subscribing, without
  # needing another filesystem event.
  Copy-Update $shim
  $expected = Get-Digest $shim
  Start-TestWatcher
  Wait-Until { Test-AgyNativeShim $shim } 'Initial reconciliation did not repair the already present update'
  Assert-Equal (Get-Digest $state.target) $expected 'Initial reconciliation lost the update'
  $configPath = Join-Path $cli 'agy-launcher.json'
  $configStamp = [IO.File]::GetLastWriteTimeUtc($configPath)
  Assert-Equal (Invoke-Control '--status') 0 'Watcher did not stay ready'
  # A second copy must leave the exact first owner running.
  $duplicateStart = [Diagnostics.ProcessStartInfo]::new()
  $duplicateStart.FileName = $executable
  $duplicateStart.Arguments = '--run "' + $prefix + '" "' + $shim + '" "' + $state.target + '"'
  $duplicateStart.UseShellExecute = $false
  $duplicate = [Diagnostics.Process]::Start($duplicateStart)
  try {
    Assert-True ($duplicate.WaitForExit(5000)) 'Duplicate watcher did not exit'
    Assert-Equal $duplicate.ExitCode 0 'Duplicate watcher failed its single-instance check'
  } finally {
    if (-not $duplicate.HasExited) { $duplicate.Kill(); [void]$duplicate.WaitForExit(1000) }
    $duplicate.Dispose()
  }
  Assert-True (-not $watcher.HasExited) 'Duplicate watcher stopped the original owner'
  Assert-Equal ([IO.File]::GetLastWriteTimeUtc($configPath)) $configStamp 'Healthy reconciliation rewrote config'

  # The updater deliberately leaves a deletion gap; elapsed time is itself the
  # negative assertion. Event-mode must not insert the previous original.
  [IO.File]::Delete($shim)
  $gap = [Diagnostics.Stopwatch]::StartNew()
  while ($gap.ElapsedMilliseconds -lt 1200) {
    Assert-True (-not [IO.File]::Exists($shim)) 'Event heal inserted a shim into the updater deletion gap'
    Start-Sleep -Milliseconds 50
  }
  $incoming = Join-Path $cli 'agy.incoming'
  Copy-Update $incoming 14MB
  $expected = Get-Digest $incoming
  [IO.File]::Move($incoming, $shim)
  Wait-Until { Test-AgyNativeShim $shim } 'Rename after a deletion gap did not repair'
  Assert-Equal (Get-Digest $state.target) $expected 'Rename repair lost the newly arrived original'

  # A whole logical parent can be renamed away. Subscriptions on its ancestors
  # must discover the recreated path and recover config from prefix metadata.
  $retired = $cliParent + '.retired'
  Move-DirectoryWhenReleased $cliParent $retired
  [void][IO.Directory]::CreateDirectory($cli)
  Copy-Update $shim 15MB
  $expected = Get-Digest $shim
  Wait-Until { Test-AgyNativeShim $shim } 'Parent replacement did not rebind logical subscriptions'
  Assert-Equal (Get-Digest $state.target) $expected 'Parent replacement lost the replacement CLI'
  Assert-True ([IO.File]::Exists($configPath)) 'Parent replacement did not recover configuration'
  Assert-True ([IO.File]::Exists((Join-Path $retired 'bin\agy.real.exe'))) 'Repair changed the retired directory'

  # A small foreign replacement stays untouched and cannot overwrite the backup.
  $backup = Get-Digest $state.target
  Write-Utf8 $shim 'small foreign replacement'
  Assert-Equal (Repair-AgyWindowsShim -Prefix $prefix -Watcher) 'Pending' 'Invalid replacement was not pending'
  Assert-Equal ([IO.File]::ReadAllText($shim)) 'small foreign replacement' 'Invalid replacement was overwritten'
  Assert-Equal (Get-Digest $state.target) $backup 'Invalid replacement damaged the known-good original'
  Copy-Update $shim 16MB
  Wait-Until { Test-AgyNativeShim $shim } 'Watcher did not recover after an invalid replacement'

  # Stop during an owned repair must await that exact child and prevent starts
  # racing teardown. No process is selected by its name.
  $active = Join-Path $prefix 'repair-active'
  $slowHeal = $heal.Replace('  if ($Watcher) {', "  if (`$Watcher) { [IO.File]::WriteAllText('$($active.Replace("'", "''"))', 'active'); Start-Sleep -Seconds 2 }`r`n  if (`$Watcher) {")
  Write-Utf8 $healPath $slowHeal
  Copy-Update $shim 17MB
  Wait-Until { [IO.File]::Exists($active) } 'Slow repair did not start'
  Stop-AgyWindowsWatcher -Prefix $prefix
  Assert-True ($watcher.WaitForExit(5000)) 'Watcher did not exit after the active repair'
  Assert-Equal $watcher.ExitCode 0 'Watcher failed graceful stop during repair'
  $watcher.Dispose(); $script:watcher = $null
  Assert-True (Test-AgyNativeShim $shim) 'Stop interrupted the active repair before commit'
  # A late task action sees the disabled marker and exits without touching files.
  $late = [Diagnostics.Process]::Start($duplicateStart)
  try {
    Assert-True ($late.WaitForExit(5000)) 'Disabled watcher still started'
    Assert-Equal $late.ExitCode 0 'Disabled watcher did not exit cleanly'
  } finally { if (-not $late.HasExited) { $late.Kill(); [void]$late.WaitForExit(1000) }; $late.Dispose() }
  Remove-AgyWindowsShim -Prefix $prefix
  Assert-True (-not (Test-AgyNativeShim $shim)) 'Removal after graceful stop did not restore the original'

  # An unexpected child result preserves only a bounded output tail. The
  # fixture emits more than a pipe buffer without depending on newline framing.
  $script:state = Install-AgyWindowsShim -Prefix $prefix -Port 65530 -Certificate $certificate -SourcePath $source
  [IO.File]::Delete((Join-Path $prefix 'watcher.disabled'))
  $watcherLog = Join-Path $prefix 'watcher.log'
  [IO.File]::WriteAllText($watcherLog, ('x' * 140000))
  Write-Utf8 $healPath @'
param([switch]$Watcher)
for ($index = 0; $index -lt 40; $index++) { [Console]::Out.Write(('z' * 65536)) }
exit 99
'@
  $script:watcher = [Diagnostics.Process]::Start($duplicateStart)
  Assert-True ($watcher.WaitForExit(15000)) 'Unexpected child status did not stop the watcher'
  Assert-Equal $watcher.ExitCode 1 'Unexpected child status was silently accepted'
  $watcher.Dispose(); $script:watcher = $null
  Assert-True ((Get-Item -LiteralPath $watcherLog).Length -lt 8192) 'Child diagnostics or log rotation exceeded their bounds'

  # A stuck child is terminated by its captured process handle and its failure
  # reaches the supervisor through a nonzero exit status.
  $timeoutPidFile = Join-Path $prefix 'timeout-child.pid'
  $timeoutHeal = "param([switch]`$Watcher)`r`n[IO.File]::WriteAllText('$($timeoutPidFile.Replace("'", "''"))', [string]`$PID)`r`nStart-Sleep -Seconds 60`r`n"
  Write-Utf8 $healPath $timeoutHeal
  $script:watcher = [Diagnostics.Process]::Start($duplicateStart)
  Wait-Until { [IO.File]::Exists($timeoutPidFile) } 'Timeout fixture child did not start'
  $childId = [int][IO.File]::ReadAllText($timeoutPidFile)
  Assert-True ($watcher.WaitForExit(30000)) 'Stuck heal child exceeded the watcher deadline'
  Assert-Equal $watcher.ExitCode 1 'Stuck heal child did not produce a supervisor failure'
  $watcher.Dispose(); $script:watcher = $null
  Assert-True ($null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Timed-out owned heal child survived'
  Write-Utf8 $healPath $heal
  Stop-AgyWindowsWatcher -Prefix $prefix
  Remove-AgyWindowsShim -Prefix $prefix

  Write-Host 'Windows watcher integration tests passed'
} finally {
  if ($null -ne $script:watcher) {
    try { Stop-TestWatcher } catch {
      # Exact process handle captured at launch; this is test cleanup only.
      if (-not $script:watcher.HasExited) { $script:watcher.Kill(); [void]$script:watcher.WaitForExit(5000) }
      $script:watcher.Dispose()
    }
  }
  $env:PATH = $savedPath
  if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
}
