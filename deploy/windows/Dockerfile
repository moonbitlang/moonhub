# escape=`
# Build the bundle with scripts/build-windows-runner.ps1 first. Match the host's
# Windows build: this image is for Windows Server 2022 (build 20348) x64.
FROM mcr.microsoft.com/windows/servercore:ltsc2022
SHELL ["powershell.exe", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]
COPY . C:/moonhub/
RUN Copy-Item C:/Windows/System32/tar.exe C:/moonhub/bin/tar.exe; `
    & C:/moonhub/install-vc-runtime.ps1; `
    Remove-Item C:/moonhub/vc_redist.x64.exe; `
    New-Item -ItemType Directory C:/workspace | Out-Null; `
    & icacls.exe C:\workspace /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null; `
    if ($LASTEXITCODE -ne 0) { throw 'Workspace ACL failed' }
ENV PATH="C:\moonhub\bin;C:\moonhub\pwsh;C:\moonhub\git\cmd;C:\moonhub\git\usr\bin;C:\Windows\System32;C:\Windows;C:\Windows\System32\WindowsPowerShell\v1.0"
USER ContainerUser
WORKDIR C:/workspace
ENTRYPOINT ["C:\\moonhub\\bin\\moonhub-runner.exe", "execute"]
