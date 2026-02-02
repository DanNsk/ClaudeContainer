# Claude Container

PowerShell scripts for running Claude Code in Windows containers, designed for Azure DevOps pipelines.

## Prerequisites

- Docker with Windows containers mode (Docker Desktop or Moby/Stevedore)
- Claude Code installed locally (`claude` command works)
- Authentication: OAuth token (`claude setup-token`), API key, or AWS Bedrock
- Windows Server 2022 host (for LTSC2022 containers)

## Quick Start

```powershell
# 1. Get your OAuth token (run once, store securely)
claude setup-token
# Copy the token and store as CLAUDE_CODE_OAUTH_TOKEN env var or in secret store

# 2. Build image (auth-agnostic, reusable)
.\scripts\Build-ClaudeContainer.ps1

# 3. Start container with auth token
.\scripts\Start-ClaudeContainer.ps1 -Id "test" -MountPath "C:\repos\myproject" -AuthToken $env:CLAUDE_CODE_OAUTH_TOKEN

# 4. Execute prompts
.\scripts\Invoke-ClaudePrompt.ps1 -Id "test" -Prompt "List all .cs files"

# 5. Stop container
.\scripts\Stop-ClaudeContainer.ps1 -Id "test" -Force
```

## Scripts

| Script | Purpose |
|--------|---------|
| `Build-ClaudeContainer.ps1` | Build auth-agnostic container image |
| `Start-ClaudeContainer.ps1` | Start container with auth (token, API key, or Bedrock) |
| `Invoke-ClaudePrompt.ps1` | Execute Claude prompt in running container |
| `Stop-ClaudeContainer.ps1` | Stop and remove container |

### Azure DevOps PR Scripts

Scripts in `C:\scripts\azdo\` inside the container for PR interaction:

| Script | Purpose |
|--------|---------|
| `Get-AzDoPullRequest.ps1` | Dump PR info (threads, comments, labels) as JSON |
| `Add-AzDoPullRequest.ps1` | Create new pull request |
| `Add-AzDoPullRequestThread.ps1` | Create new comment thread |
| `Add-AzDoPullRequestReply.ps1` | Reply to existing thread |
| `Set-AzDoPullRequestThreadStatus.ps1` | Change thread status (fixed, closed, active, etc.) |
| `Remove-AzDoPullRequestComment.ps1` | Delete a comment |

**Get-AzDoPullRequest.ps1 Options:**
- `-FindKeyword "text"` - Only output if keyword found in title/description/labels/comments
- `-NoDeletedComments $true` (default) - Filter out deleted comments
- Exit code 2 when keyword not found (useful for pipeline conditions)

**Add-AzDoPullRequest.ps1 Options:**
- `-SourceBranch`, `-TargetBranch` - Branch names (auto-prefixes refs/heads/)
- `-RequiredReviewers`, `-OptionalReviewers` - Email arrays
- `-WorkItems` - Array of work item IDs to link
- `-Labels` - Array of label names
- Returns the PR URL

**Requirements:**
- `SYSTEM_ACCESSTOKEN` environment variable (pass via `-EnvVars`)
- Organization accepts name or full URL (e.g., `contoso` or `https://dev.azure.com/contoso/`)
- RepositoryId accepts repository name or GUID

## JSON Configuration

All scripts support a `-Config` parameter for centralized configuration via JSON file.

### Example Configuration

```json
{
  "image": {
    "name": "claude-agent",
    "tag": "dev"
  },
  "sdk": {
    "dotNetVersion": "10.0",
    "nodeVersion": "22"
  },
  "instructions": {
    "mdFiles": ["./docs/*.md"],
    "noDefaultMd": false
  },
  "extensions": {
    "mcpServers": [
      { "name": "filesystem", "transport": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "C:\\source"] },
      { "name": "remote-api", "transport": "http", "url": "https://api.example.com/mcp" }
    ],
    "marketplaces": [
      { "name": "company-plugins", "url": "https://dev.azure.com/Org/Project/_git/plugins" }
    ],
    "plugins": ["formatter@company-plugins"]
  },
  "container": {
    "idleTimeout": 300,
    "envVars": {
      "SYSTEM_ACCESSTOKEN": "",
      "CUSTOM_VAR": "value"
    }
  },
  "auth": {
    "useBedrock": false,
    "awsRegion": "",
    "awsProfile": "default"
  },
  "tools": {
    "allowed": ["Read", "Glob", "Grep", "Bash(git:*)", "Bash(dotnet:*)"],
    "denied": [],
    "permissionMode": "dontAsk"
  },
  "output": {
    "format": "text",
    "timeout": 600
  },
  "model": {
    "name": "",
    "agent": "",
    "maxBudgetUsd": 0
  },
  "system": {
    "prompt": "",
    "appendPrompt": ""
  },
  "azdo": {
    "auth": true
  }
}
```

Each script reads the sections it needs:
- **Build:** image, sdk, instructions, extensions, azdo
- **Start:** image, container, auth
- **Invoke:** tools, output, model, system

`AuthToken` and `ApiKey` stay CLI-only (security).

See `claude-container.example.json` for a complete template.

### Using Config File

```powershell
# Build with config
.\scripts\Build-ClaudeContainer.ps1 -Config "claude-container.json"

# Start with config
.\scripts\Start-ClaudeContainer.ps1 -Config "claude-container.json" -Id "test" -MountPath "C:\repo" -AuthToken $token

# Invoke with config
.\scripts\Invoke-ClaudePrompt.ps1 -Config "claude-container.json" -Id "test" -Prompt "Review code"
```

CLI parameters override config file values when both are specified.

## Build Options

```powershell
# Default build (.NET 10, Node.js 22)
.\scripts\Build-ClaudeContainer.ps1

# Specific .NET version
.\scripts\Build-ClaudeContainer.ps1 -DotNetVersion 8.0

# Specific Node.js version
.\scripts\Build-ClaudeContainer.ps1 -NodeVersion 22

# Custom MD files
.\scripts\Build-ClaudeContainer.ps1 -MdFiles "./custom/*.md"

# Custom MCP servers
.\scripts\Build-ClaudeContainer.ps1 -McpServers @("filesystem:npx:-y @modelcontextprotocol/server-filesystem C:\source")
```

### Build Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Config | - | JSON config file path |
| ImageName | claude-agent | Docker image name |
| ImageTag | dev | Docker image tag |
| BaseImage | auto | Windows base image (auto, ltsc2022, ltsc2019, ltsc2016) |
| DotNetVersion | 10.0 | .NET SDK channel (8.0, 9.0, 10.0, LTS, STS) |
| NodeVersion | 22 | Node.js major version (18, 20, 22) |
| PythonVersion | 3.12 | Python version |
| IncludeBuildTools | true | Install Visual Studio Build Tools with MSBuild |
| UseBun | - | Install Bun JavaScript runtime |
| UseUv | - | Install uv Python package manager |
| AzDoAuth | - | Configure Azure DevOps auth (git + NuGet credential provider) |
| MdFiles | ./docs/*.md | MD files to copy (fallback: ~/.claude/*.md) |
| NoDefaultMd | - | Skip creating default CLAUDE.md |
| McpServers | - | MCP server configs (name:command:args or JSON) |
| Reuse | - | Skip build if image exists |

**Base Image Auto-Detection:** When `BaseImage` is `auto` (default), the script detects the host OS version and selects the matching Windows Server Core image:
- Build 20348+ -> ltsc2022 (Windows Server 2022)
- Build 17763+ -> ltsc2019 (Windows Server 2019)
- Build 14393+ -> ltsc2016 (Windows Server 2016)

## Start Options

```powershell
# OAuth token
.\scripts\Start-ClaudeContainer.ps1 -Id "test" -MountPath "C:\repo" -AuthToken $env:CLAUDE_CODE_OAUTH_TOKEN

# API key
.\scripts\Start-ClaudeContainer.ps1 -Id "test" -MountPath "C:\repo" -ApiKey $env:ANTHROPIC_API_KEY

# AWS Bedrock
.\scripts\Start-ClaudeContainer.ps1 -Id "test" -MountPath "C:\repo" -UseBedrock -AwsRegion "us-east-1"

# Custom idle timeout
.\scripts\Start-ClaudeContainer.ps1 -Id "test" -MountPath "C:\repo" -AuthToken $token -IdleTimeout 600
```

### Start Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Config | - | JSON config file path |
| Id | (required) | Container identifier |
| MountPath | (required) | Host folder to mount at C:\source |
| ImageName | claude-agent:dev | Docker image name:tag |
| IdleTimeout | 300 | Seconds before auto-shutdown |
| AuthToken | - | OAuth token (from `claude setup-token`) |
| ApiKey | - | Anthropic API key |
| UseBedrock | - | Use AWS Bedrock authentication |
| AwsRegion | - | AWS region (required with UseBedrock) |
| AwsProfile | default | AWS profile name |

## Invoke Options

```powershell
# Default read-only tools
.\scripts\Invoke-ClaudePrompt.ps1 -Id "test" -Prompt "List all .cs files"

# With write permissions
.\scripts\Invoke-ClaudePrompt.ps1 -Id "test" -Prompt "Fix the bug" -AllowedTools Read,Glob,Grep,Edit,Write

# With model selection
.\scripts\Invoke-ClaudePrompt.ps1 -Id "test" -Prompt "Review code" -Model opus

# With budget limit
.\scripts\Invoke-ClaudePrompt.ps1 -Id "test" -Prompt "Work" -MaxBudgetUsd 5.00
```

### Invoke Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Config | - | JSON config file path |
| Id | (required) | Container identifier |
| Prompt | (required) | Task prompt for Claude |
| AllowedTools | Read,Glob,Grep | Allowed tools |
| DenyTools | - | Explicitly denied tools |
| PermissionMode | dontAsk | Permission handling (dontAsk, acceptEdits, plan, dangerouslySkip) |
| OutputFormat | text | Output format (text, json, stream-json) |
| Timeout | 600 | Command timeout in seconds |
| Model | - | Model alias or full name |
| Agent | - | Agent for the session |
| SystemPrompt | - | System prompt |
| AppendSystemPrompt | - | Append to default system prompt |
| MaxBudgetUsd | - | Maximum API spend |
| Continue | - | Continue most recent conversation |
| EnvVars | - | Hashtable of env vars for container |

## Azure DevOps Integration

### Store token as secret variable

1. Run `claude setup-token` locally
2. Copy the token
3. In Azure DevOps: Pipelines > Library > Variable Groups
4. Add `CLAUDE_CODE_OAUTH_TOKEN` as secret variable

### Pipeline example

```yaml
trigger:
  - main

pool:
  name: 'SelfHostedWindows'

variables:
  containerId: 'claude-$(Build.BuildId)'

steps:
- powershell: .\scripts\Build-ClaudeContainer.ps1 -Reuse
  displayName: 'Ensure Claude image'

- template: scripts/templates/claude-pipeline.yml
  parameters:
    containerId: $(containerId)
    authToken: $(CLAUDE_CODE_OAUTH_TOKEN)
    tasks:
    - name: 'Analyze code'
      prompt: 'Analyze /source for bugs'
      allowedTools: 'Read,Glob,Grep'
      # First task starts new conversation
    - name: 'Fix issues'
      prompt: 'Fix the critical issues you found'
      allowedTools: 'Read,Glob,Grep,Edit,Write'
      continue: true  # Preserves context from previous task
```

### Bedrock pipeline example

```yaml
- template: scripts/templates/claude-pipeline.yml
  parameters:
    containerId: $(containerId)
    useBedrock: true
    awsRegion: 'us-east-1'
    tasks:
    - name: 'Code review'
      prompt: 'Review code quality'
      allowedTools: 'Read,Glob,Grep'
```

### Using from GitHub (external repository)

Reference ClaudeContainer scripts from your Azure DevOps pipeline without copying them:

```yaml
resources:
  repositories:
  - repository: claude
    type: github
    name: YourGitHubUser/ClaudeContainer
    # endpoint: 'GitHubConnection'  # Optional for public repos

trigger:
  - main

pool:
  name: 'SelfHostedWindows'

variables:
  containerId: 'claude-$(Build.BuildId)'

steps:
- checkout: self           # Your repo -> $(Build.SourcesDirectory)
- checkout: claude         # ClaudeContainer -> $(Build.SourcesDirectory)/ClaudeContainer

- powershell: .\ClaudeContainer\scripts\Build-ClaudeContainer.ps1 -Reuse
  displayName: 'Ensure Claude image'

- powershell: |
    .\ClaudeContainer\scripts\Start-ClaudeContainer.ps1 -Id $(containerId) -MountPath $(Build.SourcesDirectory) -AuthToken $(CLAUDE_CODE_OAUTH_TOKEN)
  displayName: 'Start container'

- powershell: |
    .\ClaudeContainer\scripts\Invoke-ClaudePrompt.ps1 -Id $(containerId) -Prompt "Review the code" -AllowedTools Read,Glob,Grep
  displayName: 'Run Claude'

- powershell: |
    .\ClaudeContainer\scripts\Stop-ClaudeContainer.ps1 -Id $(containerId) -Force
  displayName: 'Stop container'
  condition: always()
```

For private GitHub repos, create a service connection: Project Settings > Service connections > GitHub.

### Pipeline Examples

See `scripts/templates/examples/` for complete pipeline examples:

| Example | Description |
|---------|-------------|
| `claude-pr-review.yml` | Run Claude review only when PR has a specific label |
| `claude-bot-mention.yml` | Run Claude only when `@bot` is mentioned in PR comments |

### Environment Variables

Pass environment variables to the container using `envVars`:

```yaml
- template: scripts/templates/claude-pipeline.yml
  parameters:
    containerId: $(containerId)
    authToken: $(CLAUDE_CODE_OAUTH_TOKEN)
    envVars:
      SYSTEM_ACCESSTOKEN: $(System.AccessToken)
      AZDO_ORG: $(System.TeamFoundationCollectionUri)
      AZDO_PROJECT: $(System.TeamProject)
      AZDO_REPO: $(Build.Repository.Name)
      PR_ID: $(System.PullRequest.PullRequestId)
    tasks:
    - name: 'Review PR'
      prompt: 'Review code and add comments using powershell -File C:\scripts\azdo\*.ps1'
      allowedTools: 'Read,Glob,Grep,Bash(powershell:*)'
```

Or via PowerShell:

```powershell
.\scripts\Invoke-ClaudePrompt.ps1 -Id "test" -Prompt "Review" -EnvVars @{
    SYSTEM_ACCESSTOKEN = $env:SYSTEM_ACCESSTOKEN
    CUSTOM_VAR = "value"
}
```

EnvVars merge: config file values + CLI values (CLI overrides config).

## Tool Presets

| Use Case | AllowedTools |
|----------|--------------|
| Analysis (read-only) | `Read,Glob,Grep` |
| Analysis + Git/Build | `Read,Glob,Grep,Bash(git:*),Bash(dotnet:*)` |
| Editing | `Read,Glob,Grep,Edit,Write,MultiEdit` |
| Full access | Above + `Bash(*)` |

## Permission Modes

| Mode | Behavior |
|------|----------|
| `dontAsk` | Auto-deny tools not in AllowedTools (default, safe for automation) |
| `acceptEdits` | Auto-accept file edits only |
| `plan` | Analysis only, no modifications |
| `dangerouslySkip` | Auto-accept everything (use with caution) |

## Auto-Shutdown

Containers include a watchdog that monitors for Claude activity. When idle for the configured timeout (default 300 seconds), the container shuts down automatically.
