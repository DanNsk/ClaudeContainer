<#
.SYNOPSIS
    Adds a reply to an existing Azure DevOps pull request thread.

.DESCRIPTION
    Posts a reply comment to an existing comment thread on a PR.

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

.PARAMETER ThreadId
    Thread ID to reply to.

.PARAMETER Content
    Reply text (markdown supported).

.PARAMETER ParentCommentId
    Parent comment ID within the thread. Default: 1 (first comment)

.PARAMETER AccessToken
    Azure DevOps access token. Falls back to SYSTEM_ACCESSTOKEN env var.

.EXAMPLE
    .\Add-AzDoPullRequestReply.ps1 -PullRequestUrl "https://dev.azure.com/contoso/WebApp/_git/backend/pullrequest/123" -ThreadId 7 -Content "Good point" -AccessToken $token

.EXAMPLE
    .\Add-AzDoPullRequestReply.ps1 -Organization "contoso" -Project "WebApp" -RepositoryId "backend" -PullRequestId 123 -ThreadId 7 -Content "Will fix"
#>
param(
    [string]$PullRequestUrl,

    [string]$Organization,

    [string]$Project,

    [string]$RepositoryId,

    [int]$PullRequestId,

    [Parameter(Mandatory)]
    [int]$ThreadId,

    [Parameter(Mandatory)]
    [string]$Content,

    [int]$ParentCommentId = 1,

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

$url = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryId/pullRequests/$PullRequestId/threads/$ThreadId/comments?api-version=7.1"

$body = @{
    parentCommentId = $ParentCommentId
    content = $Content
    commentType = 1  # text
}

$jsonBody = $body | ConvertTo-Json -Depth 3

try {
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Post -Body $jsonBody
    Write-Output $response.id
} catch {
    Write-Error "Failed to add reply: $_"
    exit 1
}
