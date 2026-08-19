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

.PARAMETER ProcessNames
    Comma-separated process names (or `*` for all). Opts into per-process
    metrics. Off by default because cardinality scales with the host's
    process count.

.PARAMETER PersistentQueue
    'on' (default) or 'off'. When on, the exporter queue is backed by an
    on-disk file with a 64 MiB cap, so batches queued during a backend
    outage survive agent restarts.

.PARAMETER StorageDir
    Directory for the persistent-queue database.
    Default: C:\ProgramData\TracewayOtelAgent\storage.

.PARAMETER Version
    Agent version (vX.Y.Z). Set automatically when fetched via install.tracewayapp.com.
#>
[CmdletBinding()]
param(
    [string] $Token           = $env:TRACEWAY_TOKEN,
    [string] $Endpoint        = $(if ($env:TRACEWAY_ENDPOINT)      { $env:TRACEWAY_ENDPOINT }      else { 'https://cloud.tracewayapp.com/api/otel' }),
    [string] $ServiceNameAttr = $(if ($env:TRACEWAY_SERVICE_NAME)  { $env:TRACEWAY_SERVICE_NAME }  else { $env:COMPUTERNAME }),
    [string] $LogPaths        = $env:TRACEWAY_LOG_PATHS,
    [string] $ProcessNames    = $env:TRACEWAY_PROCESS_NAMES,
    [string] $PersistentQueue = $(if ($env:TRACEWAY_PERSISTENT_QUEUE) { $env:TRACEWAY_PERSISTENT_QUEUE } else { 'on' }),
    [string] $StorageDir      = $(if ($env:TRACEWAY_STORAGE_DIR)   { $env:TRACEWAY_STORAGE_DIR }   else { 'C:\ProgramData\TracewayOtelAgent\storage' }),
    [string] $Version         = $(if ($env:TRACEWAY_VERSION)       { $env:TRACEWAY_VERSION }       else { '__TRACEWAY_VERSION__' })
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

    # Optional process-metrics overlay: same pattern as logs. Empty
    # ProcessNames means the scraper stays off (the default in config.yaml);
    # `*` means all processes (no filter); anything else is an exact-match
    # include list.
    $processOverlayPath = Join-Path $ConfigDir 'process-overlay.yaml'
    $processOverlayConfigArg = ''
    if (-not [string]::IsNullOrWhiteSpace($ProcessNames)) {
        if ($ProcessNames.Trim() -eq '*') {
            $includeBlock = ''
        } else {
            $namesYaml = ($ProcessNames -split ',' |
                ForEach-Object { $_.Trim() } |
                Where-Object   { $_ } |
                ForEach-Object { "          - ""$_""" }) -join "`n"
            $includeBlock = @"
        include:
          match_type: strict
          names:
$namesYaml
"@
        }
        $processOverlayContent = @"
# Traceway OTel Agent -- process-metrics overlay, generated by install.ps1 on $(Get-Date -Format 'o').
# Merged on top of config.yaml at startup via a second --config= flag.

receivers:
  hostmetrics:
    scrapers:
      process:
        mute_process_exe_error: true
        mute_process_user_error: true
        mute_process_io_error: true
$includeBlock
"@
        [System.IO.File]::WriteAllText($processOverlayPath, $processOverlayContent, [System.Text.UTF8Encoding]::new($false))
        $processOverlayConfigArg = ' --config="' + $processOverlayPath + '"'
    } elseif (Test-Path $processOverlayPath) {
        Remove-Item -Force $processOverlayPath
    }

    # Persistent-queue overlay: shipped verbatim in the release archive (like
    # default.yaml) and loaded via an extra --config= flag. On by default;
    # set TRACEWAY_PERSISTENT_QUEUE=off (or -PersistentQueue off) to keep
    # the queue in-memory.
    $persistOn = ($PersistentQueue.Trim().ToLower() -notin @('off', 'false', '0'))
    $storageOverlayPath = Join-Path $ConfigDir 'storage-overlay.yaml'
    $storageOverlayConfigArg = ''
    $srcStorageOverlay = Join-Path $srcDir 'storage-overlay.yaml'
    if ($persistOn -and -not (Test-Path $srcStorageOverlay)) {
        Write-Step 'warning: this release predates the persistent queue (no storage-overlay.yaml in archive); continuing without it'
        $persistOn = $false
    }
    if ($persistOn) {
        Write-Step "installing storage overlay -> $storageOverlayPath (queue data in $StorageDir, 64 MiB cap)"
        Copy-Item -Path $srcStorageOverlay -Destination $storageOverlayPath -Force
        New-Item -ItemType Directory -Force -Path $StorageDir | Out-Null
        $storageOverlayConfigArg = ' --config="' + $storageOverlayPath + '"'
    } elseif (Test-Path $storageOverlayPath) {
        # Stale overlay from a previous persistent-queue install. The data
        # directory is left alone; it goes away with the config dir on
        # uninstall.
        Remove-Item -Force $storageOverlayPath
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
    $binArgs = '"' + $BinPath + '" --config="' + $ConfigPath + '"' + $overlayConfigArg + $processOverlayConfigArg + $storageOverlayConfigArg
    New-Service -Name $ServiceName -BinaryPathName $binArgs `
                -DisplayName 'Traceway OTel Agent' -StartupType Automatic | Out-Null
    Set-Service -Name $ServiceName -Description 'Traceway OpenTelemetry host agent'

    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    $envVars = @(
        "TRACEWAY_TOKEN=$Token",
        "TRACEWAY_ENDPOINT=$Endpoint",
        "TRACEWAY_SERVICE_NAME=$ServiceNameAttr",
        "TRACEWAY_STORAGE_DIR=$StorageDir"
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
    if ([string]::IsNullOrWhiteSpace($ProcessNames)) {
        Write-Step "note: per-process metrics are disabled (set TRACEWAY_PROCESS_NAMES=<name1,name2> or '*' and re-run to enable)."
    }
    if (-not $persistOn) {
        Write-Step 'note: persistent queue is disabled (queue is in-memory; batches pending at restart are lost).'
    }
} finally {
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
