#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Install Traceway OTel Agent on Windows.

.DESCRIPTION
    $env:TRACEWAY_TOKEN = "<your-token>"
    iwr -useb https://install.tracewayapp.com/install.ps1 | iex

.PARAMETER Token
    Traceway project token. Falls back to $env:TRACEWAY_TOKEN.

.PARAMETER Endpoint
    OTLP/HTTP base URL. Default: https://cloud.tracewayapp.com/api/otel.

.PARAMETER ServiceNameAttr
    service.name resource attribute. Default: computer name.

.PARAMETER LogPaths
    Comma-separated globs to tail. Enables logs pipeline when set.

.PARAMETER Version
    Agent version (vX.Y.Z). Set automatically when fetched via install.tracewayapp.com.
#>
[CmdletBinding()]
param(
    [string] $Token           = $env:TRACEWAY_TOKEN,
    [string] $Endpoint        = $(if ($env:TRACEWAY_ENDPOINT)     { $env:TRACEWAY_ENDPOINT }     else { 'https://cloud.tracewayapp.com/api/otel' }),
    [string] $ServiceNameAttr = $(if ($env:TRACEWAY_SERVICE_NAME) { $env:TRACEWAY_SERVICE_NAME } else { $env:COMPUTERNAME }),
    [string] $LogPaths        = $env:TRACEWAY_LOG_PATHS,
    [string] $Version         = $(if ($env:TRACEWAY_VERSION)      { $env:TRACEWAY_VERSION }      else { '__TRACEWAY_VERSION__' })
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step($msg) { Write-Host "traceway-install: $msg" }

# __TRACEWAY_VERSION__ is replaced by publish-install.yml when served from install.tracewayapp.com.
if ([string]::IsNullOrWhiteSpace($Version) -or $Version -eq '__TRACEWAY_VERSION__' -or $Version -eq '__NOT_RELEASED__') {
    throw 'this installer has not been released yet. Check https://github.com/tracewayapp/traceway-otel-agent/releases, then re-run with -Version vX.Y.Z.'
}
if ([string]::IsNullOrWhiteSpace($Token)) {
    throw 'TRACEWAY_TOKEN is required (your Traceway project token).'
}

if (-not [System.Environment]::Is64BitOperatingSystem) {
    throw 'only 64-bit Windows is supported.'
}

$Repo         = 'tracewayapp/traceway-otel-agent'
$Arch         = 'amd64'
$Os           = 'windows'
$Archive      = "traceway-otel-agent_${Version}_${Os}_${Arch}.zip"
$ArchiveUrl   = "https://github.com/$Repo/releases/download/$Version/$Archive"
$ChecksumsUrl = "https://github.com/$Repo/releases/download/$Version/checksums.txt"

$InstallDir = 'C:\Program Files\TracewayOtelAgent'
$ConfigDir  = 'C:\ProgramData\TracewayOtelAgent'
$BinPath    = Join-Path $InstallDir 'traceway-otel-agent.exe'
$ConfigPath = Join-Path $ConfigDir 'config.yaml'
$ServiceName = 'TracewayOtelAgent'

$Tmp = Join-Path $env:TEMP ("traceway-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

try {
    Write-Step "downloading $ArchiveUrl"
    $ArchivePath = Join-Path $Tmp $Archive
    Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $ArchivePath

    Write-Step 'verifying sha256'
    $ChecksumsPath = Join-Path $Tmp 'checksums.txt'
    Invoke-WebRequest -UseBasicParsing -Uri $ChecksumsUrl -OutFile $ChecksumsPath

    $expectedLine = Get-Content $ChecksumsPath |
        Where-Object { $_ -match ("\s\*?" + [Regex]::Escape($Archive) + '$') } |
        Select-Object -First 1
    if (-not $expectedLine) { throw "no checksum entry for $Archive" }
    $expected = ($expectedLine -split '\s+')[0].ToLower()
    $actual = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLower()
    if ($expected -ne $actual) { throw "checksum mismatch for ${Archive}: expected $expected, got $actual" }

    Write-Step 'unpacking'
    Expand-Archive -Path $ArchivePath -DestinationPath $Tmp -Force
    $srcDir = Join-Path $Tmp "traceway-otel-agent_${Version}_${Os}_${Arch}"
    $srcBin = Join-Path $srcDir 'traceway-otel-agent.exe'
    $srcConfig = Join-Path $srcDir 'default.yaml'
    if (-not (Test-Path $srcBin)) { throw "binary not found at $srcBin" }
    if (-not (Test-Path $srcConfig)) { throw "default.yaml not found at $srcConfig (malformed release tarball)" }

    Write-Step "installing binary -> $BinPath"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -Path $srcBin -Destination $BinPath -Force

    Write-Step "installing config -> $ConfigPath"
    # The collector config is config/default.yaml, shipped verbatim in the
    # release tarball. Keeping it as the single source of truth avoids the
    # inline-YAML drift bugs we used to have (missing *.utilization opt-ins,
    # platform-specific resourcedetection lists).
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    Copy-Item -Path $srcConfig -Destination $ConfigPath -Force

    # Optional logs overlay: merged at collector startup via a second
    # --config= flag. Only the filelog receiver + logs pipeline live here;
    # everything else comes from config.yaml.
    $overlayPath = Join-Path $ConfigDir 'logs-overlay.yaml'
    $overlayConfigArg = ''
    if (-not [string]::IsNullOrWhiteSpace($LogPaths)) {
        $globsYaml = ($LogPaths -split ',' |
            ForEach-Object { $_.Trim() } |
            Where-Object   { $_ } |
            ForEach-Object { "      - ""$_""" }) -join "`n"
        $overlayContent = @"
# Traceway OTel Agent -- logs overlay, generated by install.ps1 on $(Get-Date -Format 'o').
# Merged on top of config.yaml at startup via a second --config= flag.

receivers:
  filelog:
    include:
$globsYaml
    start_at: end
    include_file_path: true
    include_file_name: true

service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [memory_limiter, resourcedetection, resource, batch]
      exporters: [otlphttp]
"@
        # PS 5.1 `-Encoding UTF8` writes a BOM; use .NET to avoid it.
        [System.IO.File]::WriteAllText($overlayPath, $overlayContent, [System.Text.UTF8Encoding]::new($false))
        $overlayConfigArg = ' --config="' + $overlayPath + '"'
    } elseif (Test-Path $overlayPath) {
        Remove-Item -Force $overlayPath
    }

    # Restrict ProgramData config dir to Administrators + SYSTEM.
    $acl = Get-Acl $ConfigDir
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('BUILTIN\Administrators','FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('NT AUTHORITY\SYSTEM','FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    Set-Acl -Path $ConfigDir -AclObject $acl

    Write-Step 'registering Windows service'
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Status -ne 'Stopped') { Stop-Service -Name $ServiceName -Force }
        # sc.exe delete is PS-version-safe here: only the service name is
        # passed, no quoted command lines to mangle.
        & sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 1
    }

    # New-Service passes BinaryPathName directly to the Win32 CreateService
    # API, avoiding the sc.exe + PowerShell native-argument-quoting pitfall.
    $binArgs = '"' + $BinPath + '" --config="' + $ConfigPath + '"' + $overlayConfigArg
    New-Service -Name $ServiceName -BinaryPathName $binArgs `
                -DisplayName 'Traceway OTel Agent' -StartupType Automatic | Out-Null
    Set-Service -Name $ServiceName -Description 'Traceway OpenTelemetry host agent'

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $envVars = @(
        "TRACEWAY_TOKEN=$Token",
        "TRACEWAY_ENDPOINT=$Endpoint",
        "TRACEWAY_SERVICE_NAME=$ServiceNameAttr"
    )
    New-ItemProperty -Path $regPath -Name Environment -Value $envVars -PropertyType MultiString -Force | Out-Null

    Write-Step 'starting service'
    Start-Service -Name $ServiceName

    Write-Step 'waiting for health check on 127.0.0.1:13133'
    $ok = $false
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:13133/' -TimeoutSec 2
            if ($r.StatusCode -eq 200) { $ok = $true; break }
        } catch { }
        Start-Sleep -Seconds 1
    }
    if (-not $ok) { throw "agent failed to come up. Check the Windows event log (Source: $ServiceName)." }

    Write-Host ''
    Write-Step "traceway-otel-agent $Version is running -> shipping to $Endpoint"
    if ([string]::IsNullOrWhiteSpace($LogPaths)) {
        Write-Step 'note: logs pipeline is disabled (set TRACEWAY_LOG_PATHS and re-run to enable).'
    }
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
