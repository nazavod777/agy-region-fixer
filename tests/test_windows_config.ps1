$ErrorActionPreference = "Stop"
$installerPath = Join-Path (Split-Path $PSScriptRoot -Parent) "install.ps1"
$tokens = $null
$parseErrors = $null
$installerAst = [Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors -join "`n") }
$source = [IO.File]::ReadAllText($installerPath)
$helperNames = @("ConvertTo-ProxyPort", "Test-PortBindable", "Select-ProxyPort", "WriteNoBom", "WriteBom", "Stop-OurProxy")
foreach ($name in $helperNames) {
  $definition = $installerAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
  if (@($definition).Count -ne 1) { throw "Expected exactly one $name helper" }
  . ([scriptblock]::Create($definition[0].Extent.Text))
}
function Assert-True($condition, $message) {
  if (-not $condition) { throw $message }
}
function Assert-Throws($action, $expectedMessage) {
  $caught = $null
  try { & $action | Out-Null } catch { $caught = $_.Exception.Message }
  Assert-True ($caught -and $caught.Contains($expectedMessage)) "Expected error containing '$expectedMessage'; got '$caught'"
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("agy-windows-config-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
  foreach ($valid in @(@("1", 1), @("65535", 65535), @("0008090", 8090), @("00001", 1), @(("0" * 1000 + "12"), 12))) {
    Assert-True ((ConvertTo-ProxyPort $valid[0]) -eq $valid[1]) "Port did not normalize: $($valid[0])"
  }
  foreach ($invalid in @("", "0", "000", "65536", "99999999999999999999999", "-1", "+1", "1.5", "1e3", " 8090", "8090 ", "8090`n", "8090`r`n", "80;Write-Host bad", [string][char]0x0661, [string][char]0xFF11)) {
    Assert-Throws { ConvertTo-ProxyPort $invalid } "ASCII decimal integer from 1 to 65535"
  }

  $savedPath = Join-Path $scratch "port"
  $autoPort = Select-ProxyPort $null $savedPath
  Assert-True ($autoPort -ge 49152 -and $autoPort -le 65535) "Automatic port is outside the high range"
  Assert-True (Test-PortBindable $autoPort) "Automatic port is not bindable after its probe"
  WriteNoBom $savedPath ("$autoPort`r`n")
  Assert-True ((Select-ProxyPort $null $savedPath) -eq $autoPort) "Free saved high port was not reused"
  Assert-True (([IO.File]::ReadAllText($savedPath)).Trim() -ceq "$autoPort") "Selected port was not persisted"

  $busyListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $autoPort)
  $busyListener.Server.ExclusiveAddressUse = $true
  $busyListener.Start()
  try {
    Assert-True (-not (Test-PortBindable $autoPort)) "Occupied port passed the bind probe"
    Assert-Throws { Select-ProxyPort $autoPort $savedPath } "cannot be bound on 127.0.0.1"
    $replacement = Select-ProxyPort $null $savedPath
    Assert-True ($replacement -ne $autoPort -and $replacement -ge 49152 -and $replacement -le 65535) "Occupied saved port was reused"
  } finally { $busyListener.Stop() }

  foreach ($saved in @("8080", "65536", "invalid", "")) {
    WriteNoBom $savedPath $saved
    $replacement = Select-ProxyPort $null $savedPath
    Assert-True ($replacement -ge 49152 -and $replacement -le 65535) "Invalid or low saved port was reused"
  }
  Remove-Item -LiteralPath $savedPath
  & {
    $script:probeCount = 0
    function Test-PortBindable($port) { $script:probeCount++; return $false }
    Assert-Throws { Select-ProxyPort $null $savedPath } "after 32 attempts"
    Assert-True ($script:probeCount -eq 32) "Automatic port search exceeded its attempt bound"
    $script:probeCount = 0
    Assert-Throws { Select-ProxyPort 8090 $savedPath } "cannot be bound on 127.0.0.1"
    Assert-True ($script:probeCount -eq 1) "An explicit occupied port triggered automatic fallback"
  }

  # Execute the installer's selection, persistence and runner generation together.
  $selectionStart = $source.IndexOf("# Stop our previous proxy before checking")
  $selectionEnd = $source.IndexOf("# --- autostart:", $selectionStart)
  Assert-True ($selectionStart -gt 0 -and $selectionEnd -gt $selectionStart) "Port installation block is missing"
  $selectionBlock = $source.Substring($selectionStart, $selectionEnd - $selectionStart)
  $bindProbe = (Get-Command Test-PortBindable).ScriptBlock
  & {
    $PREFIX = Join-Path $scratch "generated"
    $CA_DIR = Join-Path $PREFIX "ca"
    New-Item -ItemType Directory -Path $PREFIX | Out-Null
    $script:proxyStopped = $false
    function Stop-OurProxy { $script:proxyStopped = $true }
    function Say($message) {}
    function Test-PortBindable($port) {
      Assert-True $script:proxyStopped "Port was selected before stopping the old proxy"
      return (& $bindProbe $port)
    }
    $PORT = $null
    . ([scriptblock]::Create($selectionBlock))
    $persistedPort = ([IO.File]::ReadAllText((Join-Path $PREFIX "port"))).Trim()
    Assert-True ($persistedPort -ceq "$PORT") "Actual selection was not saved"
    $runner = [IO.File]::ReadAllText((Join-Path $PREFIX "run-proxy.ps1"))
    Assert-True ($runner.Contains("--port $persistedPort --confdir")) "Runner did not use the persisted port"
    Assert-True ($runner.Contains("python.exe") -and $runner.Contains(" -I ")) "Runner did not use the isolated Python bootstrap"
    $PORT = $null
    . ([scriptblock]::Create($selectionBlock))
    Assert-True ($PORT -eq [int]$persistedPort) "Reinstallation changed the free saved port"
  }

  # Verify validation happens before any installation or process side effect.
  $validationEnd = $source.IndexOf("# --- python ")
  Assert-True ($validationEnd -gt 0) "Early configuration block is missing"
  $earlyBlock = $source.Substring(0, $validationEnd)
  & {
    $savedProfile = $env:USERPROFILE
    $savedEnvPort = $env:AGY_BYPASS_PORT
    try {
      $env:USERPROFILE = $scratch
      $env:AGY_BYPASS_PORT = "8090;unexpected"
      function Die($message) { throw $message }
      # Replace only the early error reporter so the test cannot exit its own host.
      $testBlock = $earlyBlock -replace '(?m)^function Die\(\$m\) \{.*$', 'function Die($m) { throw $m }'
      Assert-Throws { . ([scriptblock]::Create($testBlock)) } "ASCII decimal integer from 1 to 65535"
      Assert-True (-not (Test-Path (Join-Path $scratch ".agy-region-fixer"))) "Invalid port created installation files"
      $env:AGY_BYPASS_PORT = "0008090"
      . ([scriptblock]::Create($testBlock))
      Assert-True ($PORT -eq 8090) "Early explicit port was not normalized"
      $env:AGY_BYPASS_PORT = ""
      . ([scriptblock]::Create($testBlock))
      Assert-True ($null -eq $PORT) "Empty environment value did not enable automatic selection"
    } finally {
      $env:USERPROFILE = $savedProfile
      $env:AGY_BYPASS_PORT = $savedEnvPort
    }
  }

  # Process ownership is exact; another installation with a similar path survives.
  & {
    $venvMitm = Join-Path $scratch "synthetic-profile/.agy-region-fixer/venv/Scripts/mitmdump.exe"
    $script:stoppedIds = @()
    $script:waitedIds = @()
    function Get-CimInstance {
      [pscustomobject]@{ ProcessId = 12345; ExecutablePath = $venvMitm }
      [pscustomobject]@{ ProcessId = 12346; ExecutablePath = $venvMitm.Replace(".agy-region-fixer", ".agy-region-fixer-other") }
      [pscustomobject]@{ ProcessId = 12347; ExecutablePath = $null }
    }
    function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:stoppedIds += $Id }
    function Wait-Process { param($Id, $Timeout, $ErrorAction) $script:waitedIds += $Id; Assert-True ($Timeout -eq 5) "Proxy shutdown wait is unbounded" }
    Stop-OurProxy
    Assert-True ($script:stoppedIds.Count -eq 1 -and $script:stoppedIds[0] -eq 12345) "Proxy stop selected another installation"
    Assert-True ($script:waitedIds.Count -eq 1 -and $script:waitedIds[0] -eq 12345) "Proxy stop did not wait for its own process"
  }

  if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    & {
      $venvMitm = 'C:\synthetic profile\.agy-region-fixer\venv\Scripts\mitmdump.exe'
      $python = $venvMitm.Replace('mitmdump.exe', 'python.exe')
      $prefix = 'C:\synthetic profile\.agy-region-fixer'
      $command = '"' + $python + '" -I "' + $prefix + '\addon.py" --port 8090 --confdir "' + $prefix + '\ca"'
      $script:stoppedIds = @()
      $script:waitedIds = @()
      function Get-CimInstance {
        [pscustomobject]@{ ProcessId = 20001; ExecutablePath = $python; CommandLine = $command }
        [pscustomobject]@{ ProcessId = 20002; ExecutablePath = $python; CommandLine = ($command + ' --addon "' + $prefix + '\custom-addon.py"') }
        [pscustomobject]@{ ProcessId = 20003; ExecutablePath = $python; CommandLine = $command.Replace('\addon.py', '\addon.py-other') }
        [pscustomobject]@{ ProcessId = 20004; ExecutablePath = $python; CommandLine = $command.Replace('\ca"', '\ca-other"') }
        [pscustomobject]@{ ProcessId = 20005; ExecutablePath = $python; CommandLine = ('"' + $python + '" -c "print(1)"') }
        [pscustomobject]@{ ProcessId = 20006; ExecutablePath = $python; CommandLine = ($command + ' --addon "' + $prefix + '-other\custom-addon.py"') }
      }
      function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:stoppedIds += $Id }
      function Wait-Process { param($Id, $Timeout, $ErrorAction) $script:waitedIds += $Id }
      Stop-OurProxy
      Assert-True (($script:stoppedIds -join ',') -ceq '20001,20002') "Python proxy stop did not preserve unrelated commands"
      Assert-True (($script:waitedIds -join ',') -ceq '20001,20002') "Python proxy stop did not wait for its exact owned processes"
    }
  }

  # Execute the generated uninstall template with all system side effects mocked.
  $uninstallTemplate = @($installerAst.FindAll({
    param($node)
    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
      $node.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString -and
      $node.Value.Contains('Write-Host "Fully removed."')
  }, $true))
  Assert-True ($uninstallTemplate.Count -eq 1) "Uninstall template is missing"
  & {
    $expectedPrefix = Join-Path $scratch "uninstall-prefix"
    $expectedMitm = Join-Path $expectedPrefix "venv\Scripts\mitmdump.exe"
    $script:stoppedIds = @()
    $script:waitedIds = @()
    $script:removedPaths = @()
    $script:removedShimPrefixes = @()
    [IO.Directory]::CreateDirectory($expectedPrefix) | Out-Null
    [IO.File]::WriteAllText((Join-Path $expectedPrefix "windows-support.ps1"), 'function Remove-AgyWindowsShim { param($Prefix) $script:removedShimPrefixes += $Prefix }; function Stop-AgyWindowsWatcher { param($Prefix) }')
    function Remove-ItemProperty {}
    function schtasks {}
    function Get-ScheduledTask { return $null }
    function Get-CimInstance {
      param($ClassName, $Filter, $OperationTimeoutSec, $ErrorAction)
      Assert-True ($OperationTimeoutSec -eq 5) "Uninstall process lookup is unbounded"
      [pscustomobject]@{ ProcessId = 34567; ExecutablePath = $expectedMitm; CommandLine = $expectedMitm }
      $otherMitm = Join-Path ($expectedPrefix + "-other") "venv\Scripts\mitmdump.exe"
      [pscustomobject]@{ ProcessId = 34568; ExecutablePath = $otherMitm; CommandLine = $otherMitm }
      [pscustomobject]@{ ProcessId = 34569; ExecutablePath = $null; CommandLine = $expectedPrefix }
    }
    function Stop-Process { param($Id, [switch]$Force, $ErrorAction) $script:stoppedIds += $Id }
    function Wait-Process { param($Id, $Timeout, $ErrorAction) $script:waitedIds += $Id; Assert-True ($Timeout -eq 5) "Uninstall shutdown wait is unbounded" }
    function Test-Path { return $false }
    function Remove-Item { param($LiteralPath, [switch]$Recurse, [switch]$Force, $ErrorAction) $script:removedPaths += $LiteralPath }
    $uninstall = $uninstallTemplate[0].Value.Replace("@PREFIX@", $expectedPrefix.Replace("'", "''")).Replace('# @STOP_PROXY@', ("function Stop-OurProxy {`n" + ${function:Stop-OurProxy}.ToString() + "`n}"))
    . ([scriptblock]::Create($uninstall))
    Assert-True ($script:stoppedIds.Count -eq 1 -and $script:stoppedIds[0] -eq 34567) "Uninstall stopped another installation"
    Assert-True ($script:waitedIds.Count -eq 1 -and $script:waitedIds[0] -eq 34567) "Uninstall did not wait for its own process"
    Assert-True ($script:removedShimPrefixes.Count -eq 1 -and $script:removedShimPrefixes[0] -eq $expectedPrefix) "Uninstall did not restore its own native shim"
    Assert-True ($script:removedPaths.Count -eq 1 -and $script:removedPaths[0] -eq $expectedPrefix) "Uninstall selected another installation directory"
  }

  # Run the actual smoke block with a synthetic interrupted process. Its finally
  # must kill that process tree and remove its temporary files.
  $smokeStart = $source.IndexOf('$SMOKE_TIMEOUT_MS =')
  $smokeEnd = $source.IndexOf('Say "Done.', $smokeStart)
  Assert-True ($smokeStart -gt 0 -and $smokeEnd -gt $smokeStart) "Smoke block is missing"
  $smokeBlock = $source.Substring($smokeStart, $smokeEnd - $smokeStart)
  & {
    $script:killedArguments = @()
    $script:smokePaths = @()
    function Say($message) {}
    function Get-Command { return [pscustomobject]@{ Source = "synthetic-agy" } }
    function Start-Process {
      param($FilePath, $ArgumentList, [switch]$NoNewWindow, [switch]$PassThru, $RedirectStandardOutput, $RedirectStandardError)
      $script:smokePaths = @($RedirectStandardOutput, $RedirectStandardError)
      $process = [pscustomobject]@{ Id = 23456; HasExited = $false }
      $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($timeout) throw "synthetic interruption" }
      return $process
    }
    function taskkill { $script:killedArguments = @($args) }
    . ([scriptblock]::Create($smokeBlock))
    Assert-True (($script:killedArguments -join " ") -ceq "/T /F /PID 23456") "Interrupted smoke did not stop exactly its own process tree"
    foreach ($path in $script:smokePaths) { Assert-True (-not (Test-Path -LiteralPath $path)) "Smoke temporary output survived interruption" }
  }
  Write-Host "Windows port configuration and smoke cleanup tests passed"
} finally {
  Remove-Item -LiteralPath $scratch -Recurse -Force
}
