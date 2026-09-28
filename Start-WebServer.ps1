param (
    [string]$Port = "8080",
    [string]$Root = (Get-Location).Path,
    [string]$DataFile = "data.json",
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
    throw "DataFile must be a relative path inside Root."
}
$Root = [IO.Path]::GetFullPath($Root)
$dataFilePath = [IO.Path]::GetFullPath((Join-Path $Root $DataFile))
$rootPrefix = $Root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $dataFilePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "DataFile must resolve to a path inside Root."
}
$dataFileWasSpecified = $PSBoundParameters.ContainsKey("DataFile")
$dataFileIsCompressed = [IO.Path]::GetExtension($dataFilePath) -ieq ".gz"
if ($dataFileWasSpecified) {
    $rawListPath = if ($dataFileIsCompressed) { $null } else { $dataFilePath }
    $compressedListPath = if ($dataFileIsCompressed) { $dataFilePath } else { $null }
} else {
    $rawListPath = $dataFilePath
    $compressedListPath = "$dataFilePath.gz"
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
$runspace.SessionStateProxy.SetVariable("DataFilePath", $dataFilePath)
$runspace.SessionStateProxy.SetVariable("RawListPath", $rawListPath)
$runspace.SessionStateProxy.SetVariable("CompressedListPath", $compressedListPath)
$runspace.SessionStateProxy.SetVariable("DataFileWasSpecified", $dataFileWasSpecified)
$runspace.SessionStateProxy.SetVariable("DataFileIsCompressed", $dataFileIsCompressed)
$runspace.SessionStateProxy.SetVariable("mimeTypes", $mimeTypes)
$runspace.SessionStateProxy.SetVariable("EditPasswordHash", $EditPasswordHash)
$runspace.SessionStateProxy.SetVariable("EditPasswordRequired", $EditPasswordRequired)
$runspace.SessionStateProxy.SetVariable("AllowClientExit", [bool]$AllowClientExit)

# Define the script to run inside the runspace
$script = {
    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response

            $urlPath = $request.Url.AbsolutePath.TrimStart("/")
            if ([string]::IsNullOrWhiteSpace($urlPath)) { $urlPath = "index.html" }

            $localPath = Join-Path $Root $urlPath
            $isCompressedList = $false
            if ($urlPath -eq "data.json.gz") {
                $localPath = $compressedListPath
                $isCompressedList = $compressedListPath -and (Test-Path -LiteralPath $compressedListPath -PathType Leaf)
            } elseif ($urlPath -eq "data.json") {
                if ($rawListPath -and (Test-Path -LiteralPath $rawListPath -PathType Leaf)) {
                    $localPath = $rawListPath
                } elseif ($compressedListPath -and (Test-Path -LiteralPath $compressedListPath -PathType Leaf)) {
                    $localPath = $compressedListPath
                    $isCompressedList = $true
                } else {
                    $localPath = if ($rawListPath) { $rawListPath } else { $compressedListPath }
                }
            }
            Write-Host "[VERBOSE] $($request.HttpMethod) $urlPath -> $localPath"

            if ($request.HttpMethod -eq "POST" -and $urlPath -eq "client-exit") {
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

            if ($request.HttpMethod -eq "POST" -and $urlPath -eq "update-list") {
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
                    $reader = New-Object IO.StreamReader $request.InputStream, $request.ContentEncoding
                    $document = $reader.ReadToEnd() | ConvertFrom-Json
                    $propertyNames = @($document.PSObject.Properties.Name)
                    if ($propertyNames -notcontains "schema" -or $propertyNames -notcontains "records" -or -not $document.schema.fields) {
                        throw "Expected schema and records in request body"
                    }
                    $json = $document | ConvertTo-Json -Depth 10
                    $jsonBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
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
                        $writeCompressedList = $DataFileIsCompressed -or (-not $DataFileWasSpecified -and $loadedFromCompressedList)
                        if ($writeCompressedList) {
                            [IO.File]::WriteAllBytes($compressedListPath, $compressedStream.ToArray())
                        } else {
                            [IO.File]::WriteAllBytes($rawListPath, $jsonBytes)
                        }
                    } finally {
                        $compressedStream.Dispose()
                    }

                    $response.StatusCode = 200
                    $response.ContentType = "application/json"
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
                    Write-Host "[ERROR] Failed to update $DataFilePath"
                }
                $response.OutputStream.Close()
                continue
            }

            if ($request.HttpMethod -eq "GET" -and ($isCompressedList -or (Test-Path $localPath))) {
                try {
                    if ($urlPath -eq "data.json" -or $urlPath -eq "data.json.gz") {
                        $response.AddHeader("X-Edit-Password-Required", $EditPasswordRequired.ToString().ToLowerInvariant())
                        $response.AddHeader("X-Allow-Client-Exit", $AllowClientExit.ToString().ToLowerInvariant())
                    }
                    if ($isCompressedList) {
                        $bytes = [IO.File]::ReadAllBytes($compressedListPath)
                        $contentType = "application/json"
                        $response.AddHeader("Content-Encoding", "gzip")
                        $response.AddHeader("Cache-Control", "no-store")
                    } else {
                        $ext = [IO.Path]::GetExtension($localPath).ToLower()
                        $contentType = $mimeTypes[$ext]
                        if (-not $contentType) { $contentType = "application/octet-stream" }
                        $bytes = [IO.File]::ReadAllBytes($localPath)
                    }

                    $response.ContentType = $contentType
                    $response.ContentLength64 = $bytes.Length
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
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
                Write-Host "[ERROR] Listener exception."
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
while ($listener.IsListening) {
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.KeyChar -ieq 'q') {
            $listener.Stop()
            break
        }
    }
    Start-Sleep -Milliseconds 100
}

# Cleanup and stop runspace
$powershell.EndInvoke($asyncResult)
$powershell.Dispose()
$runspace.Close()

Write-Host "Server has been stopped."
