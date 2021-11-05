# startup and deployment script for Command Papers .NET framework

$logFile = "startup.log"
$runFlag = "startupActive.txt"

function write-log
{
   param(
        [string]$Message,
        [string]$Severity = 'Information'
   )

   $Time = (Get-Date -f g)
   Add-content $logFile -value "$Time - $Severity - $Message"
}

function retrieve-security-creds
{
	$sts = aws sts assume-role --role-arn arn:aws:iam::500447081210:role/discovery-s3-deployment-source-access --role-session-name s3-access | ConvertFrom-Json
	$Env:AWS_ACCESS_KEY_ID = $sts.Credentials.AccessKeyId
	$Env:AWS_SECRET_ACCESS_KEY = $sts.Credentials.SecretAccessKey
	$Env:AWS_SESSION_TOKEN = $sts.Credentials.SessionToken
	$Env:AWS_ACCESS_EXPIRATION = $sts.Credentials.Expiration
}

try {
	if (Test-Path -Path "$runFlag" -PathType leaf) {
		write-log -Message "script is already active" -Severity "Warning"
		exit
	} else {
		$Time = (Get-Date -f g)
		Add-content $runFlag -value "$Time - startup script is activated"
	}

	if (Test-Path "env:\AWS_ACCESS_KEY_ID") {
		$now = Get-Date
		$endToken = Get-Date $Env:AWS_ACCESS_EXPIRATION
		if ($now -gt $endToken) {
			write-log -Message "security token renewal" -Severity "Information"
			retrieve-security-creds
		}
	} else {
		write-log -Message "security token requested" -Severity "Information"
		retrieve-security-creds
	}

	$sysEnv = $Env:TNA_APP_ENVIRONMENT
	$sysTier = $Env:TNA_APP_TIER

	$ecommercePath = ""

	# check if environment is set correctly
	if (-not ($sysEnv -eq "dev" -or $sysEnv -eq "test" -or $sysEnv -eq "live")) {
		write-log -Message "environment variable not set" -Severity "Error"
		exit 1
	}

	if (-not ($sysTier -eq "api" -or $sysTier -eq "web")) {
		write-log -Message "tier variable not set" -Severity "Error"
		exit 1
	}

	write-log -Message "read environment variables from system manager"
	$smData = aws ssm get-parameter --name Discovery.Environment.$Env:TNA_APP_ENVIRONMENT.$Env:TNA_APP_TIER --region eu-west-2 | ConvertFrom-Json
	$smValues = $smData.Parameter.Value | ConvertFrom-Json
	# iterate over json content
	$smValues | Get-Member -MemberType NoteProperty | ForEach-Object {
    	$smKey = $_.Name
   		# setting environment variables
   		$envValue = $smValues."$smKey"
   		write-log -Message "set: $smKey - $envValue" -Severity "Information"
    	[System.Environment]::SetEnvironmentVariable($smKey.trim(), $envValue.trim(), "Machine")
		if ($smKey.trim() -eq "DISC_ECOMMERCE_LOG_FILEPATH") {
			$ecommercePath = $envValue.trim()
		}
	}

    $baseS3Path = "s3://ds-intersite-deployment/discovery/builds"
	$resourcePath = "$baseS3Path/$sysEnv/"
	$resourceFile = "TNA.Discovery.$sysTier.zip"
    $dependencyFile = "TNA.Discovery.api.dependencies.zip"
	$resource = $resourcePath + $resourceFile
    $dependencyResource = $resourcePath + $dependencyFile
	$destination = "c:\temp\deployment-files"
	$websiteName = "Main"
	$appPool = "DiscoveryAppPool"
	$websiteRoot = "C:\WebSites"
    $servicesDir = "$websiteRoot\Services"
    if ($sysTier -eq "web") {
        $webSiteDir = "$servicesDir\RDWeb"
    } else {
        $webSiteDir = "$webSiteRoot\Main"
    }

	write-log -Message "downloading for $sysEnv - $sysTier" -Severity "Information"
	if (-not (Test-Path $destination)) {
		mkdir "$destination"
	}
	aws s3 cp "$resource" "$destination"

    if ($sysTier -eq "api") {
        write-log -Message "downloading dependencies for api" -Severity "Information"
        aws s3 cp "$dependencyResource" "$destination"
    }

	write-log -Message "deploying $resourceFile to $websiteName" -Severity "Information"

    Stop-WebAppPool -Name $appPool
    net stop w3svc

    write-log -Message "removing all files from services" -Severity "Information"
    Get-ChildItem "$servicesDir" -Recurse | Remove-Item -Force -Recurse

	write-log -Message "expand downloaded packages" - Severity "Information"
    Get-ChildItem "$destination" -Filter *.zip | Expand-Archive -DestinationPath "$servicesDir" -Force

    $serviceList = Get-ChildItem -Directory -Path "$servicesDir" -Exclude "RDWeb"
    if ($sysTier -eq "web") {
        New-WebApplication -Name "API" -Site "$websiteName" -ApplicationPool "$appPool" -PhysicalPath "$servicesDir\DiscoveryAPI" -Force
    } else {
        ForEach ($entry in $serviceList) {
            $serviceName = $entry.Name
            New-WebApplication -Name "$serviceName" -Site "$websiteName" -ApplicationPool "$appPool" -PhysicalPath "$servicesDir\$serviceName" -Force
        }
    }

    net start w3svc
    Start-WebAppPool -Name $appPool

	if (-not ($ecommercePath -eq "")) {
		# create eCommerce folder
		$ecommercePath = Split-Path -Path "$ecommercePath"
		New-Item -itemtype "directory" $ecommercePath -Force

		# set IIS_IUSRS access right for folder to full control
		$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS_IUSRS", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
		$acl = Get-ACL "$ecommercePath"
		$acl.AddAccessRule($accessRule)
		Set-ACL -Path "$ecommercePath" -ACLObject $acl

		# set app pool access right for folder to write
		$accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("IIS AppPool\$appPool", "Write", "ContainerInherit,ObjectInherit", "None", "Allow")
		$acl = Get-ACL "$ecommercePath"
		$acl.AddAccessRule($accessRule)
		Set-ACL -Path "$ecommercePath" -ACLObject $acl
	}

	write-log -Message "removing deployment file(s) from $destination" -Severity "Information"
    Get-ChildItem "$destination" -Recurse | Remove-Item -Force -Recurse
	Remove-Item -Force $destination

	Remove-Item -Force $runFlag
} catch {
	write-log -Message "Caught an exception:" -Severity "Error"
	write-log -Message "Exception Type: $($_.Exception.GetType().FullName)" -Severity "Error"
	write-log -Message "Exception Message: $($_.Exception.Message)" -Severity "Error"
    exit 1
}
