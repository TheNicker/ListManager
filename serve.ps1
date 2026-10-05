param (
    [string]$Port = "41000-41010",
    [ValidateSet("listmanager", "bills")]
    [string]$App,
    [string]$DataFile,
    [switch]$OpenBrowser = $true,
    [switch]$AllowClientExit = $true,
    [switch]$AllAddresses,
    [string]$EditPassword
)

$serverParameters = @{
    Port           = $Port
    OpenBrowser    = $OpenBrowser
    AllowClientExit = $AllowClientExit
}
if ($App) {
    $serverParameters.App = $App
}
if ($PSBoundParameters.ContainsKey("DataFile")) {
    $serverParameters.DataFile = $DataFile
}
if ($AllAddresses) {
    $serverParameters.AllAddresses = $true
}
if ($EditPassword) {
    $serverParameters.EditPassword = $EditPassword
}

& (Join-Path $PSScriptRoot "Start-WebServer.ps1") @serverParameters