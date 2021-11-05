
$logFile = "updEnv.log"

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

    # check if environment is set correctly
    if (-not ($sysEnv -eq "dev" -or $sysEnv -eq "test" -or $sysEnv -eq "live")) {
        write-log -Message "environment variable not set" -Severity "Error"
        exit 1
    }

    if (-not ($sysTier -eq "api" -or $sysTier -eq "web")) {
        write-log -Message "tier variable not set" -Severity "Error"
        exit 1
    }

    net stop w3svc

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
    }

    net start w3svc
} catch {
    write-log -Message "Caught an exception:" -Severity "Error"
    write-log -Message "Exception Type: $($_.Exception.GetType().FullName)" -Severity "Error"
    write-log -Message "Exception Message: $($_.Exception.Message)" -Severity "Error"
    exit 1
}
