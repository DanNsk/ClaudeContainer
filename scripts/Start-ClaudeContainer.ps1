<#
.SYNOPSIS
    Starts a Claude Code container.

.DESCRIPTION
    Starts a detached Claude container with the specified mount path and authentication.
    The container runs a watchdog that auto-shuts down after idle timeout.

.PARAMETER Config
    Path to JSON config file (claude-container.json). Reads image, container, auth sections.

.PARAMETER Id
    Container identifier (used as container name).

.PARAMETER MountPath
    Host folder (typically a git repo) to mount at C:\source.

.PARAMETER ImageName
    Docker image name with tag. Default: claude-agent:dev

.PARAMETER IdleTimeout
    Seconds of inactivity before auto-shutdown. Default: 300

.PARAMETER AuthToken
    OAuth token for Claude authentication. Sets CLAUDE_CODE_OAUTH_TOKEN env var.
    Obtain via 'claude setup-token' command.

.PARAMETER ApiKey
    Anthropic API key for authentication. Sets ANTHROPIC_API_KEY env var.

.PARAMETER UseBedrock
    Use AWS Bedrock instead of OAuth authentication.

.PARAMETER AwsRegion
    AWS region for Bedrock. Required when UseBedrock is specified.

.PARAMETER AwsProfile
    AWS profile name for Bedrock. Default: default

.PARAMETER Silent
    Suppress all informational output. No messages, no container ID output.

.EXAMPLE
    .\Start-ClaudeContainer.ps1 -Id "build-123" -MountPath "C:\repos\myproject" -AuthToken $env:CLAUDE_CODE_OAUTH_TOKEN
    Starts container with OAuth token authentication.

.EXAMPLE
    .\Start-ClaudeContainer.ps1 -Id "build-123" -MountPath "C:\repos\myproject" -ApiKey $env:ANTHROPIC_API_KEY
    Starts container with API key authentication.

.EXAMPLE
    .\Start-ClaudeContainer.ps1 -Config "claude-container.json" -Id "build-123" -MountPath "C:\repos\myproject" -AuthToken $token
    Starts container using settings from JSON config file.

.EXAMPLE
    .\Start-ClaudeContainer.ps1 -Id "build-123" -MountPath "C:\repos\myproject" -UseBedrock -AwsRegion "us-east-1"
    Starts container with AWS Bedrock authentication.
#>
param(
    [string]$Config,

    [Parameter(Mandatory)]
    [string]$Id,

    [Parameter(Mandatory)]
    [string]$MountPath,

    [string]$ImageName,

    [int]$IdleTimeout,

    [string]$AuthToken,

    [string]$ApiKey,

    [switch]$UseBedrock,

    [string]$AwsRegion,

    [string]$AwsProfile,

    [switch]$WatchdogNonStrict,

    [switch]$Silent
)

$ErrorActionPreference = "Stop"

# Load config file if specified
$configData = $null
if ($Config -and (Test-Path $Config)) {
    $configData = Get-Content $Config -Raw | ConvertFrom-Json
}

# Apply defaults with config fallback
if (-not $ImageName) {
    if ($configData -and $configData.image.name -and $configData.image.tag) {
        $ImageName = "$($configData.image.name):$($configData.image.tag)"
    } else {
        $ImageName = "claude-agent:dev"
    }
}
if (-not $IdleTimeout -or $IdleTimeout -eq 0) {
    $IdleTimeout = if ($configData -and $configData.container.idleTimeout) { $configData.container.idleTimeout } else { 300 }
}
if (-not $UseBedrock -and $configData -and $configData.auth.useBedrock) {
    $UseBedrock = $configData.auth.useBedrock
}
if (-not $AwsRegion -and $configData -and $configData.auth.awsRegion) {
    $AwsRegion = $configData.auth.awsRegion
}
if (-not $AwsProfile) {
    $AwsProfile = if ($configData -and $configData.auth.awsProfile) { $configData.auth.awsProfile } else { "default" }
}

# Validate mount path exists
if (-not (Test-Path $MountPath)) {
    Write-Error "Mount path does not exist: $MountPath"
    exit 1
}

# Validate authentication - require exactly one method
$authMethods = @($AuthToken, $ApiKey, $UseBedrock) | Where-Object { $_ }
if ($authMethods.Count -eq 0) {
    Write-Error "Authentication required: -AuthToken, -ApiKey, or -UseBedrock"
    exit 1
}
if ($authMethods.Count -gt 1) {
    Write-Error "Only one authentication method allowed: -AuthToken, -ApiKey, or -UseBedrock"
    exit 1
}

if ($UseBedrock) {
    if (-not $AwsRegion) {
        Write-Error "AwsRegion is required when using Bedrock authentication"
        exit 1
    }
    $awsCredsPath = "$env:USERPROFILE\.aws"
    if (-not (Test-Path $awsCredsPath)) {
        Write-Error "AWS credentials not found at $awsCredsPath"
        exit 1
    }
}

# Check if container already exists
$existing = docker ps -aq --filter "name=^${Id}$" 2>$null
if ($existing) {
    $running = docker inspect -f '{{.State.Running}}' $Id 2>$null
    if ($running -eq 'true') {
        if (-not $Silent) { Write-Host "Container $Id is already running" -ForegroundColor Yellow }
        if (-not $Silent) { Write-Output $Id }
        exit 0
    }
    # Container exists but stopped - remove it
    if (-not $Silent) { Write-Host "Removing stopped container $Id" -ForegroundColor Yellow }
    docker rm $Id | Out-Null
}

if (-not $Silent) { Write-Host "Starting Claude container: $Id" }

# Build docker run arguments
$dockerArgs = @(
    "run", "-d",
    "--name", $Id,
    "-v", "${MountPath}:C:\source",
    "-e", "IDLE_TIMEOUT=$IdleTimeout"
)

if ($WatchdogNonStrict) {
    $dockerArgs += "-e", "WATCHDOG_STRICT=false"
}

if ($UseBedrock) {
    $dockerArgs += "-e", "CLAUDE_CODE_USE_BEDROCK=1"
    $dockerArgs += "-e", "AWS_REGION=$AwsRegion"
    $dockerArgs += "-e", "AWS_PROFILE=$AwsProfile"
    $dockerArgs += "-v", "${env:USERPROFILE}\.aws:C:\Users\ContainerUser\.aws:ro"
} elseif ($ApiKey) {
    $dockerArgs += "-e", "ANTHROPIC_API_KEY=$ApiKey"
} else {
    $dockerArgs += "-e", "CLAUDE_CODE_OAUTH_TOKEN=$AuthToken"
}

$dockerArgs += $ImageName

# Start container
if ($Silent) {
    & docker @dockerArgs | Out-Null
} else {
    & docker @dockerArgs
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to start container"
    exit $LASTEXITCODE
}

# Wait for container to be ready
$maxWait = 30
$waited = 0

while ($waited -lt $maxWait) {
    $status = docker inspect -f '{{.State.Running}}' $Id 2>$null
    if ($status -eq 'true') {
        break
    }
    Start-Sleep -Seconds 1
    $waited++
}

if ($waited -ge $maxWait) {
    Write-Error "Container failed to start within $maxWait seconds"
    docker logs $Id
    exit 1
}

if (-not $Silent) {
    Write-Host "Container $Id is running" -ForegroundColor Green
    Write-Output $Id
}
