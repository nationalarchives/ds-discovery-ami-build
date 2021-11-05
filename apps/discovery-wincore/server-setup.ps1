# server setup
# os and environment setup

param(
	[string]$application = "",
	[string]$environment = "",
	[string]$tier = ""
)

# Set-ExecutionPolicy Bypass -Scope Process

$tmpDir = "c:\temp"

# required packages
$installerPackageUrl =  "s3://ds-intersite-deployment/discovery/installation-packages"

$wacInstaller = "WindowsAdminCenter2103.msi"
$dotnetInstaller = "ndp48-web.exe"
$dotnetPackagename = ".NET Framework 4.8 Platform (web installer)"
$dotnetCoreInstaller = "dotnet-hosting-3.1.7-win.exe"
$dotnetCorePackagename = ".NET Core 3.1.7"
$cloudwatchAgentJSON = "discovery-cloudwatch-agent.json"
$pathAWScli = "C:\Program Files\Amazon\AWSCLIV2"

$cloudwatchAgentInstaller = "https://s3.eu-west-1.amazonaws.com/amazoncloudwatch-agent-eu-west-1/windows/amd64/latest/amazon-cloudwatch-agent.msi"
$ec2launchInstallerUrl = "https://s3.amazonaws.com/amazon-ec2launch-v2/windows/amd64/latest"
$ec2launchInstaller = "AmazonEC2Launch.msi"

# website parameters
$appPool = "DiscoveryAppPool"
$webSiteName = "Main"
$webSiteRoot = "C:\WebSites"

# discovery front-end server setup requires to be based in RDWeb service
$servicesPath = "$webSiteRoot\Services"
if ($tier -eq "web") {
    $webSitePath = "$servicesPath\RDWeb"
} else {
    $webSitePath = "$webSiteRoot\Main"
}

# environment variables for target system
$envHash = @{
    "TNA_APP_ENVIRONMENT" = "$environment"
    "TNA_APP_TIER" = "$tier"
}

Write-Host "=================> start server setup script"

try {
    # Catch non-terminateing errors
    $ErrorActionPreference = "Stop"

    Write-Host "---- create required directories"
    New-Item -itemtype "directory" $webSiteRoot -Force
    New-Item -itemtype "directory" "$servicesPath" -Force
    New-Item -itemtype "directory" "$webSitePath" -Force

    Write-Host "===> AWS CLI V2"
    Write-Host "---- downloading AWS CLI"
    Invoke-WebRequest -UseBasicParsing -Uri https://awscli.amazonaws.com/AWSCLIV2.msi -OutFile c:/temp/AWSCLIV2.msi
    Write-Host "---- installing AWS CLI"
    Start-Process msiexec.exe -Wait -ArgumentList '/i c:\temp\AWSCLIV2.msi /qn /norestart' -NoNewWindow
    Write-Host "---- set path to AWS CLI"
    $oldpath = (Get-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment" -Name PATH).path
    $newpath = $oldpath;$pathAWScli
    Set-ItemProperty -Path "Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment" -Name PATH -Value $newPath
    $env:Path = "$env:Path;$pathAWScli"

    Write-Host "===> Windows features for IIS"
    Write-Host "---- IIS-WebServerRole, IIS-WebServer, IIS-ISAPIExtensions, IIS-ISAPIFilter, IIS-URLAuthorization, IIS-ASPNET45, IIS-NetFxExtensibility45"
    Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ISAPIExtensions, IIS-ISAPIFilter, IIS-URLAuthorization, IIS-NetFxExtensibility45 -All
    if ($tier -eq "api") {
        Write-Host "---- IIS-HttpRedirect for application server"
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-HttpRedirect
    }
    Write-Host "---- NetFx4Extended-ASPNET45"
    Enable-WindowsOptionalFeature -Online -FeatureName NetFx4Extended-ASPNET45
    Write-Host "---- WCF-HTTP-Activation45"
    Enable-WindowsOptionalFeature -Online -FeatureName WCF-HTTP-Activation45 -All

    Write-Host "===> WebPlatformInstaller and URLRewrite2"
    (new-object System.Net.WebClient).DownloadFile("http://download.microsoft.com/download/C/F/F/CFF3A0B8-99D4-41A2-AE1A-496C08BEB904/WebPlatformInstaller_amd64_en-US.msi", "$tmpDir/WebPlatformInstaller_amd64_en-US.msi")
    Start-Process -FilePath "$tmpDir/WebPlatformInstaller_amd64_en-US.msi" -ArgumentList "/qn" -PassThru -Wait
    $logFile = "$tmpDir/WebpiCmd.log"
    Start-Process -FilePath "C:/Program Files/Microsoft/Web Platform Installer\WebpiCmd.exe" -ArgumentList "/Install /Products:'UrlRewrite2' /AcceptEULA /Log:$logFile" -PassThru -Wait

    Write-Host "===> IIS Remote Management"
    netsh advfirewall firewall add rule name="IIS Remote Management" dir=in action=allow protocol=TCP localport=8172
    Install-WindowsFeature Web-Mgmt-Service
    Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\WebManagement\Server -Name EnableRemoteManagement -Value 1
    Set-Service -Name WMSVC -StartupType Automatic

    Write-Host "===> AWS X-Ray"
    Write-Host "---- Daemon"
    if ( Get-Service "AWSXRayDaemon" -ErrorAction SilentlyContinue ) {
        sc.exe stop AWSXRayDaemon
        sc.exe delete AWSXRayDaemon
    }
    $targetLocation = "C:\Program Files\Amazon\XRay"
    if ((Test-Path $targetLocation) -eq 0) {
        mkdir $targetLocation
    }
    Write-Host "---- AWS XRay"
    $zipFileName = "aws-xray-daemon-windows-service-3.x.zip"
    $zipPath = "$targetLocation\$zipFileName"
    $destPath = "$targetLocation\aws-xray-daemon"
    if ((Test-Path $destPath) -eq 1) {
        Remove-Item -Recurse -Force $destPath
    }
    Write-Host "---- downloading AWS X-Ray daemon"
    $daemonPath = "$destPath\xray.exe"
    $daemonLogPath = "$targetLocation\xray-daemon.log"
    $url = "https://s3.dualstack.us-west-2.amazonaws.com/aws-xray-assets.us-west-2/xray-daemon/aws-xray-daemon-windows-service-3.x.zip"
    Invoke-WebRequest -Uri $url -OutFile $zipPath

    Write-Host "---- expanding AWS X-Ray zip file"
    Add-Type -Assembly "System.IO.Compression.Filesystem"
    [io.compression.zipfile]::ExtractToDirectory($zipPath, $destPath)

    Write-Host "---- installing AWS X-Ray daemon"
    New-Service -Name "AWSXRayDaemon" -StartupType Automatic -BinaryPathName "`"$daemonPath`" -f `"$daemonLogPath`""
    sc.exe start AWSXRayDaemon

    Write-Host "===> aquire AWS credentials"
    $sts = Invoke-Expression -Command "aws sts assume-role --role-arn arn:aws:iam::500447081210:role/discovery-s3-deployment-source-access --role-session-name s3-access" | ConvertFrom-Json
    $Env:AWS_ACCESS_KEY_ID = $sts.Credentials.AccessKeyId
    $Env:AWS_SECRET_ACCESS_KEY = $sts.Credentials.SecretAccessKey
    $Env:AWS_SESSION_TOKEN = $sts.Credentials.SessionToken

    Write-Host "===> download and install required packages and config files"
    Set-Location -Path $tmpDir

    Write-Host "---- AWS X-Ray config file"
    Invoke-Expression -Command "aws s3 cp $installerPackageUrl/xray-cfg.yaml `"$targetLocation`""

    Write-Host "===> install CloudWatch Agent"
    Write-Host "---- download agent"
    (new-object System.Net.WebClient).DownloadFile($cloudwatchAgentInstaller, "$tmpDir\amazon-cloudwatch-agent.msi")
    Write-Host "---- download config json"
    Invoke-Expression -Command "aws s3 cp $installerPackageUrl/$cloudwatchAgentJSON $tmpDir"
    Write-Host "---- start installation"
    Start-Process msiexec.exe -Wait -ArgumentList "/I `"$tmpDir\amazon-cloudwatch-agent.msi`" /quiet"
    Write-Host "---- configure agent"
    & "C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent-ctl.ps1" -a fetch-config -m ec2 -c file:$tmpDir\$cloudwatchAgentJSON -s
    Write-Host "---- end cloudwatch installation process"

    Write-Host "===> $dotnetPackagename"
    Invoke-Expression -Command "aws s3 cp $installerPackageUrl/$dotnetInstaller $tmpDir"
    Write-Host "---- start installation process"
    Start-Process -FilePath $dotnetInstaller -ArgumentList "/q /norestart" -PassThru -Wait
    Write-Host "---- end installation process"

    if ($tier -eq "api") {
        Write-Host "===> $dotnetCorePackagename"
        Invoke-Expression -Command "aws s3 cp $installerPackageUrl/$dotnetCoreInstaller $tmpDir"
        Write-Host "---- start installation process"
        Start-Process -FilePath $dotnetCoreInstaller -ArgumentList "/q /norestart" -PassThru -Wait
        Write-Host "---- end installation process"
    }

    Write-Host "---- create AppPool"
    Import-Module WebAdministration
    New-WebAppPool -name $appPool  -force
    Set-ItemProperty -Path IIS:\AppPools\$appPool -Name managedRuntimeVersion -Value 'v4.0'
    Set-ItemProperty -Path IIS:\AppPools\$appPool -Name processModel.loadUserProfile -Value 'True'

    Write-Host "---- create website"
    Stop-Website -Name "Default Web Site"
    Set-ItemProperty "IIS:\Sites\Default Web Site" serverAutoStart False
    Remove-WebSite -Name "Default Web Site"
    $site = new-WebSite -name $webSiteName -PhysicalPath $webSitePath -ApplicationPool $appPool -force

    Write-Host "---- give IIS_USRS permissions"
    $acl = Get-ACL $webSiteRoot
    $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS_IUSRS", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($accessRule)
    Set-ACL -Path "$webSiteRoot" -ACLObject $acl

    # remove unwanted IIS headers
    Clear-WebConfiguration "/system.webServer/httpProtocol/customHeaders/add[@name='X-Powered-By']"

    Write-Host "===> AWS XRay .NET Agent"
    Write-Host "---- download installer"
    Invoke-WebRequest -Uri https://s3.amazonaws.com/aws-xray-assets.us-east-1/xray-agent-installer/aws-xray-dotnet-agent-installer-beta-X64.msi -OutFile c:/temp/aws-xray-dotnet-agent-installer-beta-X64.msi
    Write-Host "---- installing XRay .NET Agent"
    #Start-Process msiexec.exe -Wait -ArgumentList '/i c:/temp/aws-xray-dotnet-agent-installer-beta-X64.msi /qn /norestart' -NoNewWindow
    Invoke-Expression -Command "c:/temp/aws-xray-dotnet-agent-installer-beta-X64.msi"

    Start-WebSite -Name $webSiteName

    # set system variables for application
    Write-Host "===> environment variables"
    foreach ($key in $envHash.keys) {
        $envKey = $($key)
        $envValue = $($envHash[$key])
        [System.Environment]::SetEnvironmentVariable($envKey, $envValue, "Machine")
    }

    Write-Host "===> set network interface profile to private"
    $networks = Get-NetConnectionProfile
    Write-Output $networks
    $interfaceIndex = $networks.InterfaceIndex
    Write-Host "change interface index $interfaceIndex"
    Set-NetConnectionProfile -InterfaceIndex $interfaceIndex -NetworkCategory private
    Write-Output $(Get-NetConnectionProfile -InterfaceIndex $interfaceIndex)

    Write-Host "===> enable SMBv2 signing"
    Set-SmbServerConfiguration -EnableSMB2Protocol $true -Force

    Write-Host "===> EC2Launch"
    Write-Host "---> set instance to generate a new password for next start and run user script"
    $destination = "C:\ProgramData\Amazon\EC2-Windows\Launch\Config"
    Set-Content -Path "$destination\LaunchConfig.json" -Value @"
{
    "SetComputerName":  false,
    "SetMonitorAlwaysOn":  false,
    "SetWallpaper":  true,
    "AddDnsSuffixList":  true,
    "ExtendBootVolumeSize":  true,
    "HandleUserData":  true,
    "AdminPasswordType":  "Random",
    "AdminPassword":  ""
}
"@
    Write-Host "---- schedule EC2Launch for next start"
    C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeInstance.ps1 -Schedule

    Write-Host "===> Windows Admin Center"
    netsh advfirewall firewall add rule name="WAC" dir=in action=allow protocol=TCP localport=3390
    Invoke-Expression -Command "aws s3 cp $installerPackageUrl/$wacInstaller $tmpDir"
    Write-Host "---- start installation process"
    Start-Process -FilePath $wacInstaller -ArgumentList "/qn /L*v log.txt SME_PORT=3390 SSL_CERTIFICATE_OPTION=generate RESTART_WINRM=0" -PassThru -Wait

    Write-Host "=================> end of server setup script"
} catch {
    Write-Host "Caught an exception:"
    Write-Host "Exception Type: $($_.Exception.GetType().FullName)"
    Write-Host "Exception Message: $($_.Exception.Message)"
    exit 1
}
