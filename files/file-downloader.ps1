# PowerShell script downloading files - http

Param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$UrlSource,

    [Parameter()]
    [ValidateScript({ Test-Path -Path $_ -PathType Container})]
    [string]$DestinationPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Filename,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$PackageName
)

try
{
    # Catch non-terminateing errors
    $ErrorActionPreference = "Stop"

    # create WebClient for copying files from URLs
    $Wget = New-Object System.Net.WebClient

    # download source
    $UrlSourceFile = $UrlSource + $Filename
    # download destination
    $FileEndPoint = $DestinationPath + $Filename

    write-host "start downloading $PackageName"
    write-host "from: $UrlSourceFile"
    write-host "to: $FileEndPoint"

    # start download
    $Wget.DownloadFile($UrlSourceFile, $FileEndPoint)

    if (Test-Path $FileEndPoint -PathType Leaf) {
        write-host "$PackageName downloaded"  -ForegroundColor Green
    } else {
        write-host "ERROR downloading $PackageName"  -ForegroundColor Red
    }
}
catch
{
    write-host "Caught an exception:" -ForegroundColor Red
    write-host "Exception Type: $($_.Exception.GetType().FullName)" -ForegroundColor Red
    write-host "Exception Message: $($_.Exception.Message)" -ForegroundColor Red
}
