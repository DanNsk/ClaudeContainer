<#
.SYNOPSIS
    Gets Azure DevOps pull request information as JSON.

.DESCRIPTION
    Retrieves pull request details including threads and comments from Azure DevOps.
    Outputs JSON to stdout or file for use by Claude or other automation.

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

.PARAMETER AccessToken
    Azure DevOps access token. Falls back to SYSTEM_ACCESSTOKEN env var.

.PARAMETER OutputFile
    Path to write JSON output. If not specified, writes to stdout.

.PARAMETER FindKeyword
    Only output if keyword is found in title, description, labels, or comments.
    Handles punctuation attached to keyword (e.g., "keyword." or "keyword,").

.PARAMETER NoDeletedComments
    Filter out deleted comments from output. Default is true.

.EXAMPLE
    .\Get-AzDoPullRequest.ps1 -PullRequestUrl "https://dev.azure.com/contoso/WebApp/_git/backend/pullrequest/123" -AccessToken $token

.EXAMPLE
    .\Get-AzDoPullRequest.ps1 -Organization "contoso" -Project "WebApp" -RepositoryId "backend" -PullRequestId 123 -OutputFile "pr.json"

.EXAMPLE
    .\Get-AzDoPullRequest.ps1 -PullRequestUrl "https://dev.azure.com/contoso/WebApp/_git/backend/pullrequest/123" -FindKeyword "TODO" -AccessToken $token
#>
param(
    [string]$PullRequestUrl,

    [string]$Organization,

    [string]$Project,

    [string]$RepositoryId,

    [int]$PullRequestId,

    [string]$AccessToken,

    [string]$OutputFile,

    [string]$FindKeyword,

    [bool]$NoDeletedComments = $true
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

# Helper function to check if text contains keyword (handles punctuation)
function Test-ContainsKeyword {
    param(
        [string]$Text,
        [string]$Keyword
    )
    if (-not $Text -or -not $Keyword) { return $false }
    # Match keyword with optional punctuation before/after, case-insensitive
    $escapedKeyword = [regex]::Escape($Keyword)
    $pattern = "(?i)(?:^|[\s\p{P}])$escapedKeyword(?:[\s\p{P}]|$)"
    return $Text -match $pattern
}

$headers = @{
    Authorization = "Bearer $AccessToken"
    "Content-Type" = "application/json"
}

$baseUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryId"

# Get PR details
$prUrl = "$baseUrl/pullRequests/$PullRequestId`?api-version=7.1"
try {
    $pr = Invoke-RestMethod -Uri $prUrl -Headers $headers -Method Get
} catch {
    Write-Error "Failed to get PR: $_"
    exit 1
}

# Get threads with comments
$threadsUrl = "$baseUrl/pullRequests/$PullRequestId/threads?api-version=7.1"
try {
    $threadsResponse = Invoke-RestMethod -Uri $threadsUrl -Headers $headers -Method Get
    $threads = $threadsResponse.value
} catch {
    Write-Error "Failed to get threads: $_"
    exit 1
}

# Get labels
$labelsUrl = "$baseUrl/pullRequests/$PullRequestId/labels?api-version=7.1"
$labels = @()
try {
    $labelsResponse = Invoke-RestMethod -Uri $labelsUrl -Headers $headers -Method Get
    if ($labelsResponse.value) {
        $labels = $labelsResponse.value | ForEach-Object { $_.name }
    }
} catch {
    # Labels API might not be available, continue without
}

# Build output object
$output = @{
    pullRequestId = $pr.pullRequestId
    title = $pr.title
    description = $pr.description
    status = $pr.status
    sourceBranch = $pr.sourceRefName
    targetBranch = $pr.targetRefName
    createdBy = @{
        displayName = $pr.createdBy.displayName
        email = $pr.createdBy.uniqueName
    }
    creationDate = $pr.creationDate
    labels = $labels
    threads = @()
}

foreach ($thread in $threads) {
    $threadObj = @{
        id = $thread.id
        status = $thread.status
        filePath = $null
        lineStart = $null
        lineEnd = $null
        comments = @()
    }

    # Extract file context if present
    if ($thread.threadContext -and $thread.threadContext.filePath) {
        $threadObj.filePath = $thread.threadContext.filePath
        if ($thread.threadContext.rightFileStart) {
            $threadObj.lineStart = $thread.threadContext.rightFileStart.line
        }
        if ($thread.threadContext.rightFileEnd) {
            $threadObj.lineEnd = $thread.threadContext.rightFileEnd.line
        }
    }

    # Add comments
    foreach ($comment in $thread.comments) {
        $isDeleted = ($comment.PSObject.Properties['isDeleted'] -and $comment.isDeleted -eq $true)

        # Skip deleted comments if NoDeletedComments is true
        if ($NoDeletedComments -and $isDeleted) {
            continue
        }

        $commentObj = @{
            id = $comment.id
            author = @{
                displayName = $comment.author.displayName
                email = $comment.author.uniqueName
            }
            content = $comment.content
            createdDate = $comment.publishedDate
            deleted = $isDeleted
        }
        $threadObj.comments += $commentObj
    }

    # Only add thread if it has comments (after filtering)
    if ($threadObj.comments.Count -gt 0) {
        $output.threads += $threadObj
    }
}

# Check keyword if specified
if ($FindKeyword) {
    $keywordFound = $false

    # Check title
    if (Test-ContainsKeyword -Text $output.title -Keyword $FindKeyword) {
        $keywordFound = $true
    }

    # Check description
    if (-not $keywordFound -and (Test-ContainsKeyword -Text $output.description -Keyword $FindKeyword)) {
        $keywordFound = $true
    }

    # Check labels
    if (-not $keywordFound) {
        foreach ($label in $output.labels) {
            if (Test-ContainsKeyword -Text $label -Keyword $FindKeyword) {
                $keywordFound = $true
                break
            }
        }
    }

    # Check comments (only non-deleted, which are already filtered in output)
    if (-not $keywordFound) {
        foreach ($thread in $output.threads) {
            foreach ($comment in $thread.comments) {
                if (Test-ContainsKeyword -Text $comment.content -Keyword $FindKeyword) {
                    $keywordFound = $true
                    break
                }
            }
            if ($keywordFound) { break }
        }
    }

    # Exit without output if keyword not found (exit code 2)
    if (-not $keywordFound) {
        exit 2
    }
}

# Output JSON
$json = $output | ConvertTo-Json -Depth 10

if ($OutputFile) {
    $json | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host "Written to $OutputFile"
} else {
    Write-Output $json
}
