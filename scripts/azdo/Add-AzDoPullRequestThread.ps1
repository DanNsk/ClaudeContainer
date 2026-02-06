<#
.SYNOPSIS
    Creates a new comment thread on an Azure DevOps pull request.

.DESCRIPTION
    Adds a new top-level comment thread to a PR. Can be a general comment
    or attached to a specific file location.

.PARAMETER PullRequestUrl
    Full PR URL (e.g., https://dev.azure.com/org/proj/_git/repo/pullrequest/123).
    If provided, Organization/Project/RepositoryId/PullRequestId are ignored.

.PARAMETER Organization
    Azure DevOps organization name.

.PARAMETER Project
    Project name or GUID.

.PARAMETER RepositoryId
    Repository ID or name.

.PARAMETER PullRequestId
    Pull request number.

.PARAMETER Content
    Comment text (markdown supported).

.PARAMETER FilePath
    File path for inline comment (optional).

.PARAMETER LineStart
    Start line for inline comment (requires FilePath).

.PARAMETER LineEnd
    End line for inline comment (requires FilePath).

.PARAMETER Status
    Thread status: active, fixed, wontFix, closed, byDesign, pending. Default: active

.PARAMETER AccessToken
    Azure DevOps access token. Falls back to SYSTEM_ACCESSTOKEN env var.

.EXAMPLE
    .\Add-AzDoPullRequestThread.ps1 -PullRequestUrl "https://dev.azure.com/contoso/WebApp/_git/backend/pullrequest/123" -Content "General comment" -AccessToken $token

.EXAMPLE
    .\Add-AzDoPullRequestThread.ps1 -Organization "contoso" -Project "WebApp" -RepositoryId "backend" -PullRequestId 123 -Content "Consider async" -FilePath "/src/Auth.cs" -LineStart 42
#>
param(
    [string]$PullRequestUrl,

    [string]$Organization,

    [string]$Project,

    [string]$RepositoryId,

    [int]$PullRequestId,

    [Parameter(Mandatory)]
    [string]$Content,

    [string]$FilePath,

    [int]$LineStart,

    [int]$LineEnd,

    [ValidateSet("active", "fixed", "wontFix", "closed", "byDesign", "pending")]
    [string]$Status = "active",

    [string]$AccessToken
)

$ErrorActionPreference = "Stop"

# Resolve access token
if (-not $AccessToken) {
    $AccessToken = $env:SYSTEM_ACCESSTOKEN
}
if (-not $AccessToken) {
    Write-Error "AccessToken parameter or SYSTEM_ACCESSTOKEN environment variable is required"
    exit 1
}

# Parse URL if provided
if ($PullRequestUrl) {
    if ($PullRequestUrl -match 'https?://dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/]+)/pullrequest/(\d+)') {
        $Organization = $Matches[1]
        $Project = $Matches[2]
        $RepositoryId = $Matches[3]
        $PullRequestId = [int]$Matches[4]
    } elseif ($PullRequestUrl -match 'https?://([^\.]+)\.visualstudio\.com/([^/]+)/_git/([^/]+)/pullrequest/(\d+)') {
        $Organization = $Matches[1]
        $Project = $Matches[2]
        $RepositoryId = $Matches[3]
        $PullRequestId = [int]$Matches[4]
    } else {
        Write-Error "Invalid PR URL format: $PullRequestUrl"
        exit 1
    }
}

# Validate required parameters
if (-not $Organization -or -not $Project -or -not $RepositoryId -or -not $PullRequestId) {
    Write-Error "Either PullRequestUrl or all of Organization/Project/RepositoryId/PullRequestId are required"
    exit 1
}

$headers = @{
    Authorization = "Bearer $AccessToken"
    "Content-Type" = "application/json"
}

$url = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryId/pullRequests/$PullRequestId/threads?api-version=7.1"

# Build request body
$body = @{
    status = $Status
    comments = @(
        @{
            parentCommentId = 0
            content = $Content
            commentType = 1  # text
        }
    )
}

# Add file context if specified
if ($FilePath) {
    if (-not $FilePath.StartsWith("/")) {
        $FilePath = "/$FilePath"
    }
    $threadContext = @{
        filePath = $FilePath
    }

    if ($LineStart -gt 0) {
        $threadContext.rightFileStart = @{
            line = $LineStart
            offset = 1
        }
    }

    if ($LineEnd -gt 0) {
        $threadContext.rightFileEnd = @{
            line = $LineEnd
            offset = 1
        }
    } elseif ($LineStart -gt 0) {
        # Default end to start if only start specified
        $threadContext.rightFileEnd = @{
            line = $LineStart
            offset = 1
        }
    }

    $body.threadContext = $threadContext
}

$jsonBody = $body | ConvertTo-Json -Depth 5

try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body $jsonBody
    Write-Output $response.id
} catch {
    Write-Error "Failed to create thread: $_"
    exit 1
}
