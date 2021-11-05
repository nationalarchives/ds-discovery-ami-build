<powershell>
Set-ExecutionPolicy -ExecutionPolicy bypass -Force
write-output "Running User Data Script"
write-host "(host) Running User Data Script"

# set the Windows Firewall to allow 3389 (RDP) and set the registry key to enable Remote Desktop connections
cmd.exe /c netsh advfirewall firewall add rule name="Open RDP Port 3389" dir=in action=allow protocol=TCP localport=3389
cmd.exe /c reg add "HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f

# set up WinRM
write-output "Setting up WinRM"
write-host "(host) setting up WinRM"
cmd.exe /c winrm quickconfig -q
#cmd.exe /c winrm quickconfig '-transport:http'

# open firewall for WinRM
cmd.exe /c netsh advfirewall firewall set rule group="windows remote management" new enable=yes
cmd.exe /c netsh firewall add portopening TCP 5985 "Port 5985"

cmd.exe /c winrm set "winrm/config" '@{MaxTimeoutms="1800000"}'
cmd.exe /c winrm set "winrmwinrm switche/config/winrs" '@{MaxMemoryPerShellMB="512"}'
cmd.exe /c winrm set "winrm/config/service" '@{AllowUnencrypted="true"}'
cmd.exe /c winrm set "winrm/config/client" '@{AllowUnencrypted="true"}'
cmd.exe /c winrm set "winrm/config/service/auth" '@{Basic="true"}'
cmd.exe /c winrm set "winrm/config/client/auth" '@{Basic="true"}'
cmd.exe /c winrm set "winrm/config/service/auth" '@{CredSSP="true"}'
cmd.exe /c net stop winrm
cmd.exe /c sc config winrm start= auto
cmd.exe /c net start winrm
</powershell>
<persist>true</persist>
