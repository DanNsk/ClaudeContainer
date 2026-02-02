# Azure DevOps PR Tools

PowerShell scripts for interacting with Azure DevOps Pull Requests from within the container.

**Location:** `C:\scripts\azdo\`

**Authentication:** All scripts use `$env:SYSTEM_ACCESSTOKEN` (Bearer token) or `-AccessToken` parameter, assume user will explicitly tell you value of the `-AccessToken` to use (if not - do not ask or pass any parameter, assume `$env:SYSTEM_ACCESSTOKEN` is set).

**Execution:** Use `powershell` or `pwsh` to run these scripts (both are available in the container).

---

## Get-AzDoPullRequest.ps1

Retrieves PR details, threads, comments, and labels as JSON.

| Parameter | Required | Description |
|-----------|----------|-------------|
| PullRequestUrl | No* | Full PR URL (parses org/project/repo/id automatically) |
| Organization | No* | Azure DevOps org name |
| Project | No* | Project name or GUID |
| RepositoryId | No* | Repository ID or name |
| PullRequestId | No* | PR number |
| AccessToken | No | Falls back to SYSTEM_ACCESSTOKEN env var |
| OutputFile | No | Path to write JSON (otherwise stdout) |
| FindKeyword | No | Only output if keyword found in title/description/labels/comments |
| NoDeletedComments | No | Filter deleted comments (default: true) |

*Either PullRequestUrl OR all of Organization/Project/RepositoryId/PullRequestId required.

**Exit codes:** 0 = success, 1 = error, 2 = keyword not found (with -FindKeyword)

```powershell
# Get PR info
C:\scripts\azdo\Get-AzDoPullRequest.ps1 -PullRequestUrl "https://dev.azure.com/org/proj/_git/repo/pullrequest/123"

# Check for @bot mention
C:\scripts\azdo\Get-AzDoPullRequest.ps1 -PullRequestUrl $prUrl -FindKeyword "@bot"
if ($LASTEXITCODE -eq 2) { Write-Host "No @bot mention found" }
```

---

## Add-AzDoPullRequest.ps1

Creates a new pull request with optional reviewers, work items, and labels.

| Parameter | Required | Description |
|-----------|----------|-------------|
| Organization | Yes | Azure DevOps org name |
| Project | Yes | Project name |
| RepositoryId | Yes | Repository ID or name |
| SourceBranch | Yes | Source branch (refs/heads/ prefix optional) |
| TargetBranch | Yes | Target branch (refs/heads/ prefix optional) |
| Title | Yes | PR title |
| Description | No | PR description |
| RequiredReviewers | No | Email addresses for required reviewers |
| OptionalReviewers | No | Email addresses for optional reviewers |
| WorkItems | No | Work item IDs to link |
| Labels | No | Labels to apply |
| IsDraft | No | Create as draft PR |
| AccessToken | No | Falls back to SYSTEM_ACCESSTOKEN env var |

**Output:** PR URL

```powershell
C:\scripts\azdo\Add-AzDoPullRequest.ps1 `
  -Organization "contoso" -Project "WebApp" -RepositoryId "backend" `
  -SourceBranch "feature/new" -TargetBranch "main" `
  -Title "Add feature" -Description "Implements X" `
  -RequiredReviewers @("reviewer@contoso.com") `
  -WorkItems @(1234) -Labels @("enhancement")
```

---

## Add-AzDoPullRequestThread.ps1

Creates a new comment thread on a PR (general or file-specific).

| Parameter | Required | Description |
|-----------|----------|-------------|
| PullRequestUrl | No* | Full PR URL |
| Organization | No* | Azure DevOps org name |
| Project | No* | Project name |
| RepositoryId | No* | Repository ID |
| PullRequestId | No* | PR number |
| Content | Yes | Comment text (markdown supported) |
| FilePath | No | File path for inline comment |
| LineStart | No | Start line (requires FilePath) |
| LineEnd | No | End line (requires FilePath) |
| Status | No | Thread status: active, fixed, wontFix, closed, byDesign, pending |
| AccessToken | No | Falls back to SYSTEM_ACCESSTOKEN env var |

**Output:** Thread ID

```powershell
# General comment
C:\scripts\azdo\Add-AzDoPullRequestThread.ps1 -PullRequestUrl $prUrl -Content "Review complete"

# Inline comment on specific lines
C:\scripts\azdo\Add-AzDoPullRequestThread.ps1 -PullRequestUrl $prUrl `
  -Content "Consider using async here" `
  -FilePath "/src/Service.cs" -LineStart 42 -LineEnd 45
```

---

## Add-AzDoPullRequestReply.ps1

Adds a reply to an existing comment thread.

| Parameter | Required | Description |
|-----------|----------|-------------|
| PullRequestUrl | No* | Full PR URL |
| Organization | No* | Azure DevOps org name |
| Project | No* | Project name |
| RepositoryId | No* | Repository ID |
| PullRequestId | No* | PR number |
| ThreadId | Yes | Thread ID to reply to |
| Content | Yes | Reply text (markdown supported) |
| ParentCommentId | No | Parent comment ID (default: 1) |
| AccessToken | No | Falls back to SYSTEM_ACCESSTOKEN env var |

**Output:** Comment ID

```powershell
C:\scripts\azdo\Add-AzDoPullRequestReply.ps1 -PullRequestUrl $prUrl -ThreadId 7 -Content "Fixed in latest commit"
```

---

## Set-AzDoPullRequestThreadStatus.ps1

Changes the status of a comment thread.

| Parameter | Required | Description |
|-----------|----------|-------------|
| PullRequestUrl | No* | Full PR URL |
| Organization | No* | Azure DevOps org name |
| Project | No* | Project name |
| RepositoryId | No* | Repository ID |
| PullRequestId | No* | PR number |
| ThreadId | Yes | Thread ID to update |
| Status | Yes | New status: active, fixed, wontFix, closed, byDesign, pending |
| AccessToken | No | Falls back to SYSTEM_ACCESSTOKEN env var |

**Output:** OK

```powershell
# Resolve a thread
C:\scripts\azdo\Set-AzDoPullRequestThreadStatus.ps1 -PullRequestUrl $prUrl -ThreadId 7 -Status "fixed"

# Reopen a thread
C:\scripts\azdo\Set-AzDoPullRequestThreadStatus.ps1 -PullRequestUrl $prUrl -ThreadId 7 -Status "active"
```

---

## Remove-AzDoPullRequestComment.ps1

Deletes a comment from a thread (marks as deleted in UI).

| Parameter | Required | Description |
|-----------|----------|-------------|
| PullRequestUrl | No* | Full PR URL |
| Organization | No* | Azure DevOps org name |
| Project | No* | Project name |
| RepositoryId | No* | Repository ID |
| PullRequestId | No* | PR number |
| ThreadId | Yes | Thread ID containing the comment |
| CommentId | Yes | Comment ID to delete |
| AccessToken | No | Falls back to SYSTEM_ACCESSTOKEN env var |

**Output:** OK

```powershell
C:\scripts\azdo\Remove-AzDoPullRequestComment.ps1 -PullRequestUrl $prUrl -ThreadId 7 -CommentId 1
```
