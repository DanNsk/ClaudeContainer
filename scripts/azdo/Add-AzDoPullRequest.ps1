<#
.SYNOPSIS
    Creates a new Azure DevOps pull request.

.DESCRIPTION
    Creates a PR with specified source/target branches, reviewers, work items, and labels.

.PARAMETER Organization
    Azure DevOps organization name or full collection URI.

.PARAMETER Project
    Project name or GUID.

.PARAMETER RepositoryId
    Repository ID or name.

.PARAMETER SourceBranch
    Source branch name (with or without refs/heads/ prefix).

.PARAMETER TargetBranch
    Target branch name (with or without refs/heads/ prefix).

.PARAMETER Title
    Pull request title.

.PARAMETER Description
    Pull request description.

.PARAMETER RequiredReviewers
    List of email addresses for required reviewers.

.PARAMETER OptionalReviewers
    List of email addresses for optional reviewers.

.PARAMETER WorkItems
    List of work item IDs to link.

.PARAMETER Labels
    List of labels to apply.

.PARAMETER IsDraft
    Create as draft PR.

.PARAMETER AccessToken
    Azure DevOps access token. Falls back to SYSTEM_ACCESSTOKEN env var.

.EXAMPLE
    .\Add-AzDoPullRequest.ps1 -Organization "contoso" -Project "WebApp" -RepositoryId "backend" -SourceBranch "feature/new-feature" -TargetBranch "main" -Title "Add new feature" -Description "This PR adds..." -RequiredReviewers @("john@contoso.com") -AccessToken $token

.EXAMPLE
    .\Add-AzDoPullRequest.ps1 -Organization "contoso" -Project "WebApp" -RepositoryId "backend" -SourceBranch "feature/bug-fix" -TargetBranch "main" -Title "Fix bug" -WorkItems @(1234, 5678) -Labels @("bug", "urgent") -AccessToken $token
#>
param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$Project,

    [Parameter(Mandatory)]
    [string]$RepositoryId,

    [Parameter(Mandatory)]
    [string]$SourceBranch,

    [Parameter(Mandatory)]
    [string]$TargetBranch,

    [Parameter(Mandatory)]
    [string]$Title,

    [string]$Description,

    [string[]]$RequiredReviewers,

    [string[]]$OptionalReviewers,

    [int[]]$WorkItems,

    [string[]]$Labels,

    [switch]$IsDraft,

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

# Normalize organization URL
if ($Organization -match '^https?://') {
    if ($Organization -match 'dev\.azure\.com/([^/]+)') {
        $Organization = $Matches[1]
    } elseif ($Organization -match '([^\.]+)\.visualstudio\.com') {
        $Organization = $Matches[1]
    }
}

# Normalize branch names
if (-not $SourceBranch.StartsWith("refs/heads/")) {
    $SourceBranch = "refs/heads/$SourceBranch"
}
if (-not $TargetBranch.StartsWith("refs/heads/")) {
    $TargetBranch = "refs/heads/$TargetBranch"
}

$headers = @{
    Authorization = "Bearer $AccessToken"
    "Content-Type" = "application/json"
}

$baseUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryId"

# Build PR creation body
$prBody = @{
    sourceRefName = $SourceBranch
    targetRefName = $TargetBranch
    title = $Title
}

if ($Description) {
    $prBody.description = $Description
}

if ($IsDraft) {
    $prBody.isDraft = $true
}

# Add work item references
if ($WorkItems -and $WorkItems.Count -gt 0) {
    $prBody.workItemRefs = @($WorkItems | ForEach-Object { @{ id = $_.ToString() } })
}

# Add labels
if ($Labels -and $Labels.Count -gt 0) {
    $prBody.labels = @($Labels | ForEach-Object { @{ name = $_ } })
}

$jsonBody = $prBody | ConvertTo-Json -Depth 5

# Create PR
$createUrl = "$baseUrl/pullRequests?api-version=7.1"
try {
    $pr = Invoke-RestMethod -Uri $createUrl -Headers $headers -Method Post -Body $jsonBody
} catch {
    Write-Error "Failed to create PR: $_"
    exit 1
}

$pullRequestId = $pr.pullRequestId

# Add reviewers if specified
function Add-Reviewer {
    param(
        [string]$Email,
        [bool]$IsRequired
    )

    # First, resolve the email to an identity
    $identityUrl = "https://vssps.dev.azure.com/$Organization/_apis/identities?searchFilter=General&filterValue=$Email&api-version=7.1"
    try {
        $identityResponse = Invoke-RestMethod -Uri $identityUrl -Headers $headers -Method Get
        if ($identityResponse.value -and $identityResponse.value.Count -gt 0) {
            $identity = $identityResponse.value[0]
            $reviewerId = $identity.id

            # Add reviewer to PR
            $reviewerUrl = "$baseUrl/pullRequests/$pullRequestId/reviewers/$reviewerId`?api-version=7.1"
            $reviewerBody = @{
                isRequired = $IsRequired
                vote = 0
            } | ConvertTo-Json

            $null = Invoke-RestMethod -Uri $reviewerUrl -Headers $headers -Method Put -Body $reviewerBody
            return $true
        } else {
            Write-Warning "Could not find identity for: $Email"
            return $false
        }
    } catch {
        Write-Warning "Failed to add reviewer $Email : $_"
        return $false
    }
}

if ($RequiredReviewers) {
    foreach ($email in $RequiredReviewers) {
        $null = Add-Reviewer -Email $email -IsRequired $true
    }
}

if ($OptionalReviewers) {
    foreach ($email in $OptionalReviewers) {
        $null = Add-Reviewer -Email $email -IsRequired $false
    }
}

# Build PR URL
$prUrl = "https://dev.azure.com/$Organization/$Project/_git/$RepositoryId/pullrequest/$pullRequestId"

Write-Output $prUrl
