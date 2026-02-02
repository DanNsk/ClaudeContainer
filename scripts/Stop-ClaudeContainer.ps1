<#
.SYNOPSIS
    Stops and removes a Claude container.

.DESCRIPTION
    Stops the specified container and removes it.

.PARAMETER Id
    Container identifier.

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    .\Stop-ClaudeContainer.ps1 -Id "build-123" -Force
    Immediately stops and removes the container.
#>
param(
    [Parameter(Mandatory)]
    [string]$Id,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Check container exists
$existing = docker ps -aq --filter "name=^${Id}$" 2>$null
if (-not $existing) {
    Write-Warning "Container '$Id' does not exist"
    exit 0
}

# Confirm unless -Force
if (-not $Force) {
    $confirm = Read-Host "Stop and remove container '$Id'? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Cancelled"
        exit 0
    }
}

Write-Host "Stopping container: $Id" -ForegroundColor Cyan

# Stop container
docker stop $Id 2>$null | Out-Null

# Remove container
docker rm $Id 2>$null | Out-Null

Write-Host "Container $Id stopped and removed" -ForegroundColor Green
