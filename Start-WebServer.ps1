param (
    [string]$Port = "8080",
    [string]$Root = $PSScriptRoot,
    [string]$DataFile = "data.json",
    [ValidateSet("listmanager", "bills")]
    [string]$App,
    [switch]$AllAddresses,
    [string]$EditPassword,
    [switch]$OpenBrowser,
    [switch]$AllowClientExit
)

$portMatch = [regex]::Match($Port, '^\s*(?<start>\d{1,5})(?:\s*-\s*(?<end>\d{1,5}))?\s*$')
if (-not $portMatch.Success) {
    throw "Port must be a number or an inclusive range such as 8080-8090."
}
$portStart = [int]$portMatch.Groups["start"].Value
$portEnd = if ($portMatch.Groups["end"].Success) { [int]$portMatch.Groups["end"].Value } else { $portStart }
if ($portStart -lt 1 -or $portEnd -gt 65535 -or $portStart -gt $portEnd) {
    throw "Port values must be between 1 and 65535, with the range start no greater than its end."
}

if ([string]::IsNullOrWhiteSpace($DataFile) -or [IO.Path]::IsPathRooted($DataFile)) {
    throw "DataFile must be a relative path inside each app folder."
}
$Root = [IO.Path]::GetFullPath($Root)
$dataFileWasSpecified = $PSBoundParameters.ContainsKey("DataFile")
$selectedAppNames = @(foreach ($appName in @("listmanager", "bills")) {
    if ($App -and $App -ne $appName) { continue }
    $appName
})
foreach ($appName in @("listmanager", "bills")) {
    if ($App -and $App -ne $appName) { continue }
    $appRoot = Join-Path (Join-Path $Root "apps") $appName
    $appPrefix = [IO.Path]::GetFullPath($appRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $appDataPath = [IO.Path]::GetFullPath((Join-Path $appRoot $DataFile))
    if (-not $appDataPath.StartsWith($appPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "DataFile must resolve to a path inside each app folder. '$DataFile' resolved to '$appDataPath'."
    }
    if (-not (Test-Path -LiteralPath $appRoot -PathType Container)) {
        throw "App folder not found: $appRoot"
    }
}

# Confirm the selected data file exists now, so a typo fails at startup instead of as a silent 404 later.
if ($DataFile) {
    $missingDataFiles = @()
    foreach ($appName in $selectedAppNames) {
        $appRoot = Join-Path (Join-Path $Root "apps") $appName
        $appDataPath = [IO.Path]::GetFullPath((Join-Path $appRoot $DataFile))
        if (-not (Test-Path -LiteralPath $appDataPath -PathType Leaf)) {
            $missingDataFiles += "$appDataPath (for app '$appName')"
        }
    }
    if ($missingDataFiles.Count) {
        $exampleApp = $selectedAppNames[0]
        $message = "DataFile '$DataFile' was not found: $($missingDataFiles -join '; '). " +
            "DataFile is relative to each app folder, so -DataFile 'Passwords2.gz' resolves to 'apps\$exampleApp\Passwords2.gz'. " +
            "Leave -DataFile unset to use data.json.gz when present, then data.json."
        if ($missingDataFiles.Count -lt $selectedAppNames.Count) {
            Write-Warning $message
        } else {
            throw $message
        }
    }
}

$EditPasswordHash = $null
if (-not [string]::IsNullOrEmpty($EditPassword)) {
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $passwordBytes = [Text.Encoding]::UTF8.GetBytes($EditPassword)
        $EditPasswordHash = [BitConverter]::ToString($sha256.ComputeHash($passwordBytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha256.Dispose()
    }
}
$EditPasswordRequired = -not [string]::IsNullOrEmpty($EditPasswordHash)
$EditPassword = $null

$validationScriptPaths = @{
    listmanager = Join-Path (Join-Path (Join-Path $Root "apps") "listmanager") "Validate.ps1"
    bills       = Join-Path (Join-Path (Join-Path $Root "apps") "bills") "Validate.ps1"
}
foreach ($appName in @("listmanager", "bills")) {
    if ($App -and $App -ne $appName) { continue }
    if (-not (Test-Path -LiteralPath $validationScriptPaths[$appName] -PathType Leaf)) {
        throw "Required validation script not found: $($validationScriptPaths[$appName])"
    }
}

if ($PSVersionTable.PSVersion.Major -ge 6) 
{
    # PowerShell 6 or later (Core), Add-Type may be needed
    Add-Type -AssemblyName System.Net.HttpListener
}
Add-Type -AssemblyName System.IO.Compression

$listener = $null
$lastStartError = $null
for ($candidatePort = $portStart; $candidatePort -le $portEnd; $candidatePort++) {
    $listenerPrefix = if ($AllAddresses) { "http://+:$candidatePort/" } else { "http://localhost:$candidatePort/" }
    $candidateListener = [System.Net.HttpListener]::new()
    $candidateListener.Prefixes.Add($listenerPrefix)
    try {
        $candidateListener.Start()
        $listener = $candidateListener
        $Port = $candidatePort
        break
    } catch {
        $lastStartError = $_.Exception
        while ($lastStartError.InnerException -and $lastStartError -isnot [System.Net.HttpListenerException]) {
            $lastStartError = $lastStartError.InnerException
        }
        $candidateListener.Close()
        $portInUseCodes = @(32, 183, 10048)
        $portIsInUse = $lastStartError -is [System.Net.HttpListenerException] -and ($portInUseCodes -contains $lastStartError.NativeErrorCode)
        if (-not $portIsInUse) {
            if ($AllAddresses -and $lastStartError -is [System.Net.HttpListenerException] -and $lastStartError.NativeErrorCode -eq 5) {
                Write-Host "[ERROR] Windows requires a URL reservation to listen on all addresses. Run this command from an elevated PowerShell prompt:"
                Write-Host ('netsh http add urlacl url=http://+:{0}/ user="{1}\{2}"' -f $candidatePort, $env:USERDOMAIN, $env:USERNAME)
            }
            throw
        }
        if ($candidatePort -lt $portEnd) {
            Write-Host "[WARN] Port $candidatePort is already in use; trying port $($candidatePort + 1)."
        }
    }
}
if (-not $listener) {
    throw "Could not start the server; ports $portStart-$portEnd are already in use. Last error: $($lastStartError.Message)"
}

if ($AllAddresses) {
    Write-Host "Starting static server on all addresses at port $Port"
    Write-Warning "Plain HTTP exposes app data and any edit-password hash to the network. Use only on a trusted network."
} else {
    Write-Host "Starting static server at http://localhost:$Port"
}
Write-Host "Serving files from: $Root"
Write-Host "Press 'q' to stop the server.`n"

$mimeTypes = @{
    ".html" = "text/html"
    ".htm"  = "text/html"
    ".js"   = "application/javascript"
    ".css"  = "text/css"
    ".json" = "application/json"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".jpeg" = "image/jpeg"
    ".gif"  = "image/gif"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
    ".txt"  = "text/plain"
}

# Create a new runspace explicitly
$runspace = [runspacefactory]::CreateRunspace()
$runspace.ApartmentState = "STA"
$runspace.ThreadOptions = "ReuseThread"
$runspace.Open()

# Pass variables into runspace session state
$runspace.SessionStateProxy.SetVariable("listener", $listener)
$runspace.SessionStateProxy.SetVariable("Root", $Root)
$runspace.SessionStateProxy.SetVariable("DataFile", $DataFile)
$runspace.SessionStateProxy.SetVariable("DataFileWasSpecified", $dataFileWasSpecified)
$runspace.SessionStateProxy.SetVariable("AppSelection", $App)
$runspace.SessionStateProxy.SetVariable("mimeTypes", $mimeTypes)
$runspace.SessionStateProxy.SetVariable("EditPasswordHash", $EditPasswordHash)
$runspace.SessionStateProxy.SetVariable("EditPasswordRequired", $EditPasswordRequired)
$runspace.SessionStateProxy.SetVariable("AllowClientExit", [bool]$AllowClientExit)
$runspace.SessionStateProxy.SetVariable("ValidationScriptPaths", $validationScriptPaths)

# Define the script to run inside the runspace
$script = {
    foreach ($validatorApp in @("listmanager", "bills")) {
        if ($AppSelection -and $AppSelection -ne $validatorApp) { continue }
        $validatorPath = $ValidationScriptPaths[$validatorApp]
        . $validatorPath
    }

    function Get-FileVersion {
        param([byte[]]$Bytes)

        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hash = $sha256.ComputeHash($Bytes)
            return '"' + [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant() + '"'
        } finally {
            $sha256.Dispose()
        }
    }

    while ($listener.IsListening) {
        $response = $null
        try {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            $response.AddHeader("X-Content-Type-Options", "nosniff")
            if ($request.HttpMethod -notin @("GET", "HEAD", "POST")) {
                $response.StatusCode = 405
                $response.AddHeader("Allow", "GET, HEAD, POST")
                $response.OutputStream.Close()
                continue
            }

            $urlPath = [Uri]::UnescapeDataString($request.Url.AbsolutePath.TrimStart("/"))
            $isSharedResource = $urlPath -eq "shared" -or $urlPath.StartsWith("shared/", [StringComparison]::OrdinalIgnoreCase)
            $appName = $null
            $relativePath = $null
            $appRoot = $null
            $appPrefix = $null
            $dataFilePath = $null
            $rawListPath = $null
            $compressedListPath = $null
            $dataFileIsCompressed = $false
            $isCompressedList = $false

            if ($isSharedResource) {
                $sharedRoot = [IO.Path]::GetFullPath((Join-Path $Root "shared"))
                $relativePath = $urlPath.Substring("shared".Length).TrimStart("/")
                if ([string]::IsNullOrEmpty($relativePath)) {
                    $response.StatusCode = 404
                    $response.OutputStream.Close()
                    continue
                }
                $sharedPrefix = $sharedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                $localPath = [IO.Path]::GetFullPath((Join-Path $sharedRoot $relativePath))
                if (-not $localPath.StartsWith($sharedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $response.StatusCode = 404
                    $response.OutputStream.Close()
                    continue
                }
            } elseif ($AppSelection) {
                if ($urlPath.StartsWith("apps/", [StringComparison]::OrdinalIgnoreCase)) {
                    $response.StatusCode = 404
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Close()
                    continue
                }
                $appName = $AppSelection
                $relativePath = $urlPath
            } elseif ([string]::IsNullOrWhiteSpace($urlPath)) {
                $response.StatusCode = 200
                $response.ContentType = "text/html; charset=utf-8"
                $landingPage = @'
<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>List Manager apps</title>
<h1>Choose an app</h1>
<ul><li><a href="/apps/listmanager/">List Manager</a></li><li><a href="/apps/bills/">Bills</a></li></ul>
</html>
'@
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($landingPage)
$response.ContentLength64 = $bytes.Length
if ($request.HttpMethod -eq "GET") {
    $response.OutputStream.Write($bytes, 0, $bytes.Length)
}
$response.OutputStream.Close()
                continue
            } else {
                $pathParts = $urlPath -split "/", 2
                if ($pathParts[0] -eq "apps" -and $pathParts.Count -eq 2) {
                    $pathParts = $pathParts[1] -split "/", 2
                }
                $appName = $pathParts[0]
                if ($appName -notin @("listmanager", "bills")) {
                    $response.StatusCode = 404
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Close()
                    continue
                }
                $relativePath = if ($pathParts.Count -eq 2) { $pathParts[1] } else { "" }
            }

            if (-not $isSharedResource) {
                $appRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $Root "apps") $appName))
                $appPrefix = $appRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
                if ([string]::IsNullOrEmpty($relativePath)) {
                    if (-not $request.Url.AbsolutePath.EndsWith("/")) {
                        $response.StatusCode = 302
                        $response.RedirectLocation = if ($AppSelection) { "/" } else { "/apps/$appName/" }
                        $response.OutputStream.Close()
                        continue
                    }
                    $relativePath = "index.html"
                }

                $dataFilePath = [IO.Path]::GetFullPath((Join-Path $appRoot $DataFile))
                if (-not $dataFilePath.StartsWith($appPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $response.StatusCode = 500
                    $response.OutputStream.Close()
                    Write-Host "[ERROR] DataFile resolves outside app folder: $DataFile"
                    continue
                }
                $dataFileIsCompressed = [IO.Path]::GetExtension($dataFilePath) -ieq ".gz"
                if ($DataFileWasSpecified) {
                    $rawListPath = if ($dataFileIsCompressed) { $null } else { $dataFilePath }
                    $compressedListPath = if ($dataFileIsCompressed) { $dataFilePath } else { $null }
                } else {
                    $rawListPath = $dataFilePath
                    $compressedListPath = "$dataFilePath.gz"
                }

                $localPath = [IO.Path]::GetFullPath((Join-Path $appRoot $relativePath))
                if (-not $localPath.StartsWith($appPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $response.StatusCode = 404
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Close()
                    continue
                }
            }
            if (-not $isSharedResource -and
                $request.HttpMethod -in @("GET", "HEAD") -and
                $relativePath -notin @("index.html", "data.json", "data.json.gz")) {
                $response.StatusCode = 404
                $bytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.OutputStream.Close()
                continue
            }
            if (-not $isSharedResource -and $relativePath -eq "data.json.gz") {
                $localPath = $compressedListPath
                $isCompressedList = $compressedListPath -and (Test-Path -LiteralPath $compressedListPath -PathType Leaf)
            } elseif (-not $isSharedResource -and $relativePath -eq "data.json") {
                if ($compressedListPath -and (Test-Path -LiteralPath $compressedListPath -PathType Leaf)) {
                    $localPath = $compressedListPath
                    $isCompressedList = $true
                } elseif ($rawListPath -and (Test-Path -LiteralPath $rawListPath -PathType Leaf)) {
                    $localPath = $rawListPath
                } else {
                    $localPath = if ($rawListPath) { $rawListPath } else { $compressedListPath }
                }
            }
            if (-not $isSharedResource -and $relativePath -in @("data.json", "data.json.gz")) {
                $response.AddHeader("X-Edit-Password-Required", $EditPasswordRequired.ToString().ToLowerInvariant())
                $response.AddHeader("X-Allow-Client-Exit", $AllowClientExit.ToString().ToLowerInvariant())
                $response.AddHeader("X-List-Loaded-From-Gzip", $isCompressedList.ToString().ToLowerInvariant())
                $response.AddHeader("Cache-Control", "no-store")
            }
            $localPathExists = $isCompressedList
            if (-not $localPathExists -and $localPath) {
                $localPathExists = Test-Path -LiteralPath $localPath -PathType Leaf
            }
            Write-Host "[VERBOSE] $($request.HttpMethod) $urlPath -> $localPath"

            if (-not $isSharedResource -and $request.HttpMethod -eq "POST" -and $relativePath -eq "client-exit") {
                if ($AllowClientExit) {
                    $response.StatusCode = 200
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{ "status": "stopping" }')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Close()
                    Write-Host "[INFO] Server shutdown requested by browser"
                    $listener.Stop()
                } else {
                    $response.StatusCode = 403
                    $response.OutputStream.Close()
                    Write-Host "[WARN] Ignored browser shutdown request; -AllowClientExit is disabled"
                }
                continue
            }

            if (-not $isSharedResource -and $request.HttpMethod -eq "POST" -and $relativePath -eq "update-list") {
                try {
                    $loadedFromCompressedList = $request.Headers["X-List-Loaded-From-Gzip"] -eq "true"
                    $submittedPasswordHash = $request.Headers["X-Edit-Password"]
                    if ($EditPasswordRequired -and ([string]::IsNullOrEmpty($submittedPasswordHash) -or $submittedPasswordHash -cne $EditPasswordHash)) {
                        $response.StatusCode = 401
                        $response.ContentType = "application/json"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{ "error": "Invalid password" }')
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Close()
                        Write-Host "[WARN] Rejected list update with invalid password"
                        continue
                    }
                    $expectedVersion = $request.Headers["If-Match"]
                    if ([string]::IsNullOrEmpty($expectedVersion)) {
                        $response.StatusCode = 428
                        $response.ContentType = "application/json"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{ "error": "A data version is required" }')
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Close()
                        Write-Host "[WARN] Rejected list update without a data version"
                        continue
                    }
                    $maxRequestBytes = 10MB
                    if ($request.ContentLength64 -gt $maxRequestBytes) {
                        $response.KeepAlive = $false
                        $response.StatusCode = 413
                        $response.ContentType = "application/json"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{ "error": "Request body is too large" }')
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Close()
                        Write-Host "[WARN] Rejected oversized list update ($($request.ContentLength64) bytes)"
                        continue
                    }
                    $requestBuffer = [IO.MemoryStream]::new()
                    $readBuffer = [byte[]]::new(81920)
                    $requestTooLarge = $false
                    $invalidUtf8 = $false
                    try {
                        while (($bytesRead = $request.InputStream.Read($readBuffer, 0, $readBuffer.Length)) -gt 0) {
                            if ($requestBuffer.Length + $bytesRead -gt $maxRequestBytes) {
                                $requestTooLarge = $true
                                break
                            }
                            $requestBuffer.Write($readBuffer, 0, $bytesRead)
                        }
                        if (-not $requestTooLarge) {
                            $requestBytes = $requestBuffer.ToArray()
                            $utf8Encoding = [System.Text.UTF8Encoding]::new($false, $true)
                            try {
                                $requestBody = $utf8Encoding.GetString($requestBytes)
                                if ($requestBody.Length -gt 0 -and $requestBody[0] -eq [char]0xFEFF) {
                                    $requestBody = $requestBody.Substring(1)
                                }
                            } catch [System.Text.DecoderFallbackException] {
                                $invalidUtf8 = $true
                            }
                        }
                    } finally {
                        $requestBuffer.Dispose()
                    }
                    if ($requestTooLarge) {
                        $response.KeepAlive = $false
                        $response.StatusCode = 413
                        $response.ContentType = "application/json"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{ "error": "Request body is too large" }')
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Close()
                        Write-Host "[WARN] Rejected oversized list update"
                        continue
                    }
                    if ($invalidUtf8) {
                        $response.StatusCode = 400
                        $response.ContentType = "application/json; charset=utf-8"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{ "error": "Request body must use UTF-8 encoding" }')
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        $response.OutputStream.Close()
                        Write-Host "[WARN] Rejected list update containing invalid UTF-8"
                        continue
                    }
                    try {
                        $document = ConvertFrom-Json -InputObject $requestBody -ErrorAction Stop
                    } catch {
                        $response.StatusCode = 400
                        $response.ContentType = "application/json"
                        $errorBody = @{ error = "Invalid JSON: $($_.Exception.Message)" } | ConvertTo-Json -Compress
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($errorBody)
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        Write-Host "[WARN] Rejected malformed JSON: $($_.Exception.Message)"
                        $response.OutputStream.Close()
                        continue
                    }
                    try {
                        $validatorName = if ($appName -eq "listmanager") { "Test-ListManagerDocument" } else { "Test-BillsDocument" }
                        & $validatorName -Document $document
                    } catch [ArgumentException] {
                        $response.StatusCode = 400
                        $response.ContentType = "application/json"
                        $errorBody = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($errorBody)
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        Write-Host "[WARN] Rejected invalid list document: $($_.Exception.Message)"
                        $response.OutputStream.Close()
                        continue
                    } catch {
                        throw
                    }
                    $json = $document | ConvertTo-Json -Depth 100 -WarningAction Stop
                    $jsonBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
                    $writeCompressedList = $DataFileIsCompressed -or (-not $DataFileWasSpecified -and $loadedFromCompressedList)
                    if ($writeCompressedList) {
                        $compressedStream = [IO.MemoryStream]::new()
                        try {
                            $gzipStream = [IO.Compression.GZipStream]::new(
                                $compressedStream,
                                [IO.Compression.CompressionMode]::Compress,
                                $true
                            )
                            try {
                                $gzipStream.Write($jsonBytes, 0, $jsonBytes.Length)
                            } finally {
                                $gzipStream.Dispose()
                            }
                            $storedBytes = $compressedStream.ToArray()
                        } finally {
                            $compressedStream.Dispose()
                        }
                        $targetPath = $compressedListPath
                    } else {
                        $storedBytes = $jsonBytes
                        $targetPath = $rawListPath
                    }

                    $mutexNameHash = [Security.Cryptography.SHA256]::Create()
                    try {
                        $mutexNameBytes = [Text.Encoding]::UTF8.GetBytes($dataFilePath.ToLowerInvariant())
                        $mutexNameSuffix = [BitConverter]::ToString($mutexNameHash.ComputeHash($mutexNameBytes)).Replace('-', '')
                    } finally {
                        $mutexNameHash.Dispose()
                    }
                    $DataFileMutexName = "ListManager-$mutexNameSuffix"
                    $currentListPath = if ($DataFileWasSpecified) {
                        $dataFilePath
                    } elseif ($compressedListPath -and (Test-Path -LiteralPath $compressedListPath -PathType Leaf)) {
                        $compressedListPath
                    } else {
                        $rawListPath
                    }
                    $mutex = [Threading.Mutex]::new($false, $DataFileMutexName)
                    $mutexAcquired = $false
                    $tempPath = $null
                    $backupPath = $null
                    $writeConflict = $false
                    try {
                        try {
                            $mutexAcquired = $mutex.WaitOne()
                        } catch [Threading.AbandonedMutexException] {
                            $mutexAcquired = $true
                        }
                        if (-not (Test-Path -LiteralPath $currentListPath -PathType Leaf) -or
                            (Get-FileVersion ([IO.File]::ReadAllBytes($currentListPath))) -cne $expectedVersion) {
                            $writeConflict = $true
                        } else {
                            $tempPath = "$targetPath.$([Guid]::NewGuid().ToString('N')).tmp"
                            [IO.File]::WriteAllBytes($tempPath, $storedBytes)
                            if (-not (Test-Path -LiteralPath $currentListPath -PathType Leaf) -or
                                (Get-FileVersion ([IO.File]::ReadAllBytes($currentListPath))) -cne $expectedVersion) {
                                $writeConflict = $true
                            } elseif ([IO.File]::Exists($targetPath)) {
                                $backupPath = "$targetPath.$([Guid]::NewGuid().ToString('N')).bak"
                                [IO.File]::Replace($tempPath, $targetPath, $backupPath)
                                $tempPath = $null
                            } else {
                                [IO.File]::Move($tempPath, $targetPath)
                                $tempPath = $null
                            }
                        }
                    } finally {
                        try {
                            if ($tempPath -and [IO.File]::Exists($tempPath)) {
                                try {
                                    [IO.File]::Delete($tempPath)
                                } catch {
                                    Write-Host "[WARN] Could not remove temporary write file ${tempPath}: $($_.Exception.Message)"
                                }
                            }
                            if ($backupPath -and [IO.File]::Exists($backupPath)) {
                                try {
                                    [IO.File]::Delete($backupPath)
                                } catch {
                                    Write-Host "[WARN] Could not remove temporary replacement backup ${backupPath}: $($_.Exception.Message)"
                                }
                            }
                        } finally {
                            try {
                                if ($mutexAcquired) {
                                    $mutex.ReleaseMutex()
                                }
                            } finally {
                                $mutex.Dispose()
                            }
                        }
                    }

                    if ($writeConflict) {
                        $response.StatusCode = 409
                        $response.ContentType = "application/json"
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{ "error": "Data file changed; reload before saving" }')
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                        Write-Host "[WARN] Rejected stale list update"
                        $response.OutputStream.Close()
                        continue
                    }

                    $response.StatusCode = 200
                    $response.ContentType = "application/json"
                    $response.AddHeader("ETag", (Get-FileVersion $storedBytes))
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{ "status": "ok" }')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    if ($writeCompressedList) {
                        Write-Host "[INFO] Updated gzip list: $compressedListPath"
                    } else {
                        Write-Host "[INFO] Updated raw JSON list: $rawListPath"
                    }
                } catch {
                    $response.StatusCode = 500
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("Error saving selected data file")
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    Write-Host "[ERROR] Failed to update ${dataFilePath}: $($_.Exception.Message)"
                }
                $response.OutputStream.Close()
                continue
            }

            if (($request.HttpMethod -eq "GET" -or $request.HttpMethod -eq "HEAD") -and $localPathExists) {
                try {
                    if ($isCompressedList) {
                        $bytes = [IO.File]::ReadAllBytes($compressedListPath)
                        $contentType = "application/json"
                        $response.AddHeader("Content-Encoding", "gzip")
                    } else {
                        $ext = [IO.Path]::GetExtension($localPath).ToLower()
                        $contentType = $mimeTypes[$ext]
                        if (-not $contentType) { $contentType = "application/octet-stream" }
                        $bytes = [IO.File]::ReadAllBytes($localPath)
                    }

                    if (-not $isSharedResource -and ($relativePath -eq "data.json" -or $relativePath -eq "data.json.gz")) {
                        $response.AddHeader("ETag", (Get-FileVersion $bytes))
                    }
                    $response.ContentType = $contentType
                    $response.ContentLength64 = $bytes.Length
                    if ($request.HttpMethod -eq "GET") {
                        $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    }
                    Write-Host "[OK] Served $localPath"
                } catch {
                    $response.StatusCode = 500
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('Internal server error.')
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    Write-Host "[ERROR] Failed to serve $localPath"
                }
            } else {
                $response.StatusCode = 404
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('404 Not Found')
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                Write-Host "[WARN] File not found: $localPath"
            }

            $response.OutputStream.Close()
        } catch {
            if ($listener.IsListening) {
                Write-Host "[ERROR] Request failed: $($_.Exception.Message)"
                if ($response) {
                    try {
                        $response.StatusCode = 500
                        $response.OutputStream.Close()
                    } catch {
                    }
                }
                continue
            }
            break
        }
    }
}

# Create PowerShell instance associated with the runspace
$powershell = [powershell]::Create()
$powershell.Runspace = $runspace
$powershell.AddScript($script) | Out-Null

# Start running the script asynchronously
$asyncResult = $powershell.BeginInvoke()
if ($OpenBrowser) {
    Start-Process "http://localhost:$Port/"
}

# Main loop to wait for 'q' to quit
$consoleInputAvailable = $true
while ($listener.IsListening) {
    if ($consoleInputAvailable) {
        try {
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                if ($key.KeyChar -ieq 'q') {
                    $listener.Stop()
                    break
                }
            }
        } catch [InvalidOperationException] {
            $consoleInputAvailable = $false
            Write-Host "[WARN] Console input is unavailable; use Ctrl+C or -AllowClientExit to stop the server."
        }
    }
    Start-Sleep -Milliseconds 100
}

# Cleanup and stop runspace
$powershell.EndInvoke($asyncResult)
$powershell.Dispose()
$runspace.Close()

Write-Host "Server has been stopped."
