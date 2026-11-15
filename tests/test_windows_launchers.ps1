# Native launcher integration tests. Run with Windows PowerShell 5.1; no installer,
# proxy package, registry writes, scheduled tasks, or real CLI are involved.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
  throw "Native launcher integration tests require Windows"
}

function Assert-True($condition, [string]$message) {
  if (-not $condition) { throw $message }
}
function Assert-Equal($actual, $expected, [string]$message) {
  if ($actual -cne $expected) { throw "$message; expected '$expected', got '$actual'" }
}
function Assert-Throws([scriptblock]$action, [string]$expectedMessage) {
  $failure = $null
  try { & $action | Out-Null } catch { $failure = $_.Exception.Message }
  Assert-True ($failure -and $failure.Contains($expectedMessage)) "Expected error containing '$expectedMessage'; got '$failure'"
}
function Assert-Arguments($actual, [string[]]$expected, [string]$message) {
  $received = @($actual)
  Assert-Equal $received.Count $expected.Count "$message (argument count)"
  for ($index = 0; $index -lt $expected.Count; $index++) {
    Assert-Equal ([string]$received[$index]) $expected[$index] "$message (argument $index)"
  }
}
function Read-EmbeddedSource($ast, [string]$name) {
  $assignments = @($ast.FindAll({
    param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
      $node.Left.VariablePath.UserPath -eq $name
  }, $true))
  Assert-Equal $assignments.Count 1 "Expected one embedded $name assignment"
  $literals = @($assignments[0].Right.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
      $node.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString
  }, $true))
  Assert-Equal $literals.Count 1 "Expected a literal embedded $name source"
  return $literals[0].Value
}
function Write-Utf8([string]$path, [string]$value) {
  [IO.File]::WriteAllText($path, $value, [Text.UTF8Encoding]::new($false))
}
function Get-Digest([string]$path) {
  return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}
function Quote-NativeArgument([AllowEmptyString()][string]$value) {
  # The direct-fixture control below proves this test harness's CRT encoding
  # independently of the launcher's own argument encoder.
  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append('"')
  $slashes = 0
  foreach ($character in $value.ToCharArray()) {
    if ($character -eq '\') { $slashes++; continue }
    if ($character -eq '"') {
      [void]$builder.Append(('\' * ($slashes * 2 + 1)))
    } else {
      [void]$builder.Append(('\' * $slashes))
    }
    [void]$builder.Append($character)
    $slashes = 0
  }
  [void]$builder.Append(('\' * ($slashes * 2)))
  [void]$builder.Append('"')
  return $builder.ToString()
}
function Stop-OwnedProcess([Diagnostics.Process]$process) {
  if ($null -eq $process -or $process.HasExited) { return }
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = Join-Path $env:SystemRoot "System32\taskkill.exe"
  $start.Arguments = "/T /F /PID $($process.Id)"
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $killer = [Diagnostics.Process]::Start($start)
  try {
    if (-not $killer.WaitForExit(2000)) { $killer.Kill(); [void]$killer.WaitForExit(1000) }
  } finally { $killer.Dispose() }
  if (-not $process.WaitForExit(2000)) { $process.Kill(); [void]$process.WaitForExit(1000) }
}
function Invoke-OwnedProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory,
    [hashtable]$Environment = @{},
    [AllowEmptyString()][string]$StandardInput = "",
    [ValidateRange(1, 30000)][int]$TimeoutMilliseconds = 8000
  )
  $start = [Diagnostics.ProcessStartInfo]::new()
  $start.FileName = $FilePath
  $start.Arguments = (($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
  $start.WorkingDirectory = $WorkingDirectory
  $start.UseShellExecute = $false
  $start.CreateNoWindow = $true
  $start.RedirectStandardInput = $true
  $start.RedirectStandardOutput = $true
  $start.RedirectStandardError = $true
  foreach ($key in $Environment.Keys) { $start.EnvironmentVariables[$key] = [string]$Environment[$key] }
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $start
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $started = $false
  try {
    $started = $process.Start()
    Assert-True $started "Could not start $FilePath"
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($StandardInput)
    $process.StandardInput.Close()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) { throw "Process exceeded $TimeoutMilliseconds ms: $FilePath" }
    $remaining = [Math]::Max(1, $TimeoutMilliseconds - [int]$watch.ElapsedMilliseconds)
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), $remaining)) {
      throw "Process streams exceeded $TimeoutMilliseconds ms: $FilePath"
    }
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result }
  } finally {
    if ($started) { Stop-OwnedProcess $process }
    $process.Dispose()
  }
}
function Invoke-Fixture([string]$path, [string[]]$arguments, [string]$inputText = "") {
  $output = Join-Path $script:scratch ("result-" + [guid]::NewGuid().ToString("N") + ".json")
  try {
    $result = Invoke-OwnedProcess -FilePath $path -Arguments $arguments -WorkingDirectory $script:workingDirectory -StandardInput $inputText -Environment @{
      AGY_TEST_OUTPUT = $output
      AGY_TEST_READ_STDIN = "1"
      AGY_TEST_EXIT = "23"
    }
    Assert-True (-not [IO.File]::Exists($script:injectionSentinel)) "An argument was interpreted as a shell command"
    Assert-Equal $result.ExitCode 23 "Child exit code was not propagated"
    Assert-Equal $result.Stdout "fixture-stdout`r`n" "Child stdout was changed"
    Assert-Equal $result.Stderr "fixture-stderr`r`n" "Child stderr was changed"
    Assert-True ([IO.File]::Exists($output)) "Fixture did not record its invocation"
    $record = [IO.File]::ReadAllText($output) | ConvertFrom-Json
    Assert-Arguments $record.arguments $arguments "Arguments changed through $path"
    Assert-Equal $record.workingDirectory $script:workingDirectory "Child working directory changed"
    Assert-Equal $record.standardInput $inputText "Child stdin was changed"
    Assert-Equal $env:HTTPS_PROXY $script:parentProxy "Launcher changed its parent proxy"
    Assert-Equal $env:SSL_CERT_FILE $script:parentCertificate "Launcher changed its parent certificate"
    return $record
  } finally {
    if ([IO.File]::Exists($output)) { [IO.File]::Delete($output) }
  }
}
function Assert-ProxyEnvironment($record, [int]$port, [bool]$available) {
  if ($available) {
    Assert-Equal $record.environment.HTTPS_PROXY "http://127.0.0.1:$port" "Proxy port was not applied to child"
    Assert-Equal $record.environment.SSL_CERT_FILE $script:certificate "Certificate was not applied to child"
  } else {
    Assert-Equal $record.environment.HTTPS_PROXY $script:parentProxy "Unavailable proxy replaced parent environment"
    Assert-Equal $record.environment.SSL_CERT_FILE $script:parentCertificate "Unavailable proxy replaced parent certificate"
  }
  Assert-Equal $record.environment.NODE_EXTRA_CA_CERTS "parent-node-ca" "Unrelated child environment was changed"
}
function Read-State([string]$prefix) {
  return ([IO.File]::ReadAllText((Join-Path $prefix "shim-state.json")) | ConvertFrom-Json)
}
function Assert-Configuration($state, [int]$port, [string]$kind) {
  $configuration = [IO.File]::ReadAllText((Join-Path (Split-Path $state.shimPath -Parent) "agy-launcher.json")) | ConvertFrom-Json
  Assert-Equal $configuration.version 1 "Launcher configuration version changed"
  Assert-Equal $configuration.target $state.target "Launcher configuration target differs from state"
  Assert-Equal $configuration.kind $kind "Launcher kind differs from discovered target"
  Assert-Equal $configuration.port $port "Selected port was not persisted to launcher"
  Assert-Equal $configuration.certificate $script:certificate "Certificate path changed"
  Assert-True ([IO.Path]::IsPathRooted($configuration.target)) "Launcher target is not absolute"
  Assert-True ([IO.Path]::IsPathRooted($configuration.certificate)) "Certificate path is not absolute"
}
function New-Scenario([string]$name) {
  $directory = Join-Path $script:profile $name
  $prefix = Join-Path $directory "installation"
  $bin = Join-Path $directory "cli"
  New-Item -ItemType Directory -Path $prefix, $bin -Force | Out-Null
  $script:mockUserPath = Join-Path $directory "foreign-before"
  $env:PATH = $bin + ";" + $script:systemPath
  return [pscustomobject]@{ Prefix = $prefix; Bin = $bin; Directory = $directory }
}
function Install-Scenario($scenario, [int]$port) {
  Install-AgyWindowsShim -Prefix $scenario.Prefix -Port $port -Certificate $script:certificate -SourcePath $script:launcherSourcePath | Out-Null
  $state = Read-State $scenario.Prefix
  Assert-True (Test-AgyNativeShim -Path $state.shimPath) "Installation did not create a native shim"
  return $state
}
function Copy-PaddedFixture([string]$destination, [long]$length = 12MB) {
  [IO.File]::Copy($script:fixturePath, $destination, $true)
  $stream = [IO.File]::OpenWrite($destination)
  try { $stream.SetLength($length) } finally { $stream.Dispose() }
}
function Write-CmdFixture([string]$directory) {
  $target = Join-Path $directory "agy.cmd"
  [IO.File]::Copy($script:fixturePath, (Join-Path $directory "fixture.exe"), $true)
  Write-Utf8 $target "@ECHO off`r`nSETLOCAL`r`nSET `"AGY_TEST_LAUNCHER_NAME=%~n0`"`r`n`"%~dp0fixture.exe`" %*`r`nexit /b %errorlevel%`r`n"
  return $target
}

$savedEnvironment = @{}
foreach ($name in @("USERPROFILE", "PATH", "HTTPS_PROXY", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS")) {
  $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}
$script:scratch = Join-Path ([IO.Path]::GetTempPath()) ("agy-windows-launcher-tests-" + [guid]::NewGuid().ToString("N"))
$listener = $null
$savedInputEncoding = [Console]::InputEncoding
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  # .NET Framework uses Console.InputEncoding for the redirected stdin writer.
  # Avoid adding an encoding preamble to the fixture's input bytes.
  [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
  $script:profile = Join-Path $scratch "profile Unicode Ж ! & (test)"
  $script:workingDirectory = Join-Path $profile "working directory"
  $script:injectionSentinel = Join-Path $workingDirectory "agy-injected-sentinel.txt"
  New-Item -ItemType Directory -Path $workingDirectory -Force | Out-Null
  $env:USERPROFILE = $profile
  $script:systemPath = (Join-Path $env:SystemRoot "System32") + ";" + (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0")
  $env:PATH = $systemPath
  $script:parentProxy = "http://parent.invalid:3333"
  $script:parentCertificate = "parent-certificate.pem"
  $env:HTTPS_PROXY = $parentProxy
  $env:SSL_CERT_FILE = $parentCertificate
  $env:NODE_EXTRA_CA_CERTS = "parent-node-ca"
  $script:certificate = Join-Path $profile "certificate Unicode Ж ! &.pem"
  Write-Utf8 $certificate "synthetic certificate"

  $installer = Join-Path (Split-Path $PSScriptRoot -Parent) "install.ps1"
  $tokens = $null
  $parseErrors = $null
  $ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
  Assert-True (-not $parseErrors) "Installer has PowerShell parse errors"
  $supportPath = Join-Path $scratch "windows-support.ps1"
  $script:launcherSourcePath = Join-Path $scratch "windows-launcher.cs"
  Write-Utf8 $supportPath (Read-EmbeddedSource $ast "windowsSupportSource")
  Write-Utf8 $launcherSourcePath (Read-EmbeddedSource $ast "windowsLauncherSource")
  . $supportPath
  # Mock only persistent User PATH access and its notification. File discovery,
  # compilation, state management, launch, repair and removal remain real.
  function Get-AgyUserPath { return $script:mockUserPath }
  function Set-AgyUserPath([string]$Value) { $script:mockUserPath = $Value }
  function Send-AgyEnvironmentChange {}

  $fixtureSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
class LauncherFixture {
    static int Main(string[] args) {
        var environment = new Dictionary<string, string>();
        foreach (var name in new[] { "HTTPS_PROXY", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "AGY_TEST_LAUNCHER_NAME" })
            environment[name] = Environment.GetEnvironmentVariable(name);
        var record = new Dictionary<string, object> {
            { "arguments", args },
            { "workingDirectory", Environment.CurrentDirectory },
            { "environment", environment },
            { "standardInput", Environment.GetEnvironmentVariable("AGY_TEST_READ_STDIN") == "1" ? Console.In.ReadToEnd() : "" }
        };
        File.WriteAllText(Environment.GetEnvironmentVariable("AGY_TEST_OUTPUT"), new JavaScriptSerializer().Serialize(record), new UTF8Encoding(false));
        Console.Out.WriteLine("fixture-stdout");
        Console.Error.WriteLine("fixture-stderr");
        return Int32.Parse(Environment.GetEnvironmentVariable("AGY_TEST_EXIT") ?? "0");
    }
}
'@
  $fixtureSourcePath = Join-Path $scratch "fixture.cs"
  $script:fixturePath = Join-Path $scratch "fixture.exe"
  Write-Utf8 $fixtureSourcePath $fixtureSource
  $compilers = @(
    (Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:SystemRoot "Microsoft.NET\Framework\v4.0.30319\csc.exe")
  )
  $availableCompilers = @($compilers | Where-Object { [IO.File]::Exists($_) })
  Assert-True ($availableCompilers.Count -gt 0) "Built-in .NET Framework C# compiler is missing"
  $compiler = $availableCompilers[0]
  $compile = Invoke-OwnedProcess -FilePath $compiler -Arguments @("/nologo", "/target:exe", "/reference:System.Web.Extensions.dll", "/out:$fixturePath", $fixtureSourcePath) -WorkingDirectory $scratch -TimeoutMilliseconds 30000
  Assert-Equal $compile.ExitCode 0 ("Fixture compilation failed: " + $compile.Stdout + $compile.Stderr)

  $arguments = @("", "two words", "Unicode Ж 中", "trailing\", 'embedded"quote', "%PATH%", "bang!value", "amp&value", "pipe|value", "caret^value", "(parentheses)", 'before" & echo INJECTED>agy-injected-sentinel.txt & rem "after')
  $control = Invoke-Fixture $fixturePath $arguments "input payload`r`n"
  Assert-ProxyEnvironment $control 1 $false

  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $listener.Start(32)
  $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  $listener.Stop()
  $listener = $null

  # A plain EXE is replaced in place and remains callable by strict EXE clients.
  $plain = New-Scenario "plain-exe"
  $plainExe = Join-Path $plain.Bin "agy.exe"
  Copy-PaddedFixture $plainExe
  $originalDigest = Get-Digest $plainExe
  $state = Install-Scenario $plain $port
  Assert-Equal $state.mode "inplace" "Plain EXE did not use in-place mode"
  Assert-Equal $state.shimPath $plainExe "Strict EXE path changed"
  Assert-Equal (Get-Digest $state.target) $originalDigest "Original EXE was not preserved"
  Assert-Configuration $state $port "exe"
  Assert-ProxyEnvironment (Invoke-Fixture $state.shimPath $arguments "plain stdin`r`n") $port $false

  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
  $listener.Start(32)
  Assert-ProxyEnvironment (Invoke-Fixture $state.shimPath $arguments) $port $true
  $nextListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
  $nextListener.Start(32)
  $listener.Stop()
  $listener = $nextListener
  $changedPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
  Assert-True ($changedPort -ne $port) "Port change fixture unexpectedly reused its previous port"
  $state = Install-Scenario $plain $changedPort
  Assert-Configuration $state $changedPort "exe"
  Assert-Equal (Get-Digest $state.target) $originalDigest "Reinstallation replaced the real EXE with the shim"
  Assert-ProxyEnvironment (Invoke-Fixture $state.shimPath @("reinstalled")) $changedPort $true
  $listener.Stop()
  $listener = $null

  # Fail after replacing an existing config: every previously committed file must
  # be restored, including the real CLI and the recovery metadata.
  $rollbackConfig = Join-Path $plain.Bin "agy-launcher.json"
  $rollbackFiles = @($state.shimPath, $state.target, $rollbackConfig, (Join-Path $plain.Prefix "shim-state.json"), (Join-Path $plain.Prefix "agy.exe.tpl"))
  $rollbackDigests = @{}
  foreach ($path in $rollbackFiles) { $rollbackDigests[$path] = Get-Digest $path }
  $transactionWriter = (Get-Command Set-AgyTransactionFile).ScriptBlock
  $script:configWriteFaultTriggered = $false
  & {
    function Set-AgyTransactionFile {
      param($Transaction, [string]$Path, [string]$Stage)
      $replacingConfig = $Path -ieq $rollbackConfig -and [IO.File]::Exists($Path)
      & $transactionWriter -Transaction $Transaction -Path $Path -Stage $Stage
      if ($replacingConfig) {
        $script:configWriteFaultTriggered = $true
        throw "synthetic failure after existing config replacement"
      }
    }
    Assert-Throws {
      Install-AgyWindowsShim -Prefix $plain.Prefix -Port $port -Certificate $certificate -SourcePath $launcherSourcePath
    } "synthetic failure after existing config replacement"
  }
  Assert-True $script:configWriteFaultTriggered "Configuration rollback injection did not execute"
  foreach ($path in $rollbackFiles) {
    Assert-Equal (Get-Digest $path) $rollbackDigests[$path] "Failed reinstallation did not restore $path"
  }
  Assert-Configuration (Read-State $plain.Prefix) $changedPort "exe"

  # A padded valid PE update is promoted; small junk must never replace the backup.
  Copy-PaddedFixture $plainExe 13MB
  $updateDigest = Get-Digest $plainExe
  Assert-True ($updateDigest -cne $originalDigest) "Update fixture did not change"
  Repair-AgyWindowsShim -Prefix $plain.Prefix | Out-Null
  Assert-True (Test-AgyNativeShim -Path $plainExe) "Heal did not restore native agy.exe"
  Assert-Equal (Get-Digest $state.target) $updateDigest "Heal did not retain the valid CLI update"
  # Event-mode deletion stays pending until the updater recreates its path;
  # healthy repeats are idempotent and do not rewrite the launcher config.
  $configPath = Join-Path $plain.Bin "agy-launcher.json"
  $configStamp = [IO.File]::GetLastWriteTimeUtc($configPath)
  Assert-Equal (Repair-AgyWindowsShim -Prefix $plain.Prefix -Watcher) "Healthy" "Healthy machine result changed"
  Assert-Equal ([IO.File]::GetLastWriteTimeUtc($configPath)) $configStamp "Healthy repair rewrote configuration"
  [IO.File]::Delete($plainExe)
  Assert-Equal (Repair-AgyWindowsShim -Prefix $plain.Prefix -Watcher) "Pending" "Deleted updater gap was not pending"
  Assert-True (-not [IO.File]::Exists($plainExe)) "Event heal restored an old binary into an updater gap"
  Repair-AgyWindowsShim -Prefix $plain.Prefix | Out-Null
  Assert-True (Test-AgyNativeShim $plainExe) "Fallback did not restore a persistently missing shim"

  # Trusted state can recreate a config removed with an updater's directory.
  [IO.File]::Delete($configPath)
  Assert-Equal (Repair-AgyWindowsShim -Prefix $plain.Prefix -Watcher) "Repaired" "Missing config did not recover from trusted state"
  Assert-Configuration (Read-State $plain.Prefix) $changedPort "exe"

  # An updater winning the race after snapshot creation must survive rollback,
  # and the previous known-good agy.real.exe must remain unchanged.
  Copy-PaddedFixture $plainExe 14MB
  $beforeRaceOriginal = Get-Digest $state.target
  $script:snapshotRaceHash = $null
  $transactionWriterForRace = (Get-Command Set-AgyTransactionFile).ScriptBlock
  & {
    function Set-AgyTransactionFile {
      param($Transaction, [string]$Path, [string]$Stage)
      if ($Path -ieq $plainExe) {
        Copy-PaddedFixture $plainExe 15MB
        $script:snapshotRaceHash = Get-Digest $plainExe
      }
      & $transactionWriterForRace -Transaction $Transaction -Path $Path -Stage $Stage
    }
    Assert-Throws { Repair-AgyWindowsShim -Prefix $plain.Prefix -Watcher } "original changed during repair"
  }
  Assert-Equal (Get-Digest $plainExe) $script:snapshotRaceHash "Snapshot rollback lost the newer updater executable"
  Assert-Equal (Get-Digest $state.target) $beforeRaceOriginal "Snapshot rollback damaged the known-good original"
  [IO.File]::Copy((Join-Path $plain.Prefix "agy.exe.tpl"), $plainExe, $true)

  # Timestamp restoration and a fixed size must not conceal active content
  # writes. The positive control accepts the same PE once its writer stops.
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class AgyReadinessMutator {
    public static volatile bool Stop;
    public static int Count;
    public static Thread Start(string path) {
        DateTime stamp = File.GetLastWriteTimeUtc(path);
        var thread = new Thread(delegate() {
            while (!Stop) {
                try {
                    using (var file = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete)) {
                        file.Position = 128;
                        file.WriteByte((byte)(Count % 251));
                        file.Flush();
                    }
                    File.SetLastWriteTimeUtc(path, stamp);
                    Interlocked.Increment(ref Count);
                } catch (IOException) { }
                Thread.Sleep(20);
            }
        });
        thread.IsBackground = true;
        thread.Start();
        return thread;
    }
}
'@
  Copy-PaddedFixture $plainExe 16MB
  $mutator = [AgyReadinessMutator]::Start($plainExe)
  try {
    $mutatorStartup = [Diagnostics.Stopwatch]::StartNew()
    while ([AgyReadinessMutator]::Count -lt 3 -and $mutatorStartup.ElapsedMilliseconds -lt 2000) { Start-Sleep -Milliseconds 10 }
    Assert-True ([AgyReadinessMutator]::Count -ge 3) "Readiness negative-control writer did not start"
    $writesBefore = [AgyReadinessMutator]::Count
    Assert-True (-not (Test-AgyStableUpdate $plainExe)) "Content writes with restored timestamps were accepted as stable"
    Assert-True ($mutator.IsAlive -and [AgyReadinessMutator]::Count -gt $writesBefore) "Readiness negative-control writer did not keep running"
  } finally {
    [AgyReadinessMutator]::Stop = $true
    Assert-True ($mutator.Join(2000)) "Readiness test writer did not stop"
  }
  Assert-True (Test-AgyStableUpdate $plainExe) "Readiness positive control rejected a quiescent PE"
  [IO.File]::Copy((Join-Path $plain.Prefix "agy.exe.tpl"), $plainExe, $true)

  Write-Utf8 $plainExe "small junk"
  Repair-AgyWindowsShim -Prefix $plain.Prefix | Out-Null
  Assert-Equal ([IO.File]::ReadAllText($plainExe)) "small junk" "Heal clobbered an invalid update"
  Assert-Equal (Get-Digest $state.target) $updateDigest "Invalid update damaged the real EXE"
  [IO.File]::Copy((Join-Path $plain.Prefix "agy.exe.tpl"), $plainExe, $true)
  Remove-AgyWindowsShim -Prefix $plain.Prefix | Out-Null
  Assert-Equal (Get-Digest $plainExe) $updateDigest "Uninstall failed to restore the latest CLI"

  # Upgrade an earlier CMD installation without leaving a competing agy.cmd.
  $legacy = New-Scenario "legacy-cmd"
  $legacyBackup = Join-Path $legacy.Bin "agy.real.exe"
  Copy-PaddedFixture $legacyBackup
  $legacyCmd = Join-Path $legacy.Bin "agy.cmd"
  Write-Utf8 $legacyCmd "@echo off`r`nREM agy-region-fixer-shim`r`n"
  Write-Utf8 (Join-Path $legacy.Prefix "shim.path") ($legacyCmd + "`r`n")
  $state = Install-Scenario $legacy $port
  Assert-Equal $state.mode "inplace" "Legacy CMD did not migrate to native in-place mode"
  Assert-True (-not [IO.File]::Exists($legacyCmd)) "Legacy CMD remained after native migration"
  Assert-ProxyEnvironment (Invoke-Fixture $state.shimPath @("legacy migrated")) $port $false
  Remove-AgyWindowsShim -Prefix $legacy.Prefix | Out-Null
  Assert-True ([IO.File]::Exists((Join-Path $legacy.Bin "agy.exe"))) "Legacy uninstall did not restore agy.exe"

  # A persistent PATH failure during both installation and rollback must not
  # prevent file rollback or restoration of the current process's PATH.
  $pathFailure = New-Scenario "user-path-failure"
  $pathFailureTarget = Write-CmdFixture $pathFailure.Bin
  $pathFailureDigest = Get-Digest $pathFailureTarget
  $pathBeforeFailure = $env:PATH
  $userPathBeforeFailure = $script:mockUserPath
  $script:userPathFailureAttempts = 0
  & {
    function Set-AgyUserPath([string]$Value) {
      $script:userPathFailureAttempts++
      throw "synthetic persistent User PATH failure"
    }
    Assert-Throws {
      Install-AgyWindowsShim -Prefix $pathFailure.Prefix -Port $port -Certificate $certificate -SourcePath $launcherSourcePath
    } "synthetic persistent User PATH failure"
  }
  Assert-Equal $script:userPathFailureAttempts 2 "User PATH failure did not exercise registry rollback"
  Assert-Equal $env:PATH $pathBeforeFailure "Registry rollback failure prevented process PATH restoration"
  Assert-Equal $script:mockUserPath $userPathBeforeFailure "Registry failure changed persistent User PATH"
  Assert-Equal (Get-Digest $pathFailureTarget) $pathFailureDigest "Registry failure changed the original CMD"
  foreach ($relative in @("bin\agy.exe", "bin\agy-launcher.json", "shim-state.json", "agy.exe.tpl")) {
    Assert-True (-not [IO.File]::Exists((Join-Path $pathFailure.Prefix $relative))) "Registry failure left an installation file: $relative"
  }

  foreach ($replacementKind in @("exe", "cmd")) {
    # A saved overlay must not keep masking another CLI after its target vanishes.
    $migration = New-Scenario ("missing-target-to-" + $replacementKind)
    $oldTarget = Write-CmdFixture $migration.Bin
    $userPathBeforeMigration = $script:mockUserPath
    $oldState = Install-Scenario $migration $port
    $oldOverlayDirectory = Split-Path $oldState.shimPath -Parent
    [IO.File]::Delete($oldTarget)
    $replacementDirectory = Join-Path $migration.Directory "replacement-cli"
    New-Item -ItemType Directory -Path $replacementDirectory | Out-Null
    if ($replacementKind -eq "exe") {
      $replacementTarget = Join-Path $replacementDirectory "agy.exe"
      Copy-PaddedFixture $replacementTarget
    } else { $replacementTarget = Write-CmdFixture $replacementDirectory }
    $replacementDigest = Get-Digest $replacementTarget
    $foreignAfter = Join-Path $migration.Directory "foreign-after"
    $script:mockUserPath += ";" + $foreignAfter
    $env:PATH = $oldOverlayDirectory + ";" + $replacementDirectory + ";" + $systemPath + ";" + $foreignAfter
    $state = Install-Scenario $migration $port
    Assert-Equal $state.kind $replacementKind "Missing-target migration retained its previous launcher kind"
    if ($replacementKind -eq "exe") {
      Assert-Equal $state.mode "inplace" "Replacement plain EXE retained overlay mode"
      Assert-Equal $state.shimPath $replacementTarget "Replacement plain EXE moved from its original path"
      Assert-Equal $state.target (Join-Path $replacementDirectory "agy.real.exe") "Replacement plain EXE target is incorrect"
      Assert-Equal (Get-Digest $state.target) $replacementDigest "Missing-target migration lost the replacement plain EXE"
      Assert-True (-not [IO.File]::Exists($oldState.shimPath)) "Missing-target migration retained its previous overlay EXE"
      Assert-True (-not [IO.File]::Exists((Join-Path $oldOverlayDirectory "agy-launcher.json"))) "Missing-target migration retained its previous overlay config"
    } else {
      Assert-Equal $state.mode "overlay" "Replacement CMD was relocated"
      Assert-Equal $state.shimPath $oldState.shimPath "Replacement CMD created a competing overlay"
      Assert-Equal $state.target $replacementTarget "Replacement CMD target is incorrect"
      Assert-Equal (Get-Digest $replacementTarget) $replacementDigest "Missing-target migration changed the replacement CMD"
    }
    Assert-Configuration $state $port $replacementKind
    Remove-AgyWindowsShim -Prefix $migration.Prefix | Out-Null
    Assert-Equal (Get-Digest $replacementTarget) $replacementDigest "Uninstall changed the replacement CLI after missing-target migration"
    Assert-Equal $script:mockUserPath ($userPathBeforeMigration + ";" + $foreignAfter) "Migration or uninstall discarded foreign User PATH changes"
    Assert-True (@($env:PATH -split ';' | Where-Object { $_ -ieq $replacementDirectory }).Count -eq 1) "Migration or uninstall lost the replacement CLI directory"
    Assert-True (@($env:PATH -split ';' | Where-Object { $_ -ieq $foreignAfter }).Count -eq 1) "Migration or uninstall lost a later process PATH change"
    Assert-True (@($env:PATH -split ';' | Where-Object { $_ -ieq $oldOverlayDirectory }).Count -eq 0) "Migration or uninstall retained its previous process PATH entry"
  }

  # Switching away from an uninstalled plain EXE must also rediscover the CLI.
  $migration = New-Scenario "missing-inplace-target-to-cmd"
  $oldExecutable = Join-Path $migration.Bin "agy.exe"
  Copy-PaddedFixture $oldExecutable
  $oldState = Install-Scenario $migration $port
  [IO.File]::Delete($oldState.target)
  $replacementDirectory = Join-Path $migration.Directory "replacement-cli"
  New-Item -ItemType Directory -Path $replacementDirectory | Out-Null
  $replacementTarget = Write-CmdFixture $replacementDirectory
  $replacementDigest = Get-Digest $replacementTarget
  $userPathBeforeMigration = $script:mockUserPath
  $env:PATH = $migration.Bin + ";" + $replacementDirectory + ";" + $systemPath
  $state = Install-Scenario $migration $port
  Assert-Equal $state.mode "overlay" "Missing in-place target did not switch to managed launcher mode"
  Assert-Equal $state.target $replacementTarget "Missing in-place target masked the replacement CMD"
  Assert-True (-not [IO.File]::Exists($oldState.shimPath)) "Migration retained the obsolete in-place shim"
  Assert-True (-not [IO.File]::Exists((Join-Path $migration.Bin "agy-launcher.json"))) "Migration retained the obsolete in-place config"
  Assert-Configuration $state $port "cmd"
  Assert-ProxyEnvironment (Invoke-Fixture $state.shimPath @("migrated from EXE")) $port $false
  Remove-AgyWindowsShim -Prefix $migration.Prefix | Out-Null
  Assert-Equal (Get-Digest $replacementTarget) $replacementDigest "Uninstall changed the replacement CMD after in-place migration"
  Assert-Equal $script:mockUserPath $userPathBeforeMigration "Uninstall retained its new overlay PATH entry"
  Assert-True (@($env:PATH -split ';' | Where-Object { $_ -ieq $migration.Bin }).Count -eq 1) "Migration removed an original process PATH entry"

  # A replacement at the original EXE path remains an update, even when its
  # backup disappeared; it must not be mistaken for a stale installation.
  $recovery = New-Scenario "missing-backup-with-cli-update"
  $updatedExecutable = Join-Path $recovery.Bin "agy.exe"
  Copy-PaddedFixture $updatedExecutable
  $state = Install-Scenario $recovery $port
  [IO.File]::Delete($state.target)
  Copy-PaddedFixture $updatedExecutable 13MB
  $updatedDigest = Get-Digest $updatedExecutable
  $state = Install-Scenario $recovery $port
  Assert-Equal $state.mode "inplace" "Missing backup relocated a valid CLI update"
  Assert-Equal (Get-Digest $state.target) $updatedDigest "Missing backup prevented retaining the CLI update"
  Assert-ProxyEnvironment (Invoke-Fixture $state.shimPath @("recovered CLI update")) $port $false
  Remove-AgyWindowsShim -Prefix $recovery.Prefix | Out-Null
  Assert-Equal (Get-Digest $updatedExecutable) $updatedDigest "Uninstall lost the recovered CLI update"

  foreach ($kind in @("cmd", "ps1", "scoop", "windowsapps-path")) {
    $scenario = New-Scenario $kind
    if ($kind -eq "windowsapps-path") {
      # A path-shaped fixture exercises preservation, not a real App Execution Alias.
      $scenario.Bin = Join-Path $scenario.Directory "AppData\Local\Microsoft\WindowsApps"
      New-Item -ItemType Directory -Path $scenario.Bin -Force | Out-Null
      $env:PATH = $scenario.Bin + ";" + $systemPath
    }
    $targetKind = "exe"
    if ($kind -eq "cmd") {
      $targetKind = "cmd"
      $target = Write-CmdFixture $scenario.Bin
    } elseif ($kind -eq "ps1") {
      $targetKind = "ps1"
      $target = Join-Path $scenario.Bin "agy.ps1"
      $package = Join-Path $scenario.Bin "node_modules\fixture-package"
      New-Item -ItemType Directory -Path $package -Force | Out-Null
      # Record at the PS script boundary: Windows PowerShell's later native
      # @args binding is a separate behavior of the original package launcher.
      Write-Utf8 $target @'
$basedir = Split-Path $MyInvocation.MyCommand.Definition -Parent
$env:AGY_TEST_LAUNCHER_NAME = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Definition)
& "$basedir/node_modules/fixture-package/record.ps1" @args
exit $LASTEXITCODE
'@
      Write-Utf8 (Join-Path $package "record.ps1") @'
$record = @{
  arguments = @($args)
  workingDirectory = [Environment]::CurrentDirectory
  environment = @{
    HTTPS_PROXY = $env:HTTPS_PROXY
    SSL_CERT_FILE = $env:SSL_CERT_FILE
    NODE_EXTRA_CA_CERTS = $env:NODE_EXTRA_CA_CERTS
    AGY_TEST_LAUNCHER_NAME = $env:AGY_TEST_LAUNCHER_NAME
  }
  standardInput = [Console]::In.ReadToEnd()
}
[IO.File]::WriteAllText($env:AGY_TEST_OUTPUT, ($record | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
[Console]::Out.WriteLine("fixture-stdout")
[Console]::Error.WriteLine("fixture-stderr")
exit ([int]$env:AGY_TEST_EXIT)
'@
    } else {
      $target = Join-Path $scenario.Bin "agy.exe"
      Copy-PaddedFixture $target
      if ($kind -eq "scoop") { Write-Utf8 (Join-Path $scenario.Bin "agy.shim") 'path = "fixture.exe"' }
    }
    $targetDigest = Get-Digest $target
    $state = Install-Scenario $scenario $port
    Assert-Equal $state.mode "overlay" "$kind launcher was relocated"
    Assert-Equal $state.target $target "$kind original target path changed"
    Assert-Equal (Get-Digest $target) $targetDigest "$kind original launcher was modified"
    Assert-Equal ([IO.Path]::GetFileName($state.target)) ("agy." + $targetKind) "$kind original launcher basename changed"
    Assert-Configuration $state $port $targetKind
    Assert-True ([bool]$state.pathAdded) "$kind overlay did not own its newly added PATH entry"
    $overlayDirectory = Split-Path $state.shimPath -Parent
    Assert-Equal (($script:mockUserPath -split ';')[0]) $overlayDirectory "Overlay was not first in User PATH"
    $state = Install-Scenario $scenario $port
    Assert-Equal @($script:mockUserPath -split ';' | Where-Object { $_ -ieq $overlayDirectory }).Count 1 "Reinstallation duplicated User PATH"
    Assert-Equal $state.target $target "Reinstallation targeted its own overlay"
    $record = Invoke-Fixture $state.shimPath $arguments "overlay stdin`r`n"
    Assert-ProxyEnvironment $record $port $false
    if ($kind -eq "ps1") {
      foreach ($argumentCase in @(@(), @(""), @("single argument"))) {
        Invoke-Fixture $state.shimPath $argumentCase | Out-Null
      }
    }
    if ($targetKind -ne "exe") { Assert-Equal $record.environment.AGY_TEST_LAUNCHER_NAME "agy" "Original launcher basename was not preserved" }
    [IO.File]::Delete($state.shimPath)
    Repair-AgyWindowsShim -Prefix $scenario.Prefix | Out-Null
    Assert-True (Test-AgyNativeShim -Path $state.shimPath) "Heal did not restore missing $kind overlay"
    Assert-Equal (Get-Digest $target) $targetDigest "Heal changed the $kind original launcher"
    if ($kind -eq "cmd") {
      $foreignOverlay = "foreign executable replacement"
      Write-Utf8 $state.shimPath $foreignOverlay
      $foreignStateDigest = Get-Digest (Join-Path $scenario.Prefix "shim-state.json")
      $foreignConfigDigest = Get-Digest (Join-Path $overlayDirectory "agy-launcher.json")
      $foreignUserPath = $script:mockUserPath
      $foreignProcessPath = $env:PATH
      Assert-Throws { Remove-AgyWindowsShim -Prefix $scenario.Prefix } "foreign executable"
      Assert-True ([IO.Directory]::Exists($scenario.Prefix)) "Refused uninstall removed its installation directory"
      Assert-Equal ([IO.File]::ReadAllText($state.shimPath)) $foreignOverlay "Refused uninstall changed a foreign overlay executable"
      Assert-Equal (Get-Digest (Join-Path $scenario.Prefix "shim-state.json")) $foreignStateDigest "Refused uninstall changed recovery state"
      Assert-Equal (Get-Digest (Join-Path $overlayDirectory "agy-launcher.json")) $foreignConfigDigest "Refused uninstall changed launcher config"
      Assert-Equal $script:mockUserPath $foreignUserPath "Refused uninstall changed User PATH"
      Assert-Equal $env:PATH $foreignProcessPath "Refused uninstall changed process PATH"
      [IO.File]::Copy((Join-Path $scenario.Prefix "agy.exe.tpl"), $state.shimPath, $true)
    }
    $foreignAfter = Join-Path $scenario.Directory "foreign-after"
    $script:mockUserPath += ";" + $foreignAfter
    $env:PATH += ";" + $foreignAfter
    Remove-AgyWindowsShim -Prefix $scenario.Prefix | Out-Null
    Assert-True (-not [IO.File]::Exists($state.shimPath)) "Uninstall retained the $kind overlay"
    Assert-True (-not [IO.File]::Exists((Join-Path $overlayDirectory "agy-launcher.json"))) "Uninstall retained the $kind launcher configuration"
    Assert-Equal (Get-Digest $target) $targetDigest "Uninstall modified original $kind launcher"
    Assert-Equal $script:mockUserPath ((Join-Path $scenario.Directory "foreign-before") + ";" + $foreignAfter) "Uninstall discarded foreign User PATH changes"
    Assert-True (@($env:PATH -split ';' | Where-Object { $_ -ieq $foreignAfter }).Count -eq 1) "Uninstall discarded a later process PATH change"
    Assert-True (@($env:PATH -split ';' | Where-Object { $_ -ieq $overlayDirectory }).Count -eq 0) "Uninstall retained its own process PATH entry"
  }
  Write-Host "Windows native launcher integration tests passed"
} finally {
  [Console]::InputEncoding = $savedInputEncoding
  if ($null -ne $listener) { $listener.Stop() }
  foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], "Process") }
  if ([IO.Directory]::Exists($scratch)) { [IO.Directory]::Delete($scratch, $true) }
}
