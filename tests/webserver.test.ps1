$ErrorActionPreference = 'Stop'

# Dependency-free checks for Start-WebServer.ps1 argument handling and data-file resolution.
# These never start a listener: every case points -Port at a port this script has already bound,
# so the run always fails at the bind step, which happens after the data-file checks. The message
# therefore says which check rejected the run.
# Run with: pwsh -File tests/webserver.test.ps1

$repoRoot = Split-Path -Parent $PSScriptRoot
$serverScript = Join-Path $repoRoot 'Start-WebServer.ps1'
$script:failures = 0

$occupiedListener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$occupiedListener.Start()
$occupiedPort = $occupiedListener.LocalEndpoint.Port

function Test-Case {
    param(
        [string]$Name,
        [scriptblock]$Body
    )
    try {
        & $Body
        Write-Host "ok - $Name"
    } catch {
        Write-Host "FAIL - $Name`n       $($_.Exception.Message)"
        $script:failures++
    }
}

function Invoke-ServerOnOccupiedPort {
    param(
        [string]$Root,
        [string]$DataFile,
        [string]$App
    )
    $arguments = @{
        Root = $Root
        Port = $occupiedPort
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('DataFile')) { $arguments.DataFile = $DataFile }
    if ($App) { $arguments.App = $App }
    & $serverScript @arguments
}

function Get-ErrorMessage {
    param([scriptblock]$Body)
    try {
        & $Body | Out-Null
        return ''
    } catch {
        return $_.Exception.Message
    }
}

function Assert-DataFileAccepted {
    param([string]$DataFile)
    $message = Get-ErrorMessage { Invoke-ServerOnOccupiedPort -Root $fixtureRoot -DataFile $DataFile -App 'listmanager' }
    if (-not $message) { throw "expected the run to fail at the bind step, but it did not fail: $DataFile" }
    if ($message -match 'was not found|must resolve to a path|must be a relative path') {
        throw "expected '$DataFile' to be accepted, got: $message"
    }
}

function Assert-DataFileRejected {
    param(
        [string]$DataFile,
        [string]$ExpectedPattern
    )
    $message = Get-ErrorMessage { Invoke-ServerOnOccupiedPort -Root $fixtureRoot -DataFile $DataFile -App 'listmanager' }
    if ($message -notmatch $ExpectedPattern) {
        throw "expected '$DataFile' to be rejected with /$ExpectedPattern/, got: $message"
    }
}

# --- fixture root: listmanager has a data file, bills does not --------------------
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "listmanager-server-tests"
if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
foreach ($appName in @('listmanager', 'bills')) {
    $appRoot = Join-Path (Join-Path $fixtureRoot 'apps') $appName
    New-Item -ItemType Directory -Path $appRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $appRoot 'Validate.ps1') -Value 'function Test-Document { param($Document) }'
}
Set-Content -LiteralPath (Join-Path (Join-Path $fixtureRoot 'apps\listmanager') 'data.json') -Value '{"schema":{"fields":[]},"records":[]}'

Test-Case 'a relative data file that exists passes validation' {
    Assert-DataFileAccepted 'data.json'
}

Test-Case 'a leading ./ prefix resolves the same as a bare name' {
    Assert-DataFileAccepted './data.json'
}

Test-Case 'a leading .\ prefix resolves the same as a bare name' {
    Assert-DataFileAccepted '.\data.json'
}

Test-Case 'a nested relative path inside the app folder is allowed' {
    $appRoot = Join-Path (Join-Path $fixtureRoot 'apps') 'listmanager'
    New-Item -ItemType Directory -Path (Join-Path $appRoot 'lists') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $appRoot 'lists\contacts.json') -Value '{"schema":{"fields":[]},"records":[]}'
    Assert-DataFileAccepted './lists/contacts.json'
}

Test-Case 'a missing relative data file fails fast with the resolved path' {
    $message = Get-ErrorMessage { Invoke-ServerOnOccupiedPort -Root $fixtureRoot -DataFile 'Passwords2.gz' -App 'listmanager' }
    if ($message -notmatch 'not found') { throw "expected a not-found failure, got: $message" }
    if ($message -notmatch 'apps\\listmanager\\Passwords2\.gz') { throw "expected the resolved path in the message, got: $message" }
    if ($message -notmatch 'relative to each app folder') { throw "expected guidance on the relative form, got: $message" }
}

Test-Case 'a data file missing from only one app warns instead of failing' {
    # Run in a child process so the warning text survives the terminating bind error.
    $output = & (Get-Process -Id $PID).Path -NoProfile -File $serverScript -Root $fixtureRoot -Port $occupiedPort -DataFile 'data.json' 2>&1 | Out-String
    if ($output -notmatch 'WARNING') { throw "expected a warning for the app without the file, got: $output" }
    if ($output -notmatch 'bills') { throw "expected the warning to name the bills app, got: $output" }
    if ($output -notmatch 'already in use') {
        throw "the run should still have reached the bind step, got: $output"
    }
}

Test-Case 'a data file path that escapes the app folder is rejected' {
    Assert-DataFileRejected -DataFile '../shared/leak.json' -ExpectedPattern 'must resolve to a path inside each app folder'
}

Test-Case 'an absolute data file path is rejected' {
    Assert-DataFileRejected -DataFile 'C:\temp\data.json' -ExpectedPattern 'must be a relative path inside each app folder'
}

Test-Case 'omitting -DataFile falls back to data.json.gz when only the gzip file exists' {
    $gzRoot = Join-Path ([IO.Path]::GetTempPath()) "listmanager-gz-only"
    if (Test-Path -LiteralPath $gzRoot) { Remove-Item -LiteralPath $gzRoot -Recurse -Force }
    $gzApp = Join-Path (Join-Path $gzRoot 'apps') 'listmanager'
    New-Item -ItemType Directory -Path $gzApp -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $gzApp 'Validate.ps1') -Value 'function Test-Document { param($Document) }'
    $jsonBytes = [Text.Encoding]::UTF8.GetBytes('{"schema":{"fields":[]},"records":[]}')
    $ms = [IO.MemoryStream]::new()
    $gz = [IO.Compression.GZipStream]::new($ms, [IO.Compression.CompressionMode]::Compress, $true)
    $gz.Write($jsonBytes, 0, $jsonBytes.Length)
    $gz.Close()
    [IO.File]::WriteAllBytes((Join-Path $gzApp 'data.json.gz'), $ms.ToArray())
    $ms.Close()
    $message = Get-ErrorMessage { Invoke-ServerOnOccupiedPort -Root $gzRoot -App 'listmanager' }
    if ($message -match 'was not found') { throw "expected the gzip fallback to resolve, got: $message" }
    if ($message -notmatch 'already in use') { throw "expected the run to reach the bind step, got: $message" }
}

Test-Case 'omitting -DataFile still starts (falls back to data.json)' {
    $message = Get-ErrorMessage { Invoke-ServerOnOccupiedPort -Root $fixtureRoot -App 'listmanager' }
    if (-not $message) { throw 'expected the run to fail at the bind step, but it did not fail' }
    if ($message -match 'was not found|must resolve to a path|must be a relative path') {
        throw "expected the default data file to resolve, got: $message"
    }
}

# --- serve.ps1 forwards every supported option --------------------------------------
Test-Case 'serve.ps1 forwards -DataFile and the other options' {
    $stubRoot = Join-Path ([IO.Path]::GetTempPath()) 'listmanager-serve-stub'
    if (Test-Path -LiteralPath $stubRoot) { Remove-Item -LiteralPath $stubRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $stubRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'serve.ps1') -Destination (Join-Path $stubRoot 'serve.ps1')
    $capturePath = Join-Path $stubRoot 'captured.json'
    Set-Content -LiteralPath (Join-Path $stubRoot 'Start-WebServer.ps1') -Value @"
param (`$Port, `$Root, `$App, `$DataFile, [switch]`$AllAddresses, `$EditPassword, [switch]`$OpenBrowser, [switch]`$AllowClientExit)
[PSCustomObject]@{
    Port = `$Port; App = `$App; DataFile = `$DataFile; OpenBrowser = `$OpenBrowser.IsPresent
    AllowClientExit = `$AllowClientExit.IsPresent; AllAddresses = `$AllAddresses.IsPresent; EditPassword = `$EditPassword
} | ConvertTo-Json | Set-Content -LiteralPath '$capturePath'
"@

    & (Join-Path $stubRoot 'serve.ps1') -DataFile './Passwords2.gz' -App 'listmanager' -EditPassword 'secret' | Out-Null
    if (-not (Test-Path -LiteralPath $capturePath)) { throw 'serve.ps1 did not invoke Start-WebServer.ps1' }
    $captured = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json

    if ($captured.DataFile -ne './Passwords2.gz') { throw "expected DataFile to be forwarded verbatim, got '$($captured.DataFile)'" }
    if ($captured.App -ne 'listmanager') { throw "expected App to be forwarded, got '$($captured.App)'" }
    if ($captured.EditPassword -ne 'secret') { throw 'expected EditPassword to be forwarded' }
    if ($captured.OpenBrowser -ne $true) { throw 'expected serve.ps1 defaults to opening the browser' }
    if ($captured.AllowClientExit -ne $true) { throw 'expected serve.ps1 defaults to allowing client exit' }
    if ($captured.Port -ne '41000-41010') { throw "expected the default port range, got '$($captured.Port)'" }
}

Test-Case 'serve.ps1 omits -DataFile when it was not supplied' {
    $stubRoot = Join-Path ([IO.Path]::GetTempPath()) 'listmanager-serve-stub-nodata'
    if (Test-Path -LiteralPath $stubRoot) { Remove-Item -LiteralPath $stubRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $stubRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'serve.ps1') -Destination (Join-Path $stubRoot 'serve.ps1')
    $capturePath = Join-Path $stubRoot 'captured.txt'
    Set-Content -LiteralPath (Join-Path $stubRoot 'Start-WebServer.ps1') -Value @"
param (`$Port, `$Root, `$App, `$DataFile, [switch]`$AllAddresses, `$EditPassword, [switch]`$OpenBrowser, [switch]`$AllowClientExit)
`$result = if (`$PSBoundParameters.ContainsKey('DataFile')) { 'forwarded' } else { 'omitted' }
Set-Content -LiteralPath '$capturePath' -Value `$result
"@

    & (Join-Path $stubRoot 'serve.ps1') -App 'bills' | Out-Null
    if ((Get-Content -LiteralPath $capturePath -Raw).Trim() -ne 'omitted') {
        throw 'serve.ps1 should not invent a -DataFile value'
    }
}

Write-Host ''
if ($script:failures) {
    Write-Host "$script:failures failing check(s)"
    exit 1
}
Write-Host 'all checks passed'