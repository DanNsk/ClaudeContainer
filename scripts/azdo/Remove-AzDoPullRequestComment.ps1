<#
.SYNOPSIS
    Deletes a comment from an Azure DevOps pull request thread.

.DESCRIPTION
    Deletes a specific comment from a thread. The comment will be hidden in the UI.

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
    Thread ID containing the comment.

.PARAMETER CommentId
    Comment ID to delete.

.PARAMETER AccessToken
    Azure DevOps access token. Falls back to SYSTEM_ACCESSTOKEN env var.

.EXAMPLE
    .\Remove-AzDoPullRequestComment.ps1 -PullRequestUrl "https://dev.azure.com/contoso/WebApp/_git/backend/pullrequest/123" -ThreadId 7 -CommentId 1 -AccessToken $token
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
    [int]$CommentId,

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
}

$url = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryId/pullRequests/$PullRequestId/threads/$ThreadId/comments/$CommentId`?api-version=7.1"

try {
    $null = Invoke-RestMethod -Uri $url -Headers $headers -Method Delete
    Write-Output "OK"
} catch {
    Write-Error "Failed to delete comment: $_"
    exit 1
}
