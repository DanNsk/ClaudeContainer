<#
.SYNOPSIS
    Executes a Claude prompt in a container, starting it if needed.

.DESCRIPTION
    Sends a prompt to Claude Code running in the specified container.
    Automatically starts the container if not already running.
    Supports configuring allowed/denied tools, output format, model selection,
    agent selection, system prompts, and budget limits.

.PARAMETER Config
    Path to JSON config file (claude-container.json). Reads all sections.

.PARAMETER Id
    Container identifier.

.PARAMETER Prompt
    Task prompt for Claude.

.PARAMETER MountPath
    Host folder to mount at C:\source. Default: current directory.

.PARAMETER ImageName
    Docker image name with tag. Default: claude-agent:dev

.PARAMETER IdleTimeout
    Seconds of inactivity before auto-shutdown. Default: 300

.PARAMETER AuthToken
    OAuth token for Claude authentication. Default: $env:CLAUDE_CODE_OAUTH_TOKEN

.PARAMETER ApiKey
    Anthropic API key for authentication. Default: $env:ANTHROPIC_API_KEY

.PARAMETER UseBedrock
    Use AWS Bedrock instead of OAuth authentication.

.PARAMETER AwsRegion
    AWS region for Bedrock.

.PARAMETER AwsProfile
    AWS profile name for Bedrock. Default: default

.PARAMETER WatchdogNonStrict
    Detect any Claude process, not just prompt mode.

.PARAMETER AllowedTools
    Array of allowed tools. Default: Read, Glob, Grep

.PARAMETER DenyTools
    Array of explicitly denied tools.

.PARAMETER PermissionMode
    Permission handling mode. Default: dontAsk
    - dontAsk: Auto-deny tools not in AllowedTools (recommended for automation)
    - acceptEdits: Auto-accept file edits only
    - plan: Analysis only, no modifications
    - dangerouslySkip: Auto-accept everything (use with caution)

.PARAMETER OutputFormat
    Output format: text, json, or stream-json. Default: text

.PARAMETER Timeout
    Command timeout in seconds. Default: 600

.PARAMETER Model
    Model alias (sonnet, opus) or full name (e.g., claude-sonnet-4-20250514).

.PARAMETER Agent
    Agent for the session. Overrides the 'agent' setting.

.PARAMETER SystemPrompt
    System prompt to use for the session.

.PARAMETER AppendSystemPrompt
    Append to the default system prompt.

.PARAMETER MaxBudgetUsd
    Maximum dollar amount to spend on API calls.

.PARAMETER Continue
    Continue the most recent conversation in the current directory.

.PARAMETER EnvVars
    Hashtable of environment variables to pass to the container.
    Merged with config.container.envVars (CLI overrides config).

.EXAMPLE
    .\Invoke-ClaudePrompt.ps1 -Id "build-123" -Prompt "List all .cs files"
    Auto-starts container using $env:CLAUDE_CODE_OAUTH_TOKEN, mounts current directory.

.EXAMPLE
    .\Invoke-ClaudePrompt.ps1 -Config "claude-container.json" -Id "build-123" -Prompt "Review code"
    Uses settings from JSON config file.

.EXAMPLE
    .\Invoke-ClaudePrompt.ps1 -Id "build-123" -Prompt "Fix the bug" -AllowedTools Read,Glob,Grep,Edit,Write
    Executes with write permissions.
#>
param(
    [string]$Config,

    [Parameter(Mandatory)]
    [string]$Id,

    [Parameter(Mandatory)]
    [string]$Prompt,

    # Container start params
    [string]$MountPath,
    [string]$ImageName,
    [int]$IdleTimeout,
    [string]$AuthToken,
    [string]$ApiKey,
    [switch]$UseBedrock,
    [string]$AwsRegion,
    [string]$AwsProfile,
    [switch]$WatchdogNonStrict,

    # Prompt execution params
    [string[]]$AllowedTools,

    [string[]]$DenyTools,

    [ValidateSet("dontAsk", "acceptEdits", "plan", "dangerouslySkip")]
    [string]$PermissionMode,

    [ValidateSet("text", "json", "stream-json")]
    [string]$OutputFormat,

    [int]$Timeout,

    [string]$Model,

    [string]$Agent,

    [string]$SystemPrompt,

    [string]$AppendSystemPrompt,

    [decimal]$MaxBudgetUsd,

    [switch]$Continue,

    [hashtable]$EnvVars
)

$ErrorActionPreference = "Stop"

# Load config file if specified
$configData = $null
if ($Config -and (Test-Path $Config)) {
    $configData = Get-Content $Config -Raw | ConvertFrom-Json
}

# --- Container start defaults ---
if (-not $MountPath) {
    $MountPath = Get-Location
}
if (-not $AuthToken -and -not $ApiKey -and -not $UseBedrock) {
    # Try environment variables
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        $AuthToken = $env:CLAUDE_CODE_OAUTH_TOKEN
    } elseif ($env:ANTHROPIC_API_KEY) {
        $ApiKey = $env:ANTHROPIC_API_KEY
    }
}

# Ensure container is running (Start script is idempotent)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$startArgs = @{
    Id = $Id
    MountPath = $MountPath
}
if ($Config) { $startArgs.Config = $Config }
if ($ImageName) { $startArgs.ImageName = $ImageName }
if ($IdleTimeout) { $startArgs.IdleTimeout = $IdleTimeout }
if ($AuthToken) { $startArgs.AuthToken = $AuthToken }
if ($ApiKey) { $startArgs.ApiKey = $ApiKey }
if ($UseBedrock) { $startArgs.UseBedrock = $true }
if ($AwsRegion) { $startArgs.AwsRegion = $AwsRegion }
if ($AwsProfile) { $startArgs.AwsProfile = $AwsProfile }
if ($WatchdogNonStrict) { $startArgs.WatchdogNonStrict = $true }

& "$scriptDir\Start-ClaudeContainer.ps1" @startArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

# Apply defaults with config fallback
if (-not $AllowedTools -or $AllowedTools.Count -eq 0) {
    if ($configData -and $configData.tools.allowed -and $configData.tools.allowed.Count -gt 0) {
        $AllowedTools = $configData.tools.allowed
    } else {
        $AllowedTools = @("Read", "Glob", "Grep")
    }
}
if (-not $DenyTools -and $configData -and $configData.tools.denied -and $configData.tools.denied.Count -gt 0) {
    $DenyTools = $configData.tools.denied
}
if (-not $PermissionMode) {
    $PermissionMode = if ($configData -and $configData.tools.permissionMode) { $configData.tools.permissionMode } else { "dontAsk" }
}
if (-not $OutputFormat) {
    $OutputFormat = if ($configData -and $configData.output.format) { $configData.output.format } else { "text" }
}
if (-not $Timeout -or $Timeout -eq 0) {
    $Timeout = if ($configData -and $configData.output.timeout) { $configData.output.timeout } else { 600 }
}
if (-not $Model -and $configData -and $configData.model.name) {
    $Model = $configData.model.name
}
if (-not $Agent -and $configData -and $configData.model.agent) {
    $Agent = $configData.model.agent
}
if (-not $MaxBudgetUsd -and $configData -and $configData.model.maxBudgetUsd -gt 0) {
    $MaxBudgetUsd = $configData.model.maxBudgetUsd
}
if (-not $SystemPrompt -and $configData -and $configData.system.prompt) {
    $SystemPrompt = $configData.system.prompt
}
if (-not $AppendSystemPrompt -and $configData -and $configData.system.appendPrompt) {
    $AppendSystemPrompt = $configData.system.appendPrompt
}

# Merge environment variables: config first, CLI overrides
$mergedEnvVars = @{}
if ($configData -and $configData.container -and $configData.container.envVars) {
    foreach ($prop in $configData.container.envVars.PSObject.Properties) {
        $mergedEnvVars[$prop.Name] = $prop.Value
    }
}
if ($EnvVars) {
    foreach ($key in $EnvVars.Keys) {
        $mergedEnvVars[$key] = $EnvVars[$key]
    }
}

# Build command arguments
$toolsArg = $AllowedTools -join ','
# Map permission mode to CLI args
$permissionArgs = switch ($PermissionMode) {
    "dangerouslySkip" { @("--dangerously-skip-permissions") }
    default { @("--permission-mode", $PermissionMode) }
}

# Build docker exec with env vars
$cmdArgs = @("exec")

foreach ($key in $mergedEnvVars.Keys) {
    $value = $mergedEnvVars[$key]
    if ($value) {  # Skip empty values
        $cmdArgs += "-e"
        $cmdArgs += "$key=$value"
    }
}

$cmdArgs += @(
    $Id
    "claude"
    "-p"
    $Prompt
    "--allowed-tools"
    $toolsArg
    "--output-format"
    $OutputFormat
) + $permissionArgs

# Add denied tools if specified
if ($DenyTools -and $DenyTools.Count -gt 0) {
    $denyArg = $DenyTools -join ','
    $cmdArgs += "--disallowed-tools"
    $cmdArgs += $denyArg
}

# Add model if specified
if ($Model) {
    $cmdArgs += "--model"
    $cmdArgs += $Model
}

# Add agent if specified
if ($Agent) {
    $cmdArgs += "--agent"
    $cmdArgs += $Agent
}

# Add system prompt if specified
if ($SystemPrompt) {
    $cmdArgs += "--system-prompt"
    $cmdArgs += $SystemPrompt
}

# Add append system prompt if specified
if ($AppendSystemPrompt) {
    $cmdArgs += "--append-system-prompt"
    $cmdArgs += $AppendSystemPrompt
}

# Add budget limit if specified
if ($MaxBudgetUsd -gt 0) {
    $cmdArgs += "--max-budget-usd"
    $cmdArgs += $MaxBudgetUsd
}

# Add continue flag if specified
if ($Continue) {
    $cmdArgs += "--continue"
}


# Execute with timeout
$job = Start-Job -ScriptBlock {
    param($dockerArgs)
    & docker @dockerArgs
    $LASTEXITCODE
} -ArgumentList (,$cmdArgs)

$completed = $job | Wait-Job -Timeout $Timeout

if ($job.State -eq 'Running') {
    Stop-Job $job
    Remove-Job $job
    Write-Error "Command timed out after $Timeout seconds"
    exit 3
}

$output = Receive-Job $job
$exitCode = $output[-1]
$result = $output[0..($output.Length - 2)] -join "`n"

Remove-Job $job

Write-Output $result

if ($exitCode -ne 0) {
    exit $exitCode
}
