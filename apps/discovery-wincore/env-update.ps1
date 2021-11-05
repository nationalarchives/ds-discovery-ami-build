# powershell test script

# stop_and_go -asGroup commandpapers-appservers-group -profile devdsadmin -region eu-west-2

param(
    [string]$standbyTime = 300,
    [string]$asGroup,
    [string]$profile,
    [string]$region,
    [string]$keyFile
)

$processOk = 0
$tgDeregistrationDelay = [int]$standbyTime
$timeout = [int]($tgDeregistrationDelay * 1.5)
$intervalSeconds = 10

$adminUser = "Administrator"

# get instances of this autoscaling group
$instanceString = aws autoscaling describe-auto-scaling-groups --profile $profile --region $region --auto-scaling-group-name $asGroup  --query 'AutoScalingGroups[*].Instances[*].InstanceId' --output text

$instances = -split $instanceString

if ($instances.count -eq 0) {
    Write-Host "No instances registered in group $asGroup"
    exit 2
}

# get target groups arns to reduce time
$targetArnsString = aws autoscaling describe-auto-scaling-groups --profile $profile --region $region --auto-scaling-group-name $asGroup --query "AutoScalingGroups[*].TargetGroupARNs" --output text

$targetArns = -split $targetArnsString
$tgBkup = @{}
Write-Host "===> backup target groups deregistration delay"
foreach ($targetArn in $targetArns) {
    $curTimeout = aws elbv2 describe-target-group-attributes --target-group-arn $targetArn --profile $profile --region $region --query "Attributes[?starts_with(Key, 'deregistration_delay.timeout_seconds')].Value" --output text

    $tgBkup.add("$targetArn", $curTimeout)
    Write-Host "---  record $curTimeout for $targetArn"

    $settingOutput = aws elbv2 modify-target-group-attributes --target-group-arn $targetArn --profile $profile --region $region --attributes Key=deregistration_delay.timeout_seconds,Value=$tgDeregistrationDelay
    Write-Host "---  set to $tgDeregistrationDelay"
}

# get other info from autoscaling group MinSize, MaxSize, DesiredCapacity
$MinSize = aws autoscaling describe-auto-scaling-groups --profile $profile --region $region --auto-scaling-group-name $asGroup  --query 'AutoScalingGroups[*].MinSize' --output text
$MaxSize = aws autoscaling describe-auto-scaling-groups --profile $profile --region $region --auto-scaling-group-name $asGroup  --query 'AutoScalingGroups[*].MaxSize' --output text
$DesiredCapacity = aws autoscaling describe-auto-scaling-groups --profile $profile --region $region --auto-scaling-group-name $asGroup  --query 'AutoScalingGroups[*].DesiredCapacity' --output text

# check if metrics is enabled - if enabled -> disable to allow changes to params
$metricsString = aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name $asGroup --profile $profile --region $region --query "AutoScalingGroups[*].EnabledMetrics" --output text

# set MinSize to 1 less than DesiredCapacity (minimum 1) to allow for one instance in standby
if ($MinSize -eq $DesiredCapacity) {
    if ($MinSize -gt 1) {
        $newMinSize = $MinSize - 1
    } else {
        $newMinSize = 1
    }
} else {
    $newMinSize = $MinSize
}
$settingOutput = aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asGroup --profile $profile --region $region --min-size $newMinSize

foreach ($instance in $instances) {
    Write-Host "Stand-by for instance-id $instance"

    $settingOutput = aws autoscaling enter-standby --instance-ids $instance --auto-scaling-group-name $asGroup --should-decrement-desired-capacity --profile $profile --region $region

    $timer = 0
    Write-Host "===> drain instance - draining period set to $tgDeregistrationDelay seconds"
    do {
        $instanceStatus = aws autoscaling describe-auto-scaling-instances --instance-ids $instance --profile $profile --region $region --query "AutoScalingInstances[*].LifecycleState" --output text

        if ($instanceStatus -eq "Standby") {
            Write-Host "===> Standby reached [$timer s]"
            break
        } else {
            Write-Host "Processing Standby [$timer s] || status reported $instanceStatus"
            if ($timer -le $timeout) {
                Start-Sleep -Seconds $intervalSeconds
            } else {
                Write-Host "---  Process timed out after [$timer s]"
                exit 1
            }
        }
        $timer = $timer + $intervalSeconds
    } while (1)

    Write-Host "===> Instance-id $instance in stand-by mode"
    $instanceIp = aws ec2 describe-instances --instance-ids $Instance --profile $profile --region $region --query "Reservations[*].Instances[*].NetworkInterfaces[*].PrivateIpAddresses[*].PrivateIpAddress" --output text
    
    Write-Host "===> credentials for $instanceIp"
    Write-Host "---- retrieve password"
    $password = aws ec2 get-password-data --instance-id $instance --region $region --profile $profile --priv-launch-key $keyFile --output text --query "PasswordData"

    if ($password -eq "") {
        Write-Host "---- !!!  password couldn't be retrieved   !!!"
        Write-Host "---- stopping deployment"
        exit 1
    }

    $securePassword = ConvertTo-SecureString -asPlainText -Force $password
    $instanceUser = "$instanceIp\$adminUser"
    $credentials = New-Object System.Management.Automation.PSCredential -ArgumentList $instanceUser, $securePassword

    Write-Host "===> Environmet variables deploy on instance (IP $instanceIp) started"
    $psSession = New-PSSession -ComputerName $instanceIp -Credential $credentials

    if(-not($psSession)) {
        Write-Host "---- !!!  no session established   !!!"
        Write-Host "---- stopping deployment"
        exit 1
    }

    Invoke-Command -Session $psSession -ScriptBlock { C:\tna-startup\updEnv.ps1 }
    
    Write-Host "===> Getting instance back to in service mode"
    $settingOutput = aws autoscaling exit-standby --instance-ids $instance --auto-scaling-group-name $asGroup --profile $profile --region $region    

    $timer = 0
    do {
        $instanceStatus = aws autoscaling describe-auto-scaling-instances --instance-ids $instance --profile $profile --region $region --query "AutoScalingInstances[*].LifecycleState" --output text

        if ($instanceStatus -eq "InService") {
            Write-Host "===> InService reached [$timer s]"
            break
        } else {
            Write-Host "Processing InService [$timer s] || status reported $instanceStatus"
            if ($timer -le $timeout) {
                Start-Sleep -Seconds $intervalSeconds
            } else {
                Write-Host "---  Process timed out after [$timer s]"
                exit 1
            }
        }
        $timer = $timer + $intervalSeconds
    } while (1)
}

# reset autoscaling group's minimum size to initial configuration
$settingOutput = aws autoscaling update-auto-scaling-group --auto-scaling-group-name $asGroup --profile $profile --region $region --min-size $MinSize

Write-Host "===> restore target groups deregistration delay"
foreach ($arn in $tgBkup.Keys) {
    $restoreDelay = $tgBkup[$arn]
    $settingOutput = aws elbv2 modify-target-group-attributes --target-group-arn $arn --profile $profile --region $region --attributes Key=deregistration_delay.timeout_seconds,Value=$restoreDelay
    Write-Host "---  restore $arn to $restoreDelay"
}
