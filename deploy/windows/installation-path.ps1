# Shared policy for privileged host installation. Validate before reading any
# persistent configuration or copying executable files into an existing tree.
function Assert-MoonHubInstallationPath {
  param([Parameter(Mandatory)][string]$Directory)
  $directoryPath = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
  $dataRoot = [Environment]::GetFolderPath('CommonApplicationData').TrimEnd('\')
  if ($directoryPath -match '[",\r\n]' -or (Split-Path $directoryPath -Parent) -ne $dataRoot) {
    throw 'Install into a direct child of the system ProgramData directory'
  }
  $ancestor = $directoryPath
  while ($ancestor) {
    if ((Test-Path -LiteralPath $ancestor) -and ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw 'Installation paths must not contain reparse points'
    }
    $ancestor = Split-Path $ancestor -Parent
  }
  if (-not (Test-Path -LiteralPath $directoryPath)) { return }
  if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) { throw 'Installation root must be a directory' }
  $trustedOwners = @('S-1-5-18', 'S-1-5-32-544')
  $writeRights = [Security.AccessControl.FileSystemRights]::Write -bor
    [Security.AccessControl.FileSystemRights]::Delete -bor
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
    [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
    [Security.AccessControl.FileSystemRights]::TakeOwnership
  $pending = [Collections.Generic.Stack[string]]::new()
  $pending.Push($directoryPath)
  while ($pending.Count -gt 0) {
    $entryPath = $pending.Pop()
    $entry = Get-Item -LiteralPath $entryPath -Force
    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Installation directory contains a reparse point' }
    $acl = Get-Acl -LiteralPath $entryPath
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $trustedOwners) { throw 'Installation tree has an untrusted owner; use a new private directory' }
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $descriptor.DiscretionaryAcl) { throw 'Installation tree has no access restrictions; use a new private directory' }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
      if ($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $writeRights) -and
          $rule.IdentityReference.Value -notin $trustedOwners) {
        throw 'Installation tree permits unprivileged writes; use a new private directory'
      }
    }
    if ($entry.PSIsContainer) {
      foreach ($child in Get-ChildItem -LiteralPath $entryPath -Force) { $pending.Push($child.FullName) }
    }
  }
}
