[CmdletBinding(DefaultParameterSetName='Isolate')]
param(
  [Parameter(Mandatory,ParameterSetName='Bootstrap')]
  [ValidatePattern('^/moonhub-runner/[a-zA-Z0-9/_-]+/i-[0-9a-f]+$')][string]$BootstrapParameter,
  [Parameter(Mandatory,ParameterSetName='Bootstrap')]
  [ValidatePattern('^[a-z0-9-]+$')][string]$Region,
  [Parameter(Mandatory,ParameterSetName='Isolate')][switch]$Isolate,
  [Parameter(Mandatory,ParameterSetName='Start')]
  [ValidatePattern('^[1-9][0-9]{0,18}$')][string]$StartJob,
  [Parameter(Mandatory,ParameterSetName='Run')]
  [ValidatePattern('^[1-9][0-9]{0,18}$')][string]$RunJob
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\ProgramData\MoonHub'
$runner = 'C:\moonhub\bin\moonhub-runner.exe'
$shell = 'C:\moonhub\pwsh\pwsh.exe'
$script = 'C:\moonhub\ci-host.ps1'
$marker = "$root\vm\isolated"
$task = 'MoonHubWindowsVmJob'
$bootstrap = "$root\private\bootstrap.json"

if ($PSCmdlet.ParameterSetName -eq 'Run') {
  $job = "$root\workspace\$RunJob"
  $dispatch = Get-Content "$job\dispatch.json" -Raw | ConvertFrom-Json
  Remove-Item "$job\dispatch.json" -Force
  $start = [Diagnostics.ProcessStartInfo]::new($runner)
  $start.UseShellExecute = $false
  $start.RedirectStandardInput = $true
  foreach ($argument in @('execute','--windows-vm','--server',$dispatch.server,
      '--assignment',"$job\assignment.json",'--workspace',"$job\job")) {
    $start.ArgumentList.Add($argument)
  }
  if ($dispatch.allow_http) { $start.ArgumentList.Add('--allow-http') }
  $executor = [Diagnostics.Process]::Start($start)
  try {
    $executor.StandardInput.WriteLine($dispatch.token)
    $executor.StandardInput.Close()
    $executor.WaitForExit()
    exit $executor.ExitCode
  } finally {
    $executor.Dispose()
  }
}

if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
  throw 'Windows VM bootstrap and dispatch require the guest SYSTEM service'
}

if ($PSCmdlet.ParameterSetName -eq 'Bootstrap') {
  $os = Get-CimInstance Win32_OperatingSystem
  if ($os.BuildNumber -ne '26100' -or $os.ProductType -ne 3 -or
      $env:PROCESSOR_ARCHITECTURE -ne 'AMD64' -or
      (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name ContainerType -ErrorAction SilentlyContinue)) {
    throw 'Expected a native Windows Server 2025 x64 guest'
  }
  if ((Test-Path $marker) -or (Test-Path "$root\workspace\ci-consumed")) {
    throw 'This guest has already been commissioned'
  }
  New-Item -ItemType Directory -Path "$root\private" -Force | Out-Null
  & icacls.exe "$root\private" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Cannot secure the guest bootstrap directory' }
  if ((Get-ScheduledTask -TaskName 'MoonHubWindowsVmWorker' -ErrorAction SilentlyContinue).State -eq 'Running') { return }
  $json = & aws.exe ssm get-parameter --region $Region --name $BootstrapParameter --with-decryption --query Parameter.Value --output text
  if ($LASTEXITCODE -ne 0) { throw 'Cannot retrieve the guest bootstrap' }
  [IO.File]::WriteAllText($bootstrap, ($json -join [Environment]::NewLine))
  $action = New-ScheduledTaskAction -Execute $runner -Argument "worker --bootstrap-file $bootstrap"
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName 'MoonHubWindowsVmWorker' -Action $action -User 'SYSTEM' -RunLevel Highest -Settings $settings -Force | Out-Null
  Start-ScheduledTask -TaskName 'MoonHubWindowsVmWorker'
  return
}

if ($Isolate) {
  if (Test-Path $bootstrap) { throw 'The worker still has a bootstrap file' }
  $agent = Get-Service -Name AmazonSSMAgent
  Set-Service -InputObject $agent -StartupType Disabled
  Stop-Service -InputObject $agent -Force
  if ((Get-Service -Name AmazonSSMAgent).Status -ne 'Stopped') { throw 'The SSM agent is still running' }
  foreach ($directory in @("$env:SystemRoot\System32\config\systemprofile\.aws",
      "$env:SystemRoot\System32\config\systemprofile\.docker",
      "$env:ProgramFiles\Amazon\SSM\credentials")) {
    if (Test-Path $directory) { Remove-Item $directory -Recurse -Force }
  }
  New-Item -ItemType Directory -Path "$root\vm" -Force | Out-Null
  & icacls.exe "$root\vm" /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-11:(OI)(CI)RX' | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Cannot protect the guest isolation marker' }
  New-Item -ItemType File -Path $marker -Force | Out-Null
  return
}

if (!(Test-Path $marker -PathType Leaf) -or (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)) {
  throw 'Expected an isolated guest which has never executed a job'
}
$job = "$root\workspace\$StartJob"
$dispatch = Get-Content "$job\dispatch.json" -Raw | ConvertFrom-Json
$password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) + 'a!A9'
$user = New-LocalUser -Name 'MoonHubJob' -Password (ConvertTo-SecureString $password -AsPlainText -Force)
$sid = $user.SID.Value
if (!(Get-LocalGroupMember -SID 'S-1-5-32-545' | Where-Object { $_.SID.Value -eq $sid })) {
  Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $user
}
$runLevel = 'Limited'
if ($dispatch.administrator) {
  Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $user
  $runLevel = 'Highest'
}
# The ordinary account also needs CreateSymbolicLinkW with flags=0. Scope the
# two rights to this disposable guest account and keep the administrator grant.
$policy = @'
[Unicode]
Unicode=yes
[Version]
signature="$CHICAGO$"
Revision=1
[Privilege Rights]
'@
$policy = ($policy -split '\r?\n') + @(
  "SeBatchLogonRight = *S-1-5-32-544,*$sid",
  "SeCreateSymbolicLinkPrivilege = *S-1-5-32-544,*$sid",
  ''
)
$policy = $policy -join [Environment]::NewLine
[IO.File]::WriteAllText("$root\private\job-rights.inf", $policy, [Text.Encoding]::Unicode)
& secedit.exe /configure /db "$root\private\job-rights.sdb" /cfg "$root\private\job-rights.inf" /areas USER_RIGHTS /quiet
if ($LASTEXITCODE -ne 0) { throw 'Cannot apply the job account rights' }
# The worker state root has a private DACL. Give the account traversal only.
& icacls.exe "$root\workspace" /grant ("*{0}:(X)" -f $sid) | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot grant workspace traversal' }
& icacls.exe $job /grant ("*{0}:(OI)(CI)M" -f $sid) | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot grant access to the job directory' }
New-Item -ItemType Directory -Path "$job\job" | Out-Null
$action = New-ScheduledTaskAction -Execute $shell -Argument "-NoProfile -NonInteractive -File $script -RunJob $StartJob"
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $task -Action $action -User "$env:COMPUTERNAME\$($user.Name)" -Password $password -RunLevel $runLevel -Settings $settings | Out-Null
$password = $null
$initial = (Get-ScheduledTaskInfo -TaskName $task).LastRunTime
Start-ScheduledTask -TaskName $task
while ($true) {
  Start-Sleep -Milliseconds 500
  $info = Get-ScheduledTaskInfo -TaskName $task
  $state = (Get-ScheduledTask -TaskName $task).State
  if ($info.LastRunTime -ne $initial -and $state -notin 'Running','Queued') {
    if ($info.LastTaskResult -notin 0,1) { throw 'The Windows VM executor did not report completion' }
    return
  }
}
